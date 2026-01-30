defmodule Concierge.ConfigServer do
  @moduledoc """
  Manages configuration with hot-reload capability.
  Watches config.json and reloads when changed.
  """

  use GenServer
  require Logger

  @config_file Path.expand(System.get_env("CONCIERGE_CONFIG") || "config.json")

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def enabled? do
    get(:enabled, true)
  end

  def get(key, default \\ nil) do
    GenServer.call(__MODULE__, {:get, key, default})
  end

  def clawdbot_command do
    configured = get([:clawdbot, :command])
    resolve_clawdbot_command(configured)
  end

  def random_wait_time do
    min = get([:filters, :min_wait_seconds], 30)
    max = get([:filters, :max_wait_seconds], 120)

    if max <= min do
      min
    else
      min + :rand.uniform(max - min)
    end
  end

  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  ## Server Callbacks

  @impl true
  def init(_state) do
    config = load_config() |> apply_runtime_paths()
    Logger.info("ConfigServer started", enabled: config[:enabled])
    {:ok, config}
  end

  @impl true
  def handle_call({:get, key, default}, _from, config) do
    value = get_in_config(config, key, default)
    {:reply, value, config}
  end

  @impl true
  def handle_cast(:reload, _config) do
    new_config = load_config() |> apply_runtime_paths()
    Logger.info("Config reloaded", enabled: new_config[:enabled])
    {:noreply, new_config}
  end

  ## Private Functions

  defp apply_runtime_paths(config) when is_map(config) do
    # Allow setting home dir via config (equivalent to CONCIERGE_HOME env).
    home_dir =
      get_in(config, [:paths, :home_dir]) ||
        get_in(config, [:CONCIERGE_HOME]) ||
        get_in(config, [:CONCIERGE_HOME])

    if is_binary(home_dir) and String.trim(home_dir) != "" do
      Concierge.Paths.set_home_dir(home_dir)
    end

    config
  end

  defp resolve_clawdbot_command(nil), do: find_clawdbot_command()
  defp resolve_clawdbot_command("auto"), do: find_clawdbot_command()

  defp resolve_clawdbot_command(cmd) when is_binary(cmd) do
    if System.find_executable(cmd) do
      cmd
    else
      find_clawdbot_command() || cmd
    end
  end

  defp find_clawdbot_command do
    System.find_executable("openclaw") ||
      System.find_executable("clawdbot") ||
      "openclaw"
  end

  defp load_config do
    path = Path.expand(@config_file)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms) do
          {:ok, config} ->
            config

          {:error, reason} ->
            Logger.error("Failed to parse config.json: #{inspect(reason)}")
            default_config()
        end

      {:error, reason} ->
        Logger.error("Failed to read config.json: #{inspect(reason)}")
        default_config()
    end
  end

  defp get_in_config(config, key, default) when is_list(key) do
    case get_in(config, key) do
      nil -> default
      value -> value
    end
  end

  defp get_in_config(config, key, default) do
    case Map.get(config, key) do
      nil -> default
      value -> value
    end
  end

  defp default_config do
    %{
      enabled: true,
      paths: %{
        home_dir: nil
      },
      hours: %{
        enabled: false,
        start: 0,
        end: 24,
        timezone: "UTC",
        weekdays_only: false
      },
      filters: %{
        only_dms: true,
        ignore_groups: false,
        ignore_broadcast: true,
        ignore_jids: [],
        max_response_length: 500,
        min_wait_seconds: 30,
        max_wait_seconds: 120
      },
      monitor: %{
        backlog_enabled: true,
        backlog_interval_seconds: 60,
        backlog_window_seconds: 600,
        backlog_retry_seconds: 300,
        backlog_catch_all_on_start: true,
        backlog_ignore_hours: false
      },
      safety: %{
        rate_limit_per_chat_per_hour: 10,
        require_human_approval_keywords: [],
        escalate_to_human_keywords: [],
        forbidden_words: [],
        processing_timeout_seconds: 180
      },
      human_takeover: %{
        auto_pause_hours: 3
      },
      sandbox_cleanup: %{
        enabled: true,
        interval_seconds: 3600,
        max_age_seconds: 3600,
        name_prefix: "clawdbot-sbx-",
        remove_running: false,
        dry_run: false
      },
      notifications: %{
        notify_on_new_message: true,
        notify_on_bot_response: true,
        notify_on_human_takeover: true,
        notify_on_escalation: true,
        notify_on_error: true,
        provider: "clawdbot"
      },
      clawdbot: %{
        command: "auto",
        config_path: nil,
        ensure_timeout_ms: 60000,
        command_timeout_ms: 15000,
        apply_tool_policy: false
      },
      sender: %{
        provider: "wacli",
        clawdbot_target: "jid",
        clawdbot_timeout_ms: 20000
      }
    }
  end
end
