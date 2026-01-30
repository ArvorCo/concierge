defmodule Concierge.SandboxCleaner do
  @moduledoc """
  Periodically cleans up Clawdbot sandbox containers (Docker) by age.
  """

  use GenServer
  require Logger

  alias Concierge.ConfigServer

  @default_prefix "clawdbot-sbx-"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_state) do
    # Run once shortly after boot to clear accumulated sandboxes
    Process.send_after(self(), :cleanup, 5_000)
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    run_cleanup()
    schedule_cleanup()
    {:noreply, state}
  end

  defp run_cleanup do
    if ConfigServer.get([:sandbox_cleanup, :enabled], false) do
      prefix = ConfigServer.get([:sandbox_cleanup, :name_prefix], @default_prefix)
      max_age = ConfigServer.get([:sandbox_cleanup, :max_age_seconds], 3600)
      remove_running = ConfigServer.get([:sandbox_cleanup, :remove_running], false)
      dry_run = ConfigServer.get([:sandbox_cleanup, :dry_run], false)

      now = System.os_time(:second)
      ids = list_container_ids(prefix)

      ids
      |> Enum.map(&inspect_container/1)
      |> Enum.filter(&eligible_for_cleanup?(&1, now, max_age, remove_running))
      |> Enum.each(fn info ->
        action = if info.running, do: ["rm", "-f", info.id], else: ["rm", info.id]

        if dry_run do
          Logger.info("Sandbox cleanup dry run",
            id: info.id,
            name: info.name,
            running: info.running
          )
        else
          case System.cmd("docker", action, stderr_to_stdout: true) do
            {_out, 0} ->
              Logger.info("Sandbox container removed",
                id: info.id,
                name: info.name,
                running: info.running
              )

            {out, code} ->
              Logger.warning("Failed to remove sandbox container",
                id: info.id,
                name: info.name,
                code: code,
                output: String.slice(out, 0, 200)
              )
          end
        end
      end)
    else
      :ok
    end
  end

  defp list_container_ids(prefix) do
    filter = "name=#{prefix}"

    case System.cmd("docker", ["ps", "-a", "--filter", filter, "--format", "{{.ID}}"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))

      {out, _code} ->
        Logger.warning("Docker ps failed", output: String.slice(out, 0, 200))
        []
    end
  end

  defp inspect_container(id) do
    case System.cmd(
           "docker",
           [
             "inspect",
             "-f",
             "{{.Id}}|{{.Name}}|{{.State.Running}}|{{.Created}}",
             id
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        parse_inspect(out)

      {out, _code} ->
        Logger.warning("Docker inspect failed", id: id, output: String.slice(out, 0, 200))
        %{id: id, name: nil, running: false, created_at: nil}
    end
  end

  defp parse_inspect(out) do
    line = out |> String.split("\n", trim: true) |> List.first() || ""
    [id, name, running, created] = String.split(line, "|", parts: 4)

    %{
      id: id,
      name: String.trim_leading(name || "", "/"),
      running: running == "true",
      created_at: parse_created(created)
    }
  end

  defp parse_created(nil), do: nil

  defp parse_created(created) do
    case DateTime.from_iso8601(String.trim(created)) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp eligible_for_cleanup?(%{created_at: nil}, _now, _max_age, _remove_running), do: false

  defp eligible_for_cleanup?(
         %{created_at: created, running: running},
         now,
         max_age,
         remove_running
       ) do
    age = now - created

    if age >= max_age do
      if running do
        remove_running
      else
        true
      end
    else
      false
    end
  end

  defp schedule_cleanup do
    interval = ConfigServer.get([:sandbox_cleanup, :interval_seconds], 3600)
    ms = max(interval, 60) * 1000
    Process.send_after(self(), :cleanup, ms)
  end
end
