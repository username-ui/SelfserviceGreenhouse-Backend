defmodule Greenhouse.Storage.Retention do
  @moduledoc """
  Per-device telemetry history count tracking and bounded FIFO eviction across ETS
  and DETS for `Greenhouse.Storage`.
  """

  alias Greenhouse.Support.DETS

  @min_ts_sentinel -1_000_000_000_000_000_000_000

  @typedoc "Per-device retained telemetry sample counts."
  @type counts_map :: %{optional(Greenhouse.device_id()) => non_neg_integer()}

  @doc """
  Scans `history_table` on startup to recover `{max_counter, per_device_counts}`.
  """
  @spec scan_history_metadata(DETS.ets_table()) :: {non_neg_integer(), counts_map()}
  def scan_history_metadata(history_table) when is_atom(history_table) do
    :ets.foldl(
      fn record, {max_counter, counts} ->
        {device_id, _ms, counter} = elem(record, 0)
        {max(counter, max_counter), Map.update(counts, device_id, 1, &(&1 + 1))}
      end,
      {0, %{}},
      history_table
    )
  end

  @doc """
  Trims any pre-existing per-device history exceeding `cap` on startup.
  """
  @spec enforce_initial_history_cap(
          DETS.ets_table(),
          counts_map(),
          non_neg_integer() | nil,
          boolean(),
          DETS.dets_map()
        ) :: counts_map()
  def enforce_initial_history_cap(history_table, history_counts, cap, persist?, dets_tables)
      when is_atom(history_table) and is_map(history_counts) and is_integer(cap) and cap >= 0 and
             is_boolean(persist?) and is_map(dets_tables) do
    Enum.reduce(history_counts, history_counts, fn {device_id, count}, acc_counts ->
      if count > cap do
        maybe_evict_excess_history(
          history_table,
          acc_counts,
          device_id,
          count,
          cap,
          persist?,
          dets_tables
        )
      else
        acc_counts
      end
    end)
  end

  def enforce_initial_history_cap(history_table, history_counts, _cap, persist?, dets_tables)
      when is_atom(history_table) and is_map(history_counts) and is_boolean(persist?) and
             is_map(dets_tables) do
    history_counts
  end

  @doc """
  Updates the per-device count and evicts the oldest entries if `new_count > cap`.
  """
  @spec maybe_evict_excess_history(
          DETS.ets_table(),
          counts_map(),
          Greenhouse.device_id(),
          non_neg_integer(),
          non_neg_integer() | nil,
          boolean(),
          DETS.dets_map()
        ) :: counts_map()
  def maybe_evict_excess_history(
        history_table,
        history_counts,
        device_id,
        new_count,
        cap,
        persist?,
        dets_tables
      )
      when is_atom(history_table) and is_map(history_counts) and is_binary(device_id) and
             is_integer(new_count) and new_count >= 0 and is_integer(cap) and cap >= 0 and
             new_count > cap and is_boolean(persist?) and is_map(dets_tables) do
    excess = new_count - cap
    deleted = evict_oldest_history(history_table, device_id, excess, persist?, dets_tables)
    updated_count = max(new_count - deleted, 0)
    Map.put(history_counts, device_id, updated_count)
  end

  def maybe_evict_excess_history(
        history_table,
        history_counts,
        device_id,
        new_count,
        _cap,
        persist?,
        dets_tables
      )
      when is_atom(history_table) and is_map(history_counts) and is_binary(device_id) and
             is_integer(new_count) and new_count >= 0 and is_boolean(persist?) and
             is_map(dets_tables) do
    Map.put(history_counts, device_id, new_count)
  end

  @spec evict_oldest_history(
          DETS.ets_table(),
          Greenhouse.device_id(),
          integer(),
          boolean(),
          DETS.dets_map()
        ) :: non_neg_integer()
  defp evict_oldest_history(_history_table, _device_id, n, _persist?, _dets_tables)
       when is_integer(n) and n <= 0,
       do: 0

  defp evict_oldest_history(history_table, device_id, n, persist?, dets_tables)
       when is_atom(history_table) and is_binary(device_id) and is_integer(n) and n > 0 and
              is_boolean(persist?) and is_map(dets_tables) do
    do_evict_oldest(history_table, device_id, n, 0, persist?, dets_tables)
  end

  @spec do_evict_oldest(
          DETS.ets_table(),
          Greenhouse.device_id(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          DETS.dets_map()
        ) :: non_neg_integer()
  defp do_evict_oldest(_history_table, _device_id, 0, deleted, _persist?, _dets_tables)
       when is_integer(deleted),
       do: deleted

  defp do_evict_oldest(history_table, device_id, remaining, deleted, persist?, dets_tables)
       when is_atom(history_table) and is_binary(device_id) and is_integer(remaining) and
              remaining > 0 and is_integer(deleted) and is_boolean(persist?) and
              is_map(dets_tables) do
    case find_oldest_history_key(history_table, device_id) do
      nil ->
        deleted

      key ->
        DETS.delete_record(history_table, key, persist?, dets_tables)

        do_evict_oldest(
          history_table,
          device_id,
          remaining - 1,
          deleted + 1,
          persist?,
          dets_tables
        )
    end
  end

  @spec find_oldest_history_key(DETS.ets_table(), Greenhouse.device_id()) ::
          {Greenhouse.device_id(), Greenhouse.timestamp_ms(), non_neg_integer()} | nil
  defp find_oldest_history_key(history_table, device_id)
       when is_atom(history_table) and is_binary(device_id) do
    case :ets.next(history_table, {device_id, @min_ts_sentinel, -1}) do
      {^device_id, _ms, _counter} = key ->
        key

      _ ->
        case :ets.select(
               history_table,
               [
                 {{{device_id, :"$1", :"$2"}, :_, :_, :_, :_, :_, :_, :_, :_}, [],
                  [{{device_id, :"$1", :"$2"}}]},
                 {{{device_id, :"$1", :"$2"}, :_, :_, :_, :_, :_, :_, :_, :_, :_}, [],
                  [{{device_id, :"$1", :"$2"}}]},
                 {{{device_id, :"$1", :"$2"}, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}, [],
                  [{{device_id, :"$1", :"$2"}}]}
               ],
               1
             ) do
          {[key], _cont} -> key
          _ -> nil
        end
    end
  end
end
