import Config

env = config_env()

parse_int = fn env_var, default ->
  case System.get_env(env_var) do
    nil ->
      default

    "" ->
      default

    raw ->
      case Integer.parse(String.trim(raw)) do
        {val, ""} -> val
        _ -> raise "Invalid integer for #{env_var}: #{inspect(raw)}"
      end
  end
end

parse_bool = fn env_var, default ->
  case System.get_env(env_var) do
    nil ->
      default

    "" ->
      default

    raw ->
      case String.downcase(String.trim(raw)) do
        "true" -> true
        "1" -> true
        "false" -> false
        "0" -> false
        _ -> raise "Invalid boolean for #{env_var}: #{inspect(raw)}"
      end
  end
end

non_empty_env = fn env_var ->
  case System.get_env(env_var) do
    nil ->
      nil

    val ->
      trimmed = String.trim(val)
      if trimmed == "", do: nil, else: val
  end
end

mqtt_enabled =
  case env do
    :prod -> parse_bool.("MQTT_ENABLED", true)
    :test -> parse_bool.("MQTT_ENABLED", false)
    _ -> parse_bool.("MQTT_ENABLED", false)
  end

config :greenhouse, Greenhouse.MQTT.Client,
  enabled: mqtt_enabled,
  host: non_empty_env.("MQTT_HOST") || "mqtt.example.com",
  port: parse_int.("MQTT_PORT", 1883),
  username: System.get_env("MQTT_USERNAME") || "customer-01",
  password: System.get_env("MQTT_PASSWORD") || "",
  client_id: non_empty_env.("MQTT_CLIENT_ID") || "greenhouse-backend-#{System.pid()}"

port_env =
  non_empty_env.("PORT") || non_empty_env.("HTTP_PORT")

cond do
  port_env not in [nil, ""] ->
    case Integer.parse(String.trim(port_env)) do
      {port, ""} ->
        config :greenhouse, Greenhouse.Web.Server, port: port

      _ ->
        raise "Invalid integer for PORT/HTTP_PORT: #{inspect(port_env)}"
    end

  env != :test ->
    config :greenhouse, Greenhouse.Web.Server, port: 4000

  true ->
    :ok
end

case System.get_env("DATA_DIR") do
  val when val not in [nil, ""] ->
    config :greenhouse, Greenhouse.Storage, data_dir: val
    config :greenhouse, Greenhouse.AccountStore, data_dir: val

  _ when env != :test ->
    config :greenhouse, Greenhouse.Storage, data_dir: "priv/data"
    config :greenhouse, Greenhouse.AccountStore, data_dir: "priv/data"

  _ ->
    :ok
end

case System.get_env("CONFIG_ACK_TIMEOUT_MS") do
  val when val not in [nil, ""] ->
    config :greenhouse, Greenhouse.ConfigManager,
      config_ack_timeout_ms: parse_int.("CONFIG_ACK_TIMEOUT_MS", 10_000)

  _ when env != :test ->
    config :greenhouse, Greenhouse.ConfigManager, config_ack_timeout_ms: 10_000

  _ ->
    :ok
end
