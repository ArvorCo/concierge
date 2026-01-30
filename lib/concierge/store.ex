defmodule Concierge.Store do
  @moduledoc """
  Tracks chat state in a local SQLite database and exports tracking.json
  for human debugging. All DB access is serialized through this GenServer.
  """

  use GenServer
  require Logger

  alias Concierge.ConfigServer

  @db_path Concierge.Paths.path("tracking.db")
  @tracking_json Concierge.Paths.path("tracking.json")

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def check_process(jid, msg_ts, msg_id \\ nil),
    do: GenServer.call(__MODULE__, {:check_process, jid, msg_ts, msg_id})

  def can_process?(jid, msg_ts, msg_id \\ nil) do
    case check_process(jid, msg_ts, msg_id) do
      {:ok, :process} -> true
      _ -> false
    end
  end

  def mark_processing(jid), do: GenServer.call(__MODULE__, {:mark_processing, jid})
  def mark_active(jid), do: GenServer.call(__MODULE__, {:mark_active, jid})

  def pause_chat(jid, paused_until, reason \\ nil),
    do: GenServer.call(__MODULE__, {:pause_chat, jid, paused_until, reason})

  def record_bot_response(jid, text \\ nil),
    do: GenServer.call(__MODULE__, {:record_bot_response, jid, text})

  def record_human_takeover(jid, ts),
    do: GenServer.call(__MODULE__, {:record_human_takeover, jid, ts})

  def last_bot_response_at(jid), do: GenServer.call(__MODULE__, {:last_bot_response_at, jid})
  def last_bot_response_hash(jid), do: GenServer.call(__MODULE__, {:last_bot_response_hash, jid})
  def last_human_response_at(jid), do: GenServer.call(__MODULE__, {:last_human_response_at, jid})

  def last_backlog_attempt_at(jid),
    do: GenServer.call(__MODULE__, {:last_backlog_attempt_at, jid})

  def record_backlog_attempt(jid, ts),
    do: GenServer.call(__MODULE__, {:record_backlog_attempt, jid, ts})

  def chat_status(jid), do: GenServer.call(__MODULE__, {:chat_status, jid})
  def set_notified(jid, value), do: GenServer.call(__MODULE__, {:set_notified, jid, value})
  def notified?(jid), do: GenServer.call(__MODULE__, {:notified, jid})
  def update_chat_name(jid, name), do: GenServer.call(__MODULE__, {:update_chat_name, jid, name})

  def rate_limited?(jid, limit_per_hour),
    do: GenServer.call(__MODULE__, {:rate_limited, jid, limit_per_hour})

  def reset_chat(jid), do: GenServer.call(__MODULE__, {:reset_chat, jid})
  def reset_all, do: GenServer.call(__MODULE__, :reset_all)

  def increment_global(key), do: GenServer.call(__MODULE__, {:increment_global, key})
  def set_global(key, value), do: GenServer.call(__MODULE__, {:set_global, key, value})

  def export_tracking_json, do: GenServer.call(__MODULE__, :export_tracking_json)

  ## Server Callbacks

  @impl true
  def init(_state) do
    db_path = Path.expand(@db_path)
    File.mkdir_p!(Path.dirname(db_path))

    case :esqlite3.open(to_charlist(db_path)) do
      {:ok, conn} ->
        ensure_schema(conn)
        maybe_import_tracking_json(conn)
        export_tracking_json(conn)
        {:ok, %{db: conn}}

      {:error, reason} ->
        Logger.error("Failed to open tracking DB: #{inspect(reason)}")
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
  def handle_call({:check_process, jid, msg_ts, msg_id}, _from, state) do
    now = unix_now()
    chat = get_chat(state.db, jid)
    stale_after = ConfigServer.get([:safety, :processing_timeout_seconds], 180)

    result =
      cond do
        is_nil(chat) ->
          {:ok, :process}

        chat.status == "paused" and not is_nil(chat.paused_until) and now < chat.paused_until ->
          {:error, %{status: "paused", paused_until: chat.paused_until, reason: chat.reason}}

        is_binary(msg_id) and msg_id != "" and chat.last_inbound_msg_id == msg_id ->
          {:error, %{status: "duplicate", last_inbound_msg_id: chat.last_inbound_msg_id}}

        not is_nil(chat.last_inbound_ts) and msg_ts <= chat.last_inbound_ts and
            (is_nil(msg_id) or msg_id == "") ->
          {:error, %{status: "duplicate", last_inbound_ts: chat.last_inbound_ts}}

        chat.status == "processing" and not is_nil(chat.processing_since) and
            now - chat.processing_since > stale_after ->
          Logger.warning("Stale processing reset",
            jid: jid,
            processing_since: chat.processing_since
          )

          upsert_chat(state.db, jid, %{status: "active", processing_since: nil})
          {:ok, :process}

        chat.status == "processing" ->
          {:ok, :queue}

        true ->
          {:ok, :process}
      end

    case result do
      {:ok, _} ->
        upsert_chat(state.db, jid, %{last_inbound_ts: msg_ts, last_inbound_msg_id: msg_id})
        export_tracking_json(state.db)

      _ ->
        :ok
    end

    {:reply, result, state}
  end

  def handle_call({:mark_processing, jid}, _from, state) do
    now = unix_now()
    upsert_chat(state.db, jid, %{status: "processing", processing_since: now})
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:mark_active, jid}, _from, state) do
    upsert_chat(state.db, jid, %{status: "active", processing_since: nil})
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:pause_chat, jid, paused_until, reason}, _from, state) do
    upsert_chat(state.db, jid, %{
      status: "paused",
      paused_until: paused_until,
      reason: reason,
      processing_since: nil
    })

    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:record_bot_response, jid, text}, _from, state) do
    now = unix_now()
    chat = get_chat(state.db, jid)
    total = (chat && chat.total_bot_msgs) || 0
    hash = if is_binary(text), do: hash_text(text), else: chat && chat.last_bot_response_hash

    upsert_chat(state.db, jid, %{
      status: "active",
      last_bot_response_at: now,
      last_bot_response_hash: hash,
      processing_since: nil,
      notified: 0,
      total_bot_msgs: total + 1
    })

    :esqlite3.q(state.db, "INSERT INTO bot_responses (jid, ts) VALUES (?, ?);", [jid, now])
    increment_global(state.db, "total_responses_today")
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:record_human_takeover, jid, ts}, _from, state) do
    upsert_chat(state.db, jid, %{last_human_response_at: ts})
    increment_global(state.db, "total_human_takeovers_today")
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:last_bot_response_at, jid}, _from, state) do
    ts =
      get_chat(state.db, jid)
      |> then(fn chat -> if chat, do: chat.last_bot_response_at, else: nil end)

    {:reply, ts, state}
  end

  def handle_call({:last_bot_response_hash, jid}, _from, state) do
    value =
      get_chat(state.db, jid)
      |> then(fn chat -> if chat, do: chat.last_bot_response_hash, else: nil end)

    {:reply, value, state}
  end

  def handle_call({:last_human_response_at, jid}, _from, state) do
    value =
      get_chat(state.db, jid)
      |> then(fn chat -> if chat, do: chat.last_human_response_at, else: nil end)

    {:reply, value, state}
  end

  def handle_call({:last_backlog_attempt_at, jid}, _from, state) do
    value =
      get_chat(state.db, jid)
      |> then(fn chat -> if chat, do: chat.last_backlog_attempt_at, else: nil end)

    {:reply, value, state}
  end

  def handle_call({:record_backlog_attempt, jid, ts}, _from, state) do
    upsert_chat(state.db, jid, %{last_backlog_attempt_at: ts})
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:chat_status, jid}, _from, state) do
    chat = get_chat(state.db, jid)
    {:reply, chat, state}
  end

  def handle_call({:rate_limited, jid, limit_per_hour}, _from, state) do
    cutoff = unix_now() - 3600
    # Best-effort cleanup to keep table small
    :esqlite3.q(state.db, "DELETE FROM bot_responses WHERE ts < ?;", [cutoff - 3600])

    count =
      case :esqlite3.q(
             state.db,
             "SELECT COUNT(*) FROM bot_responses WHERE jid = ? AND ts >= ?;",
             [jid, cutoff]
           ) do
        [[value]] -> value
        _ -> 0
      end

    {:reply, count >= limit_per_hour, state}
  end

  def handle_call({:set_notified, jid, value}, _from, state) do
    upsert_chat(state.db, jid, %{notified: if(value, do: 1, else: 0)})
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:notified, jid}, _from, state) do
    notified =
      case get_chat(state.db, jid) do
        nil -> false
        %{notified: 1} -> true
        _ -> false
      end

    {:reply, notified, state}
  end

  def handle_call({:update_chat_name, jid, name}, _from, state) do
    upsert_chat(state.db, jid, %{name: name})
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:reset_chat, jid}, _from, state) do
    :esqlite3.q(
      state.db,
      """
      UPDATE chats
      SET status = 'active',
          paused_until = NULL,
          processing_since = NULL,
          last_inbound_ts = NULL,
          last_inbound_msg_id = NULL,
          last_human_response_at = NULL,
          notified = 0,
          reason = NULL
      WHERE jid = ?;
      """,
      [jid]
    )

    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call(:reset_all, _from, state) do
    :esqlite3.q(
      state.db,
      """
      UPDATE chats
      SET status = 'active',
          paused_until = NULL,
          processing_since = NULL,
          last_inbound_ts = NULL,
          last_inbound_msg_id = NULL,
          last_human_response_at = NULL,
          notified = 0,
          reason = NULL;
      """,
      []
    )

    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:increment_global, key}, _from, state) do
    increment_global(state.db, key)
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call({:set_global, key, value}, _from, state) do
    set_global(state.db, key, value)
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  def handle_call(:export_tracking_json, _from, state) do
    export_tracking_json(state.db)
    {:reply, :ok, state}
  end

  ## DB Helpers

  defp ensure_schema(conn) do
    :esqlite3.q(conn, """
    CREATE TABLE IF NOT EXISTS chats (
      jid TEXT PRIMARY KEY,
      name TEXT,
      status TEXT,
      paused_until INTEGER,
      processing_since INTEGER,
      last_bot_response_at INTEGER,
      last_bot_response_hash TEXT,
      last_inbound_ts INTEGER,
      last_inbound_msg_id TEXT,
      last_human_response_at INTEGER,
      last_backlog_attempt_at INTEGER,
      notified INTEGER DEFAULT 0,
      reason TEXT,
      total_bot_msgs INTEGER DEFAULT 0
    );
    """)

    :esqlite3.q(conn, """
    CREATE TABLE IF NOT EXISTS globals (
      key TEXT PRIMARY KEY,
      value TEXT
    );
    """)

    :esqlite3.q(conn, """
    CREATE TABLE IF NOT EXISTS bot_responses (
      jid TEXT,
      ts INTEGER
    );
    """)

    ensure_global(conn, "total_responses_today", "0")
    ensure_global(conn, "total_escalations_today", "0")
    ensure_global(conn, "total_human_takeovers_today", "0")
    ensure_global(conn, "last_updated", "null")

    ensure_column(conn, "chats", "last_inbound_msg_id", "TEXT")
    ensure_column(conn, "chats", "last_bot_response_hash", "TEXT")
    ensure_column(conn, "chats", "last_backlog_attempt_at", "INTEGER")
  end

  defp ensure_global(conn, key, value) do
    :esqlite3.q(conn, "INSERT OR IGNORE INTO globals (key, value) VALUES (?, ?);", [key, value])
  end

  defp get_chat(conn, jid) do
    case :esqlite3.q(
           conn,
           "SELECT jid, name, status, paused_until, processing_since, last_bot_response_at, last_bot_response_hash, last_inbound_ts, last_inbound_msg_id, last_human_response_at, last_backlog_attempt_at, notified, reason, total_bot_msgs FROM chats WHERE jid = ? LIMIT 1;",
           [jid]
         ) do
      [
        [
          jid,
          name,
          status,
          paused_until,
          processing_since,
          last_bot_response_at,
          last_bot_response_hash,
          last_inbound_ts,
          last_inbound_msg_id,
          last_human_response_at,
          last_backlog_attempt_at,
          notified,
          reason,
          total_bot_msgs
        ]
      ] ->
        %{
          jid: to_string(jid),
          name: to_string(name || ""),
          status: to_string(status || "active"),
          paused_until: paused_until,
          processing_since: processing_since,
          last_bot_response_at: last_bot_response_at,
          last_bot_response_hash: to_string(last_bot_response_hash || ""),
          last_inbound_ts: last_inbound_ts,
          last_inbound_msg_id: to_string(last_inbound_msg_id || ""),
          last_human_response_at: last_human_response_at,
          last_backlog_attempt_at: last_backlog_attempt_at,
          notified: notified || 0,
          reason: to_string(reason || ""),
          total_bot_msgs: total_bot_msgs || 0
        }

      _ ->
        nil
    end
  end

  defp upsert_chat(conn, jid, updates) do
    now = unix_now()
    chat = get_chat(conn, jid) || %{}

    merged = Map.merge(chat, updates)

    :esqlite3.q(
      conn,
      """
      INSERT INTO chats (
        jid, name, status, paused_until, processing_since,
        last_bot_response_at, last_bot_response_hash, last_inbound_ts, last_inbound_msg_id, last_human_response_at, last_backlog_attempt_at, notified, reason, total_bot_msgs
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(jid) DO UPDATE SET
        name = excluded.name,
        status = excluded.status,
        paused_until = excluded.paused_until,
        processing_since = excluded.processing_since,
        last_bot_response_at = excluded.last_bot_response_at,
        last_bot_response_hash = excluded.last_bot_response_hash,
        last_inbound_ts = excluded.last_inbound_ts,
        last_inbound_msg_id = excluded.last_inbound_msg_id,
        last_human_response_at = excluded.last_human_response_at,
        last_backlog_attempt_at = excluded.last_backlog_attempt_at,
        notified = excluded.notified,
        reason = excluded.reason,
        total_bot_msgs = excluded.total_bot_msgs;
      """,
      [
        jid,
        merged[:name] || "",
        merged[:status] || "active",
        merged[:paused_until],
        merged[:processing_since],
        merged[:last_bot_response_at],
        merged[:last_bot_response_hash],
        merged[:last_inbound_ts],
        merged[:last_inbound_msg_id],
        merged[:last_human_response_at],
        merged[:last_backlog_attempt_at],
        merged[:notified] || 0,
        merged[:reason],
        merged[:total_bot_msgs] || 0
      ]
    )

    set_global(conn, "last_updated", Integer.to_string(now))
  end

  defp set_global(conn, key, value) do
    :esqlite3.q(conn, "INSERT OR REPLACE INTO globals (key, value) VALUES (?, ?);", [
      key,
      to_string(value)
    ])
  end

  defp increment_global(conn, key) do
    current =
      case :esqlite3.q(conn, "SELECT value FROM globals WHERE key = ? LIMIT 1;", [key]) do
        [[value]] ->
          value
          |> to_string()
          |> String.to_integer()

        _ ->
          0
      end

    set_global(conn, key, Integer.to_string(current + 1))
  end

  defp maybe_import_tracking_json(conn) do
    path = Path.expand(@tracking_json)

    if File.exists?(path) and chats_empty?(conn) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"chats" => chats, "global" => global}} ->
              Enum.each(chats, fn {jid, attrs} ->
                upsert_chat(conn, jid, %{
                  name: attrs["name"] || "",
                  status: attrs["status"] || "active",
                  paused_until: attrs["paused_until"],
                  processing_since: attrs["processing_since"],
                  last_bot_response_at: attrs["last_bot_response_at"],
                  last_inbound_msg_id: attrs["last_inbound_msg_id"],
                  last_human_response_at: attrs["last_human_response_at"],
                  notified: if(attrs["notified"], do: 1, else: 0),
                  reason: attrs["reason"],
                  total_bot_msgs: attrs["total_bot_msgs"] || 0
                })
              end)

              Enum.each(global, fn {key, value} ->
                set_global(conn, key, value)
              end)

              Logger.info("Imported tracking.json into tracking.db")

            _ ->
              Logger.warning("Failed to parse tracking.json for import")
          end

        {:error, reason} ->
          Logger.warning("Failed to read tracking.json: #{inspect(reason)}")
      end
    end
  end

  defp chats_empty?(conn) do
    case :esqlite3.q(conn, "SELECT COUNT(*) FROM chats;", []) do
      [[count]] -> count == 0
      _ -> true
    end
  end

  defp export_tracking_json(conn) do
    chats =
      case :esqlite3.q(
             conn,
             "SELECT jid, name, status, paused_until, processing_since, last_bot_response_at, last_bot_response_hash, last_inbound_ts, last_inbound_msg_id, last_human_response_at, last_backlog_attempt_at, notified, reason, total_bot_msgs FROM chats;",
             []
           ) do
        rows when is_list(rows) ->
          Enum.reduce(rows, %{}, fn [
                                      jid,
                                      name,
                                      status,
                                      paused_until,
                                      processing_since,
                                      last_bot_response_at,
                                      last_bot_response_hash,
                                      last_inbound_ts,
                                      last_inbound_msg_id,
                                      last_human_response_at,
                                      last_backlog_attempt_at,
                                      notified,
                                      reason,
                                      total_bot_msgs
                                    ],
                                    acc ->
            Map.put(acc, to_string(jid), %{
              "name" => to_string(name || ""),
              "last_bot_response_at" => last_bot_response_at,
              "last_bot_response_hash" => to_string(last_bot_response_hash || ""),
              "last_inbound_ts" => last_inbound_ts,
              "last_inbound_msg_id" => to_string(last_inbound_msg_id || ""),
              "last_human_response_at" => last_human_response_at,
              "last_backlog_attempt_at" => last_backlog_attempt_at,
              "paused_until" => paused_until,
              "status" => to_string(status || "active"),
              "processing_since" => processing_since,
              "notified" => notified == 1,
              "reason" => reason,
              "total_bot_msgs" => total_bot_msgs || 0
            })
          end)

        _ ->
          %{}
      end

    globals =
      case :esqlite3.q(conn, "SELECT key, value FROM globals;", []) do
        rows when is_list(rows) ->
          Enum.reduce(rows, %{}, fn [key, value], acc ->
            Map.put(acc, to_string(key), normalize_value(value))
          end)

        _ ->
          %{}
      end

    enabled = ConfigServer.enabled?()

    content =
      %{
        "chats" => chats,
        "global" => Map.put(globals, "enabled", enabled)
      }
      |> Jason.encode!(pretty: true)

    path = Path.expand(@tracking_json)
    File.write(path, content)
  end

  defp normalize_value(value) when is_integer(value), do: value

  defp normalize_value(value) do
    str = to_string(value)

    case Integer.parse(str) do
      {int, ""} -> int
      _ -> str
    end
  end

  defp unix_now, do: System.os_time(:second)

  defp hash_text(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp ensure_column(conn, table, column, type) do
    existing =
      case :esqlite3.q(conn, "PRAGMA table_info(#{table});", []) do
        rows when is_list(rows) ->
          Enum.any?(rows, fn row ->
            case row do
              [_cid, name, _type, _notnull, _dflt, _pk] -> to_string(name) == column
              _ -> false
            end
          end)

        _ ->
          false
      end

    if existing do
      :ok
    else
      :esqlite3.q(conn, "ALTER TABLE #{table} ADD COLUMN #{column} #{type};", [])
      :ok
    end
  end
end
