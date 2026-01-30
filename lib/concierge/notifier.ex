defmodule Concierge.Notifier do
  @moduledoc """
  Sends short, single-line notifications to the configured number.
  """

  require Logger

  alias Concierge.{ConfigServer, Sender}

  def notify_new_message(jid, chat_name, preview) do
    if ConfigServer.get([:notifications, :notify_on_new_message], true) do
      send_notification("📩 #{chat_name}: #{preview}", jid)
    else
      :ok
    end
  end

  def notify_bot_response(jid, chat_name, preview) do
    if ConfigServer.get([:notifications, :notify_on_bot_response], true) do
      send_notification("✅ Concierge respondeu #{chat_name}: #{preview}", jid)
    else
      :ok
    end
  end

  def notify_human_takeover(jid, chat_name) do
    if ConfigServer.get([:notifications, :notify_on_human_takeover], true) do
      send_notification("🛑 Humano assumiu: #{chat_name}", jid)
    else
      :ok
    end
  end

  def notify_escalation(jid, chat_name, keyword) do
    if ConfigServer.get([:notifications, :notify_on_escalation], true) do
      send_notification("🚨 Escalação (#{keyword}) em #{chat_name}", jid)
    else
      :ok
    end
  end

  def notify_requires_approval(jid, chat_name, keyword) do
    if ConfigServer.get([:notifications, :notify_on_escalation], true) do
      send_notification("📝 Aprovação humana (#{keyword}) em #{chat_name}", jid)
    else
      :ok
    end
  end

  def notify_error(jid, chat_name, error) do
    if ConfigServer.get([:notifications, :notify_on_error], true) do
      send_notification("❌ Erro em #{chat_name}: #{error}", jid)
    else
      :ok
    end
  end

  defp send_notification(text, origin_jid) do
    notify_number =
      ConfigServer.get([:notifications, :notify_admin_number]) ||
        ConfigServer.get([:notifications, :notify_operator_number]) ||
        ConfigServer.get([:notifications, :notify_leo_number])

    cond do
      is_nil(notify_number) or notify_number == "" ->
        :ok

      String.contains?(origin_jid, normalize_phone(notify_number)) ->
        # Never notify by responding to yourself in the same chat
        :ok

      true ->
        try do
          case Sender.send_notification(notify_number, text) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("Failed to send notification", reason: inspect(reason))
              :ok
          end
        catch
          :exit, reason ->
            Logger.warning("Notification send crashed", reason: inspect(reason))
            :ok
        end
    end
  end

  defp normalize_phone(number) do
    number
    |> String.replace(~r/[^0-9]/, "")
  end
end
