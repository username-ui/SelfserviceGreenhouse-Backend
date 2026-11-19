defmodule Greenhouse.Storage.Query do
  @moduledoc """
  Chunked ETS history pagination and streaming min/max/avg statistics for
  `Greenhouse.Storage`.
  """

  alias Greenhouse.Storage.Codec
  alias Greenhouse.Support
  alias Greenhouse.Support.DETS
  alias Greenhouse.Web.Params

  @default_history_limit 100
  @max_history_limit 5_000
  @history_select_chunk_size 500

  @typedoc "Aggregated min/max/average statistics for one float metric."
  @type metric_stats :: %{
          min: float() | nil,
          max: float() | nil,
          avg: float() | nil
        }

  @typedoc "Aggregated min/max/average statistics for light intensity (`lux`)."
  @type lux_stats :: %{
          min: integer() | nil,
          max: integer() | nil,
          avg: float() | nil
        }

  @typedoc "Interval telemetry summary returned by `get_telemetry_stats/3`."
  @type stats_result :: %{
          device_id: Greenhouse.device_id(),
          count: non_neg_integer(),
          temperature: metric_stats(),
          air_humidity: metric_stats(),
          soil_humidity: metric_stats(),
          lux: lux_stats()
        }

  @typedoc "Paginated telemetry history payload returned by `get_telemetry_history/3`."
  @type history_result :: %{
          device_id: Greenhouse.device_id(),
          total: non_neg_integer(),
          limit: non_neg_integer(),
          offset: non_neg_integer(),
          order: :asc | :desc,
          items: [Codec.telemetry_entry()],
          stats: stats_result()
        }

  @typedoc "Option accepted by `get_telemetry_history/3`."
  @type history_query_opt :: Params.history_opt() | {:b, String.t() | nil}

  @typedoc "Option accepted by `get_telemetry_stats/3`."
  @type stats_query_opt :: Params.time_range_opt() | {:b, String.t() | nil}

  @typedoc "Intermediate accumulator `{count, min_t, max_t, sum_t, ..., min_lux, max_lux, sum_lux}`."
  @type stats_acc ::
          {non_neg_integer(), integer(), integer(), integer(), integer(), integer(), integer(),
           integer(), integer(), integer(), integer(), integer(), integer()}

  @doc """
  Queries a paginated telemetry history slice and matching interval statistics.
  """
  @spec get_telemetry_history(DETS.ets_table(), Greenhouse.device_id(), [history_query_opt()]) ::
          history_result()
  def get_telemetry_history(history_table, device_id, opts \\ [])
      when is_atom(history_table) and is_binary(device_id) and is_list(opts) do
    from_ms = parse_time_bound(Keyword.get(opts, :from))
    to_ms = parse_time_bound(Keyword.get(opts, :to))
    b_filter = parse_boot_filter(Keyword.get(opts, :b))
    order = normalize_order(Keyword.get(opts, :order, :desc))
    limit = normalize_limit(Keyword.get(opts, :limit, @default_history_limit))
    offset = normalize_offset(Keyword.get(opts, :offset, 0))

    {total, items, stats} =
      query_history_page_and_stats(
        history_table,
        device_id,
        from_ms,
        to_ms,
        b_filter,
        order,
        limit,
        offset
      )

    %{
      device_id: device_id,
      total: total,
      limit: limit,
      offset: offset,
      order: order,
      items: items,
      stats: stats
    }
  end

  @doc """
  Computes interval telemetry statistics for `device_id` without returning items.
  """
  @spec get_telemetry_stats(DETS.ets_table(), Greenhouse.device_id(), [stats_query_opt()]) ::
          stats_result()
  def get_telemetry_stats(history_table, device_id, opts \\ [])
      when is_atom(history_table) and is_binary(device_id) and is_list(opts) do
    from_ms = parse_time_bound(Keyword.get(opts, :from))
    to_ms = parse_time_bound(Keyword.get(opts, :to))
    b_filter = parse_boot_filter(Keyword.get(opts, :b))

    query_stats_only(history_table, device_id, from_ms, to_ms, b_filter)
  end

  @doc """
  Parses an integer millisecond timestamp or ISO 8601 string bound into epoch ms.
  """
  @spec parse_time_bound(term()) :: Greenhouse.timestamp_ms() | nil
  def parse_time_bound(nil), do: nil
  def parse_time_bound(""), do: nil
  def parse_time_bound(val) when is_integer(val), do: val

  def parse_time_bound(val) when is_binary(val) do
    trimmed = String.trim(val)

    case Integer.parse(trimmed) do
      {int_val, ""} ->
        int_val

      _ ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
          _ -> nil
        end
    end
  end

  def parse_time_bound(_), do: nil

  @spec parse_boot_filter(term()) :: String.t() | nil | :invalid
  defp parse_boot_filter(nil), do: nil
  defp parse_boot_filter(""), do: nil

  defp parse_boot_filter(raw_b) do
    case Support.normalize_boot_id(raw_b) do
      {:ok, b} -> b
      :error -> :invalid
    end
  end

  @spec query_stats_only(
          DETS.ets_table(),
          Greenhouse.device_id(),
          Greenhouse.timestamp_ms() | nil,
          Greenhouse.timestamp_ms() | nil,
          String.t() | nil | :invalid
        ) :: stats_result()
  defp query_stats_only(_history_table, device_id, _from_ms, _to_ms, :invalid)
       when is_binary(device_id) do
    finalize_stats(device_id, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  end

  defp query_stats_only(history_table, device_id, from_ms, to_ms, b_filter)
       when is_atom(history_table) and is_binary(device_id) and
              (is_integer(from_ms) or is_nil(from_ms)) and
              (is_integer(to_ms) or is_nil(to_ms)) and
              (is_binary(b_filter) or is_nil(b_filter)) do
    guards = build_time_guards(from_ms, to_ms)
    match_spec = build_stats_match_spec(device_id, b_filter, guards)

    {count, min_t, max_t, sum_t, min_ah, max_ah, sum_ah, min_sh, max_sh, sum_sh, min_lux, max_lux,
     sum_lux} =
      history_table
      |> :ets.select(match_spec, @history_select_chunk_size)
      |> stats_chunks_loop(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    finalize_stats(
      device_id,
      count,
      min_t,
      max_t,
      sum_t,
      min_ah,
      max_ah,
      sum_ah,
      min_sh,
      max_sh,
      sum_sh,
      min_lux,
      max_lux,
      sum_lux
    )
  end

  defp query_history_page_and_stats(
         history_table,
         device_id,
         from_ms,
         to_ms,
         b_filter,
         order,
         limit,
         offset
       ) do
    stats = query_stats_only(history_table, device_id, from_ms, to_ms, b_filter)
    total = stats.count

    items =
      cond do
        limit == 0 or total == 0 or offset >= total ->
          []

        offset == 0 ->
          fetch_zero_offset_page(
            history_table,
            device_id,
            from_ms,
            to_ms,
            b_filter,
            order,
            limit,
            total
          )

        true ->
          fetch_offset_page(
            history_table,
            device_id,
            from_ms,
            to_ms,
            b_filter,
            order,
            limit,
            offset,
            total
          )
      end

    {total, items, stats}
  end

  defp fetch_zero_offset_page(
         history_table,
         device_id,
         from_ms,
         to_ms,
         b_filter,
         order,
         limit,
         total
       ) do
    take_count = min(limit, total)
    guards = build_time_guards(from_ms, to_ms)
    match_spec = build_record_match_spec(device_id, b_filter, guards)

    chunk_size =
      if guards == [] and is_nil(b_filter),
        do: min(take_count, @history_select_chunk_size),
        else: @history_select_chunk_size

    initial =
      case order do
        :asc -> :ets.select(history_table, match_spec, chunk_size)
        :desc -> :ets.select_reverse(history_table, match_spec, chunk_size)
      end

    take_page_records(initial, order, take_count, [])
  end

  defp fetch_offset_page(
         history_table,
         device_id,
         from_ms,
         to_ms,
         b_filter,
         order,
         limit,
         offset,
         total
       ) do
    take_count = min(limit, total - offset)
    guards = build_time_guards(from_ms, to_ms)
    key_match_spec = build_key_match_spec(device_id, b_filter, guards)

    chunk_size =
      if guards == [] and is_nil(b_filter),
        do: min(offset + take_count, @history_select_chunk_size),
        else: @history_select_chunk_size

    initial =
      case order do
        :asc -> :ets.select(history_table, key_match_spec, chunk_size)
        :desc -> :ets.select_reverse(history_table, key_match_spec, chunk_size)
      end

    picked_keys = take_page_keys(initial, order, offset, take_count, [])

    picked_keys
    |> Enum.reduce([], fn {ms, counter}, acc ->
      case :ets.lookup(history_table, {device_id, ms, counter}) do
        [record] -> [Codec.expand_history_record(record) | acc]
        [] -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp build_stats_match_spec(device_id, nil, guards) do
    v2_b_guard = {:or, {:is_binary, :"$6"}, {:==, :"$6", nil}}

    [
      {{{device_id, :"$1", :_}, :_, :"$6", :_, :_, :"$2", :"$3", :"$4", :"$5", :_},
       [v2_b_guard | guards], [{{:"$2", :"$3", :"$4", :"$5"}}]},
      {{{device_id, :"$1", :_}, :_, :"$6", :_, :_, :"$2", :"$3", :"$4", :"$5", :_, :_},
       [v2_b_guard | guards], [{{:"$2", :"$3", :"$4", :"$5"}}]},
      {{{device_id, :"$1", :_}, :_, :_, :_, :"$2", :"$3", :"$4", :"$5", :_}, guards,
       [{{:"$2", :"$3", :"$4", :"$5"}}]},
      {{{device_id, :"$1", :_}, :_, :"$6", :_, :"$2", :"$3", :"$4", :"$5", :_, :_},
       [{:is_integer, :"$6"} | guards], [{{:"$2", :"$3", :"$4", :"$5"}}]}
    ]
  end

  defp build_stats_match_spec(device_id, b_filter, guards) when is_binary(b_filter) do
    [
      {{{device_id, :"$1", :_}, :_, b_filter, :_, :_, :"$2", :"$3", :"$4", :"$5", :_}, guards,
       [{{:"$2", :"$3", :"$4", :"$5"}}]},
      {{{device_id, :"$1", :_}, :_, b_filter, :_, :_, :"$2", :"$3", :"$4", :"$5", :_, :_}, guards,
       [{{:"$2", :"$3", :"$4", :"$5"}}]}
    ]
  end

  defp build_record_match_spec(device_id, nil, guards) do
    [
      {{{device_id, :"$1", :_}, :_, :_, :_, :_, :_, :_, :_, :_, :_}, guards, [:"$_"]},
      {{{device_id, :"$1", :_}, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}, guards, [:"$_"]},
      {{{device_id, :"$1", :_}, :_, :_, :_, :_, :_, :_, :_, :_}, guards, [:"$_"]}
    ]
  end

  defp build_record_match_spec(device_id, b_filter, guards) when is_binary(b_filter) do
    [
      {{{device_id, :"$1", :_}, :_, b_filter, :_, :_, :_, :_, :_, :_, :_}, guards, [:"$_"]},
      {{{device_id, :"$1", :_}, :_, b_filter, :_, :_, :_, :_, :_, :_, :_, :_}, guards, [:"$_"]}
    ]
  end

  defp build_key_match_spec(device_id, nil, guards) do
    [
      {{{device_id, :"$1", :"$2"}, :_, :_, :_, :_, :_, :_, :_, :_, :_}, guards,
       [{{:"$1", :"$2"}}]},
      {{{device_id, :"$1", :"$2"}, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}, guards,
       [{{:"$1", :"$2"}}]},
      {{{device_id, :"$1", :"$2"}, :_, :_, :_, :_, :_, :_, :_, :_}, guards, [{{:"$1", :"$2"}}]}
    ]
  end

  defp build_key_match_spec(device_id, b_filter, guards) when is_binary(b_filter) do
    [
      {{{device_id, :"$1", :"$2"}, :_, b_filter, :_, :_, :_, :_, :_, :_, :_}, guards,
       [{{:"$1", :"$2"}}]},
      {{{device_id, :"$1", :"$2"}, :_, b_filter, :_, :_, :_, :_, :_, :_, :_, :_}, guards,
       [{{:"$1", :"$2"}}]}
    ]
  end

  defp take_page_records(:"$end_of_table", _order, _remaining, acc), do: Enum.reverse(acc)
  defp take_page_records(_res, _order, 0, acc), do: Enum.reverse(acc)

  defp take_page_records({rows, cont}, order, remaining, acc) do
    {next_remaining, next_acc} = take_up_to(rows, remaining, acc)

    if next_remaining == 0 or cont == :"$end_of_table" do
      Enum.reverse(next_acc)
    else
      next_res =
        case order do
          :asc -> :ets.select(cont)
          :desc -> :ets.select_reverse(cont)
        end

      take_page_records(next_res, order, next_remaining, next_acc)
    end
  end

  defp take_up_to([], remaining, acc), do: {remaining, acc}
  defp take_up_to(_rows, 0, acc), do: {0, acc}

  defp take_up_to([record | rest], remaining, acc) do
    take_up_to(rest, remaining - 1, [Codec.expand_history_record(record) | acc])
  end

  defp take_page_keys(:"$end_of_table", _order, _skip, _take, acc), do: Enum.reverse(acc)
  defp take_page_keys(_res, _order, _skip, 0, acc), do: Enum.reverse(acc)

  defp take_page_keys({rows, cont}, order, skip, take, acc) do
    {next_skip, next_take, next_acc} = skip_and_take(rows, skip, take, acc)

    if next_take == 0 or cont == :"$end_of_table" do
      Enum.reverse(next_acc)
    else
      next_res =
        case order do
          :asc -> :ets.select(cont)
          :desc -> :ets.select_reverse(cont)
        end

      take_page_keys(next_res, order, next_skip, next_take, next_acc)
    end
  end

  defp skip_and_take([], skip, take, acc), do: {skip, take, acc}
  defp skip_and_take(_rows, skip, 0, acc), do: {skip, 0, acc}

  defp skip_and_take([_row | rest], skip, take, acc) when skip > 0 do
    skip_and_take(rest, skip - 1, take, acc)
  end

  defp skip_and_take([row | rest], 0, take, acc) do
    skip_and_take(rest, 0, take - 1, [row | acc])
  end

  defp stats_chunks_loop(
         :"$end_of_table",
         count,
         min_t,
         max_t,
         sum_t,
         min_ah,
         max_ah,
         sum_ah,
         min_sh,
         max_sh,
         sum_sh,
         min_lux,
         max_lux,
         sum_lux
       ) do
    {count, min_t, max_t, sum_t, min_ah, max_ah, sum_ah, min_sh, max_sh, sum_sh, min_lux, max_lux,
     sum_lux}
  end

  defp stats_chunks_loop(
         {rows, cont},
         count,
         min_t,
         max_t,
         sum_t,
         min_ah,
         max_ah,
         sum_ah,
         min_sh,
         max_sh,
         sum_sh,
         min_lux,
         max_lux,
         sum_lux
       ) do
    {count, min_t, max_t, sum_t, min_ah, max_ah, sum_ah, min_sh, max_sh, sum_sh, min_lux, max_lux,
     sum_lux} =
      stats_rows_loop(
        rows,
        count,
        min_t,
        max_t,
        sum_t,
        min_ah,
        max_ah,
        sum_ah,
        min_sh,
        max_sh,
        sum_sh,
        min_lux,
        max_lux,
        sum_lux
      )

    if cont == :"$end_of_table" do
      {count, min_t, max_t, sum_t, min_ah, max_ah, sum_ah, min_sh, max_sh, sum_sh, min_lux,
       max_lux, sum_lux}
    else
      stats_chunks_loop(
        :ets.select(cont),
        count,
        min_t,
        max_t,
        sum_t,
        min_ah,
        max_ah,
        sum_ah,
        min_sh,
        max_sh,
        sum_sh,
        min_lux,
        max_lux,
        sum_lux
      )
    end
  end

  defp stats_rows_loop(
         [],
         count,
         min_t,
         max_t,
         sum_t,
         min_ah,
         max_ah,
         sum_ah,
         min_sh,
         max_sh,
         sum_sh,
         min_lux,
         max_lux,
         sum_lux
       ) do
    {count, min_t, max_t, sum_t, min_ah, max_ah, sum_ah, min_sh, max_sh, sum_sh, min_lux, max_lux,
     sum_lux}
  end

  defp stats_rows_loop(
         [{t, ah, sh, lux} | rest],
         0,
         _min_t,
         _max_t,
         _sum_t,
         _min_ah,
         _max_ah,
         _sum_ah,
         _min_sh,
         _max_sh,
         _sum_sh,
         _min_lux,
         _max_lux,
         _sum_lux
       ) do
    stats_rows_loop(rest, 1, t, t, t, ah, ah, ah, sh, sh, sh, lux, lux, lux)
  end

  defp stats_rows_loop(
         [{t, ah, sh, lux} | rest],
         count,
         min_t,
         max_t,
         sum_t,
         min_ah,
         max_ah,
         sum_ah,
         min_sh,
         max_sh,
         sum_sh,
         min_lux,
         max_lux,
         sum_lux
       ) do
    stats_rows_loop(
      rest,
      count + 1,
      min(min_t, t),
      max(max_t, t),
      sum_t + t,
      min(min_ah, ah),
      max(max_ah, ah),
      sum_ah + ah,
      min(min_sh, sh),
      max(max_sh, sh),
      sum_sh + sh,
      min(min_lux, lux),
      max(max_lux, lux),
      sum_lux + lux
    )
  end

  @spec build_time_guards(Greenhouse.timestamp_ms() | nil, Greenhouse.timestamp_ms() | nil) :: [
          {:>= | :"=<", :"$1", Greenhouse.timestamp_ms()}
        ]
  defp build_time_guards(from_ms, to_ms) do
    []
    |> maybe_add_guard(from_ms, fn bound -> {:>=, :"$1", bound} end)
    |> maybe_add_guard(to_ms, fn bound -> {:"=<", :"$1", bound} end)
  end

  @spec maybe_add_guard([tuple()], Greenhouse.timestamp_ms() | nil, (Greenhouse.timestamp_ms() ->
                                                                       tuple())) ::
          [tuple()]
  defp maybe_add_guard(guards, nil, _builder), do: guards

  defp maybe_add_guard(guards, bound, builder) when is_integer(bound),
    do: [builder.(bound) | guards]

  @spec finalize_stats(
          Greenhouse.device_id(),
          non_neg_integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer()
        ) :: stats_result()
  defp finalize_stats(
         device_id,
         0,
         _min_t,
         _max_t,
         _sum_t,
         _min_ah,
         _max_ah,
         _sum_ah,
         _min_sh,
         _max_sh,
         _sum_sh,
         _min_lux,
         _max_lux,
         _sum_lux
       ) do
    empty_metric = %{min: nil, max: nil, avg: nil}

    %{
      device_id: device_id,
      count: 0,
      temperature: empty_metric,
      air_humidity: empty_metric,
      soil_humidity: empty_metric,
      lux: empty_metric
    }
  end

  defp finalize_stats(
         device_id,
         count,
         min_t,
         max_t,
         sum_t,
         min_ah,
         max_ah,
         sum_ah,
         min_sh,
         max_sh,
         sum_sh,
         min_lux,
         max_lux,
         sum_lux
       ) do
    denom = count * 100.0

    %{
      device_id: device_id,
      count: count,
      temperature: %{min: min_t / 100.0, max: max_t / 100.0, avg: sum_t / denom},
      air_humidity: %{min: min_ah / 100.0, max: max_ah / 100.0, avg: sum_ah / denom},
      soil_humidity: %{min: min_sh / 100.0, max: max_sh / 100.0, avg: sum_sh / denom},
      lux: %{min: min_lux, max: max_lux, avg: sum_lux / count}
    }
  end

  @spec normalize_order(term()) :: :asc | :desc
  defp normalize_order(:asc), do: :asc
  defp normalize_order("asc"), do: :asc
  defp normalize_order(_), do: :desc

  @spec normalize_limit(term()) :: non_neg_integer()
  defp normalize_limit(limit) when is_integer(limit) do
    limit |> max(0) |> min(@max_history_limit)
  end

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {val, ""} -> normalize_limit(val)
      _ -> @default_history_limit
    end
  end

  defp normalize_limit(_), do: @default_history_limit

  @spec normalize_offset(term()) :: non_neg_integer()
  defp normalize_offset(offset) when is_integer(offset), do: max(offset, 0)

  defp normalize_offset(offset) when is_binary(offset) do
    case Integer.parse(String.trim(offset)) do
      {val, ""} -> normalize_offset(val)
      _ -> 0
    end
  end

  defp normalize_offset(_), do: 0
end
