defmodule Greenhouse.AccountStoreTest do
  use ExUnit.Case, async: false

  alias Greenhouse.{AccountStore, Storage}
  alias Greenhouse.TestSupport.Helpers

  setup do
    if Process.whereis(Storage) == nil do
      start_supervised!({Storage, persist: false})
    end

    if Process.whereis(AccountStore) == nil do
      start_supervised!({AccountStore, persist: false, seed_demo: false})
    end

    AccountStore.reset_demo!()

    on_exit(fn ->
      if Process.whereis(AccountStore), do: AccountStore.reset!()
      if Process.whereis(Storage), do: Storage.reset!()
    end)

    :ok
  end

  describe "demo seed & single simulated device invariant" do
    test "seeds alice and bob with dual passwords and only GH-0000 has storage data" do
      assert {:ok, alice} = AccountStore.verify_credentials("alice", "password123")
      assert {:ok, ^alice} = AccountStore.verify_credentials("alice", "alice123")
      assert alice.id == "user-alice"
      assert alice.displayName == "林晓"
      assert alice.role == "1号温室管理员"

      assert {:ok, bob} = AccountStore.verify_credentials("bob", "password123")
      assert {:ok, ^bob} = AccountStore.verify_credentials("bob", "bob123")
      assert bob.id == "user-bob"

      assert {:error, :invalid_credentials} = AccountStore.verify_credentials("alice", "wrong")

      # Only GH-0000 is populated in Storage with Protocol v2 fields
      assert {:ok, gh0_dev} = Storage.get_device("GH-0000")
      assert gh0_dev.status.online == true
      assert is_binary(gh0_dev.status.b)
      assert Regex.match?(~r/^[0-9a-f]{8}$/, gh0_dev.status.b)
      assert is_binary(gh0_dev.status.updated_at)
      assert is_integer(gh0_dev.status.updated_at_ms)
      assert gh0_dev.latest_telemetry != nil
      assert gh0_dev.latest_telemetry.v == 2
      assert gh0_dev.latest_telemetry.b == gh0_dev.status.b
      assert gh0_dev.latest_telemetry.raw["b"] == gh0_dev.status.b
      assert map_size(gh0_dev.config.raw) == 21
      {:ok, gh0_hist} = Storage.get_telemetry_history("GH-0000", limit: 50)
      assert gh0_hist.total == 16
      assert Enum.all?(gh0_hist.items, &(&1.v == 2 and &1.b == gh0_dev.status.b))

      # GH-0001, GH-0002 and GH-0003 must NOT have fabricated Storage data
      assert {:error, :not_found} = Storage.get_device("GH-0001")
      assert {:error, :not_found} = Storage.get_device("GH-0002")
      assert {:error, :not_found} = Storage.get_device("GH-0003")

      [gh0_binding] = AccountStore.list_user_bindings("user-alice")
      assert gh0_binding.deviceId == "GH-0000"
      gh0_snap = AccountStore.build_user_device_snapshot(gh0_binding)
      assert gh0_snap.simulated == true
      assert gh0_snap.online == true
      assert gh0_snap.source == "local"
      assert gh0_snap.latest_telemetry != nil

      [gh2_binding] = AccountStore.list_user_bindings("user-bob")
      assert gh2_binding.deviceId == "GH-0002"
      gh2_snap = AccountStore.build_user_device_snapshot(gh2_binding)
      assert gh2_snap.simulated == false
      assert gh2_snap.online == false
      assert gh2_snap.status == nil
      assert gh2_snap.latest_telemetry == nil
      assert gh2_snap.active_alarms == []
      assert gh2_snap.all_alarms == []

      assert gh2_snap.config == %{
               device_id: "GH-0002",
               raw: %{},
               human: %{},
               updated_at: nil,
               updated_at_ms: nil
             }

      assert gh2_snap.source == "backend"
    end

    test "supports registration, session lifecycle, exclusive binding 409, and unbind" do
      assert {:error, 409, "username_taken", _} =
               AccountStore.register_user(%{"username" => "Alice", "password" => "password123"})

      assert {:ok, %{user: charlie, token: token}} =
               AccountStore.register_user(%{
                 "username" => "charlie_test",
                 "password" => "secret123",
                 "displayName" => "张工"
               })

      assert charlie.username == "charlie_test"
      assert charlie.displayName == "张工"
      assert {:ok, ^charlie} = AccountStore.get_session_user(token)

      # Attempting to bind device owned by alice -> 409
      assert {:error, 409, "device_already_bound", _} =
               AccountStore.bind_device(charlie.id, %{"deviceId" => "gh-0000"})

      # Binding unknown device succeeds without fabricating storage data
      assert {:ok, binding} =
               AccountStore.bind_device(charlie.id, %{
                 "deviceId" => "gh-9999",
                 "name" => "测试大棚"
               })

      assert binding.deviceId == "GH-9999"
      assert {:error, :not_found} = Storage.get_device("GH-9999")

      snap = AccountStore.build_user_device_snapshot(binding)
      assert snap.simulated == false
      assert snap.online == false
      assert snap.latest_telemetry == nil
      assert snap.config.raw == %{}

      # Self duplicate -> 409
      assert {:error, 409, "already_bound_by_you", _} =
               AccountStore.bind_device(charlie.id, %{"deviceId" => "GH-9999"})

      # Other user cannot update or unbind
      assert {:error, :forbidden} =
               AccountStore.update_binding("user-bob", "GH-9999", %{"name" => "hack"})

      assert {:error, :forbidden} = AccountStore.unbind_device("user-bob", "GH-9999")

      assert :ok = AccountStore.unbind_device(charlie.id, "GH-9999")
      assert {:error, :not_found} = AccountStore.get_device_owner("GH-9999")

      :ok = AccountStore.delete_session(token)
      assert {:error, :unauthorized} = AccountStore.get_session_user(token)
    end

    test "allows simulation only for GH-0000 and rejects unknown devices" do
      assert {:error, 400, "not_simulated_device", _} =
               AccountStore.simulate_scenario("GH-0001", "normal")

      assert {:error, 400, "not_simulated_device", _} =
               AccountStore.simulate_scenario("GH-0002", "normal")

      assert {:error, 400, "not_simulated_device", _} =
               AccountStore.simulate_scenario("GH-0003", "water_lack")

      assert {:error, 400, "invalid_scenario", _} =
               AccountStore.simulate_scenario("GH-0000", "unknown_mode")

      {:ok, initial_dev} = Storage.get_device("GH-0000")
      initial_b = initial_dev.status.b
      initial_seq = initial_dev.latest_telemetry.seq

      assert {:ok, lack_snap} = AccountStore.simulate_scenario("GH-0000", "water_lack")
      assert lack_snap.active_alarm_count == 1
      alarm = hd(lack_snap.active_alarms)
      assert alarm.code == "water_lack"
      assert alarm.v == 2
      assert alarm.b == initial_b
      assert lack_snap.latest_telemetry.v == 2
      assert lack_snap.latest_telemetry.b == initial_b
      assert lack_snap.latest_telemetry.seq == initial_seq + 1
      assert lack_snap.latest_telemetry.water == 0

      assert {:ok, restored_snap} = AccountStore.simulate_scenario("GH-0000", "water_restored")
      assert restored_snap.active_alarm_count == 0
      assert restored_snap.latest_telemetry.b == initial_b
      assert restored_snap.latest_telemetry.seq == initial_seq + 2
      assert restored_snap.latest_telemetry.water == 1

      assert {:ok, offline_snap} = AccountStore.simulate_scenario("GH-0000", "offline")
      assert offline_snap.online == false

      # Offline -> online simulates reboot with new 8-hex b and seq reset to 0
      assert {:ok, reboot_snap} = AccountStore.simulate_scenario("GH-0000", "normal")
      assert reboot_snap.online == true
      assert Regex.match?(~r/^[0-9a-f]{8}$/, reboot_snap.status.b)
      assert reboot_snap.status.b != initial_b
      assert reboot_snap.latest_telemetry.v == 2
      assert reboot_snap.latest_telemetry.b == reboot_snap.status.b
      assert reboot_snap.latest_telemetry.seq == 0
      assert reboot_snap.latest_telemetry.up == 3
    end
  end

  describe "compact session format, expiration pruning, and legacy DETS migration" do
    test "get_session_user/1 and :prune_sessions handle compact and legacy expired sessions" do
      now_ms = System.system_time(:millisecond)
      expired_compact = "expired-compact-#{System.unique_integer([:positive])}"
      expired_legacy = "expired-legacy-#{System.unique_integer([:positive])}"
      valid_legacy = "valid-legacy-#{System.unique_integer([:positive])}"
      pruned_compact = "pruned-compact-#{System.unique_integer([:positive])}"

      :ets.insert(:gh_sessions, [
        {expired_compact, "user-alice", now_ms - 1_000},
        {expired_legacy, %{user_id: "user-bob", expires_at_ms: now_ms - 500}},
        {valid_legacy, %{user_id: "user-alice", expires_at_ms: now_ms + 60_000}},
        {pruned_compact, "user-bob", now_ms - 200}
      ])

      assert {:error, :unauthorized} = AccountStore.get_session_user(expired_compact)
      assert :ets.lookup(:gh_sessions, expired_compact) == []

      assert {:error, :unauthorized} = AccountStore.get_session_user(expired_legacy)
      assert :ets.lookup(:gh_sessions, expired_legacy) == []

      assert {:ok, alice} = AccountStore.get_session_user(valid_legacy)
      assert alice.id == "user-alice"

      # Trigger periodic prune handler and sync via GenServer call
      send(Process.whereis(AccountStore), :prune_sessions)
      _ = :sys.get_state(AccountStore)

      assert :ets.lookup(:gh_sessions, pruned_compact) == []
      assert {:ok, ^alice} = AccountStore.get_session_user(valid_legacy)
    end

    test "migrates legacy sessions.dets and prunes expired sessions when persisted" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "gh_account_legacy_#{System.unique_integer([:positive])}"
        )

      Helpers.detach_supervised_child(AccountStore, tmp_dir: tmp_dir)

      now_ms = System.system_time(:millisecond)
      sessions_file = tmp_dir |> Path.join("sessions.dets") |> String.to_charlist()
      {:ok, :legacy_sess} = :dets.open_file(:legacy_sess, file: sessions_file, type: :set)

      :ok =
        :dets.insert(:legacy_sess, [
          {"valid-tok",
           %{
             token: "valid-tok",
             user_id: "user-alice",
             created_at_ms: now_ms - 10_000,
             expires_at_ms: now_ms + 600_000
           }},
          {"old-tok",
           %{
             token: "old-tok",
             user_id: "user-alice",
             created_at_ms: now_ms - 50_000,
             expires_at_ms: now_ms - 1_000
           }}
        ])

      :ok = :dets.close(:legacy_sess)

      {:ok, pid1} = AccountStore.start_link(persist: true, data_dir: tmp_dir, seed_demo: true)

      assert {:ok, alice} = AccountStore.get_session_user("valid-tok")
      assert alice.id == "user-alice"
      assert {:error, :unauthorized} = AccountStore.get_session_user("old-tok")
      assert [{_tok, "user-alice", _exp}] = :ets.lookup(:gh_sessions, "valid-tok")
      assert :ets.lookup(:gh_sessions, "old-tok") == []

      GenServer.stop(pid1)

      {:ok, pid2} = AccountStore.start_link(persist: true, data_dir: tmp_dir, seed_demo: true)
      assert {:ok, ^alice} = AccountStore.get_session_user("valid-tok")
      assert {:ok, ^alice} = AccountStore.verify_credentials("alice", "alice123")
      GenServer.stop(pid2)
    end

    test "detaches >64B binding notes from large JSON payloads and hibernates when idle" do
      large_json =
        JSON.encode!(%{
          "deviceId" => "GH-NOTE-1",
          "name" => "温室A",
          "notes" => String.duplicate("n", 120),
          "padding" => String.duplicate("p", 8192)
        })

      params = large_json |> JSON.decode!() |> Map.delete("padding")
      assert {:ok, binding} = AccountStore.bind_device("user-alice", params)
      [{_dev, stored}] = :ets.lookup(:gh_bindings, binding.deviceId)
      assert :binary.referenced_byte_size(stored.notes) == byte_size(stored.notes)

      Helpers.detach_supervised_child(AccountStore)

      {:ok, pid} =
        AccountStore.start_link(persist: false, seed_demo: true, hibernate_after_ms: 25)

      assert {:ok, _tok} = AccountStore.create_session("user-alice")

      assert Helpers.eventually(fn ->
               Process.info(pid, :current_function) ==
                 {:current_function, {:gen_server, :loop_hibernate, 4}}
             end)

      GenServer.stop(pid)

      # Ensure seed_demo: true does not crash if Storage already has higher-seq GH-0000 telemetry
      {:ok, :recorded} =
        Greenhouse.Storage.record_telemetry_compact("GH-0000", %{
          "v" => 2,
          "b" => "7f3a91c4",
          "seq" => 99_999,
          "up" => 500_000,
          "t" => 2350,
          "ah" => 5500,
          "sh" => 4200,
          "lux" => 1000,
          "water" => 1,
          "fan" => 0,
          "light" => 1,
          "heat" => 0
        })

      {:ok, pid2} = AccountStore.start_link(persist: false, seed_demo: true)
      assert {:ok, _alice} = AccountStore.verify_credentials("alice", "alice123")
      GenServer.stop(pid2)
    end
  end
end
