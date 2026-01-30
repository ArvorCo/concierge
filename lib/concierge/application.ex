defmodule Concierge.Application do
  @moduledoc """
  Concierge Application - Main supervision tree
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Concierge application...")

    children = [
      # Registry for ChatHandlers (name -> pid mapping)
      {Registry, keys: :unique, name: Concierge.ChatRegistry},

      # Configuration server (hot-reload without restart)
      Concierge.ConfigServer,

      # Wacli DB reader
      Concierge.WacliDB,

      # Tracking store (SQLite)
      Concierge.Store,

      # Agent manager (workspace + tool restrictions)
      Concierge.AgentManager,

      # Wacli sync controller (single writer)
      Concierge.SyncController,

      # Clawdbot sandbox cleanup (Docker)
      Concierge.SandboxCleaner,

      # Dynamic supervisor for ChatHandlers (one per JID)
      {DynamicSupervisor,
       name: Concierge.ChatSupervisor, strategy: :one_for_one, max_restarts: 100},

      # Monitor (polls wacli DB for new messages)
      Concierge.Monitor
    ]

    opts = [strategy: :one_for_one, name: Concierge.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Concierge started successfully")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start Concierge: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
