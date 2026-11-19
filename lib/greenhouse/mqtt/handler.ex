defmodule Greenhouse.MQTT.Handler do
  @moduledoc """
  Routes incoming MQTT messages from Greenhouse devices to `Greenhouse.Storage`
  and `Greenhouse.ConfigManager` according to PROTOCOL.md.
  """

  require Logger

  @supported_version 2

  @typedoc "Metadata forwarded alongside an incoming MQTT PUBLISH packet."
  @type publish_meta :: %{
          optional(:qos) => 0 | 1 | 2,
          optional(:retain) => boolean(),
          optional(:dup) => boolean(),
          optional(:packet_id) => pos_integer() | nil,
          optional(:received_at_ms) => Greenhouse.timestamp_ms(),
          optional(:config_manager) => Greenhouse.server_ref()
        }

  @typedoc "Outcome of routing and persisting an incoming MQTT packet."
  @type handle_result ::
          :ok
          | {:ok,
             :recorded
             | Greenhouse.Storage.status_entry()
             | Greenhouse.Storage.alarm_entry()}
          | {:error,
             :invalid_payload
             | :unsupported_version
             | :invalid_telemetry
             | :invalid_status
             | :invalid_alarm}
          | {:duplicate, integer()}

  @doc """
  Handles an incoming MQTT `PUBLISH` message.

  Dispatches by topic pattern:
  - `gh/<deviceId>/telemetry` -> `Greenhouse.Storage.record_telemetry_compact/2,3`
  - `gh/<deviceId>/alarm/<code>` -> `Greenhouse.Storage.record_alarm/3,4`
  - `gh/<deviceId>/status` -> `Greenhouse.Storage.record_status/2,3`
  - `gh/<deviceId>/config/ack` -> `Greenhouse.ConfigManager.handle_ack/3,4`

  Accepts protocol versions `1..#{@supported_version}` (with optional `v` on
  `alarm`, `status`, and `config/ack`), and drops packets with protocol version
  `v > #{@supported_version}`, invalid JSON, non-map payloads, or unrecognized
  topics while logging a warning and never crashing.
  """
  @spec handle_message(term(), term()) :: handle_result()
  @spec handle_message(term(), term(), publish_meta() | term()) :: handle_result()
  def handle_message(topic, payload, meta \\ %{})

  def handle_message(topic, payload, meta) when is_binary(topic) and is_binary(payload) do
    received_at_ms = extract_received_at_ms(meta)

    case String.split(topic, "/") do
      ["gh", device_id, "telemetry"] when device_id != "" ->
        with {:ok, data} <- decode_json_map(topic, payload),
             :ok <- check_version(topic, data, true) do
          if received_at_ms do
            Greenhouse.Storage.record_telemetry_compact(device_id, data, received_at_ms)
          else
            Greenhouse.Storage.record_telemetry_compact(device_id, data)
          end
          |> log_storage_error(topic)
        end

      ["gh", device_id, "alarm", code | _] when device_id != "" and code != "" ->
        with {:ok, data} <- decode_json_map(topic, payload),
             :ok <- check_version(topic, data, false) do
          if received_at_ms do
            Greenhouse.Storage.record_alarm(device_id, code, data, received_at_ms)
          else
            Greenhouse.Storage.record_alarm(device_id, code, data)
          end
          |> log_storage_error(topic)
        end

      ["gh", device_id, "status"] when device_id != "" ->
        with {:ok, data} <- decode_json_map(topic, payload),
             :ok <- check_version(topic, data, false) do
          if received_at_ms do
            Greenhouse.Storage.record_status(device_id, data, received_at_ms)
          else
            Greenhouse.Storage.record_status(device_id, data)
          end
          |> log_storage_error(topic)
        end

      ["gh", device_id, "config", "ack"] when device_id != "" ->
        config_manager =
          if is_map(meta),
            do: Map.get(meta, :config_manager, Greenhouse.ConfigManager),
            else: Greenhouse.ConfigManager

        with {:ok, data} <- decode_json_map(topic, payload),
             :ok <- check_version(topic, data, false) do
          if received_at_ms do
            Greenhouse.ConfigManager.handle_ack(config_manager, device_id, data, received_at_ms)
          else
            Greenhouse.ConfigManager.handle_ack(config_manager, device_id, data)
          end
        end

      _ ->
        Logger.warning("Dropping MQTT message on unexpected topic #{inspect(topic)}")
        {:error, :invalid_payload}
    end
  end

  def handle_message(topic, _payload, _meta) do
    Logger.warning("Dropping malformed MQTT message with topic #{inspect(topic)}")
    {:error, :invalid_payload}
  end

  @spec extract_received_at_ms(term()) :: Greenhouse.timestamp_ms() | nil
  defp extract_received_at_ms(meta) when is_map(meta) do
    case Map.get(meta, :received_at_ms) do
      ms when is_integer(ms) -> ms
      _ -> nil
    end
  end

  defp extract_received_at_ms(_meta), do: nil

  @spec log_storage_error(handle_result(), String.t()) :: handle_result()
  defp log_storage_error({:error, reason} = err, topic) when is_binary(topic) do
    Logger.warning("Dropping MQTT message on #{inspect(topic)}: #{inspect(reason)}")
    err
  end

  defp log_storage_error(result, _topic), do: result

  @spec decode_json_map(String.t(), binary()) ::
          {:ok, Greenhouse.json_map()} | {:error, :invalid_payload}
  defp decode_json_map(topic, payload) when is_binary(topic) and is_binary(payload) do
    case JSON.decode(payload) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:ok, _other} ->
        Logger.warning("Dropping non-object JSON payload on topic #{inspect(topic)}")
        {:error, :invalid_payload}

      {:error, reason} ->
        Logger.warning(
          "Dropping invalid JSON payload on topic #{inspect(topic)}: #{inspect(reason)}"
        )

        {:error, :invalid_payload}
    end
  end

  @spec check_version(String.t(), Greenhouse.json_map(), boolean()) ::
          :ok | {:error, :unsupported_version | :invalid_payload}
  defp check_version(topic, data, require_v?)
       when is_binary(topic) and is_map(data) and is_boolean(require_v?) do
    case Map.get(data, "v") do
      v when is_integer(v) and v >= 1 and v <= @supported_version ->
        :ok

      v when is_integer(v) and v > @supported_version ->
        Logger.warning(
          "Dropping MQTT message on #{inspect(topic)} with unsupported protocol version v=#{v}"
        )

        {:error, :unsupported_version}

      nil when not require_v? ->
        :ok

      other ->
        Logger.warning(
          "Dropping MQTT message on #{inspect(topic)} with invalid protocol version #{inspect(other)}"
        )

        {:error, :invalid_payload}
    end
  end
end
