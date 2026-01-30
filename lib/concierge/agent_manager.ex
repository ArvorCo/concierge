defmodule Concierge.AgentManager do
  @moduledoc """
  Ensures an isolated agent workspace per JID.

  Tool access is enforced by OpenClaw. Concierge defaults to *no tools*.
  """

  use GenServer
  require Logger

  alias Concierge.ConfigServer

  @agents_dir Concierge.Paths.path("agents")
  @workspace_config "config.json"
  @tools_allowlist []

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{ensured: MapSet.new()}, name: __MODULE__)
  end

  @impl true
  def init(state), do: {:ok, state}

  def ensure_agent(jid, chat_name, timeout_ms \\ nil) do
    timeout = timeout_ms || ConfigServer.get([:clawdbot, :ensure_timeout_ms], 60_000)

    try do
      GenServer.call(__MODULE__, {:ensure_agent, jid, chat_name}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
    end
  end

  def agent_id_for_jid(jid) do
    hash =
      :crypto.hash(:sha256, jid)
      |> Base.url_encode64(padding: false)

    "wa_" <> hash
  end

  ## Server Callbacks

  @impl true
  def handle_call({:ensure_agent, jid, chat_name}, _from, state) do
    agent_id = agent_id_for_jid(jid)

    if MapSet.member?(state.ensured, agent_id) do
      {:reply, {:ok, agent_id}, state}
    else
      case ensure_workspace(jid, chat_name) do
        :ok ->
          ensure_clawdbot_agent(agent_id, jid)
          ensured = MapSet.put(state.ensured, agent_id)
          {:reply, {:ok, agent_id}, %{state | ensured: ensured}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  ## Workspace helpers

  defp ensure_workspace(jid, chat_name) do
    base = Path.expand(@agents_dir)
    workspace = Path.join(base, jid)
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, "memory"))

    agents_path = Path.join(workspace, "AGENTS.md")
    identity_path = Path.join(workspace, "IDENTITY.md")
    soul_path = Path.join(workspace, "SOUL.md")
    user_path = Path.join(workspace, "USER.md")
    tools_path = Path.join(workspace, "TOOLS.md")
    config_path = Path.join(workspace, @workspace_config)

    unless File.exists?(agents_path) do
      File.write!(agents_path, agents_template())
    end

    unless File.exists?(identity_path) do
      File.write!(identity_path, identity_template(jid, chat_name))
    end

    ensure_soul_link(soul_path)

    unless File.exists?(user_path) do
      File.write!(user_path, user_template(jid, chat_name))
    end

    unless File.exists?(tools_path) do
      File.write!(tools_path, tools_template())
    end

    unless File.exists?(config_path) do
      File.write!(config_path, Jason.encode!(%{tools: %{allow: @tools_allowlist}}, pretty: true))
    end

    :ok
  rescue
    e -> {:error, e}
  end

  defp identity_template(jid, chat_name) do
    """
    # IDENTITY.md - Concierge for WhatsApp

    - Name: Concierge
    - Contact: #{chat_name}
    - JID: #{jid}
    - Created: #{DateTime.utc_now() |> DateTime.to_string()}
    - Role: assistant for the organization
    """
  end

  defp agents_template do
    """
    # AGENTS.md

    This workspace is isolated per WhatsApp JID.
    Tools are restricted by the system. No filesystem or exec tools.
    """
  end

  defp user_template(jid, chat_name) do
    """
    # USER.md - Contact Profile

    - Name: #{chat_name}
    - Platform: WhatsApp
    - JID: #{jid}
    - First interaction: #{DateTime.utc_now() |> DateTime.to_string()}

    ## Notes
    (memory of interactions will accumulate here)
    """
  end

  defp default_soul do
    """
    # SOUL.md - Concierge Personality (WhatsApp)

    You are Concierge, the official assistant for this organization.

    ## Tone
    - Professional and warm
    - Direct and helpful
    - Never sarcastic

    ## Rules
    - Max 500 characters
    - Never mention other conversations
    - If unsure, be honest
    """
  end

  defp resolve_soul_template do
    candidates = [
      Concierge.Paths.path("CONCIERGE.md"),
      Concierge.Paths.path("PROMPT.md"),
      Concierge.Paths.path("CONCIERGE_TEMPLATE.md")
    ]

    Enum.find(candidates, fn path -> File.exists?(path) end)
  end

  defp ensure_soul_link(soul_path) do
    template = resolve_soul_template() || Concierge.Paths.path("CONCIERGE_TEMPLATE.md")

    unless File.exists?(template) do
      File.write!(template, default_soul())
    end

    relink =
      case File.lstat(soul_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          case File.read_link(soul_path) do
            {:ok, target} ->
              target_path =
                if Path.type(target) == :absolute do
                  target
                else
                  Path.expand(Path.join(Path.dirname(soul_path), target))
                end

              Path.expand(target_path) != template

            _ ->
              true
          end

        {:ok, _} ->
          true

        _ ->
          true
      end

    if relink do
      if File.exists?(soul_path), do: File.rm(soul_path)
      File.ln_s(template, soul_path)
    end

    :ok
  end

  defp tools_template do
    """
    # TOOLS.md

    This workspace is restricted by the system tool allowlist.
    """
  end

  ## Clawdbot agent helpers

  defp ensure_clawdbot_agent(agent_id, jid) do
    workspace = Path.expand(Path.join(@agents_dir, jid))
    cmd = resolve_cli()

    cmd_timeout = ConfigServer.get([:clawdbot, :command_timeout_ms], 15_000)

    case run_cmd(cmd, ["agents", "add", agent_id, "--workspace", workspace], cmd_timeout) do
      {_output, 0} ->
        :ok

      {output, code} ->
        # If agent already exists, clawdbot returns non-zero; continue.
        Logger.warning("clawdbot agents add failed (may already exist)",
          code: code,
          output: output
        )

        :ok
    end

    _ =
      run_cmd(
        cmd,
        ["agents", "set-identity", "--workspace", workspace, "--from-identity"],
        cmd_timeout
      )

    if ConfigServer.get([:clawdbot, :apply_tool_policy], false) do
      ensure_tool_policy(cmd, agent_id, workspace)
    else
      :ok
    end
  end

  defp ensure_tool_policy(cmd, agent_id, workspace) do
    case agent_index(cmd, agent_id) do
      {:ok, idx} ->
        _ = config_set(cmd, "agents.list[#{idx}].workspace", workspace)
        _ = config_set(cmd, "agents.list[#{idx}].sandbox.mode", "all")
        _ = config_set(cmd, "agents.list[#{idx}].sandbox.scope", "agent")
        _ = config_set(cmd, "agents.list[#{idx}].sandbox.workspaceAccess", "none")
        _ = config_set(cmd, "agents.list[#{idx}].tools.allow", @tools_allowlist, json: true)
        :ok

      {:error, reason} ->
        Logger.error("Failed to resolve agent index; applying global tool allowlist",
          reason: inspect(reason)
        )

        _ = config_set(cmd, "agents.defaults.sandbox.mode", "all")
        _ = config_set(cmd, "agents.defaults.sandbox.scope", "session")
        _ = config_set(cmd, "agents.defaults.sandbox.workspaceAccess", "none")
        _ = config_set(cmd, "tools.allow", @tools_allowlist, json: true)
        :ok
    end
  end

  defp resolve_cli do
    ConfigServer.clawdbot_command()
  end

  defp agent_index(cmd, agent_id) do
    cmd_timeout = ConfigServer.get([:clawdbot, :command_timeout_ms], 15_000)

    case run_cmd(cmd, ["config", "get", "agents.list", "--json"], cmd_timeout) do
      {output, 0} ->
        with {:ok, list} <- parse_json5_list(output),
             idx when is_integer(idx) <- find_index(list, agent_id) do
          {:ok, idx}
        else
          _ ->
            Logger.error("Failed to resolve agent index", sample: safe_sample(output))
            {:error, :index_not_found}
        end

      {output, code} ->
        Logger.warning("clawdbot config get failed", code: code, output: output)
        {:error, :config_get_failed}
    end
  end

  defp find_index(list, agent_id) when is_list(list) do
    Enum.find_index(list, fn item ->
      is_map(item) and Map.get(item, "id") == agent_id
    end)
  end

  defp find_index(_, _), do: nil

  defp config_set(cmd, path, value, opts \\ []) do
    cmd_timeout = ConfigServer.get([:clawdbot, :command_timeout_ms], 15_000)

    args =
      if Keyword.get(opts, :json, false) do
        ["config", "set", path, Jason.encode!(value), "--json"]
      else
        ["config", "set", path, to_string(value)]
      end

    run_cmd(cmd, args, cmd_timeout)
  end

  defp run_cmd(cmd, args, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(cmd, args, stderr_to_stdout: true, env: [{"NODE_NO_WARNINGS", "1"}])
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"", 124}
    end
  end

  defp parse_json5_list(raw) do
    cleaned =
      raw
      |> strip_ansi()
      |> extract_json_block()
      |> strip_json5()
      |> String.trim()

    Jason.decode(cleaned)
  rescue
    _ -> {:error, :invalid_json}
  end

  defp strip_json5(text) do
    text
    |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
    |> String.replace(~r/\/\/.*$/, "", global: true)
    |> String.replace(~r/,\s*([}\]])/, "\\1")
  end

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\[[0-9;]*m/, "")
  end

  defp safe_sample(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 300)
  end

  defp extract_json_block(text) do
    start_idx =
      case :binary.match(text, "[") do
        {idx, _} -> idx
        :nomatch -> nil
      end

    end_idx =
      case :binary.matches(text, "]") do
        [] -> nil
        matches -> matches |> List.last() |> elem(0)
      end

    if is_integer(start_idx) and is_integer(end_idx) and end_idx > start_idx do
      String.slice(text, start_idx, end_idx - start_idx + 1)
    else
      text
    end
  end
end
