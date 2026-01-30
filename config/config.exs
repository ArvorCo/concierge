import Config

# Configure logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:jid, :pid, :module]

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Import environment specific config
import_config "#{config_env()}.exs"
