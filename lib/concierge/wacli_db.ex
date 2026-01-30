defmodule Concierge.WacliDB do
  @moduledoc """
  Serialized access to the wacli SQLite database.
  """

  use GenServer
  require Logger

  @db_path "~/.wacli/wacli.db"

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def recent_messages(cutoff_ts, limit \\ 100) do
    GenServer.call(__MODULE__, {:recent_messages, cutoff_ts, limit})
  end

  def recent_human_messages(cutoff_ts, limit \\ 100) do
    GenServer.call(__MODULE__, {:recent_human_messages, cutoff_ts, limit})
  end

  def last_message(jid) do
    GenServer.call(__MODULE__, {:last_message, jid})
  end

  def last_message_full(jid) do
    GenServer.call(__MODULE__, {:last_message_full, jid})
  end

  def latest_messages_per_chat do
    GenServer.call(__MODULE__, :latest_messages_per_chat)
  end

  def latest_inbound_per_chat do
    GenServer.call(__MODULE__, :latest_inbound_per_chat)
  end

  def outbound_timestamps do
    GenServer.call(__MODULE__, :outbound_timestamps)
  end

  def last_sender_jid(jid) do
    GenServer.call(__MODULE__, {:last_sender_jid, jid})
  end

  def context(jid, limit \\ 6) do
    GenServer.call(__MODULE__, {:context, jid, limit})
  end

  ## Server Callbacks

  @impl true
  def init(_state) do
    db_path = Path.expand(@db_path)
    Logger.info("Opening wacli DB", path: db_path)

    case :esqlite3.open(to_charlist(db_path)) do
      {:ok, conn} ->
        {:ok, %{db: conn}}

      {:error, reason} ->
        Logger.error("Failed to open wacli DB: #{inspect(reason)}")
        {:stop, {:db_error, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if conn = state[:db] do
      :esqlite3.close(conn)
    end

    :ok
  end

  @impl true
  def handle_call({:recent_messages, cutoff_ts, limit}, _from, state) do
    query = """
    SELECT chat_jid, from_me, text, ts, chat_name, sender_name, msg_id
    FROM messages
    WHERE ts > ? AND from_me = 0
    AND text IS NOT NULL AND text != ''
    AND length(text) < 1000
    ORDER BY ts DESC
    LIMIT ?
    """

    rows = :esqlite3.q(state.db, query, [cutoff_ts, limit])
    messages = parse_rows(rows)
    {:reply, messages, state}
  end

  def handle_call({:recent_human_messages, cutoff_ts, limit}, _from, state) do
    query = """
    SELECT chat_jid, from_me, text, ts, chat_name, sender_name, msg_id
    FROM messages
    WHERE ts > ? AND from_me = 1
    AND text IS NOT NULL AND text != ''
    AND length(text) < 1000
    ORDER BY ts DESC
    LIMIT ?
    """

    rows = :esqlite3.q(state.db, query, [cutoff_ts, limit])
    messages = parse_rows(rows)
    {:reply, messages, state}
  end

  def handle_call({:last_message, jid}, _from, state) do
    query = """
    SELECT from_me, text, ts
    FROM messages
    WHERE chat_jid = ?
    ORDER BY ts DESC LIMIT 1
    """

    result =
      case :esqlite3.q(state.db, query, [jid]) do
        [[from_me, text, ts]] ->
          {:ok,
           %{
             from_me: from_me == 1,
             text: to_string(text || ""),
             timestamp: ts
           }}

        _ ->
          {:ok, nil}
      end

    {:reply, result, state}
  end

  def handle_call({:last_message_full, jid}, _from, state) do
    query = """
    SELECT chat_jid, from_me, text, ts, chat_name, sender_name, msg_id
    FROM messages
    WHERE chat_jid = ?
    ORDER BY ts DESC LIMIT 1
    """

    result =
      case :esqlite3.q(state.db, query, [jid]) do
        [[jid, from_me, text, ts, chat_name, sender_name, msg_id]] ->
          {:ok,
           %{
             jid: to_string(jid),
             from_me: from_me == 1,
             text: to_string(text || ""),
             timestamp: ts,
             chat_name: to_string(chat_name || "Unknown"),
             sender_name: to_string(sender_name || "Unknown"),
             msg_id: to_string(msg_id || "")
           }}

        _ ->
          {:ok, nil}
      end

    {:reply, result, state}
  end

  def handle_call(:latest_messages_per_chat, _from, state) do
    query = """
    SELECT m.chat_jid, m.from_me, m.text, m.ts, m.chat_name, m.sender_name, m.msg_id
    FROM messages m
    INNER JOIN (
      SELECT chat_jid, MAX(ts) AS ts
      FROM messages
      WHERE text IS NOT NULL AND text != ''
      GROUP BY chat_jid
    ) t
    ON m.chat_jid = t.chat_jid AND m.ts = t.ts
    """

    rows = :esqlite3.q(state.db, query, [])
    messages = parse_rows(rows)
    {:reply, messages, state}
  end

  def handle_call(:latest_inbound_per_chat, _from, state) do
    query = """
    SELECT m.chat_jid, m.from_me, m.text, m.ts, m.chat_name, m.sender_name, m.msg_id
    FROM messages m
    INNER JOIN (
      SELECT chat_jid, MAX(ts) AS ts
      FROM messages
      WHERE from_me = 0 AND text IS NOT NULL AND text != ''
      GROUP BY chat_jid
    ) t
    ON m.chat_jid = t.chat_jid AND m.ts = t.ts
    """

    rows = :esqlite3.q(state.db, query, [])
    messages = parse_rows(rows)
    {:reply, messages, state}
  end

  def handle_call(:outbound_timestamps, _from, state) do
    query = """
    SELECT chat_jid, MAX(ts)
    FROM messages
    WHERE from_me = 1
    GROUP BY chat_jid
    """

    rows = :esqlite3.q(state.db, query, [])

    map =
      case rows do
        list when is_list(list) ->
          Enum.reduce(list, %{}, fn [jid, ts], acc ->
            Map.put(acc, to_string(jid), ts)
          end)

        _ ->
          %{}
      end

    {:reply, map, state}
  end

  def handle_call({:context, jid, limit}, _from, state) do
    query = """
    SELECT from_me, text, sender_name, ts
    FROM messages
    WHERE chat_jid = ? AND text IS NOT NULL AND text != ''
    ORDER BY ts DESC
    LIMIT ?
    """

    messages =
      case :esqlite3.q(state.db, query, [jid, limit]) do
        rows when is_list(rows) ->
          rows
          |> Enum.map(fn [from_me, text, sender, ts] ->
            %{
              from_me: from_me == 1,
              text: to_string(text || ""),
              sender: to_string(sender || ""),
              timestamp: ts
            }
          end)
          |> Enum.reverse()

        _ ->
          []
      end

    {:reply, messages, state}
  end

  def handle_call({:last_sender_jid, jid}, _from, state) do
    query = """
    SELECT sender_jid
    FROM messages
    WHERE chat_jid = ? AND sender_jid IS NOT NULL AND sender_jid != ''
    ORDER BY ts DESC LIMIT 1
    """

    result =
      case :esqlite3.q(state.db, query, [jid]) do
        [[sender_jid]] -> to_string(sender_jid || "")
        _ -> nil
      end

    sender =
      case result do
        "" -> nil
        other -> other
      end

    {:reply, sender, state}
  end

  ## Helpers

  defp parse_rows(rows) when is_list(rows) do
    Enum.map(rows, fn row ->
      case row do
        [jid, from_me, text, ts, chat_name, sender_name, msg_id] ->
          %{
            jid: to_string(jid),
            from_me: from_me == 1,
            text: to_string(text || ""),
            timestamp: ts,
            chat_name: to_string(chat_name || "Unknown"),
            sender_name: to_string(sender_name || "Unknown"),
            msg_id: to_string(msg_id || "")
          }

        [jid, from_me, text, ts, chat_name, sender_name] ->
          %{
            jid: to_string(jid),
            from_me: from_me == 1,
            text: to_string(text || ""),
            timestamp: ts,
            chat_name: to_string(chat_name || "Unknown"),
            sender_name: to_string(sender_name || "Unknown")
          }
      end
    end)
  end

  defp parse_rows(_), do: []
end
