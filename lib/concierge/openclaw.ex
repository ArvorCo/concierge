defmodule Concierge.OpenClaw do
  @moduledoc """
  Lightweight access to OpenClaw/Clawdbot CLI configuration.

  We intentionally treat OpenClaw as the source of truth for message
  formatting (e.g. response prefix), because it is installation-specific.
  """

  require Logger

  alias Concierge.ConfigServer

  @timeout_ms 5_000

  def response_prefix do
    case get_config_value("messages.responsePrefix") do
      prefix when is_binary(prefix) -> prefix
      _ -> ""
    end
  end

  defp get_config_value(path) when is_binary(path) do
    cmd = ConfigServer.clawdbot_command()

    # Try JSON first (best-effort), then fall back to raw output.
    case run_cmd(cmd, ["config", "get", path, "--json"]) do
      {:ok, output} ->
        case decode_json(output) do
          {:ok, value} -> value
          _ -> raw_get(cmd, path)
        end

      {:error, _} ->
        raw_get(cmd, path)
    end
  end

  defp raw_get(cmd, path) do
    case run_cmd(cmd, ["config", "get", path]) do
      {:ok, output} ->
        output
        |> strip_ansi()
        |> String.trim()
        |> strip_wrapping_quotes()

      _ ->
        nil
    end
  end

  defp run_cmd(cmd, args) do
    task =
      Task.async(fn ->
        System.cmd(cmd, args, stderr_to_stdout: true, env: [{"NODE_NO_WARNINGS", "1"}])
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {code, output}}
      _ -> {:error, :timeout}
    end
  end

  defp decode_json(output) when is_binary(output) do
    cleaned =
      output
      |> strip_ansi()
      |> extract_json_blob()
      |> strip_json5()
      |> String.trim()

    Jason.decode(cleaned)
  rescue
    _ -> {:error, :invalid_json}
  end

  defp extract_json_blob(text) do
    # OpenClaw may output logs + a JSON blob; attempt to isolate the blob.
    start_idx =
      case :binary.match(text, "{") do
        {idx, _} -> idx
        :nomatch -> nil
      end

    end_idx =
      case :binary.matches(text, "}") do
        [] -> nil
        matches -> matches |> List.last() |> elem(0)
      end

    if is_integer(start_idx) and is_integer(end_idx) and end_idx > start_idx do
      String.slice(text, start_idx, end_idx - start_idx + 1)
    else
      text
    end
  end

  defp strip_json5(text) do
    text
    |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
    |> String.replace(~r/\/\/.*$/, "", global: true)
    |> String.replace(~r/,\s*([}\]])/, "\1")
  end

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\[[0-9;]*m/, "")
  end

  defp strip_wrapping_quotes(value) do
    v = String.trim(value)

    cond do
      String.length(v) >= 2 and String.starts_with?(v, "\"") and String.ends_with?(v, "\"") ->
        v |> String.trim_leading("\"") |> String.trim_trailing("\"")

      true ->
        v
    end
  end
end
