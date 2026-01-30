defmodule Concierge.Reprocessor do
  @moduledoc """
  Reprocesses chats whose latest message was not answered.
  """

  alias Concierge.{ChatPool, ConfigServer, Jid, Store, WacliDB}

  @system_patterns [
    ~r/\[clawdbot\]/i,
    ~r/Concierge vai responder/i,
    ~r/Chat ativo/i,
    ~r/Nova mensagem WhatsApp/i,
    ~r/Status atual do wacli/i,
    ~r/AUTHENTICATED.*false/i,
    ~r/wacli auth/i
  ]

  def reprocess_all do
    messages = WacliDB.latest_messages_per_chat()

    Enum.each(messages, fn msg ->
      with true <- should_reprocess?(msg),
           true <- not msg.from_me,
           false <- system_message?(msg.text),
           false <- should_ignore_chat?(msg),
           true <- not already_responded?(msg) do
        Store.reset_chat(msg.jid)
        {:ok, pid} = ChatPool.get_or_create(msg.jid, msg.chat_name)
        Concierge.ChatHandler.process_message(pid, msg)
      else
        _ -> :skip
      end
    end)

    :ok
  end

  def reprocess(jid) do
    case WacliDB.last_message_full(jid) do
      {:ok, nil} ->
        {:error, :no_messages}

      {:ok, msg} ->
        if msg.from_me or system_message?(msg.text) or should_ignore_chat?(msg) or
             already_responded?(msg) do
          {:error, :not_eligible}
        else
          Store.reset_chat(msg.jid)
          {:ok, pid} = ChatPool.get_or_create(msg.jid, msg.chat_name)
          Concierge.ChatHandler.process_message(pid, msg)
          :ok
        end
    end
  end

  defp should_reprocess?(msg) do
    is_binary(msg.jid) and is_integer(msg.timestamp)
  end

  defp system_message?(text) when is_binary(text) do
    Enum.any?(@system_patterns, &Regex.match?(&1, text))
  end

  defp system_message?(_), do: false

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

  defp already_responded?(msg) do
    case Store.last_bot_response_at(msg.jid) do
      nil -> false
      last_bot_ts when last_bot_ts >= msg.timestamp -> true
      _ -> false
    end
  end
end
