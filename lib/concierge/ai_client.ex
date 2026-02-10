defmodule Concierge.AIClient do
  @moduledoc """
  Interface to OpenClaw/Clawdbot CLI for generating AI responses.
  """

  require Logger

  alias Concierge.{AgentManager, ConfigServer, OpenClaw}

  @timeout_ms 90_000

  def generate_response(jid, contact_name, message, _context) do
    Logger.info("Ensuring agent", jid: jid, contact: contact_name)

    with {:ok, agent_id} <- AgentManager.ensure_agent(jid, contact_name) do
      # Important: do NOT wrap the user's message in an additional "system prompt".
      # OpenClaw builds the system prompt from the workspace files (SOUL/IDENTITY/TOOLS).
      # Some agent configurations will produce empty payloads if the input looks like meta-instructions.
      prompt = to_string(message)

      case call_clawdbot(agent_id, jid, prompt) do
        {:ok, response} ->
          Logger.info("AI response ready",
            jid: jid,
            agent: agent_id,
            length: String.length(response)
          )

          {:ok, sanitize_response(response)}

        {:error, :missing_text} ->
          Logger.error("AI returned empty payloads (:missing_text)", jid: jid, agent: agent_id)
          {:error, :missing_text}

        {:error, reason} ->
          Logger.error("AI generation failed: #{inspect(reason)}", jid: jid)
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.error("AI generation failed: #{inspect(reason)}", jid: jid)
        {:error, reason}
    end
  end

  defp call_clawdbot(agent_id, session_id, prompt) do
    args = [
      "agent",
      "--agent",
      agent_id,
      "--session-id",
      session_id,
      "--message",
      prompt,
      "--json"
    ]

    cmd = ConfigServer.clawdbot_command()

    task =
      Task.async(fn ->
        System.cmd(cmd, args, stderr_to_stdout: true, env: [{"NODE_NO_WARNINGS", "1"}])
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        parse_response(output)

      {:ok, {output, code}} ->
        Logger.error("Clawdbot CLI failed: #{String.slice(output, 0, 200)}", code: code)
        {:error, :clawdbot_failed}

      _ ->
        Logger.error("Clawdbot CLI timeout")
        {:error, :timeout}
    end
  end

  defp parse_response(output) do
    with {:ok, json} <- decode_json(output),
         text <- extract_text(json),
         true <- is_binary(text) and String.trim(text) != "" do
      {:ok, text}
    else
      {:error, reason} ->
        log_invalid_json(output, reason)
        {:error, reason}

      _ ->
        case extract_error(json_or_nil(output)) do
          nil ->
            log_invalid_json(output, :missing_text)
            {:error, :missing_text}

          error ->
            Logger.error("Clawdbot returned error: #{error}")
            {:error, {:clawdbot_error, error}}
        end
    end
  end

  defp decode_json(output) do
    case Jason.decode(output) do
      {:ok, json} ->
        {:ok, json}

      {:error, _} ->
        case extract_json_blob(output) do
          nil -> {:error, :invalid_json}
          blob -> Jason.decode(blob)
        end
    end
  end

  defp extract_json_blob(output) do
    start_idx =
      case :binary.match(output, "{") do
        {idx, _} -> idx
        :nomatch -> nil
      end

    end_idx =
      case :binary.matches(output, "}") do
        [] -> nil
        matches -> matches |> List.last() |> elem(0)
      end

    if is_integer(start_idx) and is_integer(end_idx) and end_idx > start_idx do
      String.slice(output, start_idx, end_idx - start_idx + 1)
    else
      nil
    end
  end

  defp extract_text(json) do
    result = json["result"] || json[:result]

    text =
      cond do
        is_map(result) and is_list(result["payloads"]) ->
          extract_from_payloads(result["payloads"])

        is_list(json["payloads"]) ->
          extract_from_payloads(json["payloads"])

        is_map(result) ->
          extract_from_result(result)

        true ->
          nil
      end

    text ||
      json["reply"] ||
      json["text"] ||
      json["message"] ||
      json["output_text"] ||
      json["final"]
  end

  defp extract_from_result(result) when is_map(result) do
    # Common response shapes (anthropic/openai-style, or clawdbot wrappers)
    candidates = [
      ["output_text"],
      ["final"],
      ["text"],
      ["message"],
      ["response", "output_text"],
      ["response", "final"],
      ["response", "text"],
      ["response", "message"],
      ["response", "output", :first, "content", :first, "text"],
      ["response", "output", :first, "content", :first, "value"],
      ["response", "content", :first, "text"],
      ["response", "choices", :first, "message", "content"],
      ["response", "choices", :first, "text"],
      ["output", :first, "content", :first, "text"],
      ["output", :first, "content", :first, "value"],
      ["content", :first, "text"],
      ["content", :first, "value"],
      ["choices", :first, "message", "content"],
      ["choices", :first, "text"],
      ["message", "content"],
      ["assistant", "text"],
      ["assistant", "message"]
    ]

    Enum.find_value(candidates, fn path -> dig_text(result, path) end) ||
      extract_from_payloads(result["payloads"] || [])
  end

  defp extract_from_result(_), do: nil

  defp dig_text(data, path) do
    value =
      Enum.reduce_while(path, data, fn key, acc ->
        case {acc, key} do
          {nil, _} ->
            {:halt, nil}

          {list, :first} when is_list(list) ->
            {:cont, List.first(list)}

          {map, key} when is_map(map) ->
            {:cont, Map.get(map, key)}

          {binary, _} when is_binary(binary) ->
            {:halt, binary}

          _ ->
            {:halt, nil}
        end
      end)

    if is_binary(value) and String.trim(value) != "", do: value, else: nil
  end

  defp extract_from_payloads(payloads) do
    payloads
    |> Enum.map(fn payload ->
      cond do
        is_map(payload) ->
          payload["text"] ||
            payload["reply"] ||
            payload["message"] ||
            extract_payload_content(payload["content"]) ||
            payload["value"]

        true ->
          nil
      end
    end)
    |> Enum.reject(&is_nil_or_empty/1)
    |> Enum.join("\n")
  end

  defp extract_payload_content(content) when is_list(content) do
    content
    |> Enum.map(fn item ->
      cond do
        is_map(item) -> item["text"] || item["value"]
        is_binary(item) -> item
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil_or_empty/1)
    |> Enum.join("\n")
  end

  defp extract_payload_content(content) when is_binary(content), do: content
  defp extract_payload_content(_), do: nil

  defp is_nil_or_empty(value) do
    case value do
      nil -> true
      "" -> true
      _ -> false
    end
  end

  defp log_invalid_json(output, reason) do
    path = maybe_log_full_json(output, reason)

    sample =
      output
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, 300)

    if path do
      Logger.error("Invalid clawdbot JSON: #{inspect(reason)}; sample=#{sample}; full=#{path}")
    else
      Logger.error("Invalid clawdbot JSON: #{inspect(reason)}; sample=#{sample}")
    end
  end

  defp extract_error(json) when is_map(json) do
    json["error"] ||
      json["message"] ||
      get_in(json, ["result", "error"]) ||
      get_in(json, ["result", "message"])
  end

  defp extract_error(_), do: nil

  defp json_or_nil(output) do
    case decode_json(output) do
      {:ok, json} -> json
      _ -> nil
    end
  end

  defp maybe_log_full_json(output, reason) do
    if ConfigServer.get([:logging, :log_full_json_on_error], false) do
      log_dir = ConfigServer.get([:logging, :log_dir], Concierge.Paths.path("logs"))
      dir = Path.expand(log_dir)
      _ = File.mkdir_p(dir)
      ts = System.os_time(:second)
      safe_reason = to_string(reason) |> String.replace(~r/[^a-zA-Z0-9_-]+/, "_")
      path = Path.join(dir, "clawdbot_invalid_json_#{safe_reason}_#{ts}.log")
      _ = File.write(path, output)
      path
    else
      nil
    end
  end

  defp sanitize_response(text) do
    prefix = OpenClaw.response_prefix()

    text
    |> strip_prefix(prefix)
    |> String.replace(~r/```[^`]*```/s, "")
    |> String.replace("`", "")
    |> String.trim()
  end

  defp strip_prefix(text, prefix) when is_binary(text) and is_binary(prefix) do
    trimmed = String.trim_leading(text)

    if String.starts_with?(trimmed, prefix) do
      trimmed |> String.slice(String.length(prefix)..-1) |> String.trim_leading()
    else
      text
    end
  end

  defp strip_prefix(text, _), do: text
end
