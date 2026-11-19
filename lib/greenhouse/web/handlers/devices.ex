defmodule Greenhouse.Web.Handlers.Devices do
  @moduledoc """
  HTTP handlers for health checks, device snapshots, telemetry queries, alarms,
  configuration updates, simulation triggers, and demo reset endpoints.
  """

  alias Greenhouse.{ConfigManager, ConfigValidator, Support}
  alias Greenhouse.Web.{Params, Respond, Router}

  @typedoc "Handler dependency injection options."
  @type options :: [Router.handler_option()]

  @doc """
  Handles `GET /health` and `GET /api/v1/health`.
  """
  @spec health(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def health(%Plug.Conn{} = conn, opts) when is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    mqtt_client = Keyword.get(opts, :mqtt_client, Greenhouse.MQTT.Client)

    mqtt_status =
      try do
        if is_atom(mqtt_client) do
          mqtt_client.status()
        else
          Greenhouse.MQTT.Client.status(mqtt_client)
        end
      rescue
        _ -> %{connected: false, available: false}
      catch
        :exit, _ -> %{connected: false, available: false}
      end

    device_count =
      try do
        if Code.ensure_loaded?(storage) and function_exported?(storage, :device_count, 0) do
          storage.device_count()
        else
          length(storage.list_devices())
        end
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    Respond.json(conn, 200, %{
      ok: true,
      status: "healthy",
      mqtt: mqtt_status,
      device_count: device_count,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Handles `POST /api/v1/dev/reset`.
  """
  @spec dev_reset(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def dev_reset(%Plug.Conn{} = conn, opts) when is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)
    :ok = account_store.reset_demo!()
    Respond.json(conn, 200, %{ok: true})
  end

  @doc """
  Handles `GET /api/v1/devices`.
  """
  @spec list_devices(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def list_devices(%Plug.Conn{} = conn, opts) when is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    Respond.json(conn, 200, %{ok: true, data: storage.list_devices()})
  end

  @doc """
  Handles `GET /api/v1/devices/:device_id`.
  """
  @spec show_device(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def show_device(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})

    case storage.get_device(device_id) do
      {:ok, snapshot} ->
        Respond.json(conn, 200, %{ok: true, data: snapshot})

      {:error, :not_found} ->
        Respond.json(conn, 404, %{ok: false, error: "not_found", message: "Device not found"})
    end
  end

  @doc """
  Handles `GET /api/v1/devices/:device_id/status`.
  """
  @spec show_status(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def show_status(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})

    case storage.get_device_status(device_id) do
      {:ok, status} ->
        Respond.json(conn, 200, %{ok: true, data: status})

      {:error, :not_found} ->
        Respond.json(conn, 404, %{
          ok: false,
          error: "not_found",
          message: "Device status not found"
        })
    end
  end

  @doc """
  Handles `GET /api/v1/devices/:device_id/telemetry/latest` and `.../current`.
  """
  @spec latest_telemetry(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def latest_telemetry(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})

    case storage.get_latest_telemetry(device_id) do
      {:ok, telemetry} ->
        Respond.json(conn, 200, %{ok: true, data: telemetry})

      {:error, :not_found} ->
        Respond.json(conn, 404, %{ok: false, error: "not_found", message: "Telemetry not found"})
    end
  end

  @doc """
  Handles `GET /api/v1/devices/:device_id/telemetry` and `.../history`.
  """
  @spec telemetry_history(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def telemetry_history(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})
    history_opts = Params.parse_history_opts(conn.query_params)

    case storage.get_telemetry_history(device_id, history_opts) do
      {:ok, history_result} ->
        Respond.json(conn, 200, %{ok: true, data: history_result})

      {:error, :not_found} ->
        Respond.json(conn, 404, %{ok: false, error: "not_found", message: "Device not found"})
    end
  end

  @doc """
  Handles `GET /api/v1/devices/:device_id/telemetry/stats`.
  """
  @spec telemetry_stats(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def telemetry_stats(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})
    stats_opts = Params.parse_stats_opts(conn.query_params)

    case storage.get_telemetry_stats(device_id, stats_opts) do
      {:ok, stats_result} ->
        Respond.json(conn, 200, %{ok: true, data: stats_result})

      {:error, :not_found} ->
        Respond.json(conn, 404, %{ok: false, error: "not_found", message: "Device not found"})
    end
  end

  @doc """
  Handles `GET /api/v1/devices/:device_id/alarms`.
  """
  @spec list_alarms(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def list_alarms(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})
    active_only = Params.parse_bool_param(conn.query_params["active_only"])

    {:ok, alarms} = storage.get_alarms(device_id, active_only: active_only)
    Respond.json(conn, 200, %{ok: true, data: alarms})
  end

  @doc """
  Handles `POST /api/v1/devices/:device_id/alarms/:code/clear` and `DELETE .../alarms/:code`.
  """
  @spec clear_alarm(Plug.Conn.t(), Greenhouse.device_id(), String.t(), options()) :: Plug.Conn.t()
  def clear_alarm(%Plug.Conn{} = conn, device_id, code, opts)
      when is_binary(device_id) and is_binary(code) and is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    conn = Params.put_path_params(conn, %{"device_id" => device_id, "code" => code})

    case storage.clear_alarm(device_id, code, "manual_api") do
      {:ok, alarm} ->
        Respond.json(conn, 200, %{ok: true, data: alarm})

      {:error, :not_found} ->
        Respond.json(conn, 404, %{ok: false, error: "not_found", message: "Alarm not found"})
    end
  end

  @doc """
  Handles `GET /api/v1/devices/:device_id/config`.
  """
  @spec show_config(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def show_config(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})

    {:ok, config} = storage.get_config(device_id)
    Respond.json(conn, 200, %{ok: true, data: config})
  end

  @doc """
  Handles `PATCH / PUT / POST /api/v1/devices/:device_id/config`.
  """
  @spec update_config(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def update_config(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    config_manager = Keyword.get(opts, :config_manager, ConfigManager)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})
    apply_opts = Params.parse_unit_opts(conn.query_params, conn.body_params)
    config_params = Params.strip_unit_param(conn.body_params)

    case apply_device_config(config_manager, device_id, config_params, apply_opts) do
      {:ok, updated_config} ->
        Respond.json(conn, 200, %{ok: true, data: updated_config})

      {:error, {:validation_failed, errors}} ->
        Respond.json(conn, 422, %{ok: false, error: "validation_failed", details: errors})

      {:error, {:device_rejected, "syntax"}} ->
        Respond.json(conn, 400, %{ok: false, error: "device_syntax_error", reason: "syntax"})

      {:error, {:device_rejected, reason}} ->
        Respond.json(conn, 422, %{ok: false, error: "device_rejected", reason: reason})

      {:error, :ack_timeout} ->
        Respond.json(conn, 504, %{
          ok: false,
          error: "ack_timeout",
          message: "Device did not respond within timeout and was marked offline"
        })

      {:error, :mqtt_disconnected} ->
        if Params.parse_bool_param(conn.query_params["cache_fallback"]) do
          handle_config_cache_fallback(conn, device_id, config_params, apply_opts, opts)
        else
          Respond.json(conn, 503, %{
            ok: false,
            error: "mqtt_disconnected",
            message: "MQTT broker connection is currently unavailable"
          })
        end

      {:error, :config_in_progress} ->
        Respond.json(conn, 409, %{
          ok: false,
          error: "config_in_progress",
          message: "A configuration update is already in progress for this device"
        })

      {:error, reason} ->
        Respond.json(conn, 500, %{ok: false, error: "internal_error", message: inspect(reason)})
    end
  end

  @doc """
  Handles `POST /api/v1/devices/:device_id/simulate`.
  """
  @spec simulate(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def simulate(%Plug.Conn{} = conn, device_id, opts)
      when is_binary(device_id) and is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})

    scenario =
      Map.get(conn.body_params, "scenario") ||
        Map.get(conn.body_params, :scenario)

    case account_store.simulate_scenario(device_id, scenario) do
      {:ok, snapshot} ->
        Respond.json(conn, 200, %{ok: true, data: snapshot})

      {:error, status, error_code, message} ->
        Respond.json(conn, status, %{ok: false, error: error_code, message: message})
    end
  end

  @spec apply_device_config(
          Greenhouse.server_ref(),
          Greenhouse.device_id(),
          map(),
          [Params.unit_opt()]
        ) :: ConfigManager.apply_result() | {:error, term()}
  defp apply_device_config(config_manager, device_id, config_params, apply_opts)
       when is_atom(config_manager) and is_binary(device_id) and is_map(config_params) and
              is_list(apply_opts) do
    config_manager.apply_config(device_id, config_params, apply_opts)
  end

  defp apply_device_config(config_manager, device_id, config_params, apply_opts)
       when is_binary(device_id) and is_map(config_params) and is_list(apply_opts) do
    ConfigManager.apply_config(config_manager, device_id, config_params, apply_opts)
  end

  @spec handle_config_cache_fallback(
          Plug.Conn.t(),
          Greenhouse.device_id(),
          map(),
          [Params.unit_opt()],
          options()
        ) :: Plug.Conn.t()
  defp handle_config_cache_fallback(
         %Plug.Conn{} = conn,
         device_id,
         config_params,
         apply_opts,
         opts
       )
       when is_binary(device_id) and is_map(config_params) and is_list(apply_opts) and
              is_list(opts) do
    storage = Keyword.get(opts, :storage, Greenhouse.Storage)

    normalized_input =
      if Keyword.get(apply_opts, :unit) == :human do
        ConfigValidator.from_human(config_params)
      else
        config_params
      end

    current_raw = Support.fetch_raw_config(storage, device_id)

    case ConfigValidator.validate_patch(normalized_input, current_raw) do
      {:ok, wire_patch} ->
        {:ok, updated_config} = storage.update_config_cache(device_id, wire_patch)
        Respond.json(conn, 200, %{ok: true, data: updated_config, simulated_ack: true})

      {:error, errors} ->
        Respond.json(conn, 422, %{ok: false, error: "validation_failed", details: errors})
    end
  end
end
