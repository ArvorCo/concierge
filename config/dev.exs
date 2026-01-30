import Config

# Development configuration

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:jid, :pid, :module],
  level: :debug
