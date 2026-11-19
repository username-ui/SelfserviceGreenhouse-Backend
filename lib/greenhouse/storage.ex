defmodule Greenhouse.Storage do
  @moduledoc """
  In-memory ETS storage with optional DETS persistence for greenhouse device
  status, telemetry, alarms, and configuration caches.

  Telemetry history, latest telemetry, and config caches are stored in compact
  tuples in ETS/DETS via `Greenhouse.Storage.Codec`, queried via
  `Greenhouse.Storage.Query`, and bounded via `Greenhouse.Storage.Retention`.
  """

  use GenServer

  alias Greenhouse.Storage.{Codec, Query, Retention}
  alias Greenhouse.Support
  alias Greenhouse.Support.DETS

  @devices_table :gh_devices
  @telemetry_latest_table :gh_telemetry_latest
  @telemetry_history_table :gh_telemetry_history
  @alarms_table :gh_alarms
  @configs_table :gh_configs

  @all_ets_tables [
    @devices_table,
    @telemetry_latest_table,
    @telemetry_history_table,
    @alarms_table,
    @configs_table
  ]

  @dets_table_specs [
    {@devices_table, :gh_devices_dets, "devices.dets"},
    {@telemetry_latest_table, :gh_telemetry_latest_dets, "telemetry_latest.dets"},
    {@telemetry_history_table, :gh_telemetry_history_dets, "telemetry_history.dets"},
    {@alarms_table, :gh_alarms_dets, "alarms.dets"},
    {@configs_table, :gh_configs_dets, "configs.dets"}
  ]

  @default_max_history_per_device 10_000
  @hibernate_after_ms 15_000

  @typedoc "Startup options accepted by `start_link/1`."
  @type option ::
          {:name, GenServer.name() | nil}
          | {:persist, boolean()}
          | {:data_dir, Path.t()}
          | {:max_history_per_device, non_neg_integer() | nil}
          | {:hibernate_after_ms, pos_integer()}

  @typedoc "Device online/offline status entry stored on a device record."
  @type status_entry :: %{
          device_id: Greenhouse.device_id(),
          online: boolean(),
          b: String.t() | nil,
          up: integer() | nil,
          offline_reason: String.t() | nil,
          updated_at: Greenhouse.iso8601_timestamp(),
          updated_at_ms: Greenhouse.timestamp_ms()
        }

  @typedoc "Alarm entry persisted in `:gh_alarms`."
  @type alarm_entry :: %{
          device_id: Greenhouse.device_id(),
          code: String.t(),
          active: boolean(),
          v: integer() | nil,
          b: String.t() | nil,
          up: integer() | nil,
          clear_reason: String.t() | nil,
          cleared_at: Greenhouse.iso8601_timestamp() | nil,
          cleared_at_ms: Greenhouse.timestamp_ms() | nil,
          received_at: Greenhouse.iso8601_timestamp(),
          received_at_ms: Greenhouse.timestamp_ms(),
          updated_at: Greenhouse.iso8601_timestamp(),
          updated_at_ms: Greenhouse.timestamp_ms()
        }

  @typedoc "Internal device metadata record stored in `:gh_devices`."
  @type device_record :: %{
          device_id: Greenhouse.device_id(),
          status: status_entry() | nil,
          last_b: String.t() | nil,
          last_seq: integer() | nil,
          last_up: integer() | nil,
          last_seen_at_ms: Greenhouse.timestamp_ms() | nil
        }

  @typedoc "Device summary item returned by `list_devices/0`."
  @type device_overview :: %{
          device_id: Greenhouse.device_id(),
          online: boolean(),
          status: status_entry() | nil,
          latest_telemetry: Codec.telemetry_entry() | map() | nil,
          active_alarms: [alarm_entry()],
          active_alarm_count: non_neg_integer(),
          last_seen_at: Greenhouse.iso8601_timestamp() | nil,
          last_seen_at_ms: Greenhouse.timestamp_ms() | nil
        }

  @typedoc "Detailed device snapshot returned by `get_device/1` and `get_device_with_all_alarms/1`."
  @type device_snapshot :: %{
          device_id: Greenhouse.device_id(),
          status: status_entry() | nil,
          latest_telemetry: Codec.telemetry_entry() | map() | nil,
          active_alarms: [alarm_entry()],
          config: Codec.config_entry(),
          last_seen_at: Greenhouse.iso8601_timestamp() | nil,
          last_seen_at_ms: Greenhouse.timestamp_ms() | nil
        }

  defstruct persist: false,
            data_dir: "priv/data",
            dets_tables: %{},
            history_counter: 0,
            history_counts: %{},
            max_history_per_device: @default_max_history_per_device

  @typedoc "Internal GenServer state struct for `Greenhouse.Storage`."
  @type state :: %__MODULE__{
          persist: boolean(),
          data_dir: Path.t(),
          dets_tables: DETS.dets_map(),
          history_counter: non_neg_integer(),
          history_counts: Retention.counts_map(),
          max_history_per_device: non_neg_integer() | nil
        }

  # --- Client API ---

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

  @spec reset!() :: :ok
  def reset! do
    GenServer.call(__MODULE__, :reset)
  end

  @spec device_count() :: non_neg_integer()
  def device_count do
    :ets.info(@devices_table, :size) || 0
  end

  @spec record_telemetry(term(), term()) ::
          {:ok, Codec.telemetry_entry() | map()}
          | {:duplicate, integer()}
          | {:error, :invalid_telemetry}
  @spec record_telemetry(term(), term(), term()) ::
          {:ok, Codec.telemetry_entry() | map()}
          | {:duplicate, integer()}
          | {:error, :invalid_telemetry}
  def record_telemetry(device_id, payload, received_at_ms \\ System.system_time(:millisecond))

  def record_telemetry(device_id, payload, received_at_ms)
      when is_binary(device_id) and byte_size(device_id) > 0 and is_map(payload) and
             is_integer(received_at_ms) do
    case Codec.parse_telemetry_payload(payload) do
      {:ok, compact_fields, extra} ->
        case GenServer.call(
               __MODULE__,
               {:record_telemetry, Support.detach_binary(device_id), compact_fields, extra,
                received_at_ms, true}
             ) do
          {:ok, latest_record} -> {:ok, Codec.expand_latest_record(latest_record)}
          other -> other
        end

      :error ->
        {:error, :invalid_telemetry}
    end
  end

  def record_telemetry(_device_id, _payload, _received_at_ms), do: {:error, :invalid_telemetry}

  @spec record_telemetry_compact(term(), term()) ::
          {:ok, :recorded} | {:duplicate, integer()} | {:error, :invalid_telemetry}
  @spec record_telemetry_compact(term(), term(), term()) ::
          {:ok, :recorded} | {:duplicate, integer()} | {:error, :invalid_telemetry}
  def record_telemetry_compact(
        device_id,
        payload,
        received_at_ms \\ System.system_time(:millisecond)
      )

  def record_telemetry_compact(device_id, payload, received_at_ms)
      when is_binary(device_id) and byte_size(device_id) > 0 and is_map(payload) and
             is_integer(received_at_ms) do
    case Codec.parse_telemetry_payload(payload) do
      {:ok, compact_fields, extra} ->
        GenServer.call(
          __MODULE__,
          {:record_telemetry, Support.detach_binary(device_id), compact_fields, extra,
           received_at_ms, false}
        )

      :error ->
        {:error, :invalid_telemetry}
    end
  end

  def record_telemetry_compact(_device_id, _payload, _received_at_ms),
    do: {:error, :invalid_telemetry}

  @spec record_status(term(), term()) :: {:ok, status_entry()} | {:error, :invalid_status}
  @spec record_status(term(), term(), term()) :: {:ok, status_entry()} | {:error, :invalid_status}
  def record_status(device_id, payload, received_at_ms \\ System.system_time(:millisecond))

  def record_status(device_id, payload, received_at_ms)
      when is_binary(device_id) and byte_size(device_id) > 0 and is_map(payload) and
             is_integer(received_at_ms) do
    with {:ok, online} when is_boolean(online) <- Support.fetch_field(payload, "online", :online),
         :ok <- validate_optional_version(payload) do
      up =
        case Support.fetch_field(payload, "up", :up) do
          {:ok, val} when is_integer(val) -> val
          _ -> nil
        end

      b =
        case Support.fetch_boot_id(payload, :optional) do
          {:ok, normalized_b} -> normalized_b
          :error -> nil
        end

      GenServer.call(
        __MODULE__,
        {:record_status, Support.detach_binary(device_id), online, b, up, received_at_ms}
      )
    else
      _ ->
        {:error, :invalid_status}
    end
  end

  def record_status(_device_id, _payload, _received_at_ms), do: {:error, :invalid_status}

  @spec mark_device_offline(term()) :: {:ok, status_entry()} | {:error, :invalid_device}
  @spec mark_device_offline(term(), term()) :: {:ok, status_entry()} | {:error, :invalid_device}
  def mark_device_offline(device_id, reason \\ "ack_timeout")

  def mark_device_offline(device_id, reason)
      when is_binary(device_id) and byte_size(device_id) > 0 and is_binary(reason) do
    now_ms = System.system_time(:millisecond)

    GenServer.call(
      __MODULE__,
      {:mark_device_offline, Support.detach_binary(device_id), Support.detach_binary(reason),
       now_ms}
    )
  end

  def mark_device_offline(_device_id, _reason), do: {:error, :invalid_device}

  @spec record_alarm(term(), term(), term()) :: {:ok, alarm_entry()} | {:error, :invalid_alarm}
  @spec record_alarm(term(), term(), term(), term()) ::
          {:ok, alarm_entry()} | {:error, :invalid_alarm}
  def record_alarm(device_id, code, payload, received_at_ms \\ System.system_time(:millisecond))

  def record_alarm(device_id, code, payload, received_at_ms)
      when is_binary(device_id) and byte_size(device_id) > 0 and is_binary(code) and
             byte_size(code) > 0 and is_map(payload) and is_integer(received_at_ms) do
    case parse_alarm_payload(payload) do
      {:ok, v, b, raw_active, up} ->
        GenServer.call(
          __MODULE__,
          {:record_alarm, Support.detach_binary(device_id), Support.detach_binary(code), v, b,
           raw_active, up, received_at_ms}
        )

      :error ->
        {:error, :invalid_alarm}
    end
  end

  def record_alarm(_device_id, _code, _payload, _received_at_ms), do: {:error, :invalid_alarm}

  @spec clear_alarm(term(), term()) :: {:ok, alarm_entry()} | {:error, :not_found}
  @spec clear_alarm(term(), term(), term()) :: {:ok, alarm_entry()} | {:error, :not_found}
  def clear_alarm(device_id, code, reason \\ "manual")

  def clear_alarm(device_id, code, reason)
      when is_binary(device_id) and is_binary(code) and is_binary(reason) do
    now_ms = System.system_time(:millisecond)

    GenServer.call(
      __MODULE__,
      {:clear_alarm, device_id, code, Support.detach_binary(reason), now_ms}
    )
  end

  def clear_alarm(_device_id, _code, _reason), do: {:error, :not_found}

  @spec get_alarms(Greenhouse.device_id(), [{:active_only, boolean()}]) :: {:ok, [alarm_entry()]}
  def get_alarms(device_id, opts \\ []) when is_binary(device_id) and is_list(opts) do
    active_only = Keyword.get(opts, :active_only, false)

    match_spec =
      if active_only do
        [{{{device_id, :_}, :"$1"}, [{:==, {:map_get, :active, :"$1"}, true}], [:"$1"]}]
      else
        [{{{device_id, :_}, :"$1"}, [], [:"$1"]}]
      end

    {:ok, :ets.select(@alarms_table, match_spec)}
  end

  @spec get_raw_config(Greenhouse.device_id()) :: Greenhouse.json_map()
  def get_raw_config(device_id) when is_binary(device_id) do
    case :ets.lookup(@configs_table, device_id) do
      [{^device_id, raw, _updated_at_ms}] -> raw
      [{^device_id, %{raw: raw}}] -> raw
      [] -> %{}
    end
  end

  @spec get_config(Greenhouse.device_id()) :: {:ok, Codec.config_entry()}
  def get_config(device_id) when is_binary(device_id) do
    case :ets.lookup(@configs_table, device_id) do
      [{^device_id, raw, updated_at_ms}] ->
        {:ok, Codec.build_config_entry(device_id, raw, updated_at_ms)}

      [{^device_id, config_entry}] ->
        {:ok, config_entry}

      [] ->
        {:ok,
         %{
           device_id: device_id,
           raw: %{},
           human: %{},
           updated_at: nil,
           updated_at_ms: nil
         }}
    end
  end

  @spec update_config_cache(Greenhouse.device_id(), map(), Greenhouse.timestamp_ms()) ::
          {:ok, Codec.config_entry()}
  def update_config_cache(
        device_id,
        wire_patch_map,
        updated_at_ms \\ System.system_time(:millisecond)
      )
      when is_binary(device_id) and is_map(wire_patch_map) and is_integer(updated_at_ms) do
    normalized_patch = Codec.normalize_string_keys(wire_patch_map)

    {:ok, merged_raw} =
      GenServer.call(
        __MODULE__,
        {:update_config_cache, Support.detach_binary(device_id), normalized_patch, updated_at_ms}
      )

    {:ok, Codec.build_config_entry(device_id, merged_raw, updated_at_ms)}
  end

  @spec list_devices() :: [device_overview()]
  def list_devices do
    active_by_device = active_alarms_by_device()

    :ets.foldl(
      fn {device_id, device}, acc ->
        active_alarms = Map.get(active_by_device, device_id, [])

        overview = %{
          device_id: device_id,
          online: if(device.status, do: device.status.online, else: false),
          status: device.status,
          latest_telemetry: lookup_latest_telemetry(device_id),
          active_alarms: active_alarms,
          active_alarm_count: length(active_alarms),
          last_seen_at: Support.maybe_iso8601(device.last_seen_at_ms),
          last_seen_at_ms: device.last_seen_at_ms
        }

        [overview | acc]
      end,
      [],
      @devices_table
    )
    |> Enum.sort_by(& &1.device_id)
  end

  @spec get_device(Greenhouse.device_id()) :: {:ok, device_snapshot()} | {:error, :not_found}
  def get_device(device_id) when is_binary(device_id) do
    case :ets.lookup(@devices_table, device_id) do
      [{^device_id, device}] ->
        {:ok, active_alarms} = get_alarms(device_id, active_only: true)
        {:ok, config} = get_config(device_id)

        {:ok,
         %{
           device_id: device_id,
           status: device.status,
           latest_telemetry: lookup_latest_telemetry(device_id),
           active_alarms: active_alarms,
           config: config,
           last_seen_at: Support.maybe_iso8601(device.last_seen_at_ms),
           last_seen_at_ms: device.last_seen_at_ms
         }}

      [] ->
        {:error, :not_found}
    end
  end

  @doc false
  @spec get_device_with_all_alarms(Greenhouse.device_id()) ::
          {:ok, device_snapshot(), [alarm_entry()]} | {:error, :not_found}
  def get_device_with_all_alarms(device_id) when is_binary(device_id) do
    case :ets.lookup(@devices_table, device_id) do
      [{^device_id, device}] ->
        {:ok, all_alarms} = get_alarms(device_id, active_only: false)
        active_alarms = Enum.filter(all_alarms, & &1.active)
        {:ok, config} = get_config(device_id)

        snapshot = %{
          device_id: device_id,
          status: device.status,
          latest_telemetry: lookup_latest_telemetry(device_id),
          active_alarms: active_alarms,
          config: config,
          last_seen_at: Support.maybe_iso8601(device.last_seen_at_ms),
          last_seen_at_ms: device.last_seen_at_ms
        }

        {:ok, snapshot, all_alarms}

      [] ->
        {:error, :not_found}
    end
  end

  @spec get_device_status(Greenhouse.device_id()) :: {:ok, status_entry()} | {:error, :not_found}
  def get_device_status(device_id) when is_binary(device_id) do
    case :ets.lookup(@devices_table, device_id) do
      [{^device_id, %{status: status}}] when not is_nil(status) -> {:ok, status}
      _ -> {:error, :not_found}
    end
  end

  @spec get_latest_telemetry(Greenhouse.device_id()) ::
          {:ok, Codec.telemetry_entry() | map()} | {:error, :not_found}
  def get_latest_telemetry(device_id) when is_binary(device_id) do
    case lookup_latest_telemetry(device_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @spec get_telemetry_history(Greenhouse.device_id(), [Query.history_query_opt()]) ::
          {:ok, Query.history_result()}
  def get_telemetry_history(device_id, opts \\ []) when is_binary(device_id) and is_list(opts) do
    {:ok, Query.get_telemetry_history(@telemetry_history_table, device_id, opts)}
  end

  @spec get_telemetry_stats(Greenhouse.device_id(), [Query.stats_query_opt()]) ::
          {:ok, Query.stats_result()}
  def get_telemetry_stats(device_id, opts \\ []) when is_binary(device_id) and is_list(opts) do
    {:ok, Query.get_telemetry_stats(@telemetry_history_table, device_id, opts)}
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  @spec init([option()]) :: {:ok, state()}
  def init(opts) when is_list(opts) do
    app_cfg = Application.get_env(:greenhouse, __MODULE__, [])
    persist = Keyword.get(opts, :persist, Keyword.get(app_cfg, :persist, false))
    data_dir = Keyword.get(opts, :data_dir, Keyword.get(app_cfg, :data_dir, "priv/data"))

    max_history_per_device =
      Keyword.get(
        opts,
        :max_history_per_device,
        Keyword.get(app_cfg, :max_history_per_device, @default_max_history_per_device)
      )

    init_ets_tables()

    {dets_tables, max_counter, history_counts} =
      if persist do
        tables = DETS.open_tables(data_dir, @dets_table_specs)
        DETS.load_into_ets(tables)

        Codec.normalize_loaded_tables(
          @telemetry_latest_table,
          @telemetry_history_table,
          @configs_table,
          @devices_table,
          @alarms_table,
          tables
        )

        {counter, counts} = Retention.scan_history_metadata(@telemetry_history_table)
        {tables, counter, counts}
      else
        {%{}, 0, %{}}
      end

    trimmed_counts =
      Retention.enforce_initial_history_cap(
        @telemetry_history_table,
        history_counts,
        max_history_per_device,
        persist,
        dets_tables
      )

    state = %__MODULE__{
      persist: persist,
      data_dir: data_dir,
      dets_tables: dets_tables,
      history_counter: max_counter,
      history_counts: trimmed_counts,
      max_history_per_device: max_history_per_device
    }

    {:ok, state}
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call(:reset, _from, %__MODULE__{} = state) do
    DETS.clear_tables(@all_ets_tables, state.persist, state.dets_tables)
    {:reply, :ok, %{state | history_counter: 0, history_counts: %{}}}
  end

  def handle_call(
        {:record_telemetry, device_id, {v, b, seq, up, t, ah, sh, lux, flags_or_tuple}, extra,
         received_at_ms, reply_record?},
        _from,
        %__MODULE__{} = state
      ) do
    existing_device = lookup_device_record(device_id)

    if duplicate_telemetry?(existing_device, b, seq, up) do
      {:reply, {:duplicate, seq}, state}
    else
      latest_record =
        Codec.build_latest_record(
          device_id,
          received_at_ms,
          v,
          b,
          seq,
          up,
          t,
          ah,
          sh,
          lux,
          flags_or_tuple,
          extra
        )

      DETS.put_record(@telemetry_latest_table, latest_record, state.persist, state.dets_tables)

      state =
        if state.max_history_per_device == 0 do
          state
        else
          counter = state.history_counter + 1
          history_key = {device_id, received_at_ms, counter}

          history_record =
            Codec.build_history_record(
              history_key,
              v,
              b,
              seq,
              up,
              t,
              ah,
              sh,
              lux,
              flags_or_tuple,
              extra
            )

          DETS.put_record(
            @telemetry_history_table,
            history_record,
            state.persist,
            state.dets_tables
          )

          new_device_count = Map.get(state.history_counts, device_id, 0) + 1

          updated_counts =
            Retention.maybe_evict_excess_history(
              @telemetry_history_table,
              state.history_counts,
              device_id,
              new_device_count,
              state.max_history_per_device,
              state.persist,
              state.dets_tables
            )

          %{state | history_counter: counter, history_counts: updated_counts}
        end

      updated_device =
        build_device_record(device_id, existing_device, %{
          last_b: b,
          last_seq: seq,
          last_up: up,
          last_seen_at_ms: bump_last_seen(existing_device, received_at_ms)
        })

      DETS.put_record(
        @devices_table,
        {device_id, updated_device},
        state.persist,
        state.dets_tables
      )

      {water, _fan, _light, _heat} = Codec.unpack_flags(flags_or_tuple)

      if water == 1 do
        maybe_autoclear_water_lack(device_id, received_at_ms, state)
      end

      reply = if reply_record?, do: {:ok, latest_record}, else: {:ok, :recorded}
      {:reply, reply, state}
    end
  end

  def handle_call({:record_status, device_id, online, b, up, received_at_ms}, _from, state) do
    existing_device = lookup_device_record(device_id)

    status_entry = %{
      device_id: device_id,
      online: online,
      b: b,
      up: up,
      offline_reason: nil,
      updated_at: Support.iso8601(received_at_ms),
      updated_at_ms: received_at_ms
    }

    last_seen_at_ms =
      if online do
        bump_last_seen(existing_device, received_at_ms)
      else
        keep_or_init_last_seen(existing_device, received_at_ms)
      end

    updated_device =
      build_device_record(device_id, existing_device, %{
        status: status_entry,
        last_seen_at_ms: last_seen_at_ms
      })

    DETS.put_record(@devices_table, {device_id, updated_device}, state.persist, state.dets_tables)
    {:reply, {:ok, status_entry}, state}
  end

  def handle_call({:mark_device_offline, device_id, reason, now_ms}, _from, state) do
    existing_device = lookup_device_record(device_id)

    existing_up =
      if existing_device && existing_device.status, do: existing_device.status.up, else: nil

    existing_b =
      if existing_device && existing_device.status,
        do: Map.get(existing_device.status, :b),
        else: nil

    status_entry = %{
      device_id: device_id,
      online: false,
      b: existing_b,
      up: existing_up,
      offline_reason: reason,
      updated_at: Support.iso8601(now_ms),
      updated_at_ms: now_ms
    }

    updated_device =
      build_device_record(device_id, existing_device, %{
        status: status_entry
      })

    DETS.put_record(@devices_table, {device_id, updated_device}, state.persist, state.dets_tables)
    {:reply, {:ok, status_entry}, state}
  end

  def handle_call(
        {:record_alarm, device_id, code, v, b, raw_active, up, received_at_ms},
        _from,
        state
      ) do
    {active, clear_reason, cleared_at, cleared_at_ms} =
      resolve_alarm_state(device_id, code, raw_active, b, up, received_at_ms)

    ts = Support.iso8601(received_at_ms)

    alarm_entry = %{
      device_id: device_id,
      code: code,
      active: active,
      v: v,
      b: b,
      up: up,
      clear_reason: clear_reason,
      cleared_at: cleared_at,
      cleared_at_ms: cleared_at_ms,
      received_at: ts,
      received_at_ms: received_at_ms,
      updated_at: ts,
      updated_at_ms: received_at_ms
    }

    DETS.put_record(
      @alarms_table,
      {{device_id, code}, alarm_entry},
      state.persist,
      state.dets_tables
    )

    existing_device = lookup_device_record(device_id)

    updated_device =
      build_device_record(device_id, existing_device, %{
        last_seen_at_ms: keep_or_init_last_seen(existing_device, received_at_ms)
      })

    DETS.put_record(@devices_table, {device_id, updated_device}, state.persist, state.dets_tables)
    {:reply, {:ok, alarm_entry}, state}
  end

  def handle_call({:clear_alarm, device_id, code, reason, now_ms}, _from, state) do
    case :ets.lookup(@alarms_table, {device_id, code}) do
      [{{^device_id, ^code}, alarm}] ->
        ts = Support.iso8601(now_ms)

        updated_alarm = %{
          alarm
          | active: false,
            clear_reason: reason,
            cleared_at: ts,
            cleared_at_ms: now_ms,
            updated_at: ts,
            updated_at_ms: now_ms
        }

        DETS.put_record(
          @alarms_table,
          {{device_id, code}, updated_alarm},
          state.persist,
          state.dets_tables
        )

        {:reply, {:ok, updated_alarm}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:update_config_cache, device_id, normalized_patch, updated_at_ms},
        _from,
        state
      ) do
    existing_raw = get_raw_config(device_id)
    merged_raw = Map.merge(existing_raw, normalized_patch)

    DETS.put_record(
      @configs_table,
      {device_id, merged_raw, updated_at_ms},
      state.persist,
      state.dets_tables
    )

    {:reply, {:ok, merged_raw}, state}
  end

  @impl GenServer
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, %__MODULE__{} = state) do
    DETS.close_tables(state.persist, state.dets_tables)
  end

  # --- Private Helpers ---

  @spec validate_optional_version(map()) :: :ok | :error
  defp validate_optional_version(payload) when is_map(payload) do
    case Support.fetch_field(payload, "v", :v) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, v} when v in [1, 2] -> :ok
      _ -> :error
    end
  end

  @spec parse_alarm_payload(map()) ::
          {:ok, integer() | nil, String.t() | nil, boolean(), integer() | nil} | :error
  defp parse_alarm_payload(payload) when is_map(payload) do
    with {:ok, v} <- parse_alarm_version(payload),
         {:ok, b} <- parse_alarm_boot_id(payload, v) do
      raw_active =
        case Support.fetch_field(payload, "active", :active) do
          {:ok, false} -> false
          _ -> true
        end

      up =
        case Support.fetch_field(payload, "up", :up) do
          {:ok, val} when is_integer(val) -> val
          _ -> nil
        end

      {:ok, v, b, raw_active, up}
    else
      _ -> :error
    end
  end

  @spec parse_alarm_version(map()) :: {:ok, integer() | nil} | :error
  defp parse_alarm_version(payload) when is_map(payload) do
    case Support.fetch_field(payload, "v", :v) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, v} when v in [1, 2] -> {:ok, v}
      _ -> :error
    end
  end

  @spec parse_alarm_boot_id(map(), integer() | nil) :: {:ok, String.t() | nil} | :error
  defp parse_alarm_boot_id(payload, 2), do: Support.fetch_boot_id(payload, :required)
  defp parse_alarm_boot_id(payload, _v), do: Support.fetch_boot_id(payload, :optional)

  @spec init_ets_tables() :: :ok
  defp init_ets_tables do
    Enum.each([@devices_table, @telemetry_latest_table, @configs_table], fn table ->
      _ = :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    end)

    Enum.each([@telemetry_history_table, @alarms_table], fn table ->
      _ = :ets.new(table, [:named_table, :ordered_set, :public, read_concurrency: true])
    end)
  end

  @spec lookup_device_record(Greenhouse.device_id()) :: device_record() | nil
  defp lookup_device_record(device_id) when is_binary(device_id) do
    case :ets.lookup(@devices_table, device_id) do
      [{^device_id, device}] -> device
      [] -> nil
    end
  end

  @spec lookup_latest_telemetry(Greenhouse.device_id()) :: Codec.telemetry_entry() | map() | nil
  defp lookup_latest_telemetry(device_id) when is_binary(device_id) do
    case :ets.lookup(@telemetry_latest_table, device_id) do
      [record] -> Codec.expand_latest_record(record)
      [] -> nil
    end
  end

  @spec lookup_latest_water_b_and_up(Greenhouse.device_id()) ::
          {integer(), String.t() | nil, integer()} | nil
  defp lookup_latest_water_b_and_up(device_id) when is_binary(device_id) do
    case :ets.lookup(@telemetry_latest_table, device_id) do
      [record] -> Codec.extract_water_b_and_up(record)
      [] -> nil
    end
  end

  @spec active_alarms_by_device() :: %{optional(Greenhouse.device_id()) => [alarm_entry()]}
  defp active_alarms_by_device do
    match_spec = [
      {{{:"$1", :_}, :"$2"}, [{:==, {:map_get, :active, :"$2"}, true}], [{{:"$1", :"$2"}}]}
    ]

    grouped =
      @alarms_table
      |> :ets.select(match_spec)
      |> Enum.reduce(%{}, fn {device_id, alarm}, acc ->
        Map.update(acc, device_id, [alarm], &[alarm | &1])
      end)

    :maps.map(fn _device_id, alarms -> Enum.reverse(alarms) end, grouped)
  end

  @spec build_device_record(Greenhouse.device_id(), device_record() | nil, map()) ::
          device_record()
  defp build_device_record(device_id, existing, updates)
       when is_binary(device_id) and (is_map(existing) or is_nil(existing)) and is_map(updates) do
    base =
      case existing do
        nil ->
          %{
            device_id: device_id,
            status: nil,
            last_b: nil,
            last_seq: nil,
            last_up: nil,
            last_seen_at_ms: nil
          }

        %{} = dev ->
          Map.put_new(dev, :last_b, nil)
      end

    Map.merge(base, updates)
  end

  @spec bump_last_seen(device_record() | nil, Greenhouse.timestamp_ms()) ::
          Greenhouse.timestamp_ms()
  defp bump_last_seen(nil, received_at_ms) when is_integer(received_at_ms), do: received_at_ms

  defp bump_last_seen(%{last_seen_at_ms: nil}, received_at_ms) when is_integer(received_at_ms),
    do: received_at_ms

  defp bump_last_seen(%{last_seen_at_ms: existing_ms}, received_at_ms)
       when is_integer(existing_ms) and is_integer(received_at_ms) do
    max(existing_ms, received_at_ms)
  end

  @spec keep_or_init_last_seen(device_record() | nil, Greenhouse.timestamp_ms()) ::
          Greenhouse.timestamp_ms()
  defp keep_or_init_last_seen(nil, received_at_ms) when is_integer(received_at_ms),
    do: received_at_ms

  defp keep_or_init_last_seen(%{last_seen_at_ms: nil}, received_at_ms)
       when is_integer(received_at_ms),
       do: received_at_ms

  defp keep_or_init_last_seen(%{last_seen_at_ms: existing_ms}, _received_at_ms)
       when is_integer(existing_ms),
       do: existing_ms

  @spec duplicate_telemetry?(device_record() | nil, String.t() | nil, integer(), integer()) ::
          boolean()
  defp duplicate_telemetry?(nil, _b, _seq, _up), do: false
  defp duplicate_telemetry?(%{last_seq: nil}, _b, _seq, _up), do: false
  defp duplicate_telemetry?(%{last_up: nil}, _b, _seq, _up), do: false

  defp duplicate_telemetry?(%{last_seq: last_seq, last_up: last_up} = device, b, seq, up)
       when (is_binary(b) or is_nil(b)) and is_integer(last_seq) and is_integer(last_up) and
              is_integer(seq) and is_integer(up) do
    last_b = Map.get(device, :last_b)

    if b != last_b do
      false
    else
      reboot? = up < last_up or (seq < last_seq and up <= last_up)
      not reboot? and seq <= last_seq
    end
  end

  @spec maybe_autoclear_water_lack(Greenhouse.device_id(), Greenhouse.timestamp_ms(), state()) ::
          :ok
  defp maybe_autoclear_water_lack(device_id, received_at_ms, %__MODULE__{} = state)
       when is_binary(device_id) and is_integer(received_at_ms) do
    case :ets.lookup(@alarms_table, {device_id, "water_lack"}) do
      [{{^device_id, "water_lack"}, %{active: true} = alarm}] ->
        ts = Support.iso8601(received_at_ms)

        cleared_alarm = %{
          alarm
          | active: false,
            clear_reason: "telemetry_water_normal",
            cleared_at: ts,
            cleared_at_ms: received_at_ms,
            updated_at: ts,
            updated_at_ms: received_at_ms
        }

        DETS.put_record(
          @alarms_table,
          {{device_id, "water_lack"}, cleared_alarm},
          state.persist,
          state.dets_tables
        )

      _ ->
        :ok
    end
  end

  @spec resolve_alarm_state(
          Greenhouse.device_id(),
          String.t(),
          boolean(),
          String.t() | nil,
          integer() | nil,
          Greenhouse.timestamp_ms()
        ) ::
          {boolean(), String.t() | nil, Greenhouse.iso8601_timestamp() | nil,
           Greenhouse.timestamp_ms() | nil}
  defp resolve_alarm_state(device_id, "water_lack", true, alarm_b, up, received_at_ms)
       when is_binary(device_id) and (is_binary(alarm_b) or is_nil(alarm_b)) and
              is_integer(received_at_ms) do
    alarm_up = if is_integer(up), do: up, else: -1

    case lookup_latest_water_b_and_up(device_id) do
      {1, latest_b, latest_up}
      when (is_nil(alarm_b) or is_nil(latest_b) or alarm_b == latest_b) and
             latest_up > alarm_up ->
        {false, "telemetry_water_normal", Support.iso8601(received_at_ms), received_at_ms}

      _ ->
        {true, nil, nil, nil}
    end
  end

  defp resolve_alarm_state(_device_id, _code, true, _alarm_b, _up, _received_at_ms) do
    {true, nil, nil, nil}
  end

  defp resolve_alarm_state(_device_id, _code, false, _alarm_b, _up, received_at_ms)
       when is_integer(received_at_ms) do
    {false, nil, Support.iso8601(received_at_ms), received_at_ms}
  end
end
