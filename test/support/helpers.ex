defmodule Greenhouse.TestSupport.Helpers do
  @moduledoc false

  import ExUnit.Assertions, only: [assert: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Greenhouse.Storage

  def eventually(fun, attempts \\ 40)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(15)
      eventually(fun, attempts - 1)
    end
  end

  def await_until(fun, attempts \\ 40)
  def await_until(fun, 0), do: assert(fun.())

  def await_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(15)
      await_until(fun, attempts - 1)
    end
  end

  def stop_safely(server, timeout \\ 5_000)

  def stop_safely(name, timeout) when is_atom(name) and not is_nil(name) do
    name
    |> Process.whereis()
    |> stop_safely(timeout)
  end

  def stop_safely(pid, timeout) when is_pid(pid) do
    ref = Process.monitor(pid)

    try do
      GenServer.stop(pid, :normal, timeout)
    catch
      :exit, {:timeout, _} ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end

      :exit, _ ->
        :ok
    after
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  def stop_safely(_, _timeout), do: :ok

  @doc """
  Detaches a supervised named child (e.g. `Greenhouse.Storage` or `Greenhouse.AccountStore`)
  so a test can start temporary instances with custom options and restore the supervisor child on exit.
  """
  def detach_supervised_child(module, opts \\ []) do
    tmp_dir = Keyword.get(opts, :tmp_dir)
    if tmp_dir, do: File.mkdir_p!(tmp_dir)

    sup_alive = Process.whereis(Greenhouse.Supervisor) != nil

    if sup_alive do
      :ok = Supervisor.terminate_child(Greenhouse.Supervisor, module)
    else
      stop_safely(module)
    end

    on_exit(fn ->
      stop_safely(module)

      if tmp_dir, do: File.rm_rf!(tmp_dir)

      if sup_alive and Process.whereis(Greenhouse.Supervisor) != nil do
        case Supervisor.restart_child(Greenhouse.Supervisor, module) do
          {:ok, _} -> :ok
          {:error, :running} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      end
    end)

    :ok
  end

  def sample_telemetry_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "seq" => 1,
        "up" => 100,
        "t" => 2350,
        "ah" => 5680,
        "sh" => 3120,
        "lux" => 812,
        "water" => 1,
        "fan" => 0,
        "light" => 1,
        "heat" => 0
      },
      overrides
    )
  end

  def sample_v2_telemetry_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "v" => 2,
        "b" => "7f3a91c4",
        "seq" => 1,
        "up" => 100,
        "t" => 2350,
        "ah" => 5680,
        "sh" => 3120,
        "lux" => 812,
        "water" => 1,
        "fan" => 0,
        "light" => 1,
        "heat" => 0
      },
      overrides
    )
  end

  def seed_device!(device_id) do
    {:ok, _} =
      Storage.record_status(device_id, %{
        "v" => 2,
        "b" => "7f3a91c4",
        "online" => true,
        "up" => 86_400
      })

    {:ok, _} =
      Storage.record_telemetry(device_id, %{
        "v" => 2,
        "b" => "7f3a91c4",
        "seq" => 1,
        "up" => 86_400,
        "t" => 2350,
        "ah" => 5680,
        "sh" => 3120,
        "lux" => 812,
        "water" => 1,
        "fan" => 0,
        "light" => 1,
        "heat" => 0
      })
  end
end
