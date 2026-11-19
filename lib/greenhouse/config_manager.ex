defmodule Greenhouse.ConfigManager do
  @moduledoc """
  GenServer coordinating downlink device configuration updates (`gh/<deviceId>/config`)
  and matching `gh/<deviceId>/config/ack` responses with timeout handling.
  """

  use GenServer
  require Logger

  @default_ack_timeout_ms 10_000
  @hibernate_after_ms 15_000

  @typedoc "GenServer reference for `ConfigManager`."
  @type server :: GenServer.server()

  @typedoc "Publish callback signature used to send wire configuration patches."
  @type publish_fn :: (String.t(), binary(), keyword() -> :ok | {:error, term()})

  @typedoc "Unit selector accepted by `apply_config/3` and `apply_config/4`."
  @type unit_opt :: :raw | :human | String.t()

  @typedoc "Per-request options for `apply_config/3` and `apply_config/4`."
  @type apply_option :: {:unit, unit_opt()} | {:timeout, pos_integer()}

  @typedoc "Startup options accepted by `start_link/1`."
  @type option ::
          {:name, GenServer.name() | nil}
          | {:publish_fn, publish_fn()}
          | {:config_ack_timeout_ms, pos_integer()}
          | {:storage_mod, module()}
          | {:hibernate_after_ms, pos_integer()}

  @typedoc "Pending device configuration acknowledgement waiter entry."
  @type waiter :: %{
          from: GenServer.from(),
          ref: reference(),
          timer_ref: reference(),
          wire_patch: Greenhouse.ConfigValidator.wire_patch()
        }

  @typedoc "Result returned by `apply_config/2,3,4`."
  @type apply_result ::
          {:ok, map()}
          | {:error,
             {:validation_failed, [String.t()]}
             | {:device_rejected, String.t()}
             | :ack_timeout
             | :mqtt_disconnected
             | :config_in_progress}

  @enforce_keys [:config_ack_timeout_ms, :publish_fn, :storage_mod, :waiters]
  defstruct [:config_ack_timeout_ms, :publish_fn, :storage_mod, :waiters]

  @typedoc "Internal GenServer state struct for `Greenhouse.ConfigManager`."
  @type state :: %__MODULE__{
          config_ack_timeout_ms: pos_integer(),
          publish_fn: publish_fn(),
          storage_mod: module(),
          waiters: %{optional(Greenhouse.device_id()) => waiter()}
        }

  @doc """
  Starts the `ConfigManager` GenServer.

  Options:
  - `:name` - process registration name (defaults to `#{__MODULE__}`, pass `nil` for unnamed)
  - `:publish_fn` - 3-arity function `(topic, payload, opts) -> :ok | {:error, term()}`
    (defaults to `&Greenhouse.MQTT.Client.publish/3`)
  - `:config_ack_timeout_ms` - default ack timeout in milliseconds (defaults to app env or `10_000`)
  - `:storage_mod` - storage module (defaults to `Greenhouse.Storage`)
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {hibernate_after, opts} = Keyword.pop(opts, :hibernate_after_ms, @hibernate_after_ms)

    case Keyword.get(opts, :name, __MODULE__) do
      nil ->
        GenServer.start_link(__MODULE__, opts, hibernate_after: hibernate_after)

      name ->
        GenServer.start_link(__MODULE__, opts, name: name, hibernate_after: hibernate_after)
    end
  end

  @doc """
  Validates, publishes, and awaits device acknowledgement for a configuration patch.

  Options:
  - `:unit` - `:human` or `"human"` to convert human temperature/humidity units to wire `0.01` integers
  - `:timeout` - per-call ack timeout in milliseconds
  """
  @spec apply_config(Greenhouse.device_id(), term()) :: apply_result()
  @spec apply_config(Greenhouse.device_id(), term(), [apply_option()]) :: apply_result()
  @spec apply_config(server(), Greenhouse.device_id(), term()) :: apply_result()
  @spec apply_config(server(), Greenhouse.device_id(), term(), [apply_option()]) :: apply_result()
  def apply_config(device_id, patch_params) when is_binary(device_id) do
    apply_config(__MODULE__, device_id, patch_params, [])
  end

  def apply_config(device_id, patch_params, opts)
      when is_binary(device_id) and is_list(opts) do
    apply_config(__MODULE__, device_id, patch_params, opts)
  end

  def apply_config(server, device_id, patch_params)
      when not is_binary(server) and is_binary(device_id) do
    apply_config(server, device_id, patch_params, [])
  end

  def apply_config(server, device_id, patch_params, opts)
      when not is_binary(server) and is_binary(device_id) and is_list(opts) do
    GenServer.call(server, {:apply_config, device_id, patch_params, opts}, :infinity)
  end

  @doc """
  Processes an incoming `gh/<deviceId>/config/ack` JSON map from a device.

  Per PROTOCOL.md §4.2, `config/ack` omits `b` and uses `received_at_ms` as the
  receipt timestamp recorded on the updated configuration cache entry.
  """
  @spec handle_ack(Greenhouse.device_id(), Greenhouse.json_map()) :: :ok
  @spec handle_ack(Greenhouse.device_id(), Greenhouse.json_map(), Greenhouse.timestamp_ms()) ::
          :ok
  @spec handle_ack(server(), Greenhouse.device_id(), Greenhouse.json_map()) :: :ok
  @spec handle_ack(
          server(),
          Greenhouse.device_id(),
          Greenhouse.json_map(),
          Greenhouse.timestamp_ms()
        ) :: :ok
  def handle_ack(device_id, ack_map) when is_binary(device_id) and is_map(ack_map) do
    handle_ack(__MODULE__, device_id, ack_map, System.system_time(:millisecond))
  end

  def handle_ack(device_id, ack_map, received_at_ms)
      when is_binary(device_id) and is_map(ack_map) and is_integer(received_at_ms) do
    handle_ack(__MODULE__, device_id, ack_map, received_at_ms)
  end

  def handle_ack(server, device_id, ack_map)
      when not is_binary(server) and is_binary(device_id) and is_map(ack_map) do
    handle_ack(server, device_id, ack_map, System.system_time(:millisecond))
  end

  def handle_ack(server, device_id, ack_map, received_at_ms)
      when not is_binary(server) and is_binary(device_id) and is_map(ack_map) and
             is_integer(received_at_ms) do
    GenServer.cast(server, {:handle_ack, device_id, ack_map, received_at_ms})
  end

  @impl GenServer
  @spec init([option()]) :: {:ok, state()}
  def init(opts) when is_list(opts) do
    app_cfg = Application.get_env(:greenhouse, __MODULE__, [])

    timeout_ms =
      Keyword.get(
        opts,
        :config_ack_timeout_ms,
        Keyword.get(app_cfg, :config_ack_timeout_ms, @default_ack_timeout_ms)
      )

    state = %__MODULE__{
      config_ack_timeout_ms: timeout_ms,
      publish_fn: Keyword.get(opts, :publish_fn, &Greenhouse.MQTT.Client.publish/3),
      storage_mod: Keyword.get(opts, :storage_mod, Greenhouse.Storage),
      waiters: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  @spec handle_call(
          {:apply_config, Greenhouse.device_id(), term(), [apply_option()]},
          GenServer.from(),
          state()
        ) :: {:reply, apply_result(), state()} | {:noreply, state()}
  def handle_call({:apply_config, device_id, patch_params, opts}, from, %__MODULE__{} = state)
      when is_binary(device_id) and is_list(opts) do
    cond do
      device_id == "" ->
        {:reply, {:error, {:validation_failed, ["device_id must be a non-empty string"]}}, state}

      not is_map(patch_params) ->
        {:reply, {:error, {:validation_failed, ["configuration patch must be a map"]}}, state}

      Map.has_key?(state.waiters, device_id) ->
        {:reply, {:error, :config_in_progress}, state}

      true ->
        execute_apply(device_id, patch_params, opts, from, state)
    end
  end

  @impl GenServer
  @spec handle_cast(
          {:handle_ack, Greenhouse.device_id(), Greenhouse.json_map()}
          | {:handle_ack, Greenhouse.device_id(), Greenhouse.json_map(),
             Greenhouse.timestamp_ms()},
          state()
        ) :: {:noreply, state()}
  def handle_cast({:handle_ack, device_id, ack_map}, %__MODULE__{} = state)
      when is_binary(device_id) and is_map(ack_map) do
    handle_cast(
      {:handle_ack, device_id, ack_map, System.system_time(:millisecond)},
      state
    )
  end

  def handle_cast(
        {:handle_ack, device_id, ack_map, received_at_ms},
        %__MODULE__{} = state
      )
      when is_binary(device_id) and is_map(ack_map) and is_integer(received_at_ms) do
    case Map.get(state.waiters, device_id) do
      nil ->
        Logger.debug("Ignoring config ack for #{device_id} with no pending request")
        {:noreply, state}

      waiter ->
        new_state = resolve_waiter(device_id, waiter, ack_map, received_at_ms, state)
        {:noreply, new_state}
    end
  end

  @impl GenServer
  @spec handle_info({:ack_timeout, Greenhouse.device_id(), reference()}, state()) ::
          {:noreply, state()}
  def handle_info({:ack_timeout, device_id, ref}, %__MODULE__{} = state)
      when is_binary(device_id) and is_reference(ref) do
    case Map.get(state.waiters, device_id) do
      %{ref: ^ref, from: from} ->
        Logger.warning("Config ack timeout for #{device_id}; marking device offline")
        state.storage_mod.mark_device_offline(device_id, "config_ack_timeout")
        GenServer.reply(from, {:error, :ack_timeout})
        {:noreply, %{state | waiters: Map.delete(state.waiters, device_id)}}

      _ ->
        {:noreply, state}
    end
  end

  @spec execute_apply(
          Greenhouse.device_id(),
          map(),
          [apply_option()],
          GenServer.from(),
          state()
        ) :: {:reply, apply_result(), state()} | {:noreply, state()}
  defp execute_apply(device_id, patch_params, opts, from, %__MODULE__{} = state)
       when is_binary(device_id) and is_map(patch_params) and is_list(opts) do
    normalized_input = maybe_convert_human(patch_params, opts)
    current_raw = fetch_current_raw(state.storage_mod, device_id)

    case Greenhouse.ConfigValidator.validate_patch(normalized_input, current_raw) do
      {:error, errors} ->
        {:reply, {:error, {:validation_failed, errors}}, state}

      {:ok, wire_patch} ->
        topic = "gh/#{device_id}/config"
        payload = JSON.encode!(wire_patch)

        case safe_publish(state.publish_fn, topic, payload) do
          :ok ->
            timeout_ms = Keyword.get(opts, :timeout, state.config_ack_timeout_ms)
            ref = make_ref()
            timer_ref = Process.send_after(self(), {:ack_timeout, device_id, ref}, timeout_ms)

            waiter = %{
              from: from,
              ref: ref,
              timer_ref: timer_ref,
              wire_patch: wire_patch
            }

            {:noreply, %{state | waiters: Map.put(state.waiters, device_id, waiter)}}

          {:error, reason} ->
            Logger.warning("Failed to publish config to #{topic}: #{inspect(reason)}")
            {:reply, {:error, :mqtt_disconnected}, state}
        end
    end
  end

  @spec resolve_waiter(
          Greenhouse.device_id(),
          waiter(),
          Greenhouse.json_map(),
          Greenhouse.timestamp_ms(),
          state()
        ) :: state()
  defp resolve_waiter(
         device_id,
         waiter,
         %{"ok" => true},
         received_at_ms,
         %__MODULE__{} = state
       )
       when is_binary(device_id) and is_map(waiter) and is_integer(received_at_ms) do
    cancel_and_flush_timer(waiter.timer_ref, device_id, waiter.ref)

    {:ok, updated_config} =
      update_config_cache(state.storage_mod, device_id, waiter.wire_patch, received_at_ms)

    GenServer.reply(waiter.from, {:ok, updated_config})
    %{state | waiters: Map.delete(state.waiters, device_id)}
  end

  defp resolve_waiter(
         device_id,
         waiter,
         %{"ok" => false} = ack_map,
         _received_at_ms,
         %__MODULE__{} = state
       )
       when is_binary(device_id) and is_map(waiter) do
    cancel_and_flush_timer(waiter.timer_ref, device_id, waiter.ref)

    reason =
      case Map.get(ack_map, "reason") do
        r when is_binary(r) and r != "" -> r
        _ -> "rejected"
      end

    GenServer.reply(waiter.from, {:error, {:device_rejected, reason}})
    %{state | waiters: Map.delete(state.waiters, device_id)}
  end

  defp resolve_waiter(device_id, _waiter, ack_map, _received_at_ms, %__MODULE__{} = state)
       when is_binary(device_id) do
    Logger.warning("Ignoring malformed config ack for #{device_id}: #{inspect(ack_map)}")

    state
  end

  @spec update_config_cache(
          module(),
          Greenhouse.device_id(),
          Greenhouse.ConfigValidator.wire_patch(),
          Greenhouse.timestamp_ms()
        ) :: {:ok, map()}
  defp update_config_cache(storage_mod, device_id, wire_patch, received_at_ms)
       when is_atom(storage_mod) and is_binary(device_id) and is_map(wire_patch) and
              is_integer(received_at_ms) do
    if Code.ensure_loaded?(storage_mod) and
         function_exported?(storage_mod, :update_config_cache, 3) do
      storage_mod.update_config_cache(device_id, wire_patch, received_at_ms)
    else
      storage_mod.update_config_cache(device_id, wire_patch)
    end
  end

  @spec cancel_and_flush_timer(reference(), Greenhouse.device_id(), reference()) :: :ok
  defp cancel_and_flush_timer(timer_ref, device_id, ref)
       when is_reference(timer_ref) and is_binary(device_id) and is_reference(ref) do
    _ = Process.cancel_timer(timer_ref)

    receive do
      {:ack_timeout, ^device_id, ^ref} -> :ok
    after
      0 -> :ok
    end
  end

  @spec maybe_convert_human(map(), [apply_option()]) :: map()
  defp maybe_convert_human(patch_params, opts) when is_map(patch_params) and is_list(opts) do
    if Keyword.get(opts, :unit) in [:human, "human"] do
      Greenhouse.ConfigValidator.from_human(patch_params)
    else
      patch_params
    end
  end

  @spec fetch_current_raw(module(), Greenhouse.device_id()) :: map()
  defp fetch_current_raw(storage_mod, device_id)
       when is_atom(storage_mod) and is_binary(device_id) do
    Greenhouse.Support.fetch_raw_config(storage_mod, device_id)
  end

  @spec safe_publish(publish_fn(), String.t(), binary()) :: :ok | {:error, term()}
  defp safe_publish(publish_fn, topic, payload)
       when is_function(publish_fn, 3) and is_binary(topic) and is_binary(payload) do
    case publish_fn.(topic, payload, qos: 1, retain: false) do
      :ok -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_publish_result, other}}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
