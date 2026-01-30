defmodule Concierge.Jid do
  @moduledoc """
  Helpers for WhatsApp JID parsing.
  """

  def group?(jid) when is_binary(jid) do
    String.contains?(jid, "@g.us")
  end

  def broadcast?(jid) when is_binary(jid) do
    String.contains?(jid, "@broadcast")
  end

  def lid?(jid) when is_binary(jid) do
    String.contains?(jid, "@lid")
  end
end
