defmodule Concierge.ChatHandler do
  @moduledoc """
  Handles conversation with a single WhatsApp contact.
  Each ChatHandler is an isolated process with its own state/context.
  Supervised - if it crashes, it will be restarted automatically.
  """

  use GenServer, restart: :transient
  require Logger

  alias Concierge.{AIClient, ConfigServer, Notifier, Store, WacliDB}

  defstruct [
    :jid,
    :name,
    # :idle | :processing | :paused
    :status,
    # Last N messages
    :context,
    :paused_until,
    :pending_msg,
    :pending_msgs,
    :timer_ref
  ]

  @context_limit 6

  ## Client API

  def start_link(opts) do
    jid = Keyword.fetch!(opts, :jid)
    name = Keyword.get(opts, :name, "Unknown")

    GenServer.start_link(__MODULE__, {jid, name}, name: via_tuple(jid))
  end

  def process_message(pid, message) do
    GenServer.cast(pid, {:process_message, message})
  end

  ## Server Callbacks

  @impl true
  def init({jid, name}) do
    Logger.info("ChatHandler started for #{name} (#{jid})")

    state = %__MODULE__{
      jid: jid,
      name: name,
      status: :idle,
      context: [],
      paused_until: nil,
      pending_msg: nil,
      pending_msgs: [],
      timer_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Store.mark_active(state.jid)
    Store.set_notified(state.jid, false)
    :ok
  end

  @impl true
  def handle_cast({:process_message, msg}, state) do
    # Check if paused
    if paused?(state) do
      Logger.debug("Chat paused until #{state.paused_until}, skipping", jid: state.jid)
      {:noreply, state}
    else
      # Refresh processing timestamp
      Store.mark_processing(state.jid)
      Store.update_chat_name(state.jid, state.name)

      # Wait random delay (configured in config)
      wait_time = ConfigServer.random_wait_time()

      state =
        case state.status do
          :processing ->
            # Update pending message and reschedule response
            maybe_cancel_timer(state.timer_ref)

            Logger.info("New message queued; rescheduling response in #{wait_time}s",
              jid: state.jid
            )

            pending_msgs = append_pending(state.pending_msgs, msg)

            %{
              state
              | pending_msg: msg,
                pending_msgs: pending_msgs,
                timer_ref: schedule_response(wait_time)
            }

          _ ->
            Logger.info("Waiting #{wait_time}s before responding to #{state.name}",
              jid: state.jid
            )

            %{
              state
              | status: :processing,
                pending_msg: msg,
                pending_msgs: [msg],
                timer_ref: schedule_response(wait_time)
            }
        end

      # Notify on new message (only once per cycle)
      unless Store.notified?(state.jid) do
        preview = String.slice(msg.text || "", 0, 80)
        Task.start(fn -> Notifier.notify_new_message(state.jid, state.name, preview) end)
        Store.set_notified(state.jid, true)
      end

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:generate_response, ref}, state) do
    if ref != state.timer_ref do
      {:noreply, state}
    else
      msg = state.pending_msg
      combined = combine_messages(state.pending_msgs, msg)

      if is_nil(msg) do
        Store.mark_active(state.jid)
        Store.set_notified(state.jid, false)
        {:noreply, %{state | status: :idle, timer_ref: nil, pending_msg: nil, pending_msgs: []}}
      else
        # Escalation keywords
        case find_blocking_keyword(msg.text) do
          {:require_approval, keyword} ->
            Logger.info("Human approval keyword detected", jid: state.jid, keyword: keyword)
            Store.increment_global("total_escalations_today")

            Task.start(fn ->
              Notifier.notify_requires_approval(state.jid, state.name, keyword)
            end)

            Store.mark_active(state.jid)
            Store.set_notified(state.jid, false)

            {:noreply,
             %{state | status: :idle, pending_msg: nil, pending_msgs: [], timer_ref: nil}}

          {:escalate, keyword} ->
            Logger.info("Escalation keyword detected", jid: state.jid, keyword: keyword)
            Store.increment_global("total_escalations_today")
            Task.start(fn -> Notifier.notify_escalation(state.jid, state.name, keyword) end)
            Store.mark_active(state.jid)
            Store.set_notified(state.jid, false)

            {:noreply,
             %{state | status: :idle, pending_msg: nil, pending_msgs: [], timer_ref: nil}}

          :continue ->
            # Check if human took over during wait
            case check_human_takeover(state.jid) do
              {:ok, {:human_took_over, ts}} ->
                Logger.info("Human took over chat with #{state.name}, pausing", jid: state.jid)

                pause_duration = ConfigServer.get([:human_takeover, :auto_pause_hours], 3) * 3600
                paused_until = unix_now() + pause_duration

                Store.pause_chat(state.jid, paused_until, "human_takeover")
                Store.record_human_takeover(state.jid, ts)
                Task.start(fn -> Notifier.notify_human_takeover(state.jid, state.name) end)

                state = %{
                  state
                  | status: :paused,
                    paused_until: paused_until,
                    pending_msg: nil,
                    pending_msgs: [],
                    timer_ref: nil
                }

                {:noreply, state}

              {:ok, :bot_can_respond} ->
                # Rate limiting per chat
                limit = ConfigServer.get([:safety, :rate_limit_per_chat_per_hour], 0)

                if limit > 0 and Store.rate_limited?(state.jid, limit) do
                  Logger.info("Rate limit reached for chat", jid: state.jid, limit: limit)
                  Store.mark_active(state.jid)
                  Store.set_notified(state.jid, false)

                  Task.start(fn ->
                    Notifier.notify_error(state.jid, state.name, "rate_limited")
                  end)

                  {:noreply,
                   %{state | status: :idle, pending_msg: nil, pending_msgs: [], timer_ref: nil}}
                else
                  # Load conversation context
                  context = WacliDB.context(state.jid, @context_limit)

                  # Generate response via AI
                  case AIClient.generate_response(state.jid, state.name, combined.text, context) do
                    {:ok, response} ->
                      if contains_forbidden_words?(response) do
                        Logger.warning("Response blocked by forbidden words", jid: state.jid)
                        Store.mark_active(state.jid)
                        Store.set_notified(state.jid, false)

                        Task.start(fn ->
                          Notifier.notify_error(state.jid, state.name, "forbidden_words")
                        end)

                        {:noreply,
                         %{
                           state
                           | status: :idle,
                             pending_msg: nil,
                             pending_msgs: [],
                             timer_ref: nil
                         }}
                      else
                        # Send via wacli
                        case Concierge.Sender.send_message(state.jid, response) do
                          :ok ->
                            Logger.info("Response sent to #{state.name}",
                              jid: state.jid,
                              length: String.length(response)
                            )

                            # Record in tracker
                            Store.record_bot_response(state.jid, response)
                            Store.set_notified(state.jid, false)

                            Task.start(fn ->
                              Notifier.notify_bot_response(
                                state.jid,
                                state.name,
                                String.slice(response, 0, 80)
                              )
                            end)

                            # Update context
                            new_context = [msg | context] |> Enum.take(@context_limit)

                            state = %{
                              state
                              | status: :idle,
                                context: new_context,
                                pending_msg: nil,
                                pending_msgs: [],
                                timer_ref: nil
                            }

                            {:noreply, state}

                          {:error, reason} ->
                            Logger.error("Failed to send message to #{state.name}",
                              jid: state.jid,
                              reason: inspect(reason)
                            )

                            Store.mark_active(state.jid)
                            Store.set_notified(state.jid, false)

                            Task.start(fn ->
                              Notifier.notify_error(state.jid, state.name, "send_failed")
                            end)

                            state = %{
                              state
                              | status: :idle,
                                pending_msg: nil,
                                pending_msgs: [],
                                timer_ref: nil
                            }

                            {:noreply, state}
                        end
                      end

                    {:error, reason} ->
                      Logger.error(
                        "Failed to generate response for #{state.name}: #{inspect(reason)}",
                        jid: state.jid
                      )

                      Store.mark_active(state.jid)
                      Store.set_notified(state.jid, false)

                      Task.start(fn ->
                        Notifier.notify_error(state.jid, state.name, "ai_failed")
                      end)

                      state = %{
                        state
                        | status: :idle,
                          pending_msg: nil,
                          pending_msgs: [],
                          timer_ref: nil
                      }

                      {:noreply, state}
                  end
                end

              {:error, reason} ->
                Logger.error("Failed to check human takeover", reason: inspect(reason))

                Store.mark_active(state.jid)
                Store.set_notified(state.jid, false)

                state = %{
                  state
                  | status: :idle,
                    pending_msg: nil,
                    pending_msgs: [],
                    timer_ref: nil
                }

                {:noreply, state}
            end
        end
      end
    end
  end

  ## Private Functions

  defp paused?(state) do
    case state.paused_until do
      nil -> false
      timestamp -> unix_now() < timestamp
    end
  end

  defp check_human_takeover(jid) do
    case WacliDB.last_message(jid) do
      {:ok, %{from_me: true, timestamp: ts, text: text}} ->
        bot_hash = Store.last_bot_response_hash(jid)
        text_hash = if is_binary(text), do: hash_text(text), else: nil

        cond do
          is_binary(bot_hash) and bot_hash != "" and text_hash == bot_hash ->
            {:ok, :bot_can_respond}

          true ->
            case Store.last_bot_response_at(jid) do
              nil -> {:ok, {:human_took_over, ts}}
              last_bot_ts when ts > last_bot_ts -> {:ok, {:human_took_over, ts}}
              _ -> {:ok, :bot_can_respond}
            end
        end

      {:ok, %{from_me: false}} ->
        {:ok, :bot_can_respond}

      {:ok, nil} ->
        {:ok, :bot_can_respond}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unix_now, do: System.os_time(:second)

  defp via_tuple(jid) do
    {:via, Registry, {Concierge.ChatRegistry, jid}}
  end

  defp find_blocking_keyword(text) when is_binary(text) do
    approval = ConfigServer.get([:safety, :require_human_approval_keywords], [])
    escalate = ConfigServer.get([:safety, :escalate_to_human_keywords], [])

    approval_match =
      Enum.find_value(approval, nil, fn keyword ->
        if String.contains?(String.downcase(text), String.downcase(keyword)) do
          {:require_approval, keyword}
        else
          false
        end
      end)

    if approval_match do
      approval_match
    else
      Enum.find_value(escalate, :continue, fn keyword ->
        if String.contains?(String.downcase(text), String.downcase(keyword)) do
          {:escalate, keyword}
        else
          false
        end
      end)
    end
  end

  defp find_blocking_keyword(_), do: :continue

  defp contains_forbidden_words?(text) when is_binary(text) do
    forbidden = ConfigServer.get([:safety, :forbidden_words], [])

    Enum.any?(forbidden, fn word ->
      String.contains?(String.downcase(text), String.downcase(word))
    end)
  end

  defp contains_forbidden_words?(_), do: false

  defp hash_text(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp schedule_response(wait_time) do
    ref = make_ref()
    Process.send_after(self(), {:generate_response, ref}, wait_time * 1000)
    ref
  end

  defp maybe_cancel_timer(nil), do: :ok

  defp maybe_cancel_timer(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp append_pending(pending, msg) do
    pending = pending || []
    pending ++ [msg]
  end

  defp combine_messages(pending, last_msg) do
    messages = pending || []

    combined_text =
      messages
      |> Enum.map(&(&1.text || ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if is_map(last_msg) do
      Map.put(last_msg, :text, if(combined_text == "", do: last_msg.text, else: combined_text))
    else
      last_msg
    end
  end
end
