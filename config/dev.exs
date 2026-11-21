import Config

config :greenhouse, Greenhouse.MQTT.Client, enabled: false

config :greenhouse, Greenhouse.Web.Server, port: 4000

config :greenhouse, Greenhouse.Storage,
  persist: true,
  data_dir: "priv/data"

config :greenhouse, Greenhouse.AccountStore,
  persist: true,
  data_dir: "priv/data",
  seed_demo: false

config :logger, level: :info
