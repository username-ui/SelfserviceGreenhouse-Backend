defmodule Greenhouse.Support.DETS do
  @moduledoc """
  Shared ETS + optional DETS table lifecycle and write-through helpers.
  """

  @typedoc "Named ETS table identifier."
  @type ets_table :: atom()

  @typedoc "Named DETS table identifier."
  @type dets_table :: atom()

  @typedoc "ETS-to-DETS table specification `{ets_table, dets_table, filename}`."
  @type table_spec :: {ets_table(), dets_table(), String.t()}

  @typedoc "Mapping from ETS table name to its paired DETS table name."
  @type dets_map :: %{optional(ets_table()) => dets_table()}

  @doc """
  Opens DETS tables specified by `{ets_table, dets_table, filename}` tuples under `data_dir`.
  """
  @spec open_tables(Path.t(), [table_spec()]) :: dets_map()
  def open_tables(data_dir, specs) when is_binary(data_dir) and is_list(specs) do
    File.mkdir_p!(data_dir)

    Map.new(specs, fn {ets_name, dets_name, filename}
                      when is_atom(ets_name) and is_atom(dets_name) and is_binary(filename) ->
      file_path = data_dir |> Path.join(filename) |> String.to_charlist()
      {:ok, ^dets_name} = :dets.open_file(dets_name, file: file_path, type: :set)
      {ets_name, dets_name}
    end)
  end

  @doc """
  Loads all objects from each DETS table into its paired ETS table.
  """
  @spec load_into_ets(dets_map()) :: :ok
  def load_into_ets(dets_tables) when is_map(dets_tables) do
    Enum.each(dets_tables, fn {ets_name, dets_name}
                              when is_atom(ets_name) and is_atom(dets_name) ->
      :ets.from_dets(ets_name, dets_name)
    end)
  end

  @doc """
  Inserts `record` into `ets_table` and writes through to DETS when `persist?` is `true`.
  """
  @spec put_record(ets_table(), tuple(), boolean(), dets_map()) :: :ok
  def put_record(ets_table, record, persist?, dets_tables)
      when is_atom(ets_table) and is_tuple(record) and is_boolean(persist?) and
             is_map(dets_tables) do
    :ets.insert(ets_table, record)

    _ =
      if persist? do
        dets_table = Map.fetch!(dets_tables, ets_table)
        :dets.insert(dets_table, record)
      end

    :ok
  end

  @doc """
  Deletes `key` from `ets_table` and from DETS when `persist?` is `true`.
  """
  @spec delete_record(ets_table(), term(), boolean(), dets_map()) :: :ok
  def delete_record(ets_table, key, persist?, dets_tables)
      when is_atom(ets_table) and is_boolean(persist?) and is_map(dets_tables) do
    :ets.delete(ets_table, key)

    _ =
      if persist? do
        dets_table = Map.fetch!(dets_tables, ets_table)
        :dets.delete(dets_table, key)
      end

    :ok
  end

  @doc """
  Clears all objects from `ets_tables` and their paired DETS tables when `persist?` is `true`.
  """
  @spec clear_tables([ets_table()], boolean(), dets_map()) :: :ok
  def clear_tables(ets_tables, persist?, dets_tables)
      when is_list(ets_tables) and is_boolean(persist?) and is_map(dets_tables) do
    Enum.each(ets_tables, &:ets.delete_all_objects/1)

    if persist? do
      Enum.each(dets_tables, fn {_ets_name, dets_name} when is_atom(dets_name) ->
        :dets.delete_all_objects(dets_name)
      end)
    end

    :ok
  end

  @doc """
  Closes all opened DETS tables when `persist?` is `true`.
  """
  @spec close_tables(boolean(), dets_map()) :: :ok
  def close_tables(false, dets_tables) when is_map(dets_tables), do: :ok

  def close_tables(true, dets_tables) when is_map(dets_tables) do
    Enum.each(dets_tables, fn {_ets_name, dets_name} when is_atom(dets_name) ->
      :dets.close(dets_name)
    end)

    :ok
  end
end
