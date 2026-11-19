defmodule Greenhouse.ConfigValidator do
  @moduledoc """
  Validates and converts greenhouse device configuration patches according to
  PROTOCOL.md sections 4.1, 4.3, and 4.4.

  All wire values are integers (temperature and humidity values are scaled by 100).
  """

  @known_keys [
    "tMin",
    "tMax",
    "tHys",
    "ahMin",
    "ahMax",
    "ahHys",
    "shMin",
    "shMax",
    "luxMin",
    "luxMax",
    "luxOnMs",
    "dayStartMs",
    "dayLenMs",
    "pumpMs",
    "pumpIntervalMs",
    "pumpMaxPerDay",
    "sampleMs",
    "turnPerDay",
    "turnMax",
    "turnStep",
    "turnIntervalMs"
  ]

  @scaled_keys [
    "tMin",
    "tMax",
    "tHys",
    "ahMin",
    "ahMax",
    "ahHys",
    "shMin",
    "shMax"
  ]

  @range_rules %{
    "tMin" => {-1000, 5000},
    "tMax" => {-1000, 5000},
    "ahMin" => {0, 10_000},
    "ahMax" => {0, 10_000},
    "shMin" => {0, 10_000},
    "shMax" => {0, 10_000},
    "luxMin" => {0, 200_000},
    "luxMax" => {0, 200_000},
    "luxOnMs" => {0, 86_400_000},
    "dayStartMs" => {0, 86_399_999},
    "dayLenMs" => {60_000, 86_400_000},
    "pumpMs" => {1, 600_000},
    "pumpMaxPerDay" => {1, 12},
    "sampleMs" => {10, 60_000},
    "turnMax" => {0, 180},
    "turnStep" => {1, 180}
  }

  @min_max_pairs [
    {"tMin", :tMin, "tMax", :tMax},
    {"ahMin", :ahMin, "ahMax", :ahMax},
    {"shMin", :shMin, "shMax", :shMax},
    {"luxMin", :luxMin, "luxMax", :luxMax}
  ]

  @hysteresis_triples [
    {"tHys", :tHys, "tMin", :tMin, "tMax", :tMax},
    {"ahHys", :ahHys, "ahMin", :ahMin, "ahMax", :ahMax}
  ]

  for key <- @known_keys do
    atom_key = String.to_atom(key)
    defp known_key_str(unquote(key)), do: unquote(key)
    defp known_key_str(unquote(atom_key)), do: unquote(key)
  end

  defp known_key_str(_), do: nil

  for key <- @scaled_keys do
    atom_key = String.to_atom(key)
    defp scaled_key?(unquote(key)), do: true
    defp scaled_key?(unquote(atom_key)), do: true
    defp scaled_binary_key?(unquote(key)), do: true
  end

  defp scaled_key?(_), do: false
  defp scaled_binary_key?(_), do: false

  @typedoc "Known wire configuration parameter name."
  @type wire_key :: String.t()

  @typedoc "Validated configuration patch keyed by protocol wire field names."
  @type wire_patch :: %{optional(wire_key()) => integer()}

  @typedoc "Raw device configuration map containing string or atom keys."
  @type raw_config :: %{optional(wire_key() | atom()) => term()}

  @typedoc "Human-unit configuration map where temperature and humidity fields are floats."
  @type human_config :: %{optional(String.t() | atom()) => term()}

  @doc """
  Returns the list of known wire configuration keys.
  """
  @spec known_keys() :: [wire_key()]
  def known_keys, do: @known_keys

  @doc """
  Validates a partial configuration patch against individual field bounds and
  cross-field consistency rules computed over `Map.merge(existing_raw_config, patch)`.

  Accepts string or atom keys, ignores unknown keys per PROTOCOL.md 4.1, and
  requires at least one known key with all provided values being integers.
  """
  @spec validate_patch(term()) :: {:ok, wire_patch()} | {:error, [String.t()]}
  @spec validate_patch(term(), term()) :: {:ok, wire_patch()} | {:error, [String.t()]}
  def validate_patch(patch_map, existing_raw_config \\ %{})

  def validate_patch(patch_map, existing_raw_config)
      when is_map(patch_map) and not is_struct(patch_map) and is_map(existing_raw_config) do
    normalized_patch = normalize_known_keys(patch_map)

    if map_size(normalized_patch) == 0 do
      {:error, ["No valid configuration fields provided"]}
    else
      errors =
        validate_patch_fields(normalized_patch) ++
          validate_cross_field_rules(normalized_patch, existing_raw_config)

      case errors do
        [] -> {:ok, normalized_patch}
        _ -> {:error, errors}
      end
    end
  end

  def validate_patch(_patch_map, _existing_raw_config) do
    {:error, ["Configuration payload must be a map"]}
  end

  @doc """
  Converts wire configuration values to human-readable units by dividing
  temperature and humidity fields by `100.0`.
  """
  @spec to_human(raw_config()) :: human_config()
  @spec to_human(term()) :: term()
  def to_human(raw_map) when is_map(raw_map) and not is_struct(raw_map) do
    :maps.map(
      fn k, v ->
        if scaled_key?(k) and is_number(v) do
          v / 100.0
        else
          v
        end
      end,
      raw_map
    )
  end

  def to_human(other), do: other

  @doc """
  Converts human-readable configuration values back to wire integers by multiplying
  temperature and humidity fields by `100` and rounding.

  Keys are normalized to strings; non-number values are preserved so `validate_patch/2`
  can report clear validation errors.
  """
  @spec from_human(human_config()) :: %{optional(term()) => term()}
  @spec from_human(term()) :: term()
  def from_human(human_map) when is_map(human_map) and not is_struct(human_map) do
    Enum.reduce(human_map, %{}, fn
      {k, v}, acc when is_atom(k) ->
        str_k = Atom.to_string(k)
        val = if scaled_binary_key?(str_k) and is_number(v), do: round(v * 100), else: v
        Map.put_new(acc, str_k, val)

      {k, v}, acc when is_binary(k) ->
        val = if scaled_binary_key?(k) and is_number(v), do: round(v * 100), else: v
        Map.put(acc, k, val)

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  def from_human(other), do: other

  @spec normalize_known_keys(map()) :: %{optional(wire_key()) => term()}
  defp normalize_known_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      case known_key_str(k) do
        nil -> acc
        str_k when is_binary(k) -> Map.put(acc, str_k, v)
        str_k -> Map.put_new(acc, str_k, v)
      end
    end)
  end

  @spec validate_patch_fields(%{optional(wire_key()) => term()}) :: [String.t()]
  defp validate_patch_fields(patch) when is_map(patch) do
    @known_keys
    |> Enum.reduce([], fn key, acc ->
      case Map.fetch(patch, key) do
        :error -> acc
        {:ok, val} -> prepend_single_field_errors(acc, key, val)
      end
    end)
    |> maybe_reverse()
  end

  @spec prepend_single_field_errors([String.t()], wire_key(), term()) :: [String.t()]
  defp prepend_single_field_errors(acc, key, val)
       when is_list(acc) and is_binary(key) and not is_integer(val) do
    ["#{key} must be an integer" | acc]
  end

  defp prepend_single_field_errors(acc, "tHys", val) when is_list(acc) and is_integer(val) do
    if val > 0 and val <= 6000,
      do: acc,
      else: ["tHys must be > 0 and <= 6000" | acc]
  end

  defp prepend_single_field_errors(acc, "ahHys", val) when is_list(acc) and is_integer(val) do
    if val > 0 and val <= 10_000,
      do: acc,
      else: ["ahHys must be > 0 and <= 10000" | acc]
  end

  defp prepend_single_field_errors(acc, "pumpIntervalMs", val)
       when is_list(acc) and is_integer(val) do
    if val >= 1,
      do: acc,
      else: ["pumpIntervalMs must be >= 1" | acc]
  end

  defp prepend_single_field_errors(acc, "turnPerDay", val)
       when is_list(acc) and is_integer(val) do
    if val > 0 and rem(180, val) == 0,
      do: acc,
      else: ["turnPerDay must be > 0 and a divisor of 180" | acc]
  end

  defp prepend_single_field_errors(acc, "turnIntervalMs", val)
       when is_list(acc) and is_integer(val) do
    if val >= 1000,
      do: acc,
      else: ["turnIntervalMs must be >= 1000" | acc]
  end

  defp prepend_single_field_errors(acc, key, val)
       when is_list(acc) and is_binary(key) and is_integer(val) do
    {min_val, max_val} = Map.fetch!(@range_rules, key)

    if val >= min_val and val <= max_val do
      acc
    else
      ["#{key} must be between #{min_val} and #{max_val}" | acc]
    end
  end

  @spec validate_cross_field_rules(%{optional(wire_key()) => term()}, raw_config()) :: [
          String.t()
        ]
  defp validate_cross_field_rules(patch, existing) when is_map(patch) and is_map(existing) do
    acc =
      Enum.reduce(@min_max_pairs, [], fn {min_k, min_atom, max_k, max_atom}, acc ->
        case {effective_value(patch, existing, min_k, min_atom),
              effective_value(patch, existing, max_k, max_atom)} do
          {min_v, max_v} when is_integer(min_v) and is_integer(max_v) and min_v >= max_v ->
            ["#{min_k} must be less than #{max_k}" | acc]

          _ ->
            acc
        end
      end)

    acc =
      Enum.reduce(@hysteresis_triples, acc, fn {hys_k, hys_atom, min_k, min_atom, max_k, max_atom},
                                               acc ->
        case {effective_value(patch, existing, hys_k, hys_atom),
              effective_value(patch, existing, min_k, min_atom),
              effective_value(patch, existing, max_k, max_atom)} do
          {hys_v, min_v, max_v}
          when is_integer(hys_v) and is_integer(min_v) and is_integer(max_v) and
                 hys_v >= max_v - min_v ->
            ["#{hys_k} must be less than (#{max_k} - #{min_k})" | acc]

          _ ->
            acc
        end
      end)

    acc =
      case {effective_value(patch, existing, "pumpMs", :pumpMs),
            effective_value(patch, existing, "pumpIntervalMs", :pumpIntervalMs)} do
        {pump_ms, interval_ms}
        when is_integer(pump_ms) and is_integer(interval_ms) and interval_ms < pump_ms ->
          ["pumpIntervalMs must be >= pumpMs" | acc]

        _ ->
          acc
      end

    acc =
      case {effective_value(patch, existing, "turnStep", :turnStep),
            effective_value(patch, existing, "turnMax", :turnMax)} do
        {turn_step, turn_max}
        when is_integer(turn_step) and is_integer(turn_max) and turn_step > turn_max ->
          ["turnStep must be <= turnMax" | acc]

        _ ->
          acc
      end

    maybe_reverse(acc)
  end

  @spec effective_value(%{optional(wire_key()) => term()}, map(), wire_key(), atom()) :: term()
  defp effective_value(patch, existing, str_k, atom_k)
       when is_map(patch) and is_map(existing) and is_binary(str_k) and is_atom(atom_k) do
    case patch do
      %{^str_k => val} ->
        val

      _ ->
        case existing do
          %{^str_k => val} -> val
          %{^atom_k => val} -> val
          _ -> nil
        end
    end
  end

  @spec maybe_reverse([String.t()]) :: [String.t()]
  defp maybe_reverse([]), do: []
  defp maybe_reverse([_] = single), do: single
  defp maybe_reverse(list) when is_list(list), do: Enum.reverse(list)
end
