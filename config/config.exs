import Config

config :greenhouse, Greenhouse.MQTT.Client,
  enabled: false,
  host: "mqtt.example.com",
  port: 1883,
  username: "customer-01",
  password: "",
  keep_alive: 60,
  initial_backoff_ms: 1_000,
  max_backoff_ms: 60_000

config :greenhouse, Greenhouse.Web.Server, port: 4000

config :greenhouse, Greenhouse.Storage,
  persist: true,
  data_dir: "priv/data"

config :greenhouse, Greenhouse.AccountStore,
  persist: true,
  data_dir: "priv/data",
  seed_demo: true

config :greenhouse, Greenhouse.ConfigManager, config_ack_timeout_ms: 10_000

env_config = "#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end
