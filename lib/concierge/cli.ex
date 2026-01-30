defmodule Concierge.CLI do
  @moduledoc """
  Simple CLI for manual control (pause/resume/status).
  """

  alias Concierge.{Reprocessor, Store}

  def main(argv) do
    case argv do
      ["pause", jid] ->
        paused_until = System.os_time(:second) + 3 * 3600
        Store.pause_chat(jid, paused_until, "manual_pause")
        IO.puts("Paused #{jid} until #{paused_until}")

      ["resume", jid] ->
        Store.mark_active(jid)
        IO.puts("Resumed #{jid}")

      ["status", jid] ->
        case Store.last_bot_response_at(jid) do
          nil -> IO.puts("No state for #{jid}")
          ts -> IO.puts("Last bot response: #{ts}")
        end

      ["reset", jid] ->
        Store.reset_chat(jid)
        IO.puts("Reset state for #{jid}")

      ["reset-all"] ->
        Store.reset_all()
        IO.puts("Reset state for all chats")

      ["reprocess", jid] ->
        case Reprocessor.reprocess(jid) do
          :ok -> IO.puts("Reprocessing #{jid}")
          {:error, reason} -> IO.puts("Cannot reprocess #{jid}: #{inspect(reason)}")
        end

      ["reprocess-all"] ->
        Reprocessor.reprocess_all()
        IO.puts("Reprocessing all eligible chats")

      _ ->
        IO.puts("""
        Usage:
          bin/concierge pause <jid>
          bin/concierge resume <jid>
          bin/concierge status <jid>
          bin/concierge reset <jid>
          bin/concierge reset-all
          bin/concierge reprocess <jid>
          bin/concierge reprocess-all
        """)
    end
  end
end
