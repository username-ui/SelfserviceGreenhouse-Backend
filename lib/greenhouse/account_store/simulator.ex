defmodule Greenhouse.AccountStore.Simulator do
  @moduledoc """
  Demo account seeding and local simulation scenarios for the sole reserved
  simulated greenhouse device (`GH-0000`).
  """

  alias Greenhouse.AccountStore.{Auth, Bindings}
  alias Greenhouse.{Storage, Support}
  alias Greenhouse.Support.DETS

  @users_table :gh_users
  @usernames_table :gh_usernames
  @bindings_table :gh_bindings

  @reserved_sim_device_id "GH-0000"
  @valid_scenarios [
    "normal",
    "hot",
    "dry",
    "water_lack",
    "turntable_failed",
    "water_restored",
    "offline"
  ]

  @seed_raw_config %{
    "tMin" => 1800,
    "tMax" => 2800,
    "tHys" => 150,
    "ahMin" => 5000,
    "ahMax" => 7500,
    "ahHys" => 300,
    "shMin" => 3800,
    "shMax" => 6500,
    "luxMin" => 300,
    "luxMax" => 15_000,
    "luxOnMs" => 1_800_000,
    "dayStartMs" => 21_600_000,
    "dayLenMs" => 43_200_000,
    "pumpMs" => 5_000,
    "pumpIntervalMs" => 300_000,
    "pumpMaxPerDay" => 4,
    "sampleMs" => 5_000,
    "turnPerDay" => 30,
    "turnMax" => 180,
    "turnStep" => 15,
    "turnIntervalMs" => 30_000
  }

  @doc """
  Returns the sole reserved simulated device ID (`"GH-0000"`).
  """
  @spec simulated_device_id() :: Greenhouse.device_id()
  def simulated_device_id, do: @reserved_sim_device_id

  @doc """
  Returns `true` if `device_id` normalizes to `"GH-0000"`.
  """
  @spec simulated_device?(term()) :: boolean()
  def simulated_device?(device_id) do
    Bindings.normalize_device_id(device_id) == @reserved_sim_device_id
  end

  @doc """
  Validates a scenario trigger request, returning `{:ok, normalized_device_id}` or an error tuple.
  """
  @spec validate_scenario(term(), term()) ::
          {:ok, Greenhouse.device_id()} | {:error, pos_integer(), String.t(), String.t()}
  def validate_scenario(raw_device_id, scenario) do
    device_id = Bindings.normalize_device_id(raw_device_id)

    cond do
      not simulated_device?(device_id) ->
        {:error, 400, "not_simulated_device", "仅预留模拟设备支持本地工况模拟"}

      not is_binary(scenario) or scenario not in @valid_scenarios ->
        {:error, 400, "invalid_scenario", "不支持的模拟场景"}

      true ->
        {:ok, device_id}
    end
  end

  @doc """
  Seeds the demo accounts (`alice`, `bob`), bindings (`GH-0000`, `GH-0002`), and
  initial `GH-0000` simulated telemetry/config if missing.
  """
  @spec seed_demo_data!(boolean(), DETS.dets_map()) :: :ok
  def seed_demo_data!(persist?, dets_tables)
      when is_boolean(persist?) and is_map(dets_tables) do
    now_ms = System.system_time(:millisecond)
    now_iso = Support.iso8601(now_ms)

    alice_salt = Auth.random_hex(16)
    bob_salt = Auth.random_hex(16)

    alice = %{
      id: "user-alice",
      username: "alice",
      displayName: "林晓",
      role: "1号温室管理员",
      createdAt: now_iso,
      passwordSalt: alice_salt,
      passwordHashes: [
        Auth.hash_password(alice_salt, "password123"),
        Auth.hash_password(alice_salt, "alice123")
      ]
    }

    bob = %{
      id: "user-bob",
      username: "bob",
      displayName: "陈工",
      role: "2号温室管理员",
      createdAt: now_iso,
      passwordSalt: bob_salt,
      passwordHashes: [
        Auth.hash_password(bob_salt, "password123"),
        Auth.hash_password(bob_salt, "bob123")
      ]
    }

    DETS.put_record(@users_table, {alice.id, alice}, persist?, dets_tables)
    DETS.put_record(@users_table, {bob.id, bob}, persist?, dets_tables)
    :ets.insert(@usernames_table, [{"alice", alice.id}, {"bob", bob.id}])

    gh0_binding = %{
      deviceId: @reserved_sim_device_id,
      userId: "user-alice",
      name: "1号智能育苗温室",
      location: "A区-东侧",
      cropType: "番茄育苗",
      notes: "本地模拟测试设备",
      boundAt: now_iso,
      updatedAt: now_iso
    }

    gh2_binding = %{
      deviceId: "GH-0002",
      userId: "user-bob",
      name: "2号兰花恒温温室",
      location: "B区-南侧",
      cropType: "蝴蝶兰",
      notes: "高湿遮阴恒温养护",
      boundAt: now_iso,
      updatedAt: now_iso
    }

    DETS.put_record(@bindings_table, {@reserved_sim_device_id, gh0_binding}, persist?, dets_tables)
    DETS.put_record(@bindings_table, {"GH-0002", gh2_binding}, persist?, dets_tables)

    if Process.whereis(Storage) != nil and
         Storage.get_device(@reserved_sim_device_id) == {:error, :not_found} do
      seed_simulated_device!()
    end

    :ok
  end

  @doc """
  Populates 16 synthetic historical points, online status, and default config for `GH-0000`.
  """
  @spec seed_simulated_device!() :: :ok
  def seed_simulated_device! do
    now_ms = System.system_time(:millisecond)
    point_count = 16
    interval_ms = 10 * 60 * 1_000
    start_ms = now_ms - point_count * interval_ms
    base_up = 76_800
    base_seq = 1_001
    boot_id = Auth.random_hex(4)

    {latest_up, latest_ts} =
      Enum.reduce(0..(point_count - 1), nil, fn i, _acc ->
        ts = start_ms + i * interval_ms
        wave = :math.sin(i / point_count * :math.pi() * 2)
        wave2 = :math.cos(i / point_count * :math.pi() * 1.5)
        jitter = if rem(i, 3) == 0, do: 0.15, else: -0.1

        temp = 23.8 + wave * 1.35 + jitter
        ah = 58.2 - wave * 3.2 + wave2 * 1.4
        sh = 44.6 + wave2 * 2.4
        lux = max(200, round(6_400 + wave * 950 + i * 35))
        seq = base_seq + i
        up = base_up + i * 600
        light = if lux < 6_400, do: 1, else: 0

        payload = %{
          "v" => 2,
          "b" => boot_id,
          "seq" => seq,
          "up" => up,
          "t" => round(temp * 100),
          "ah" => round(ah * 100),
          "sh" => round(sh * 100),
          "lux" => lux,
          "water" => 1,
          "fan" => 0,
          "light" => light,
          "heat" => 0
        }

        case Storage.record_telemetry_compact(@reserved_sim_device_id, payload, ts) do
          {:ok, :recorded} -> :ok
          {:duplicate, _seq} -> :ok
        end

        {up, ts}
      end)

    {:ok, _status} =
      Storage.record_status(
        @reserved_sim_device_id,
        %{"v" => 2, "b" => boot_id, "online" => true, "up" => latest_up},
        latest_ts
      )

    {:ok, _cfg} =
      Storage.update_config_cache(@reserved_sim_device_id, @seed_raw_config, latest_ts)

    :ok
  end

  @doc """
  Applies a named simulation scenario to `device_id` in `Greenhouse.Storage`.
  """
  @spec run_simulation(Greenhouse.device_id(), String.t()) :: :ok
  def run_simulation(device_id, "offline") when is_binary(device_id) do
    {:ok, _status} = Storage.mark_device_offline(device_id, "simulated_lwt")
    :ok
  end

  def run_simulation(device_id, scenario)
      when is_binary(device_id) and scenario in @valid_scenarios do
    now_ms = System.system_time(:millisecond)
    {last, boot_id, next_seq, next_up} = resolve_next_simulation_state(device_id)
    payload = build_scenario_payload(scenario, last, boot_id, next_seq, next_up)

    {:ok, _status} =
      Storage.record_status(
        device_id,
        %{"v" => 2, "b" => boot_id, "online" => true, "up" => next_up},
        now_ms
      )

    {:ok, :recorded} = Storage.record_telemetry_compact(device_id, payload, now_ms)

    _ =
      case scenario do
        "water_lack" ->
          Storage.record_alarm(
            device_id,
            "water_lack",
            %{
              "v" => 2,
              "b" => boot_id,
              "up" => next_up,
              "code" => "water_lack",
              "active" => true
            },
            now_ms
          )

        "turntable_failed" ->
          Storage.record_alarm(
            device_id,
            "turntable_failed",
            %{
              "v" => 2,
              "b" => boot_id,
              "up" => next_up,
              "code" => "turntable_failed",
              "active" => true
            },
            now_ms
          )

        _ ->
          :ok
      end

    :ok
  end

  @spec resolve_next_simulation_state(Greenhouse.device_id()) ::
          {map() | nil, String.t(), non_neg_integer(), non_neg_integer()}
  defp resolve_next_simulation_state(device_id) when is_binary(device_id) do
    last =
      case Storage.get_latest_telemetry(device_id) do
        {:ok, latest} -> latest
        {:error, :not_found} -> nil
      end

    status =
      case Storage.get_device_status(device_id) do
        {:ok, current_status} -> current_status
        {:error, :not_found} -> nil
      end

    was_offline? = status != nil and status.online == false
    prev_b = (last && Map.get(last, :b)) || (status && Map.get(status, :b))

    cond do
      was_offline? or not valid_lowercase_boot_id?(prev_b) ->
        {last, next_boot_id(prev_b), 0, 3}

      last != nil ->
        {last, prev_b, last.seq + 1, last.up + 60}

      true ->
        base_up = if status && is_integer(status.up), do: status.up + 60, else: 3
        {nil, prev_b, 0, base_up}
    end
  end

  @spec valid_lowercase_boot_id?(term()) :: boolean()
  defp valid_lowercase_boot_id?(b) when is_binary(b) and byte_size(b) == 8 do
    Support.normalize_boot_id(b) == {:ok, b}
  end

  defp valid_lowercase_boot_id?(_), do: false

  @spec next_boot_id(term()) :: String.t()
  defp next_boot_id(prev_b) do
    candidate = Auth.random_hex(4)
    if candidate == prev_b, do: next_boot_id(prev_b), else: candidate
  end

  @spec build_scenario_payload(
          String.t(),
          map() | nil,
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Greenhouse.json_map()
  defp build_scenario_payload(scenario, last, boot_id, next_seq, next_up)
       when is_binary(scenario) and (is_map(last) or is_nil(last)) and is_binary(boot_id) and
              is_integer(next_seq) and is_integer(next_up) do
    jitter = (rem(next_seq, 5) - 2) * 0.15

    case scenario do
      "normal" ->
        %{
          "v" => 2,
          "b" => boot_id,
          "seq" => next_seq,
          "up" => next_up,
          "t" => round((23.5 + jitter) * 100),
          "ah" => round((58.5 - jitter * 2) * 100),
          "sh" => round((45.5 + jitter * 1.5) * 100),
          "lux" => 5_600 + rem(next_seq, 7) * 120,
          "water" => 1,
          "fan" => 0,
          "light" => 0,
          "heat" => 0
        }

      "hot" ->
        prev_sh = if last, do: max(25.0, last.soil_humidity - 1.2), else: 36.4

        %{
          "v" => 2,
          "b" => boot_id,
          "seq" => next_seq,
          "up" => next_up,
          "t" => round((34.6 + abs(jitter)) * 100),
          "ah" => round((81.5 + abs(jitter) * 2) * 100),
          "sh" => round(prev_sh * 100),
          "lux" => 26_400,
          "water" => 1,
          "fan" => 1,
          "light" => 0,
          "heat" => 0
        }

      "dry" ->
        %{
          "v" => 2,
          "b" => boot_id,
          "seq" => next_seq,
          "up" => next_up,
          "t" => round((26.8 + jitter) * 100),
          "ah" => 3140,
          "sh" => 1820,
          "lux" => 9_400,
          "water" => 1,
          "fan" => 0,
          "light" => 1,
          "heat" => 0
        }

      "water_lack" ->
        %{
          "v" => 2,
          "b" => boot_id,
          "seq" => next_seq,
          "up" => next_up,
          "t" => 2510,
          "ah" => 4760,
          "sh" => 2180,
          "lux" => 4_800,
          "water" => 0,
          "fan" => 0,
          "light" => 0,
          "heat" => 0
        }

      "turntable_failed" ->
        %{
          "v" => 2,
          "b" => boot_id,
          "seq" => next_seq,
          "up" => next_up,
          "t" => if(last, do: round(last.temperature * 100), else: 2400),
          "ah" => if(last, do: round(last.air_humidity * 100), else: 5900),
          "sh" => if(last, do: round(last.soil_humidity * 100), else: 4400),
          "lux" => if(last, do: last.lux, else: 4_200),
          "water" => 1,
          "fan" => if(last, do: last.fan, else: 0),
          "light" => 1,
          "heat" => 0
        }

      "water_restored" ->
        %{
          "v" => 2,
          "b" => boot_id,
          "seq" => next_seq,
          "up" => next_up,
          "t" => 2340,
          "ah" => 5920,
          "sh" => 4780,
          "lux" => 5_300,
          "water" => 1,
          "fan" => 0,
          "light" => 0,
          "heat" => 0
        }
    end
  end
end
