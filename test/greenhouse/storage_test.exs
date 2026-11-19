defmodule Greenhouse.StorageTest do
  use ExUnit.Case, async: false

  alias Greenhouse.Storage
  alias Greenhouse.TestSupport.Helpers

  @device_id "GH-0001"
  @boot_id "7f3a91c4"
  @boot_id_2 "1c04be77"

  setup do
    if Process.whereis(Storage) == nil do
      start_supervised!({Storage, persist: false})
    end

    Storage.reset!()
    :ok
  end

  defp v2_telemetry(overrides \\ %{}) do
    Helpers.sample_telemetry_payload(Map.merge(%{"v" => 2, "b" => @boot_id}, overrides))
  end

  describe "record_telemetry/3" do
    test "records v2 telemetry with normalized lowercase b, scaled values, flags, timestamp, and raw fields" do
      ts = 1_700_000_000_123

      assert {:ok, entry} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => "7F3A91C4", "t" => -550}),
                 ts
               )

      assert entry.device_id == @device_id
      assert entry.v == 2
      assert entry.b == "7f3a91c4"
      assert entry.seq == 1
      assert entry.up == 100
      assert entry.temperature == -5.5
      assert entry.air_humidity == 56.8
      assert entry.soil_humidity == 31.2
      assert entry.lux == 812
      assert entry.water == 1
      assert entry.water_sufficient == true
      assert entry.fan == 0
      assert entry.fan_on == false
      assert entry.light == 1
      assert entry.light_on == true
      assert entry.heat == 0
      assert entry.heat_on == false
      assert entry.received_at == "2023-11-14T22:13:20.123Z"
      assert entry.received_at_ms == ts
      assert entry.raw["t"] == -550
      assert entry.raw["b"] == "7f3a91c4"

      assert {:ok, ^entry} = Storage.get_latest_telemetry(@device_id)
    end

    test "supports legacy v1 telemetry without b while accepting atom keys and rejecting malformed payloads" do
      atom_v2_payload = %{
        v: 2,
        b: "AbCdEf01",
        seq: 0,
        up: 0,
        t: 2000,
        ah: 5000,
        sh: 4000,
        lux: 500,
        water: 0,
        fan: 1,
        light: 0,
        heat: 1
      }

      assert {:ok, entry} =
               Storage.record_telemetry(@device_id, atom_v2_payload, 1_700_000_000_000)

      assert entry.v == 2
      assert entry.b == "abcdef01"
      assert entry.water_sufficient == false
      assert entry.fan_on == true
      assert entry.heat_on == true

      # Legacy v1 without b remains supported (b stored as nil, never "")
      assert {:ok, v1_entry} =
               Storage.record_telemetry(
                 "GH-V1",
                 Helpers.sample_telemetry_payload(%{"seq" => 1, "up" => 10}),
                 1_700_000_000_500
               )

      assert v1_entry.v == 1
      assert v1_entry.b == nil
      refute Map.has_key?(v1_entry.raw, "b")

      # v2 strictly requires valid 8-hex b
      for bad_b_payload <- [
            Map.delete(v2_telemetry(), "b"),
            v2_telemetry(%{"b" => nil}),
            v2_telemetry(%{"b" => ""}),
            v2_telemetry(%{"b" => "7f3a91c"}),
            v2_telemetry(%{"b" => "7f3a91c40"}),
            v2_telemetry(%{"b" => "7f3a91zz"}),
            v2_telemetry(%{"b" => 12_345_678})
          ] do
        assert {:error, :invalid_telemetry} = Storage.record_telemetry(@device_id, bad_b_payload)
      end

      # Unsupported version or bad scalar fields
      assert {:error, :invalid_telemetry} =
               Storage.record_telemetry(@device_id, v2_telemetry(%{"v" => 3}))

      assert {:error, :invalid_telemetry} =
               Storage.record_telemetry(@device_id, v2_telemetry(%{"v" => 0}))

      assert {:error, :invalid_telemetry} =
               Storage.record_telemetry(@device_id, Map.delete(v2_telemetry(), "lux"))

      assert {:error, :invalid_telemetry} =
               Storage.record_telemetry(@device_id, v2_telemetry(%{"t" => 23.5}))

      assert {:error, :invalid_telemetry} =
               Storage.record_telemetry(@device_id, v2_telemetry(%{"seq" => -1}))
    end

    test "deduplicates by (device_id, b, seq), accepts b-change reboots, and handles rare same-b up rollback" do
      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => "7F3A91C4", "seq" => 10, "up" => 100}),
                 1000
               )

      # Exact QoS 1 redelivery (including lowercase vs uppercase b normalization)
      assert {:duplicate, 10} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => "7f3a91c4", "seq" => 10, "up" => 100}),
                 2000
               )

      # Stale seq within same session b and non-decreasing uptime is duplicate
      assert {:duplicate, 9} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => "7f3a91c4", "seq" => 9, "up" => 120}),
                 3000
               )

      # Next seq in same session accepted
      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => "7f3a91c4", "seq" => 11, "up" => 160}),
                 4000
               )

      # Device reboot with new b resets seq to 0 (accepted even if up or seq matches/exceeds prior)
      assert {:ok, rebooted} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => @boot_id_2, "seq" => 0, "up" => 3}),
                 5000
               )

      assert rebooted.b == @boot_id_2
      assert rebooted.seq == 0

      # QoS 1 redelivery in new session is deduplicated
      assert {:duplicate, 0} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => @boot_id_2, "seq" => 0, "up" => 3}),
                 5500
               )

      # Advance in session 2
      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => @boot_id_2, "seq" => 5, "up" => 100}),
                 6000
               )

      # Rare b-collision reboot: same b, up < last_up -> accepted based on received_at
      assert {:ok, collision_reboot} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => @boot_id_2, "seq" => 0, "up" => 2}),
                 7000
               )

      assert collision_reboot.b == @boot_id_2
      assert collision_reboot.seq == 0
      assert collision_reboot.received_at_ms == 7000

      # Quick same-second b-collision reboot: same b, up == last_up and seq < last_seq
      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => @boot_id_2, "seq" => 4, "up" => 10}),
                 8000
               )

      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => @boot_id_2, "seq" => 1, "up" => 10}),
                 9000
               )

      assert {:ok, history} = Storage.get_telemetry_history(@device_id)
      assert history.total == 7
    end
  end

  describe "status and offline marking" do
    test "records online status with normalized b, LWT offline status without b, and ack timeout offline marking" do
      assert {:error, :not_found} = Storage.get_device_status(@device_id)

      assert {:ok, status} =
               Storage.record_status(
                 @device_id,
                 %{"v" => 2, "b" => "7F3A91C4", "online" => true, "up" => 86_400},
                 1000
               )

      assert status.online == true
      assert status.b == "7f3a91c4"
      assert status.up == 86_400
      assert status.offline_reason == nil
      assert status.updated_at == "1970-01-01T00:00:01.000Z"
      assert status.updated_at_ms == 1000

      assert {:ok, timed_out} = Storage.mark_device_offline(@device_id, "config_ack_timeout")
      assert timed_out.online == false
      assert timed_out.b == "7f3a91c4"
      assert timed_out.up == 86_400
      assert timed_out.offline_reason == "config_ack_timeout"

      # Protocol v2 LWT omits b and up
      assert {:ok, lwt} = Storage.record_status(@device_id, %{"v" => 2, "online" => false}, 2000)
      assert lwt.online == false
      assert lwt.b == nil
      assert lwt.up == nil
      assert lwt.offline_reason == nil
      assert lwt.updated_at_ms == 2000

      # Atom keys and invalid/empty optional b on status degrade safely to nil
      assert {:ok, atom_off} =
               Storage.record_status("GH-0002", %{v: 2, online: false, b: ""}, 3000)

      assert atom_off.online == false
      assert atom_off.b == nil

      assert {:error, :invalid_status} = Storage.record_status(@device_id, %{"v" => 2})

      assert {:error, :invalid_status} =
               Storage.record_status(@device_id, %{"v" => 3, "online" => true})
    end
  end

  describe "alarms and water_lack auto-clearing" do
    test "validates v2 alarm b requirement and auto-clears active water_lack on water == 1" do
      for bad_alarm <- [
            %{"v" => 2, "up" => 100, "code" => "water_lack", "active" => true},
            %{"v" => 2, "b" => "", "up" => 100, "code" => "water_lack", "active" => true},
            %{"v" => 2, "b" => "bad", "up" => 100, "code" => "water_lack", "active" => true},
            %{"v" => 3, "b" => @boot_id, "up" => 100, "active" => true}
          ] do
        assert {:error, :invalid_alarm} =
                 Storage.record_alarm(@device_id, "water_lack", bad_alarm, 1000)
      end

      assert {:ok, alarm} =
               Storage.record_alarm(
                 @device_id,
                 "water_lack",
                 %{
                   "v" => 2,
                   "b" => "7F3A91C4",
                   "up" => 100,
                   "code" => "water_lack",
                   "active" => true
                 },
                 1000
               )

      assert alarm.active == true
      assert alarm.v == 2
      assert alarm.b == "7f3a91c4"

      assert {:ok, _} =
               Storage.record_alarm(
                 @device_id,
                 "turntable_failed",
                 %{
                   "v" => 2,
                   "b" => @boot_id,
                   "up" => 105,
                   "code" => "turntable_failed",
                   "active" => true
                 },
                 1500
               )

      assert {:ok, active_alarms} = Storage.get_alarms(@device_id, active_only: true)
      assert length(active_alarms) == 2

      # water: 0 does not clear water_lack
      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"seq" => 1, "up" => 110, "water" => 0}),
                 2000
               )

      assert {:ok, active_after_dry} = Storage.get_alarms(@device_id, active_only: true)
      assert length(active_after_dry) == 2

      # water: 1 auto-clears water_lack only
      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"seq" => 2, "up" => 120, "water" => 1}),
                 3000
               )

      assert {:ok, active_after_wet} = Storage.get_alarms(@device_id, active_only: true)
      assert [%{code: "turntable_failed"}] = active_after_wet

      assert {:ok, all_alarms} = Storage.get_alarms(@device_id)
      water_alarm = Enum.find(all_alarms, &(&1.code == "water_lack"))
      assert water_alarm.active == false
      assert water_alarm.b == @boot_id
      assert water_alarm.clear_reason == "telemetry_water_normal"
      assert water_alarm.cleared_at == "1970-01-01T00:00:03.000Z"
    end

    test "keeps stale retained water_lack inactive in same session b while new boot session alarm stays active" do
      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => @boot_id, "seq" => 5, "up" => 200, "water" => 1}),
                 2000
               )

      # Stale retained alarm from same session b at up: 150
      assert {:ok, stale} =
               Storage.record_alarm(
                 @device_id,
                 "water_lack",
                 %{
                   "v" => 2,
                   "b" => @boot_id,
                   "up" => 150,
                   "code" => "water_lack",
                   "active" => true
                 },
                 3000
               )

      assert stale.active == false
      assert stale.clear_reason == "telemetry_water_normal"

      # Newer water_lack in same session at up: 250 IS active
      assert {:ok, fresh} =
               Storage.record_alarm(
                 @device_id,
                 "water_lack",
                 %{
                   "v" => 2,
                   "b" => @boot_id,
                   "up" => 250,
                   "code" => "water_lack",
                   "active" => true
                 },
                 4000
               )

      assert fresh.active == true
      assert fresh.clear_reason == nil

      # Fresh water_lack after reboot (new b, lower up: 5) must NOT be auto-cleared by old b's up: 200
      assert {:ok, reboot_alarm} =
               Storage.record_alarm(
                 @device_id,
                 "water_lack",
                 %{
                   "v" => 2,
                   "b" => @boot_id_2,
                   "up" => 5,
                   "code" => "water_lack",
                   "active" => true
                 },
                 5000
               )

      assert reboot_alarm.active == true
      assert reboot_alarm.b == @boot_id_2
      assert reboot_alarm.clear_reason == nil
    end

    test "manual clear_alarm clears alarm and returns not_found for missing alarm" do
      assert {:error, :not_found} = Storage.clear_alarm(@device_id, "water_lack")

      assert {:ok, _} =
               Storage.record_alarm(@device_id, "turntable_failed", %{"active" => true}, 1000)

      assert {:ok, cleared} = Storage.clear_alarm(@device_id, "turntable_failed", "manual_api")
      assert cleared.active == false
      assert cleared.b == nil
      assert cleared.clear_reason == "manual_api"
      assert is_binary(cleared.cleared_at)
    end
  end

  describe "config cache and device snapshots" do
    test "merges config cache and computes human-readable representation" do
      assert {:ok, empty_cfg} = Storage.get_config(@device_id)
      assert empty_cfg.raw == %{}
      assert empty_cfg.human == %{}
      assert empty_cfg.updated_at == nil

      assert {:ok, cfg1} =
               Storage.update_config_cache(@device_id, %{"tMin" => 1000, "luxMin" => 500}, 1000)

      assert cfg1.raw == %{"tMin" => 1000, "luxMin" => 500}
      assert cfg1.human == %{"tMin" => 10.0, "luxMin" => 500}

      assert {:ok, cfg2} = Storage.update_config_cache(@device_id, %{"tMax" => 3050}, 2000)
      assert cfg2.raw == %{"tMin" => 1000, "tMax" => 3050, "luxMin" => 500}
      assert cfg2.human == %{"tMin" => 10.0, "tMax" => 30.5, "luxMin" => 500}
    end

    test "list_devices/0 and get_device/1 return complete v2 snapshots" do
      assert Storage.list_devices() == []
      assert {:error, :not_found} = Storage.get_device(@device_id)

      {:ok, _} =
        Storage.record_status(
          @device_id,
          %{"v" => 2, "b" => @boot_id, "online" => true, "up" => 10},
          1000
        )

      {:ok, _} =
        Storage.record_telemetry(
          @device_id,
          v2_telemetry(%{"seq" => 1, "up" => 20}),
          2000
        )

      {:ok, _} =
        Storage.record_alarm(
          @device_id,
          "turntable_failed",
          %{"v" => 2, "b" => @boot_id, "up" => 25, "active" => true},
          2500
        )

      {:ok, _} = Storage.update_config_cache(@device_id, %{"tMin" => 1200}, 2600)

      assert [overview] = Storage.list_devices()
      assert overview.device_id == @device_id
      assert overview.online == true
      assert overview.status.b == @boot_id
      assert overview.latest_telemetry.b == @boot_id
      assert overview.active_alarm_count == 1
      assert hd(overview.active_alarms).b == @boot_id
      assert overview.last_seen_at_ms == 2000

      assert {:ok, snapshot} = Storage.get_device(@device_id)
      assert snapshot.device_id == @device_id
      assert snapshot.status.online == true
      assert snapshot.status.b == @boot_id
      assert snapshot.latest_telemetry.seq == 1
      assert snapshot.latest_telemetry.b == @boot_id
      assert length(snapshot.active_alarms) == 1
      assert hd(snapshot.active_alarms).b == @boot_id
      assert snapshot.config.raw == %{"tMin" => 1200}
      assert snapshot.last_seen_at_ms == 2000
    end
  end

  describe "record_telemetry_compact/3 and sub-binary detachment" do
    test "record_telemetry_compact/3 records v2 payloads, deduplicates, and detaches >64B extra sub-binaries" do
      large_json =
        JSON.encode!(%{
          "v" => 2,
          "b" => "7F3A91C4",
          "seq" => 10,
          "up" => 100,
          "t" => 2300,
          "ah" => 5500,
          "sh" => 4200,
          "lux" => 1500,
          "water" => 1,
          "fan" => 0,
          "light" => 1,
          "heat" => 0,
          "note" => String.duplicate("x", 120),
          "padding" => String.duplicate("p", 8192)
        })

      decoded = JSON.decode!(large_json)
      payload = Map.delete(decoded, "padding")

      assert {:ok, :recorded} = Storage.record_telemetry_compact("GH-SUB", payload, 50_000)

      assert {:duplicate, 10} =
               Storage.record_telemetry_compact("GH-SUB", payload, 50_100)

      assert {:ok, latest} = Storage.get_latest_telemetry("GH-SUB")
      assert latest.v == 2
      assert latest.b == "7f3a91c4"
      assert latest.raw["b"] == "7f3a91c4"
      assert latest.raw["note"] == String.duplicate("x", 120)

      [{_dev, _ms, _v, stored_b, _seq, _up, _t, _ah, _sh, _lux, _flags, extra}] =
        :ets.lookup(:gh_telemetry_latest, "GH-SUB")

      assert stored_b == "7f3a91c4"
      assert :binary.referenced_byte_size(stored_b) == byte_size(stored_b)
      assert :binary.referenced_byte_size(extra["note"]) == byte_size(extra["note"])
    end
  end
end
