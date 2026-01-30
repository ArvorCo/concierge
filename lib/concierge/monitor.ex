defmodule Concierge.Monitor do
  @moduledoc """
  Monitors wacli SQLite database for new messages and dispatches to ChatHandlers.
  Runs as a GenServer with periodic polling.
  """

  use GenServer
  require Logger

  alias Concierge.{ChatPool, ConfigServer, Jid, Notifier, Reprocessor, Store, WacliDB}

  # 5 seconds
  @poll_interval 5_000
  @commands_dir Concierge.Paths.path("commands")
  @system_patterns [
    ~r/\[clawdbot\]/i,
    ~r/Concierge vai responder/i,
    ~r/Chat ativo/i,
    ~r/Nova mensagem WhatsApp/i,
    ~r/Status atual do wacli/i,
    ~r/AUTHENTICATED.*false/i,
    ~r/wacli auth/i
  ]

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  ## Server Callbacks

  @impl true
  def init(_state) do
    Logger.info("Monitor starting...")
    schedule_poll()
    schedule_catch_up_start()
    Logger.info("Monitor started, polling every #{@poll_interval}ms")
    {:ok, %{last_backlog_at: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    process_commands()

    if ConfigServer.enabled?() do
      in_hours = within_hours?()

      if in_hours do
        handle_human_messages()
        messages = check_new_messages()
        Enum.each(messages, &handle_new_message/1)
      end

      state = maybe_catch_up(state, in_hours)
      schedule_poll()
      {:noreply, state}
    else
      schedule_poll()
      {:noreply, state}
    end
  end

  def handle_info(:catch_up_start, state) do
    if ConfigServer.enabled?() and ConfigServer.get([:monitor, :backlog_catch_all_on_start], true) do
      Logger.info("Backlog catch-up on start")
      catch_up_all()
      {:noreply, %{state | last_backlog_at: unix_now()}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  ## Private Functions

  defp check_new_messages do
    # Get messages from last 30 seconds
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.to_unix()
    messages = WacliDB.recent_messages(cutoff)
    filter_system_messages(messages)
  end

  defp filter_system_messages(messages) do
    Enum.reject(messages, fn msg ->
      Enum.any?(@system_patterns, &Regex.match?(&1, msg.text))
    end)
  end

  defp handle_human_messages do
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.to_unix()
    messages = WacliDB.recent_human_messages(cutoff)

    Enum.each(messages, fn msg ->
      if should_ignore_chat?(msg) do
        :ok
      else
        case human_message?(msg) do
          true ->
            last_human = Store.last_human_response_at(msg.jid)

            if is_nil(last_human) or msg.timestamp > last_human do
              pause_duration = ConfigServer.get([:human_takeover, :auto_pause_hours], 3) * 3600
              paused_until = unix_now() + pause_duration

              Store.pause_chat(msg.jid, paused_until, "human_takeover")
              Store.record_human_takeover(msg.jid, msg.timestamp)
              Task.start(fn -> Notifier.notify_human_takeover(msg.jid, msg.chat_name) end)
            end

          false ->
            :ok
        end
      end
    end)
  end

  defp maybe_catch_up(state, in_hours) do
    enabled = ConfigServer.get([:monitor, :backlog_enabled], true)
    interval = ConfigServer.get([:monitor, :backlog_interval_seconds], 60)
    ignore_hours = ConfigServer.get([:monitor, :backlog_ignore_hours], false)

    if enabled and (in_hours or ignore_hours) do
      now = unix_now()

      if now - (state.last_backlog_at || 0) >= interval do
        backlog_window = ConfigServer.get([:monitor, :backlog_window_seconds], 600)

        if is_integer(backlog_window) and backlog_window > 0 do
          Logger.debug("Backlog scan", window_seconds: backlog_window)
          catch_up(backlog_window)
        else
          Logger.info("Backlog scan (all)")
          catch_up_all()
        end

        %{state | last_backlog_at: now}
      else
        state
      end
    else
      state
    end
  end

  defp catch_up(backlog_window) do
    cutoff = unix_now() - backlog_window
    outbound_map = WacliDB.outbound_timestamps()
    last_sender_map = latest_sender_map()

    WacliDB.latest_inbound_per_chat()
    |> Enum.each(fn msg ->
      if should_ignore_chat?(msg) or system_message?(msg.text) or
           last_sender_is_me?(msg.jid, last_sender_map) do
        :ok
      else
        if msg.timestamp >= cutoff do
          outbound_ts = Map.get(outbound_map, msg.jid)
          last_bot = Store.last_bot_response_at(msg.jid)
          latest_bot_ts = max_ts(outbound_ts, last_bot)
          last_human = Store.last_human_response_at(msg.jid)

          cond do
            is_integer(last_human) and last_human >= msg.timestamp ->
              :ok

            is_integer(latest_bot_ts) and latest_bot_ts >= msg.timestamp ->
              :ok

            true ->
              maybe_enqueue(msg)
          end
        end
      end
    end)
  end

  defp catch_up_all do
    outbound_map = WacliDB.outbound_timestamps()
    last_sender_map = latest_sender_map()

    WacliDB.latest_inbound_per_chat()
    |> Enum.each(fn msg ->
      if should_enqueue_backlog?(msg, outbound_map, last_sender_map) do
        enqueue_backlog(msg)
      else
        :ok
      end
    end)
  end

  defp maybe_enqueue(msg), do: enqueue_backlog(msg)

  defp enqueue_backlog(msg) do
    now = unix_now()
    retry_seconds = ConfigServer.get([:monitor, :backlog_retry_seconds], 300)
    last_attempt = Store.last_backlog_attempt_at(msg.jid)

    if is_integer(last_attempt) and last_attempt <= 0 do
      Store.record_backlog_attempt(msg.jid, nil)
    end

    if is_nil(last_attempt) or last_attempt == :undefined or not is_integer(last_attempt) or
         now - last_attempt >= retry_seconds do
      Store.record_backlog_attempt(msg.jid, now)

      case Store.check_process(msg.jid, msg.timestamp, msg[:msg_id]) do
        {:ok, _} ->
          {:ok, pid} = ChatPool.get_or_create(msg.jid, msg.chat_name)
          Concierge.ChatHandler.process_message(pid, msg)

        {:error, %{status: "paused"}} ->
          :ok

        {:error, %{status: "duplicate"}} ->
          {:ok, pid} = ChatPool.get_or_create(msg.jid, msg.chat_name)
          Concierge.ChatHandler.process_message(pid, msg)

        {:error, _} ->
          :ok
      end
    else
      :ok
    end
  end

  defp should_enqueue_backlog?(msg, outbound_map, last_sender_map) do
    if should_ignore_chat?(msg) or system_message?(msg.text) or msg.from_me or
         last_sender_is_me?(msg.jid, last_sender_map) do
      false
    else
      last_human = Store.last_human_response_at(msg.jid)
      outbound_ts = Map.get(outbound_map, msg.jid)
      last_bot = Store.last_bot_response_at(msg.jid)
      latest_bot_ts = max_ts(outbound_ts, last_bot)

      cond do
        is_integer(last_human) and last_human >= msg.timestamp ->
          false

        is_integer(latest_bot_ts) and latest_bot_ts >= msg.timestamp ->
          false

        true ->
          true
      end
    end
  end

  defp human_message?(msg) do
    bot_hash = Store.last_bot_response_hash(msg.jid)
    text_hash = if is_binary(msg.text), do: hash_text(msg.text), else: nil

    cond do
      is_binary(bot_hash) and bot_hash != "" and text_hash == bot_hash -> false
      true -> true
    end
  end

  defp system_message?(text) when is_binary(text) do
    Enum.any?(@system_patterns, &Regex.match?(&1, text))
  end

  defp system_message?(_), do: false

  defp handle_new_message(msg) do
    ignore_jids = ConfigServer.get([:filters, :ignore_jids], [])

    if should_ignore_chat?(msg) or ignore_jid?(msg.jid, ignore_jids) do
      :ignore
    else
      Logger.debug("New message in #{msg.chat_name}: #{String.slice(msg.text, 0, 50)}...")

      # Check if chat can process (not paused, not already processing)
      case Store.check_process(msg.jid, msg.timestamp, msg[:msg_id]) do
        {:ok, :process} ->
          # Get or create ChatHandler for this JID
          {:ok, pid} = ChatPool.get_or_create(msg.jid, msg.chat_name)

          # Send message to ChatHandler (async)
          Concierge.ChatHandler.process_message(pid, msg)

        {:ok, :queue} ->
          {:ok, pid} = ChatPool.get_or_create(msg.jid, msg.chat_name)
          Concierge.ChatHandler.process_message(pid, msg)

        {:error, reason} ->
          Logger.debug("Chat #{msg.chat_name} skipped: #{format_skip_reason(reason)}",
            jid: msg.jid
          )
      end
    end
  end

  defp ignore_jid?(jid, ignore_jids) when is_list(ignore_jids) do
    Enum.any?(ignore_jids, fn entry ->
      is_binary(entry) and (jid == entry or String.contains?(jid, entry))
    end)
  end

  defp ignore_jid?(_jid, _), do: false

  defp should_ignore_chat?(msg) do
    only_dms = ConfigServer.get([:filters, :only_dms], true)
    ignore_groups = ConfigServer.get([:filters, :ignore_groups], false)
    ignore_broadcast = ConfigServer.get([:filters, :ignore_broadcast], true)

    is_group = Jid.group?(msg.jid)
    is_broadcast = Jid.broadcast?(msg.jid)

    cond do
      ignore_broadcast and is_broadcast -> true
      ignore_groups and is_group -> true
      only_dms and (is_group or is_broadcast) -> true
      true -> false
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp schedule_catch_up_start do
    Process.send_after(self(), :catch_up_start, 2000)
  end

  defp process_commands do
    dir = Path.expand(@commands_dir)
    File.mkdir_p!(dir)

    Path.wildcard(Path.join(dir, "*.json"))
    |> Enum.each(fn path ->
      case File.read(path) do
        {:ok, content} ->
          handle_command(content)

        _ ->
          :ok
      end

      File.rm(path)
    end)
  end

  defp handle_command(content) do
    case Jason.decode(content) do
      {:ok, %{"action" => "reprocess_all"}} ->
        Logger.info("Command: reprocess_all")
        Reprocessor.reprocess_all()

      {:ok, %{"action" => "reprocess", "jid" => jid}} ->
        Logger.info("Command: reprocess", jid: jid)
        _ = Reprocessor.reprocess(jid)

      {:ok, %{"action" => "reset_all"}} ->
        Logger.info("Command: reset_all")
        Store.reset_all()

      {:ok, %{"action" => "reset", "jid" => jid}} ->
        Logger.info("Command: reset", jid: jid)
        Store.reset_chat(jid)

      _ ->
        Logger.warning("Unknown command payload")
    end
  end

  defp within_hours? do
    hours_enabled = ConfigServer.get([:hours, :enabled], false)

    if hours_enabled do
      tz = ConfigServer.get([:hours, :timezone], "UTC")
      start_hour = ConfigServer.get([:hours, :start], 0)
      end_hour = ConfigServer.get([:hours, :end], 24)
      weekdays_only = ConfigServer.get([:hours, :weekdays_only], false)

      now =
        case DateTime.now(tz) do
          {:ok, dt} -> dt
          _ -> DateTime.utc_now()
        end

      hour = now.hour
      in_window = hour >= start_hour and hour < end_hour

      if weekdays_only do
        day = Date.day_of_week(DateTime.to_date(now))
        in_window and day <= 5
      else
        in_window
      end
    else
      true
    end
  end

  defp unix_now, do: System.os_time(:second)

  defp latest_sender_map do
    WacliDB.latest_messages_per_chat()
    |> Enum.reduce(%{}, fn msg, acc ->
      Map.put(acc, msg.jid, msg.from_me)
    end)
  end

  defp last_sender_is_me?(jid, map) do
    case Map.get(map, jid) do
      true -> true
      _ -> false
    end
  end

  defp max_ts(a, b) do
    cond do
      is_integer(a) and is_integer(b) -> max(a, b)
      is_integer(a) -> a
      is_integer(b) -> b
      true -> nil
    end
  end

  defp hash_text(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp format_skip_reason(reason) do
    case reason do
      %{status: "paused", paused_until: until, reason: why} ->
        "paused(until=#{until}, reason=#{why})"

      %{status: "processing", processing_since: since} ->
        "processing(since=#{since})"

      %{status: "duplicate", last_inbound_msg_id: msg_id} ->
        "duplicate(msg_id=#{msg_id})"

      %{status: "duplicate", last_inbound_ts: ts} ->
        "duplicate(ts=#{ts})"

      _ ->
        inspect(reason)
    end
  end
end
