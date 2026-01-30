defmodule Concierge.Sender do
  @moduledoc """
  Sends messages via configured provider (wacli or clawdbot).
  """

  require Logger

  alias Concierge.{ConfigServer, Jid, WacliDB}

  def send_message(jid, text) do
    provider = ConfigServer.get([:sender, :provider], "wacli")

    case provider do
      "clawdbot" -> send_via_clawdbot(jid, text)
      :clawdbot -> send_via_clawdbot(jid, text)
      "openclaw" -> send_via_clawdbot(jid, text)
      :openclaw -> send_via_clawdbot(jid, text)
      _ -> Concierge.SyncController.send_message(jid, text)
    end
  end

  def send_notification(target, text) do
    provider = ConfigServer.get([:notifications, :provider], "wacli")

    case provider do
      "clawdbot" -> send_via_clawdbot_target(target, text)
      :clawdbot -> send_via_clawdbot_target(target, text)
      "openclaw" -> send_via_clawdbot_target(target, text)
      :openclaw -> send_via_clawdbot_target(target, text)
      _ -> Concierge.SyncController.send_message(target, text)
    end
  end

  defp send_via_clawdbot(jid, text) do
    target = resolve_target(jid)
    send_via_clawdbot_target(target, text)
  end

  defp send_via_clawdbot_target(target, text) do
    cmd = ConfigServer.clawdbot_command()
    timeout_ms = ConfigServer.get([:sender, :clawdbot_timeout_ms], 20_000)

    args = [
      "message",
      "send",
      "--target",
      target,
      "--message",
      text
    ]

    task =
      Task.async(fn ->
        System.cmd(cmd, args, stderr_to_stdout: true, env: [{"NODE_NO_WARNINGS", "1"}])
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        Logger.info("Sent via clawdbot", target: target, bytes: byte_size(text))
        if output != "", do: Logger.debug("Clawdbot send output: #{String.slice(output, 0, 120)}")
        :ok

      {:ok, {output, code}} ->
        Logger.error("Clawdbot send failed", code: code, output: String.slice(output, 0, 200))
        {:error, :clawdbot_failed}

      _ ->
        Logger.error("Clawdbot send timeout", target: target)
        {:error, :timeout}
    end
  end

  defp resolve_target(jid) do
    mode = ConfigServer.get([:sender, :clawdbot_target], "jid")

    case mode do
      "sender_jid" ->
        WacliDB.last_sender_jid(jid) || jid

      "phone" ->
        phone_from_jid(jid) || phone_from_sender(jid) || jid

      _ ->
        jid
    end
  end

  defp phone_from_sender(jid) do
    case WacliDB.last_sender_jid(jid) do
      nil -> nil
      sender_jid -> phone_from_jid(sender_jid)
    end
  end

  defp phone_from_jid(jid) when is_binary(jid) do
    cond do
      String.starts_with?(jid, "+") ->
        jid

      String.contains?(jid, "@s.whatsapp.net") ->
        digits = normalize_phone(jid)
        if digits == "", do: nil, else: "+" <> digits

      Jid.lid?(jid) ->
        nil

      true ->
        nil
    end
  end

  defp phone_from_jid(_), do: nil

  defp normalize_phone(value) do
    value
    |> String.replace(~r/[^0-9]/, "")
  end
end
