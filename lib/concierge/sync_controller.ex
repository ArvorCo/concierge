defmodule Concierge.SyncController do
  @moduledoc """
  Owns the wacli sync process and serializes all send operations.
  """

  use GenServer
  require Logger

  @log_file Concierge.Paths.path("logs/wacli-sync.log")
  @ensure_interval_ms 10_000

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def send_message(jid, text, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(__MODULE__, {:send, jid, text}, timeout)
  end

  ## Server Callbacks

  @impl true
  def init(_state) do
    File.mkdir_p!(Concierge.Paths.path("logs"))
    state = %{sync_task: nil}
    state = start_sync(state)
    schedule_ensure()
    {:ok, state}
  end

  @impl true
  def handle_call({:send, jid, text}, _from, state) do
    stopped_state = stop_sync(state)
    result = do_send(jid, text)
    restarted_state = start_sync(stopped_state)
    {:reply, result, restarted_state}
  end

  @impl true
  def handle_info(:ensure_sync, state) do
    schedule_ensure()
    {:noreply, start_sync(state)}
  end

  ## Internal

  defp do_send(jid, text) do
    task =
      Task.async(fn ->
        System.cmd(
          "wacli",
          ["send", "text", "--to", jid, "--message", text],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 20_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        Logger.info("Message sent via wacli", jid: jid, output: String.slice(output, 0, 200))
        :ok

      {:ok, {output, code}} ->
        Logger.error("wacli send failed: #{String.slice(output, 0, 200)}",
          jid: jid,
          code: code
        )

        {:error, {:send_failed, code, output}}

      _ ->
        _ = System.cmd("pkill", ["-f", "wacli send text"], stderr_to_stdout: true)
        {:error, :send_timeout}
    end
  end

  defp start_sync(state) do
    case sync_running?() do
      true ->
        state

      false ->
        log_path = Path.expand(@log_file)
        _ = File.open(log_path, [:append])

        Task.start(fn ->
          System.cmd(
            "wacli",
            ["sync", "--follow"],
            stderr_to_stdout: true,
            into: File.stream!(log_path, [:append])
          )
        end)

        Logger.info("wacli sync started")
        %{state | sync_task: :running}
    end
  end

  defp stop_sync(state) do
    _ = System.cmd("pkill", ["-TERM", "-f", "wacli sync --follow"], stderr_to_stdout: true)

    wait_for_sync_exit(10, 300)

    if sync_running?() do
      _ = System.cmd("pkill", ["-KILL", "-f", "wacli sync --follow"], stderr_to_stdout: true)
      wait_for_sync_exit(5, 300)
    end

    # Clear stale lock if no sync is running
    if not sync_running?() do
      lock_path = Path.expand("~/.wacli/LOCK")

      if File.exists?(lock_path) do
        File.rm(lock_path)
      end
    end

    state
  end

  defp sync_running? do
    case System.cmd("pgrep", ["-f", "wacli sync --follow"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp wait_for_sync_exit(0, _sleep_ms), do: :ok

  defp wait_for_sync_exit(attempts, sleep_ms) do
    if sync_running?() do
      Process.sleep(sleep_ms)
      wait_for_sync_exit(attempts - 1, sleep_ms)
    else
      :ok
    end
  end

  defp schedule_ensure do
    Process.send_after(self(), :ensure_sync, @ensure_interval_ms)
  end
end
