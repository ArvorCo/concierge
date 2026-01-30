defmodule Concierge.ChatPool do
  @moduledoc """
  Manages the pool of ChatHandler processes.
  Uses DynamicSupervisor to start/stop ChatHandlers on demand.
  """

  require Logger

  def get_or_create(jid, name) do
    case Registry.lookup(Concierge.ChatRegistry, jid) do
      [{pid, _}] ->
        Logger.debug("Using existing ChatHandler", jid: jid, pid: inspect(pid))
        {:ok, pid}

      [] ->
        Logger.info("Creating new ChatHandler", jid: jid, name: name)

        spec = {Concierge.ChatHandler, jid: jid, name: name}

        case DynamicSupervisor.start_child(Concierge.ChatSupervisor, spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            Logger.error("Failed to start ChatHandler",
              jid: jid,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  def list_active do
    Registry.select(Concierge.ChatRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  def stop(jid) do
    case Registry.lookup(Concierge.ChatRegistry, jid) do
      [{pid, _}] ->
        Logger.info("Stopping ChatHandler", jid: jid)
        DynamicSupervisor.terminate_child(Concierge.ChatSupervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  def count do
    list_active() |> length()
  end
end
