import Config

config :greenhouse, Greenhouse.MQTT.Client, enabled: false

config :greenhouse, Greenhouse.Web.Server,
  port: 0,
  startup_log: false

config :greenhouse, Greenhouse.Storage, persist: false

config :greenhouse, Greenhouse.AccountStore,
  persist: false,
  seed_demo: false

config :greenhouse, Greenhouse.ConfigManager, config_ack_timeout_ms: 500

config :logger, level: :warning
