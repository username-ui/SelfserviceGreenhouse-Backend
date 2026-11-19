defmodule Greenhouse.Web.Params do
  @moduledoc """
  Query, path, and request parameter parsing helpers for `Greenhouse.Web` handlers.
  """

  @typedoc "Time-range query option accepted by telemetry storage queries."
  @type time_range_opt :: {:from, integer() | String.t()} | {:to, integer() | String.t()}

  @typedoc "Boot session query option accepted by telemetry storage queries."
  @type boot_opt :: {:b, String.t()}

  @typedoc "Stats query option parsed from query parameters."
  @type stats_opt :: time_range_opt() | boot_opt()

  @typedoc "History query option parsed from query parameters."
  @type history_opt ::
          time_range_opt()
          | boot_opt()
          | {:limit, pos_integer()}
          | {:offset, non_neg_integer()}
          | {:order, :asc | :desc}

  @typedoc "Configuration unit option parsed from query or body parameters."
  @type unit_opt :: {:unit, :human}

  @doc """
  Attaches extracted `path_params` onto `conn` and merges them into `conn.params`.
  """
  @spec put_path_params(Plug.Conn.t(), %{optional(String.t()) => String.t()}) :: Plug.Conn.t()
  def put_path_params(%Plug.Conn{} = conn, path_params) when is_map(path_params) do
    existing_params = if is_struct(conn.params, Plug.Conn.Unfetched), do: %{}, else: conn.params
    %{conn | path_params: path_params, params: merge_maps(existing_params, path_params)}
  end

  @doc """
  Merges two maps, fast-pathing empty maps without allocating.
  """
  @spec merge_maps(map(), map()) :: map()
  def merge_maps(left, right) when is_map(left) and is_map(right) and map_size(left) == 0,
    do: right

  def merge_maps(left, right) when is_map(left) and is_map(right) and map_size(right) == 0,
    do: left

  def merge_maps(left, right) when is_map(left) and is_map(right), do: Map.merge(left, right)

  @doc """
  Parses `from` and `to` query parameters for telemetry queries.
  """
  @spec parse_time_range_opts(map()) :: [time_range_opt()]
  def parse_time_range_opts(query_params) when is_map(query_params) do
    []
    |> maybe_put_time(:from, query_params["from"])
    |> maybe_put_time(:to, query_params["to"])
  end

  @doc """
  Parses `from`, `to`, and optional `b` boot session query parameters for telemetry stats queries.
  """
  @spec parse_stats_opts(map()) :: [stats_opt()]
  def parse_stats_opts(query_params) when is_map(query_params) do
    query_params
    |> parse_time_range_opts()
    |> maybe_put_boot_id(query_params["b"])
  end

  @doc """
  Parses pagination, ordering, boot session `b`, and time-range options for telemetry history queries.
  """
  @spec parse_history_opts(map()) :: [history_opt()]
  def parse_history_opts(query_params) when is_map(query_params) do
    query_params
    |> parse_time_range_opts()
    |> maybe_put_boot_id(query_params["b"])
    |> maybe_put_non_neg_int(:limit, query_params["limit"], positive: true)
    |> maybe_put_non_neg_int(:offset, query_params["offset"], positive: false)
    |> maybe_put_order(query_params["order"])
  end

  @doc """
  Parses a boolean query/body flag (`"true"` case-insensitively or `true`).
  """
  @spec parse_bool_param(term()) :: boolean()
  def parse_bool_param(nil), do: false

  def parse_bool_param(value) when is_binary(value) do
    String.downcase(String.trim(value)) == "true"
  end

  def parse_bool_param(value) when is_boolean(value), do: value
  def parse_bool_param(_), do: false

  @doc """
  Extracts `[unit: :human]` or `[]` from query and body parameters.
  """
  @spec parse_unit_opts(map(), map()) :: [unit_opt()]
  def parse_unit_opts(query_params, body_params)
      when is_map(query_params) and is_map(body_params) do
    unit =
      Map.get(query_params, "unit") ||
        Map.get(body_params, "unit") ||
        Map.get(body_params, :unit)

    cond do
      is_binary(unit) and String.downcase(unit) == "human" -> [unit: :human]
      unit == :human -> [unit: :human]
      true -> []
    end
  end

  @doc """
  Removes the `"unit"`/`:unit` control field from configuration patch payloads.
  """
  @spec strip_unit_param(map()) :: map()
  def strip_unit_param(body_params) when is_map(body_params) do
    body_params
    |> Map.delete("unit")
    |> Map.delete(:unit)
  end

  @spec maybe_put_time([time_range_opt()], :from | :to, term()) :: [time_range_opt()]
  defp maybe_put_time(opts, _key, nil) when is_list(opts), do: opts
  defp maybe_put_time(opts, _key, "") when is_list(opts), do: opts

  defp maybe_put_time(opts, key, value)
       when is_list(opts) and key in [:from, :to] and is_integer(value),
       do: [{key, value} | opts]

  defp maybe_put_time(opts, key, value)
       when is_list(opts) and key in [:from, :to] and is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {ms, ""} -> [{key, ms} | opts]
      _ -> [{key, trimmed} | opts]
    end
  end

  defp maybe_put_time(opts, _key, _other) when is_list(opts), do: opts

  @spec maybe_put_boot_id([stats_opt()], term()) :: [stats_opt()]
  defp maybe_put_boot_id(opts, nil) when is_list(opts), do: opts

  defp maybe_put_boot_id(opts, value) when is_list(opts) and is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: opts, else: [{:b, trimmed} | opts]
  end

  defp maybe_put_boot_id(opts, _other) when is_list(opts), do: opts

  @spec maybe_put_non_neg_int([history_opt()], :limit | :offset, term(), keyword()) ::
          [history_opt()]
  defp maybe_put_non_neg_int(opts, _key, nil, _flags) when is_list(opts), do: opts
  defp maybe_put_non_neg_int(opts, _key, "", _flags) when is_list(opts), do: opts

  defp maybe_put_non_neg_int(opts, key, value, flags)
       when is_list(opts) and key in [:limit, :offset] and is_integer(value) and is_list(flags) do
    min_val = if Keyword.get(flags, :positive, false), do: 1, else: 0
    if value >= min_val, do: [{key, value} | opts], else: opts
  end

  defp maybe_put_non_neg_int(opts, key, value, flags)
       when is_list(opts) and key in [:limit, :offset] and is_binary(value) and is_list(flags) do
    case Integer.parse(String.trim(value)) do
      {num, ""} ->
        min_val = if Keyword.get(flags, :positive, false), do: 1, else: 0
        if num >= min_val, do: [{key, num} | opts], else: opts

      _ ->
        opts
    end
  end

  defp maybe_put_non_neg_int(opts, _key, _other, _flags) when is_list(opts), do: opts

  @spec maybe_put_order([history_opt()], term()) :: [history_opt()]
  defp maybe_put_order(opts, nil) when is_list(opts), do: opts
  defp maybe_put_order(opts, "") when is_list(opts), do: opts

  defp maybe_put_order(opts, value) when is_list(opts) and value in [:asc, :desc],
    do: [{:order, value} | opts]

  defp maybe_put_order(opts, value) when is_list(opts) and is_binary(value) do
    case String.downcase(String.trim(value)) do
      "asc" -> [{:order, :asc} | opts]
      "desc" -> [{:order, :desc} | opts]
      _ -> opts
    end
  end

  defp maybe_put_order(opts, _other) when is_list(opts), do: opts
end
