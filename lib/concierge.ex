defmodule Concierge do
  @moduledoc """
  Concierge - WhatsApp Orchestration System

  Monitors WhatsApp messages via wacli and generates intelligent responses
  via OpenClaw (formerly Clawdbot) AI agents.

  ## Architecture

  - **Monitor**: Polls wacli SQLite DB for new messages (5s interval)
  - **ChatHandler**: One process per WhatsApp contact (isolated context)
  - **AIClient**: Integrates with OpenClaw/Clawdbot CLI for response generation
  - **Sender**: Sends messages via wacli CLI (via SyncController)
  - **Store**: Manages chat state in SQLite (atomic operations)
  - **ConfigServer**: Hot-reloadable configuration

  ## Features

  - ✅ Concurrency-safe (GenServer per chat)
  - ✅ Fault-tolerant (Supervisor trees)
  - ✅ Context isolation (process per JID)
  - ✅ Human takeover detection
  - ✅ Configurable wait times
  - ✅ Structured logging

  ## Usage

      # Start in interactive mode
      iex -S mix

      # List active chats
      Concierge.ChatPool.list_active()

      # Get or create ChatHandler
      {:ok, pid} = Concierge.ChatPool.get_or_create("123@lid", "John")

      # Check if chat can process
      Concierge.Store.can_process?("123@lid", System.os_time(:second))

      # Reload config without restart
      Concierge.ConfigServer.reload()
  """

  @doc """
  Returns application version.
  """
  def version do
    Application.spec(:concierge, :vsn) |> to_string()
  end
end
