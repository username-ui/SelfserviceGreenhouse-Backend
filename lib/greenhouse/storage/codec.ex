defmodule Greenhouse.Storage.Codec do
  @moduledoc """
  Compact ETS/DETS tuple serialization, bit-packed actuator/sensor flags,
  API map expansion, and legacy map-format migration for `Greenhouse.Storage`.
  """

  import Bitwise

  alias Greenhouse.{ConfigValidator, Support}
  alias Greenhouse.Support.DETS

  @typedoc "Packed integer bitmask or 4-tuple for `{water, fan, light, heat}` flags."
  @type packed_flags :: byte() | {integer(), integer(), integer(), integer()}

  @typedoc "Composite ETS key for `:gh_telemetry_history`: `{device_id, received_at_ms, counter}`."
  @type history_key :: {Greenhouse.device_id(), Greenhouse.timestamp_ms(), non_neg_integer()}

  @typedoc "Parsed compact protocol fields before adding device ID and receipt timestamp."
  @type parsed_compact_fields ::
          {integer(), String.t() | nil, non_neg_integer(), non_neg_integer(), integer(),
           integer(), integer(), integer(), packed_flags()}

  @typedoc "Record stored in `:gh_telemetry_latest` (v2 compact 11/12-tuple, v1 10/11-tuple, or legacy 2-tuple)."
  @type latest_record ::
          {Greenhouse.device_id(), Greenhouse.timestamp_ms(), integer(), String.t() | nil,
           non_neg_integer(), non_neg_integer(), integer(), integer(), integer(), integer(),
           packed_flags()}
          | {Greenhouse.device_id(), Greenhouse.timestamp_ms(), integer(), String.t() | nil,
             non_neg_integer(), non_neg_integer(), integer(), integer(), integer(), integer(),
             packed_flags(), Greenhouse.json_map()}
          | {Greenhouse.device_id(), Greenhouse.timestamp_ms(), integer(), non_neg_integer(),
             non_neg_integer(), integer(), integer(), integer(), integer(), packed_flags()}
          | {Greenhouse.device_id(), Greenhouse.timestamp_ms(), integer(), non_neg_integer(),
             non_neg_integer(), integer(), integer(), integer(), integer(), packed_flags(),
             Greenhouse.json_map()}
          | {Greenhouse.device_id(), map()}

  @typedoc "Record stored in `:gh_telemetry_history` (v2 compact 10/11-tuple, v1 9/10-tuple, or legacy 2-tuple)."
  @type history_record ::
          {history_key(), integer(), String.t() | nil, non_neg_integer(), non_neg_integer(),
           integer(), integer(), integer(), integer(), packed_flags()}
          | {history_key(), integer(), String.t() | nil, non_neg_integer(), non_neg_integer(),
             integer(), integer(), integer(), integer(), packed_flags(), Greenhouse.json_map()}
          | {history_key(), integer(), non_neg_integer(), non_neg_integer(), integer(), integer(),
             integer(), integer(), packed_flags()}
          | {history_key(), integer(), non_neg_integer(), non_neg_integer(), integer(), integer(),
             integer(), integer(), packed_flags(), Greenhouse.json_map()}
          | {history_key(), map()}

  @typedoc "Expanded telemetry entry exposed through public APIs."
  @type telemetry_entry :: %{
          device_id: Greenhouse.device_id(),
          v: integer(),
          b: String.t() | nil,
          seq: integer(),
          up: integer(),
          temperature: float(),
          air_humidity: float(),
          soil_humidity: float(),
          lux: integer(),
          water: integer(),
          water_sufficient: boolean(),
          fan: integer(),
          fan_on: boolean(),
          light: integer(),
          light_on: boolean(),
          heat: integer(),
          heat_on: boolean(),
          received_at: Greenhouse.iso8601_timestamp(),
          received_at_ms: Greenhouse.timestamp_ms(),
          raw: Greenhouse.json_map()
        }

  @typedoc "Device configuration cache entry containing wire and human-scaled views."
  @type config_entry :: %{
          device_id: Greenhouse.device_id(),
          raw: Greenhouse.json_map(),
          human: ConfigValidator.human_config(),
          updated_at: Greenhouse.iso8601_timestamp() | nil,
          updated_at_ms: Greenhouse.timestamp_ms() | nil
        }

  @required_key_set MapSet.new([
                      "v",
                      "b",
                      "seq",
                      "up",
                      "t",
                      "ah",
                      "sh",
                      "lux",
                      "water",
                      "fan",
                      "light",
                      "heat",
                      :v,
                      :b,
                      :seq,
                      :up,
                      :t,
                      :ah,
                      :sh,
                      :lux,
                      :water,
                      :fan,
                      :light,
                      :heat
                    ])

  @doc """
  Parses an incoming telemetry payload map into compact tuple fields and optional extra raw fields.

  Protocol v2 (`v == 2`) strictly requires a valid 8-char hex `b` (normalized to lowercase).
  Protocol v1 (`v == 1`) allows `b` to be omitted/`nil` (or normalized if provided).
  """
  @spec parse_telemetry_payload(map()) ::
          {:ok, parsed_compact_fields(), Greenhouse.json_map() | nil} | :error
  def parse_telemetry_payload(payload) when is_map(payload) do
    with {:ok, v} when v in [1, 2] <- fetch_req_int(payload, "v", :v),
         {:ok, b} <- parse_telemetry_boot_id(payload, v),
         {:ok, seq} when seq >= 0 <- fetch_req_int(payload, "seq", :seq),
         {:ok, up} when up >= 0 <- fetch_req_int(payload, "up", :up),
         {:ok, t} <- fetch_req_int(payload, "t", :t),
         {:ok, ah} <- fetch_req_int(payload, "ah", :ah),
         {:ok, sh} <- fetch_req_int(payload, "sh", :sh),
         {:ok, lux} <- fetch_req_int(payload, "lux", :lux),
         {:ok, water} <- fetch_req_int(payload, "water", :water),
         {:ok, fan} <- fetch_req_int(payload, "fan", :fan),
         {:ok, light} <- fetch_req_int(payload, "light", :light),
         {:ok, heat} <- fetch_req_int(payload, "heat", :heat) do
      req_count = if Map.has_key?(payload, "b") or Map.has_key?(payload, :b), do: 12, else: 11
      extra = if map_size(payload) > req_count, do: extract_extra_raw(payload), else: nil
      flags = pack_flags(water, fan, light, heat)
      {:ok, {v, b, seq, up, t, ah, sh, lux, flags}, extra}
    else
      _ -> :error
    end
  end

  @spec parse_telemetry_boot_id(map(), 1 | 2) :: {:ok, String.t() | nil} | :error
  defp parse_telemetry_boot_id(payload, 2), do: Support.fetch_boot_id(payload, :required)
  defp parse_telemetry_boot_id(payload, 1), do: Support.fetch_boot_id(payload, :optional)

  @doc """
  Builds a compact tuple for the `:gh_telemetry_latest` table.
  """
  @spec build_latest_record(
          Greenhouse.device_id(),
          Greenhouse.timestamp_ms(),
          integer(),
          String.t() | nil,
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          packed_flags(),
          Greenhouse.json_map() | nil
        ) :: latest_record()
  def build_latest_record(
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
        nil
      )
      when is_binary(device_id) and is_integer(received_at_ms) and is_integer(v) and
             (is_binary(b) or is_nil(b)) and is_integer(seq) and is_integer(up) and
             is_integer(t) and is_integer(ah) and is_integer(sh) and is_integer(lux) do
    {device_id, received_at_ms, v, b, seq, up, t, ah, sh, lux, flags_or_tuple}
  end

  def build_latest_record(
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
      when is_binary(device_id) and is_integer(received_at_ms) and is_integer(v) and
             (is_binary(b) or is_nil(b)) and is_integer(seq) and is_integer(up) and
             is_integer(t) and is_integer(ah) and is_integer(sh) and is_integer(lux) and
             is_map(extra) do
    {device_id, received_at_ms, v, b, seq, up, t, ah, sh, lux, flags_or_tuple, extra}
  end

  @doc """
  Builds a compact tuple for the `:gh_telemetry_history` table.
  """
  @spec build_history_record(
          history_key(),
          integer(),
          String.t() | nil,
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          packed_flags(),
          Greenhouse.json_map() | nil
        ) :: history_record()
  def build_history_record(key, v, b, seq, up, t, ah, sh, lux, flags_or_tuple, nil)
      when is_tuple(key) and tuple_size(key) == 3 and is_integer(v) and
             (is_binary(b) or is_nil(b)) and is_integer(seq) and is_integer(up) and
             is_integer(t) and is_integer(ah) and is_integer(sh) and is_integer(lux) do
    {key, v, b, seq, up, t, ah, sh, lux, flags_or_tuple}
  end

  def build_history_record(key, v, b, seq, up, t, ah, sh, lux, flags_or_tuple, extra)
      when is_tuple(key) and tuple_size(key) == 3 and is_integer(v) and
             (is_binary(b) or is_nil(b)) and is_integer(seq) and is_integer(up) and
             is_integer(t) and is_integer(ah) and is_integer(sh) and is_integer(lux) and
             is_map(extra) do
    {key, v, b, seq, up, t, ah, sh, lux, flags_or_tuple, extra}
  end

  @doc """
  Expands a compact or legacy `:gh_telemetry_latest` record into the public API telemetry map.
  """
  @spec expand_latest_record(latest_record()) :: telemetry_entry() | map()
  def expand_latest_record(
        {device_id, received_at_ms, v, b, seq, up, t, ah, sh, lux, flags_or_tuple}
      )
      when is_binary(b) or is_nil(b) do
    expand_telemetry(
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
      nil
    )
  end

  def expand_latest_record(
        {device_id, received_at_ms, v, b, seq, up, t, ah, sh, lux, flags_or_tuple, extra}
      )
      when (is_binary(b) or is_nil(b)) and is_map(extra) do
    expand_telemetry(
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
  end

  def expand_latest_record(
        {device_id, received_at_ms, v, seq, up, t, ah, sh, lux, flags_or_tuple}
      )
      when is_integer(seq) do
    expand_telemetry(
      device_id,
      received_at_ms,
      v,
      nil,
      seq,
      up,
      t,
      ah,
      sh,
      lux,
      flags_or_tuple,
      nil
    )
  end

  def expand_latest_record(
        {device_id, received_at_ms, v, seq, up, t, ah, sh, lux, flags_or_tuple, extra}
      )
      when is_integer(seq) and is_map(extra) do
    {b, cleaned_extra} = pop_legacy_extra_boot_id(extra)

    expand_telemetry(
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
      cleaned_extra
    )
  end

  def expand_latest_record({_device_id, %{} = legacy_entry}),
    do: normalize_legacy_entry(legacy_entry)

  @doc """
  Expands a compact or legacy `:gh_telemetry_history` record into the public API telemetry map.
  """
  @spec expand_history_record(history_record()) :: telemetry_entry() | map()
  def expand_history_record(
        {{device_id, received_at_ms, _counter}, v, b, seq, up, t, ah, sh, lux, flags_or_tuple}
      )
      when is_binary(b) or is_nil(b) do
    expand_telemetry(
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
      nil
    )
  end

  def expand_history_record(
        {{device_id, received_at_ms, _counter}, v, b, seq, up, t, ah, sh, lux, flags_or_tuple,
         extra}
      )
      when (is_binary(b) or is_nil(b)) and is_map(extra) do
    expand_telemetry(
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
  end

  def expand_history_record(
        {{device_id, received_at_ms, _counter}, v, seq, up, t, ah, sh, lux, flags_or_tuple}
      )
      when is_integer(seq) do
    expand_telemetry(
      device_id,
      received_at_ms,
      v,
      nil,
      seq,
      up,
      t,
      ah,
      sh,
      lux,
      flags_or_tuple,
      nil
    )
  end

  def expand_history_record(
        {{device_id, received_at_ms, _counter}, v, seq, up, t, ah, sh, lux, flags_or_tuple, extra}
      )
      when is_integer(seq) and is_map(extra) do
    {b, cleaned_extra} = pop_legacy_extra_boot_id(extra)

    expand_telemetry(
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
      cleaned_extra
    )
  end

  def expand_history_record({{_device_id, _ms, _counter}, %{} = legacy_entry}),
    do: normalize_legacy_entry(legacy_entry)

  @doc """
  Extracts `{water, b, up}` from a `:gh_telemetry_latest` record without expanding the full map.
  """
  @spec extract_water_b_and_up(term()) :: {integer(), String.t() | nil, integer()} | nil
  def extract_water_b_and_up(
        {_device_id, _ms, _v, b, _seq, up, _t, _ah, _sh, _lux, flags_or_tuple}
      )
      when is_binary(b) or is_nil(b) do
    {water, _fan, _light, _heat} = unpack_flags(flags_or_tuple)
    {water, b, up}
  end

  def extract_water_b_and_up(
        {_device_id, _ms, _v, b, _seq, up, _t, _ah, _sh, _lux, flags_or_tuple, _extra}
      )
      when is_binary(b) or is_nil(b) do
    {water, _fan, _light, _heat} = unpack_flags(flags_or_tuple)
    {water, b, up}
  end

  def extract_water_b_and_up({_device_id, _ms, _v, seq, up, _t, _ah, _sh, _lux, flags_or_tuple})
      when is_integer(seq) do
    {water, _fan, _light, _heat} = unpack_flags(flags_or_tuple)
    {water, nil, up}
  end

  def extract_water_b_and_up(
        {_device_id, _ms, _v, seq, up, _t, _ah, _sh, _lux, flags_or_tuple, extra}
      )
      when is_integer(seq) and is_map(extra) do
    {water, _fan, _light, _heat} = unpack_flags(flags_or_tuple)
    {b, _cleaned} = pop_legacy_extra_boot_id(extra)
    {water, b, up}
  end

  def extract_water_b_and_up({_device_id, %{water: water, up: up} = entry}) do
    b =
      case Support.normalize_boot_id(Map.get(entry, :b)) do
        {:ok, normalized} -> normalized
        :error -> nil
      end

    {water, b, up}
  end

  def extract_water_b_and_up(_), do: nil

  @doc """
  Extracts `{water, up}` from a `:gh_telemetry_latest` record without expanding the full map.
  """
  @spec extract_water_and_up(term()) :: {integer(), integer()} | nil
  def extract_water_and_up(record) do
    case extract_water_b_and_up(record) do
      {water, _b, up} -> {water, up}
      nil -> nil
    end
  end

  @doc """
  Packs four binary flags (`0`/`1`) into an integer bitmask, or falls back to a 4-tuple.
  """
  @spec pack_flags(integer(), integer(), integer(), integer()) :: packed_flags()
  def pack_flags(water, fan, light, heat)
      when water in [0, 1] and fan in [0, 1] and light in [0, 1] and heat in [0, 1] do
    water ||| fan <<< 1 ||| light <<< 2 ||| heat <<< 3
  end

  def pack_flags(water, fan, light, heat)
      when is_integer(water) and is_integer(fan) and is_integer(light) and is_integer(heat) do
    {water, fan, light, heat}
  end

  @doc """
  Unpacks a bitmask or fallback 4-tuple into `{water, fan, light, heat}`.
  """
  @spec unpack_flags(packed_flags()) :: {integer(), integer(), integer(), integer()}
  def unpack_flags(flags) when is_integer(flags) do
    {
      flags &&& 1,
      flags >>> 1 &&& 1,
      flags >>> 2 &&& 1,
      flags >>> 3 &&& 1
    }
  end

  def unpack_flags({water, fan, light, heat}), do: {water, fan, light, heat}

  @doc """
  Normalizes map keys to detached strings and recursively detaches values.
  """
  @spec normalize_string_keys(map()) :: Greenhouse.json_map()
  def normalize_string_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_binary(k) ->
        Map.put(acc, Support.detach_binary(k), Support.detach_term(v))

      {k, v}, acc when is_atom(k) ->
        Map.put_new(acc, Atom.to_string(k), Support.detach_term(v))

      _other, acc ->
        acc
    end)
  end

  @doc """
  Builds the public config entry map containing both `raw` and `human` views.
  """
  @spec build_config_entry(
          Greenhouse.device_id(),
          Greenhouse.json_map(),
          Greenhouse.timestamp_ms() | nil
        ) :: config_entry()
  def build_config_entry(device_id, raw, updated_at_ms)
      when is_binary(device_id) and is_map(raw) and
             (is_integer(updated_at_ms) or is_nil(updated_at_ms)) do
    %{
      device_id: device_id,
      raw: raw,
      human: ConfigValidator.to_human(raw),
      updated_at: Support.maybe_iso8601(updated_at_ms),
      updated_at_ms: updated_at_ms
    }
  end

  @doc """
  Migrates legacy map-format and v1 compact-tuple records loaded from DETS into v2 ETS/DETS records.
  """
  @spec normalize_loaded_tables(
          DETS.ets_table(),
          DETS.ets_table(),
          DETS.ets_table(),
          DETS.dets_map()
        ) :: :ok
  @spec normalize_loaded_tables(
          DETS.ets_table(),
          DETS.ets_table(),
          DETS.ets_table(),
          DETS.ets_table() | nil,
          DETS.ets_table() | nil,
          DETS.dets_map()
        ) :: :ok
  def normalize_loaded_tables(latest_table, history_table, configs_table, dets_tables)
      when is_atom(latest_table) and is_atom(history_table) and is_atom(configs_table) and
             is_map(dets_tables) do
    normalize_loaded_tables(
      latest_table,
      history_table,
      configs_table,
      nil,
      nil,
      dets_tables
    )
  end

  def normalize_loaded_tables(
        latest_table,
        history_table,
        configs_table,
        devices_table,
        alarms_table,
        dets_tables
      )
      when is_atom(latest_table) and is_atom(history_table) and is_atom(configs_table) and
             (is_atom(devices_table) or is_nil(devices_table)) and
             (is_atom(alarms_table) or is_nil(alarms_table)) and is_map(dets_tables) do
    normalize_table_entries(latest_table, dets_tables, &normalize_latest_dets_record/1)
    normalize_table_entries(history_table, dets_tables, &normalize_history_dets_record/1)

    normalize_table_entries(configs_table, dets_tables, fn
      {device_id, %{raw: raw} = legacy} ->
        {:replace, {device_id, raw, Map.get(legacy, :updated_at_ms)}}

      _other ->
        :keep
    end)

    if devices_table != nil do
      normalize_table_entries(devices_table, dets_tables, &normalize_device_dets_record/1)
    end

    if alarms_table != nil do
      normalize_table_entries(alarms_table, dets_tables, &normalize_alarm_dets_record/1)
    end

    :ok
  end

  @spec normalize_latest_dets_record(tuple()) :: {:replace, latest_record()} | :keep
  defp normalize_latest_dets_record({device_id, %{} = legacy}) do
    {:replace, legacy_map_to_latest_record(device_id, legacy)}
  end

  defp normalize_latest_dets_record({device_id, ms, v, seq, up, t, ah, sh, lux, flags})
       when is_integer(seq) do
    {:replace, build_latest_record(device_id, ms, v, nil, seq, up, t, ah, sh, lux, flags, nil)}
  end

  defp normalize_latest_dets_record({device_id, ms, v, seq, up, t, ah, sh, lux, flags, extra})
       when is_integer(seq) and is_map(extra) do
    {b, cleaned_extra} = pop_legacy_extra_boot_id(extra)

    {:replace,
     build_latest_record(device_id, ms, v, b, seq, up, t, ah, sh, lux, flags, cleaned_extra)}
  end

  defp normalize_latest_dets_record({device_id, ms, v, b, seq, up, t, ah, sh, lux, flags})
       when is_binary(b) do
    normalize_boot_in_record(b, fn norm_b ->
      build_latest_record(device_id, ms, v, norm_b, seq, up, t, ah, sh, lux, flags, nil)
    end)
  end

  defp normalize_latest_dets_record({device_id, ms, v, b, seq, up, t, ah, sh, lux, flags, extra})
       when is_binary(b) and is_map(extra) do
    normalize_boot_in_record(b, fn norm_b ->
      build_latest_record(device_id, ms, v, norm_b, seq, up, t, ah, sh, lux, flags, extra)
    end)
  end

  defp normalize_latest_dets_record(_other), do: :keep

  @spec normalize_history_dets_record(tuple()) :: {:replace, history_record()} | :keep
  defp normalize_history_dets_record({{device_id, received_at_ms, counter} = key, %{} = legacy}) do
    {:replace, legacy_map_to_history_record(key, device_id, received_at_ms, counter, legacy)}
  end

  defp normalize_history_dets_record({key, v, seq, up, t, ah, sh, lux, flags})
       when is_tuple(key) and tuple_size(key) == 3 and is_integer(seq) do
    {:replace, build_history_record(key, v, nil, seq, up, t, ah, sh, lux, flags, nil)}
  end

  defp normalize_history_dets_record({key, v, seq, up, t, ah, sh, lux, flags, extra})
       when is_tuple(key) and tuple_size(key) == 3 and is_integer(seq) and is_map(extra) do
    {b, cleaned_extra} = pop_legacy_extra_boot_id(extra)
    {:replace, build_history_record(key, v, b, seq, up, t, ah, sh, lux, flags, cleaned_extra)}
  end

  defp normalize_history_dets_record({key, v, b, seq, up, t, ah, sh, lux, flags})
       when is_tuple(key) and tuple_size(key) == 3 and is_binary(b) do
    normalize_boot_in_record(b, fn norm_b ->
      build_history_record(key, v, norm_b, seq, up, t, ah, sh, lux, flags, nil)
    end)
  end

  defp normalize_history_dets_record({key, v, b, seq, up, t, ah, sh, lux, flags, extra})
       when is_tuple(key) and tuple_size(key) == 3 and is_binary(b) and is_map(extra) do
    normalize_boot_in_record(b, fn norm_b ->
      build_history_record(key, v, norm_b, seq, up, t, ah, sh, lux, flags, extra)
    end)
  end

  defp normalize_history_dets_record(_other), do: :keep

  @spec normalize_device_dets_record(tuple()) :: {:replace, tuple()} | :keep
  defp normalize_device_dets_record({device_id, %{status: status} = dev})
       when is_binary(device_id) and is_map(dev) do
    last_b = normalize_optional_boot_id(Map.get(dev, :last_b))

    normalized_status =
      if is_map(status) do
        status_b = normalize_optional_boot_id(Map.get(status, :b))
        Map.put(status, :b, status_b)
      else
        status
      end

    updated_dev =
      dev
      |> Map.put(:last_b, last_b)
      |> Map.put(:status, normalized_status)

    if updated_dev == dev, do: :keep, else: {:replace, {device_id, updated_dev}}
  end

  defp normalize_device_dets_record({device_id, %{} = legacy_dev}) when is_binary(device_id) do
    last_seen_at_ms =
      Map.get(legacy_dev, :last_seen_at_ms) || Map.get(legacy_dev, :last_seen_ms)

    migrated = %{
      device_id: device_id,
      status: nil,
      last_b: nil,
      last_seq: Map.get(legacy_dev, :last_seq),
      last_up: Map.get(legacy_dev, :last_up),
      last_seen_at_ms: last_seen_at_ms
    }

    {:replace, {device_id, migrated}}
  end

  defp normalize_device_dets_record(_other), do: :keep

  @spec normalize_alarm_dets_record(tuple()) :: {:replace, tuple()} | :keep
  defp normalize_alarm_dets_record({{device_id, code}, %{} = alarm})
       when is_binary(device_id) and is_binary(code) do
    norm_b = normalize_optional_boot_id(Map.get(alarm, :b))
    updated_alarm = Map.put(alarm, :b, norm_b)
    if updated_alarm == alarm, do: :keep, else: {:replace, {{device_id, code}, updated_alarm}}
  end

  defp normalize_alarm_dets_record(_other), do: :keep

  @spec normalize_boot_in_record(String.t(), (String.t() | nil -> tuple())) ::
          {:replace, tuple()} | :keep
  defp normalize_boot_in_record(b, builder_fn) when is_binary(b) and is_function(builder_fn, 1) do
    case Support.normalize_boot_id(b) do
      {:ok, ^b} -> :keep
      {:ok, norm_b} -> {:replace, builder_fn.(norm_b)}
      :error -> {:replace, builder_fn.(nil)}
    end
  end

  @spec normalize_optional_boot_id(term()) :: String.t() | nil
  defp normalize_optional_boot_id(raw_b) do
    case Support.normalize_boot_id(raw_b) do
      {:ok, norm_b} -> norm_b
      :error -> nil
    end
  end

  @spec pop_legacy_extra_boot_id(Greenhouse.json_map()) ::
          {String.t() | nil, Greenhouse.json_map() | nil}
  defp pop_legacy_extra_boot_id(extra) when is_map(extra) do
    raw_b = Map.get(extra, "b") || Map.get(extra, :b)
    norm_b = normalize_optional_boot_id(raw_b)

    cleaned =
      extra
      |> Map.delete("b")
      |> Map.delete(:b)

    {norm_b, if(map_size(cleaned) == 0, do: nil, else: cleaned)}
  end

  @spec normalize_legacy_entry(map()) :: map()
  defp normalize_legacy_entry(entry) when is_map(entry) do
    norm_b =
      normalize_optional_boot_id(
        Map.get(entry, :b) ||
          case Map.get(entry, :raw) do
            %{} = raw -> Map.get(raw, "b")
            _ -> nil
          end
      )

    Map.put_new(entry, :b, norm_b)
  end

  @spec expand_telemetry(
          Greenhouse.device_id(),
          Greenhouse.timestamp_ms(),
          integer(),
          String.t() | nil,
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          packed_flags(),
          Greenhouse.json_map() | nil
        ) :: telemetry_entry()
  defp expand_telemetry(
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
       when is_binary(device_id) and is_integer(received_at_ms) and is_integer(v) and
              (is_binary(b) or is_nil(b)) and is_integer(seq) and is_integer(up) and
              is_integer(t) and is_integer(ah) and is_integer(sh) and is_integer(lux) and
              (is_map(extra) or is_nil(extra)) do
    {water, fan, light, heat} = unpack_flags(flags_or_tuple)

    base_raw = %{
      "v" => v,
      "seq" => seq,
      "up" => up,
      "t" => t,
      "ah" => ah,
      "sh" => sh,
      "lux" => lux,
      "water" => water,
      "fan" => fan,
      "light" => light,
      "heat" => heat
    }

    base_raw = if is_binary(b), do: Map.put(base_raw, "b", b), else: base_raw
    raw = if extra == nil, do: base_raw, else: Map.merge(extra, base_raw)

    %{
      device_id: device_id,
      v: v,
      b: b,
      seq: seq,
      up: up,
      temperature: t / 100.0,
      air_humidity: ah / 100.0,
      soil_humidity: sh / 100.0,
      lux: lux,
      water: water,
      water_sufficient: water == 1,
      fan: fan,
      fan_on: fan == 1,
      light: light,
      light_on: light == 1,
      heat: heat,
      heat_on: heat == 1,
      received_at: Support.iso8601(received_at_ms),
      received_at_ms: received_at_ms,
      raw: raw
    }
  end

  @spec fetch_req_int(
          map(),
          nonempty_binary(),
          :v | :seq | :up | :t | :ah | :sh | :lux | :water | :fan | :light | :heat
        ) ::
          {:ok, integer()} | :error
  defp fetch_req_int(map, str_k, atom_k)
       when is_map(map) and is_binary(str_k) and is_atom(atom_k) do
    case Map.fetch(map, str_k) do
      {:ok, val} when is_integer(val) ->
        {:ok, val}

      {:ok, _} ->
        :error

      :error ->
        case Map.fetch(map, atom_k) do
          {:ok, val} when is_integer(val) -> {:ok, val}
          _ -> :error
        end
    end
  end

  @spec extract_extra_raw(map()) :: Greenhouse.json_map() | nil
  defp extract_extra_raw(map) when is_map(map) do
    extra =
      Enum.reduce(map, %{}, fn {k, v}, acc ->
        cond do
          MapSet.member?(@required_key_set, k) ->
            acc

          is_binary(k) ->
            Map.put(acc, Support.detach_binary(k), Support.detach_term(v))

          is_atom(k) ->
            Map.put_new(acc, Atom.to_string(k), Support.detach_term(v))

          true ->
            acc
        end
      end)

    if map_size(extra) == 0, do: nil, else: extra
  end

  @spec normalize_table_entries(
          DETS.ets_table(),
          DETS.dets_map(),
          (tuple() -> {:replace, tuple()} | :keep)
        ) :: :ok
  defp normalize_table_entries(ets_table, dets_tables, mapper_fn)
       when is_atom(ets_table) and is_map(dets_tables) and is_function(mapper_fn, 1) do
    replacements =
      :ets.foldl(
        fn record, acc ->
          case mapper_fn.(record) do
            {:replace, new_record} -> [new_record | acc]
            :keep -> acc
          end
        end,
        [],
        ets_table
      )

    _ =
      if replacements != [] do
        :ets.insert(ets_table, replacements)

        if dets_table = Map.get(dets_tables, ets_table) do
          :dets.insert(dets_table, replacements)
        end
      end

    :ok
  end

  @spec legacy_map_to_latest_record(Greenhouse.device_id(), map()) :: latest_record()
  defp legacy_map_to_latest_record(device_id, legacy)
       when is_binary(device_id) and is_map(legacy) do
    {fields, extra, received_at_ms} = extract_legacy_fields(legacy)

    build_latest_record(
      device_id,
      received_at_ms,
      fields.v,
      fields.b,
      fields.seq,
      fields.up,
      fields.t,
      fields.ah,
      fields.sh,
      fields.lux,
      fields.flags,
      extra
    )
  end

  @spec legacy_map_to_history_record(
          history_key(),
          Greenhouse.device_id(),
          Greenhouse.timestamp_ms(),
          non_neg_integer(),
          map()
        ) :: history_record()
  defp legacy_map_to_history_record(key, _device_id, _received_at_ms, _counter, legacy)
       when is_tuple(key) and tuple_size(key) == 3 and is_map(legacy) do
    {fields, extra, _ms} = extract_legacy_fields(legacy)

    build_history_record(
      key,
      fields.v,
      fields.b,
      fields.seq,
      fields.up,
      fields.t,
      fields.ah,
      fields.sh,
      fields.lux,
      fields.flags,
      extra
    )
  end

  @spec extract_legacy_fields(map()) :: {map(), Greenhouse.json_map() | nil, integer()}
  defp extract_legacy_fields(legacy) when is_map(legacy) do
    raw =
      case Map.get(legacy, :raw) do
        %{} = r -> r
        _ -> %{}
      end

    v = legacy_int(legacy, :v, raw, "v", 1)
    b = normalize_optional_boot_id(Map.get(legacy, :b) || Map.get(raw, "b"))
    seq = legacy_int(legacy, :seq, raw, "seq", 0)
    up = legacy_int(legacy, :up, raw, "up", 0)
    t = legacy_scaled_int(raw, "t", legacy, :temperature, 0)
    ah = legacy_scaled_int(raw, "ah", legacy, :air_humidity, 0)
    sh = legacy_scaled_int(raw, "sh", legacy, :soil_humidity, 0)
    lux = legacy_int(legacy, :lux, raw, "lux", 0)
    water = legacy_int(legacy, :water, raw, "water", 0)
    fan = legacy_int(legacy, :fan, raw, "fan", 0)
    light = legacy_int(legacy, :light, raw, "light", 0)
    heat = legacy_int(legacy, :heat, raw, "heat", 0)

    received_at_ms =
      case Map.get(legacy, :received_at_ms) do
        ms when is_integer(ms) -> ms
        _ -> 0
      end

    extra = extract_extra_raw(raw)
    flags = pack_flags(water, fan, light, heat)

    {%{v: v, b: b, seq: seq, up: up, t: t, ah: ah, sh: sh, lux: lux, flags: flags}, extra,
     received_at_ms}
  end

  @spec legacy_int(
          map(),
          :v | :seq | :up | :lux | :water | :fan | :light | :heat,
          map(),
          nonempty_binary(),
          0 | 1
        ) :: integer()
  defp legacy_int(legacy, leg_key, raw, raw_key, default)
       when is_map(legacy) and is_atom(leg_key) and is_map(raw) and is_binary(raw_key) and
              is_integer(default) do
    case Map.get(legacy, leg_key) do
      val when is_integer(val) ->
        val

      _ ->
        case Map.get(raw, raw_key) do
          val when is_integer(val) -> val
          _ -> default
        end
    end
  end

  @spec legacy_scaled_int(
          map(),
          nonempty_binary(),
          map(),
          :temperature | :air_humidity | :soil_humidity,
          0
        ) :: integer()
  defp legacy_scaled_int(raw, raw_key, legacy, leg_key, default)
       when is_map(raw) and is_binary(raw_key) and is_map(legacy) and is_atom(leg_key) and
              is_integer(default) do
    case Map.get(raw, raw_key) do
      val when is_integer(val) ->
        val

      val when is_float(val) ->
        round(val)

      _ ->
        case Map.get(legacy, leg_key) do
          val when is_number(val) -> round(val * 100)
          _ -> default
        end
    end
  end
end
