defmodule Greenhouse.Support do
  @moduledoc """
  Shared low-level helpers for binary detachment, timestamps, map field lookups,
  and storage adapter interoperability across Greenhouse modules.
  """

  @subbinary_copy_threshold 64

  @doc """
  Copies binaries larger than #{@subbinary_copy_threshold} bytes so long-lived ETS
  and GenServer terms do not retain references to large decoded JSON buffers.
  """
  @spec detach_binary(binary()) :: binary()
  @spec detach_binary(term()) :: term()
  def detach_binary(bin) when is_binary(bin) and byte_size(bin) > @subbinary_copy_threshold do
    :binary.copy(bin)
  end

  def detach_binary(bin), do: bin

  @doc """
  Recursively detaches binaries inside arbitrary lists, plain maps, and tuples.
  """
  @spec detach_term(term()) :: term()
  def detach_term(val) when is_binary(val), do: detach_binary(val)
  def detach_term(val) when is_list(val), do: Enum.map(val, &detach_term/1)

  def detach_term(val) when is_map(val) and not is_struct(val) do
    :maps.fold(
      fn k, v, acc ->
        Map.put(acc, detach_term(k), detach_term(v))
      end,
      %{},
      val
    )
  end

  def detach_term(val) when is_tuple(val) do
    val
    |> Tuple.to_list()
    |> Enum.map(&detach_term/1)
    |> List.to_tuple()
  end

  def detach_term(val), do: val

  @doc """
  Formats a Unix epoch millisecond timestamp as an ISO 8601 UTC string.
  """
  @spec iso8601(Greenhouse.timestamp_ms()) :: Greenhouse.iso8601_timestamp()
  def iso8601(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  @doc """
  Formats a nullable Unix epoch millisecond timestamp as an ISO 8601 UTC string.
  """
  @spec maybe_iso8601(Greenhouse.timestamp_ms() | nil) :: Greenhouse.iso8601_timestamp() | nil
  def maybe_iso8601(nil), do: nil
  def maybe_iso8601(ms) when is_integer(ms), do: iso8601(ms)

  @doc """
  Fetches a field from `map` trying `string_key` first and falling back to `atom_key`.
  """
  @spec fetch_field(map(), String.t(), atom()) :: {:ok, term()} | :error
  def fetch_field(map, string_key, atom_key)
      when is_map(map) and is_binary(string_key) and is_atom(atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, val} -> {:ok, val}
      :error -> Map.fetch(map, atom_key)
    end
  end

  @doc """
  Fetches an optional binary field from `map` by string key or atom key.
  Returns `nil` when absent or non-binary.
  """
  @spec fetch_optional_str(map(), String.t(), atom()) :: String.t() | nil
  def fetch_optional_str(map, str_key, atom_key)
      when is_map(map) and is_binary(str_key) and is_atom(atom_key) do
    case Map.fetch(map, str_key) do
      {:ok, val} when is_binary(val) ->
        val

      {:ok, _other} ->
        nil

      :error ->
        case Map.fetch(map, atom_key) do
          {:ok, val} when is_binary(val) -> val
          _ -> nil
        end
    end
  end

  @doc """
  Validates and normalizes a Protocol v2 boot session ID (`b`) into 8 lowercase hex characters.

  Returns `{:ok, normalized_b}` or `:error`.
  """
  @spec normalize_boot_id(term()) :: {:ok, String.t()} | :error
  def normalize_boot_id(b) when is_binary(b) and byte_size(b) == 8 do
    if valid_hex8?(b) do
      {:ok, b |> String.downcase() |> :binary.copy()}
    else
      :error
    end
  end

  def normalize_boot_id(_), do: :error

  @doc """
  Fetches and normalizes boot session ID `b` from `map` in `:required` or `:optional` mode.

  In `:required` mode, missing, `nil`, empty, or malformed values return `:error`.
  In `:optional` mode, absent or `nil` values return `{:ok, nil}`, while non-nil values
  must be valid 8-hex boot IDs (otherwise `:error`).
  """
  @spec fetch_boot_id(map(), :required | :optional) :: {:ok, String.t() | nil} | :error
  def fetch_boot_id(map, :required) when is_map(map) do
    case fetch_field(map, "b", :b) do
      {:ok, raw_b} -> normalize_boot_id(raw_b)
      :error -> :error
    end
  end

  def fetch_boot_id(map, :optional) when is_map(map) do
    case fetch_field(map, "b", :b) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, raw_b} -> normalize_boot_id(raw_b)
    end
  end

  @spec valid_hex8?(binary()) :: boolean()
  defp valid_hex8?(<<c1, c2, c3, c4, c5, c6, c7, c8>>) do
    hex_char?(c1) and hex_char?(c2) and hex_char?(c3) and hex_char?(c4) and
      hex_char?(c5) and hex_char?(c6) and hex_char?(c7) and hex_char?(c8)
  end

  defp valid_hex8?(_), do: false

  @spec hex_char?(byte()) :: boolean()
  defp hex_char?(c)
       when (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or (c >= ?A and c <= ?F),
       do: true

  defp hex_char?(_), do: false

  @doc """
  Fetches a binary field from `map` by string key or atom key, returning `""` when missing.
  """
  @spec fetch_str(map(), String.t(), atom()) :: String.t()
  def fetch_str(map, str_key, atom_key)
      when is_map(map) and is_binary(str_key) and is_atom(atom_key) do
    case fetch_optional_str(map, str_key, atom_key) do
      val when is_binary(val) -> val
      nil -> ""
    end
  end

  @doc """
  Safely extracts a string value from a decoded body map using `key` or an existing atom key.
  """
  @spec get_body_string(term(), String.t()) :: String.t()
  def get_body_string(body, key) when is_map(body) and is_binary(key) do
    case Map.get(body, key) do
      val when is_binary(val) ->
        val

      _ ->
        try do
          atom_key = String.to_existing_atom(key)

          case Map.get(body, atom_key) do
            val when is_binary(val) -> val
            _ -> ""
          end
        rescue
          ArgumentError -> ""
        end
    end
  end

  def get_body_string(_, key) when is_binary(key), do: ""

  @doc """
  Reads the cached raw device configuration from `storage_mod`, supporting both
  `get_raw_config/1` and the `get_config/1` fallback for test doubles.
  """
  @spec fetch_raw_config(module(), Greenhouse.device_id()) :: map()
  def fetch_raw_config(storage_mod, device_id)
      when is_atom(storage_mod) and is_binary(device_id) do
    if Code.ensure_loaded?(storage_mod) and function_exported?(storage_mod, :get_raw_config, 1) do
      storage_mod.get_raw_config(device_id)
    else
      case storage_mod.get_config(device_id) do
        {:ok, %{raw: raw}} when is_map(raw) -> raw
        _ -> %{}
      end
    end
  end
end
