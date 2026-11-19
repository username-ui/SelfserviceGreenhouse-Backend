defmodule Greenhouse.Storage.QueryAndRetentionTest do
  use ExUnit.Case, async: false

  alias Greenhouse.{Storage, Support}
  alias Greenhouse.Storage.{Codec, Query}
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

  defp v2_telemetry(overrides) do
    Helpers.sample_telemetry_payload(Map.merge(%{"v" => 2, "b" => @boot_id}, overrides))
  end

  describe "telemetry history and stats" do
    test "filters by time bounds and boot session b, orders, paginates, and computes stats" do
      assert {:ok, empty_stats} = Storage.get_telemetry_stats(@device_id)
      assert empty_stats.count == 0
      assert empty_stats.temperature == %{min: nil, max: nil, avg: nil}

      {:ok, _} =
        Storage.record_telemetry(
          @device_id,
          v2_telemetry(%{
            "b" => @boot_id,
            "seq" => 1,
            "up" => 10,
            "t" => 2000,
            "ah" => 5000,
            "sh" => 3000,
            "lux" => 100
          }),
          1_700_000_001_000
        )

      {:ok, _} =
        Storage.record_telemetry(
          @device_id,
          v2_telemetry(%{
            "b" => @boot_id,
            "seq" => 2,
            "up" => 20,
            "t" => 2200,
            "ah" => 6000,
            "sh" => 4000,
            "lux" => 200
          }),
          1_700_000_002_000
        )

      {:ok, _} =
        Storage.record_telemetry(
          @device_id,
          v2_telemetry(%{
            "b" => @boot_id_2,
            "seq" => 0,
            "up" => 5,
            "t" => 2400,
            "ah" => 7000,
            "sh" => 5000,
            "lux" => 300
          }),
          1_700_000_003_000
        )

      {:ok, _} =
        Storage.record_telemetry(
          @device_id,
          v2_telemetry(%{
            "b" => @boot_id_2,
            "seq" => 1,
            "up" => 15,
            "t" => 2600,
            "ah" => 8000,
            "sh" => 6000,
            "lux" => 400
          }),
          1_700_000_004_000
        )

      # Default desc order + pagination
      assert {:ok, page} = Storage.get_telemetry_history(@device_id, limit: 2, offset: 1)
      assert page.total == 4
      assert page.order == :desc
      assert Enum.map(page.items, & &1.seq) == [0, 2]
      assert Enum.map(page.items, & &1.b) == [@boot_id_2, @boot_id]
      assert page.stats.count == 4
      assert page.stats.temperature == %{min: 20.0, max: 26.0, avg: 23.0}
      assert page.stats.lux == %{min: 100, max: 400, avg: 250.0}

      # Filter with ISO8601 and ms bounds + asc order
      assert {:ok, filtered} =
               Storage.get_telemetry_history(@device_id,
                 from: "2023-11-14T22:13:22.000Z",
                 to: 1_700_000_003_000,
                 order: :asc
               )

      assert filtered.total == 2
      assert Enum.map(filtered.items, & &1.seq) == [2, 0]
      assert filtered.stats.temperature == %{min: 22.0, max: 24.0, avg: 23.0}

      # Filter by boot session b (case-insensitive normalization)
      assert {:ok, session1} =
               Storage.get_telemetry_history(@device_id, b: "7F3A91C4", order: :asc)

      assert session1.total == 2
      assert Enum.map(session1.items, & &1.seq) == [1, 2]
      assert session1.stats.temperature == %{min: 20.0, max: 22.0, avg: 21.0}

      assert {:ok, session2_stats} = Storage.get_telemetry_stats(@device_id, b: @boot_id_2)
      assert session2_stats.count == 2
      assert session2_stats.temperature == %{min: 24.0, max: 26.0, avg: 25.0}

      assert {:ok, invalid_b_hist} = Storage.get_telemetry_history(@device_id, b: "not-hex")
      assert invalid_b_hist.total == 0
      assert invalid_b_hist.items == []

      # Limit clamped at 5000
      assert {:ok, clamped} = Storage.get_telemetry_history(@device_id, limit: 99_999)
      assert clamped.limit == 5_000
    end

    test "device_count/0, get_raw_config/1, limit: 0, extra fields, and non-0/1 flags work accurately" do
      assert Storage.device_count() == 0
      assert Storage.get_raw_config("GH-EMPTY") == %{}

      payload =
        v2_telemetry(%{
          "seq" => 10,
          "water" => 2,
          "fan" => 3,
          "light" => 0,
          "heat" => 1,
          "rssi" => -62,
          "note" => "extra-field"
        })

      assert {:ok, entry} = Storage.record_telemetry("GH-EXTRA", payload, 1_700_000_001_000)
      assert entry.b == @boot_id
      assert entry.water == 2
      assert entry.water_sufficient == false
      assert entry.fan == 3
      assert entry.fan_on == false
      assert entry.heat == 1
      assert entry.heat_on == true
      assert entry.raw["b"] == @boot_id
      assert entry.raw["rssi"] == -62
      assert entry.raw["note"] == "extra-field"
      assert entry.raw["water"] == 2

      assert {:ok, ^entry} = Storage.get_latest_telemetry("GH-EXTRA")
      assert Storage.device_count() == 1

      assert {:ok, %{total: 1, items: [], stats: stats}} =
               Storage.get_telemetry_history("GH-EXTRA", limit: 0)

      assert stats.count == 1
      assert stats.temperature.min == 23.5

      {:ok, _} = Storage.update_config_cache("GH-EXTRA", %{"tMin" => 1500, "tMax" => 2600}, 5000)
      assert %{"tMin" => 1500, "tMax" => 2600} = Storage.get_raw_config("GH-EXTRA")
    end

    test "chunked history pagination and stats across >500 entries preserve order and precision" do
      base_ms = 1_700_000_000_000

      for i <- 1..1_100 do
        {:ok, _} =
          Storage.record_telemetry(
            "GH-CHUNK",
            v2_telemetry(%{"seq" => i, "up" => i * 10, "t" => 2000 + i}),
            base_ms + i * 1_000
          )
      end

      assert {:ok, page_desc} =
               Storage.get_telemetry_history("GH-CHUNK", order: :desc, offset: 520, limit: 10)

      assert page_desc.total == 1_100
      assert Enum.map(page_desc.items, & &1.seq) == Enum.to_list(580..571//-1)
      assert page_desc.stats.count == 1_100
      assert page_desc.stats.temperature.min == 20.01
      assert page_desc.stats.temperature.max == 31.0

      assert {:ok, page_asc} =
               Storage.get_telemetry_history("GH-CHUNK", order: :asc, offset: 1_095, limit: 10)

      assert page_asc.total == 1_100
      assert Enum.map(page_asc.items, & &1.seq) == [1096, 1097, 1098, 1099, 1100]
      assert page_asc.stats.count == 1_100
    end

    test "offset > 0, offset >= total, and filtered time bounds match exact stats" do
      for i <- 1..600 do
        assert {:ok, :recorded} =
                 Storage.record_telemetry_compact(
                   "GH-PAGE",
                   v2_telemetry(%{
                     "seq" => i,
                     "up" => i * 2,
                     "t" => 2000 + i
                   }),
                   100_000 + i
                 )
      end

      assert {:ok, page} =
               Storage.get_telemetry_history("GH-PAGE",
                 order: :desc,
                 limit: 5,
                 offset: 520,
                 from: 100_001,
                 to: 100_600
               )

      assert page.total == 600
      assert Enum.map(page.items, & &1.seq) == [80, 79, 78, 77, 76]
      assert page.stats.count == 600

      assert {:ok, empty_page} =
               Storage.get_telemetry_history("GH-PAGE", limit: 10, offset: 600)

      assert empty_page.total == 600
      assert empty_page.items == []
      assert empty_page.stats.count == 600
    end
  end

  describe "DETS persistence, retention, and legacy migration" do
    test "reloads devices, telemetry, alarms, configs, boot session state, and history counter from disk" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "gh_storage_dets_test_#{System.unique_integer([:positive])}"
        )

      Helpers.detach_supervised_child(Storage, tmp_dir: tmp_dir)

      {:ok, pid1} = Storage.start_link(persist: true, data_dir: tmp_dir)

      {:ok, _} =
        Storage.record_status(
          @device_id,
          %{"v" => 2, "b" => @boot_id, "online" => true, "up" => 50},
          1000
        )

      {:ok, _} =
        Storage.record_telemetry(
          @device_id,
          v2_telemetry(%{"seq" => 1, "up" => 50}),
          2000
        )

      {:ok, _} =
        Storage.record_alarm(
          @device_id,
          "turntable_failed",
          %{"v" => 2, "b" => @boot_id, "up" => 55, "active" => true},
          2500
        )

      {:ok, _} = Storage.update_config_cache(@device_id, %{"tMin" => 1100, "tMax" => 2900}, 3000)

      GenServer.stop(pid1)

      {:ok, pid2} = Storage.start_link(persist: true, data_dir: tmp_dir)

      # Same-millisecond append after reload should not overwrite previous entry
      {:ok, _} =
        Storage.record_telemetry(
          @device_id,
          v2_telemetry(%{"seq" => 2, "up" => 60, "t" => 2400}),
          2000
        )

      # Duplicate (device_id, b, seq) from before/after restart is still caught
      assert {:duplicate, 2} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"seq" => 2, "up" => 60}),
                 2500
               )

      # Reboot with new b after restart resets seq and is accepted
      assert {:ok, _} =
               Storage.record_telemetry(
                 @device_id,
                 v2_telemetry(%{"b" => @boot_id_2, "seq" => 0, "up" => 3}),
                 2600
               )

      assert {:ok, snapshot} = Storage.get_device(@device_id)
      assert snapshot.status.online == true
      assert snapshot.status.b == @boot_id
      assert snapshot.latest_telemetry.seq == 0
      assert snapshot.latest_telemetry.b == @boot_id_2
      assert length(snapshot.active_alarms) == 1
      assert hd(snapshot.active_alarms).b == @boot_id
      assert snapshot.config.raw == %{"tMin" => 1100, "tMax" => 2900}

      assert {:ok, history} = Storage.get_telemetry_history(@device_id, order: :asc)
      assert history.total == 3
      assert Enum.map(history.items, & &1.seq) == [1, 2, 0]

      GenServer.stop(pid2)
    end

    test "evicts oldest per-device history beyond max_history_per_device across ETS and DETS" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "gh_storage_retention_#{System.unique_integer([:positive])}"
        )

      Helpers.detach_supervised_child(Storage, tmp_dir: tmp_dir)

      {:ok, pid1} =
        Storage.start_link(persist: true, data_dir: tmp_dir, max_history_per_device: 5)

      for i <- 1..12 do
        {:ok, _} =
          Storage.record_telemetry(
            "GH-0001",
            v2_telemetry(%{"seq" => i, "up" => i * 5, "extra" => i}),
            10_000 + i
          )
      end

      for i <- 1..3 do
        {:ok, _} =
          Storage.record_telemetry(
            "GH-0002",
            v2_telemetry(%{"seq" => i, "up" => i * 5}),
            10_000 + i
          )
      end

      assert {:ok, hist1} = Storage.get_telemetry_history("GH-0001", order: :asc, limit: 20)
      assert hist1.total == 5
      assert Enum.map(hist1.items, & &1.seq) == [8, 9, 10, 11, 12]

      assert {:ok, hist2} = Storage.get_telemetry_history("GH-0002", order: :asc, limit: 20)
      assert hist2.total == 3
      assert Enum.map(hist2.items, & &1.seq) == [1, 2, 3]

      GenServer.stop(pid1)

      {:ok, pid2} =
        Storage.start_link(persist: true, data_dir: tmp_dir, max_history_per_device: 5)

      assert {:ok, hist1_after} = Storage.get_telemetry_history("GH-0001", order: :asc, limit: 20)
      assert hist1_after.total == 5
      assert Enum.map(hist1_after.items, & &1.seq) == [8, 9, 10, 11, 12]

      assert {:ok, hist2_after} = Storage.get_telemetry_history("GH-0002", order: :asc, limit: 20)
      assert hist2_after.total == 3
      assert Enum.map(hist2_after.items, & &1.seq) == [1, 2, 3]

      GenServer.stop(pid2)
    end

    test "migrates legacy map-format DETS records into v2 compact tuples on startup" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "gh_storage_legacy_#{System.unique_integer([:positive])}"
        )

      Helpers.detach_supervised_child(Storage, tmp_dir: tmp_dir)

      legacy_entry = %{
        device_id: "GH-LEGACY",
        v: 1,
        seq: 42,
        up: 900,
        temperature: 24.5,
        air_humidity: 60.0,
        soil_humidity: 45.0,
        lux: 5_000,
        water: 1,
        water_sufficient: true,
        fan: 0,
        fan_on: false,
        light: 1,
        light_on: true,
        heat: 0,
        heat_on: false,
        received_at: "2026-01-01T00:00:01.000Z",
        received_at_ms: 1_767_225_601_000,
        raw: %{
          "v" => 1,
          "seq" => 42,
          "up" => 900,
          "t" => 2450,
          "ah" => 6000,
          "sh" => 4500,
          "lux" => 5000,
          "water" => 1,
          "fan" => 0,
          "light" => 1,
          "heat" => 0,
          "legacyExtra" => "kept"
        }
      }

      hist_file = tmp_dir |> Path.join("telemetry_history.dets") |> String.to_charlist()
      {:ok, :legacy_hist} = :dets.open_file(:legacy_hist, file: hist_file, type: :set)
      :ok = :dets.insert(:legacy_hist, {{"GH-LEGACY", 1_767_225_601_000, 1}, legacy_entry})
      :ok = :dets.close(:legacy_hist)

      latest_file = tmp_dir |> Path.join("telemetry_latest.dets") |> String.to_charlist()
      {:ok, :legacy_latest} = :dets.open_file(:legacy_latest, file: latest_file, type: :set)
      :ok = :dets.insert(:legacy_latest, {"GH-LEGACY", legacy_entry})
      :ok = :dets.close(:legacy_latest)

      cfg_file = tmp_dir |> Path.join("configs.dets") |> String.to_charlist()
      {:ok, :legacy_cfg} = :dets.open_file(:legacy_cfg, file: cfg_file, type: :set)

      :ok =
        :dets.insert(
          :legacy_cfg,
          {"GH-LEGACY",
           %{
             device_id: "GH-LEGACY",
             raw: %{"tMin" => 1800, "tMax" => 2800},
             human: %{"tMin" => 18.0, "tMax" => 28.0},
             updated_at: "2026-01-01T00:00:01.000Z",
             updated_at_ms: 1_767_225_601_000
           }}
        )

      :ok = :dets.close(:legacy_cfg)

      dev_file = tmp_dir |> Path.join("devices.dets") |> String.to_charlist()
      {:ok, :legacy_dev} = :dets.open_file(:legacy_dev, file: dev_file, type: :set)

      :ok =
        :dets.insert(
          :legacy_dev,
          {"GH-LEGACY", %{device_id: "GH-LEGACY", online: true, last_seen_ms: 1_767_225_601_000}}
        )

      :ok = :dets.close(:legacy_dev)

      {:ok, pid} = Storage.start_link(persist: true, data_dir: tmp_dir)

      assert {:ok, latest} = Storage.get_latest_telemetry("GH-LEGACY")
      assert latest.seq == 42
      assert latest.b == nil
      assert latest.temperature == 24.5
      assert latest.raw["legacyExtra"] == "kept"

      assert {:ok, hist} = Storage.get_telemetry_history("GH-LEGACY", limit: 10)
      assert hist.total == 1
      assert hd(hist.items).seq == 42
      assert hd(hist.items).b == nil
      assert hist.stats.temperature.avg == 24.5

      assert {:ok, cfg} = Storage.get_config("GH-LEGACY")
      assert cfg.raw == %{"tMin" => 1800, "tMax" => 2800}
      assert cfg.human["tMin"] == 18.0
      assert %{"tMin" => 1800, "tMax" => 2800} = Storage.get_raw_config("GH-LEGACY")

      assert {:ok, snap} = Storage.get_device("GH-LEGACY")
      assert snap.last_seen_at_ms == 1_767_225_601_000

      [{_k, _v, nil, _seq, _up, _t, _ah, _sh, _lux, _flags, extra}] =
        :ets.lookup(:gh_telemetry_history, {"GH-LEGACY", 1_767_225_601_000, 1})

      assert extra == %{"legacyExtra" => "kept"}

      GenServer.stop(pid)
    end

    test "migrates v1 compact DETS tuples, devices, and alarms cleanly to v2 on startup" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "gh_storage_v1_tuples_#{System.unique_integer([:positive])}"
        )

      Helpers.detach_supervised_child(Storage, tmp_dir: tmp_dir)

      flags = Codec.pack_flags(1, 0, 1, 0)

      # v1 9-tuple (no extra) and v1 10-tuple (with extra) in telemetry_history.dets
      hist_file = tmp_dir |> Path.join("telemetry_history.dets") |> String.to_charlist()
      {:ok, :v1_hist} = :dets.open_file(:v1_hist, file: hist_file, type: :set)

      :ok =
        :dets.insert(
          :v1_hist,
          {{"GH-V1-TUP", 1_700_000_001_000, 1}, 1, 10, 100, 2350, 5680, 3120, 812, flags}
        )

      :ok =
        :dets.insert(
          :v1_hist,
          {{"GH-V1-TUP", 1_700_000_002_000, 2}, 1, 11, 160, 2450, 5780, 3220, 900, flags,
           %{"rssi" => -65}}
        )

      :ok = :dets.close(:v1_hist)

      # v1 11-tuple (with extra) in telemetry_latest.dets
      latest_file = tmp_dir |> Path.join("telemetry_latest.dets") |> String.to_charlist()
      {:ok, :v1_latest} = :dets.open_file(:v1_latest, file: latest_file, type: :set)

      :ok =
        :dets.insert(
          :v1_latest,
          {"GH-V1-TUP", 1_700_000_002_000, 1, 11, 160, 2450, 5780, 3220, 900, flags,
           %{"rssi" => -65}}
        )

      :ok = :dets.close(:v1_latest)

      # v1 device_record without :last_b and status without :b
      dev_file = tmp_dir |> Path.join("devices.dets") |> String.to_charlist()
      {:ok, :v1_dev} = :dets.open_file(:v1_dev, file: dev_file, type: :set)

      :ok =
        :dets.insert(
          :v1_dev,
          {"GH-V1-TUP",
           %{
             device_id: "GH-V1-TUP",
             status: %{
               device_id: "GH-V1-TUP",
               online: true,
               up: 160,
               offline_reason: nil,
               updated_at: "2023-11-14T22:13:22.000Z",
               updated_at_ms: 1_700_000_002_000
             },
             last_seq: 11,
             last_up: 160,
             last_seen_at_ms: 1_700_000_002_000
           }}
        )

      :ok = :dets.close(:v1_dev)

      # v1 alarm_entry without :b
      alarms_file = tmp_dir |> Path.join("alarms.dets") |> String.to_charlist()
      {:ok, :v1_alarms} = :dets.open_file(:v1_alarms, file: alarms_file, type: :set)

      :ok =
        :dets.insert(
          :v1_alarms,
          {{"GH-V1-TUP", "turntable_failed"},
           %{
             device_id: "GH-V1-TUP",
             code: "turntable_failed",
             active: true,
             v: 1,
             up: 150,
             clear_reason: nil,
             cleared_at: nil,
             cleared_at_ms: nil,
             received_at: "2023-11-14T22:13:21.000Z",
             received_at_ms: 1_700_000_001_500,
             updated_at: "2023-11-14T22:13:21.000Z",
             updated_at_ms: 1_700_000_001_500
           }}
        )

      :ok = :dets.close(:v1_alarms)

      {:ok, pid} = Storage.start_link(persist: true, data_dir: tmp_dir)

      assert {:ok, latest} = Storage.get_latest_telemetry("GH-V1-TUP")
      assert latest.v == 1
      assert latest.b == nil
      assert latest.seq == 11
      assert latest.raw["rssi"] == -65

      assert {:ok, hist} = Storage.get_telemetry_history("GH-V1-TUP", order: :asc)
      assert hist.total == 2
      assert Enum.map(hist.items, & &1.seq) == [10, 11]
      assert Enum.map(hist.items, & &1.b) == [nil, nil]
      assert hist.stats.temperature == %{min: 23.5, max: 24.5, avg: 24.0}

      assert {:ok, snap} = Storage.get_device("GH-V1-TUP")
      assert snap.status.b == nil
      assert [%{code: "turntable_failed", b: nil}] = snap.active_alarms

      # Upgraded device transitioning from v1 (last_b: nil) to v2 (b: @boot_id) accepts seq 0
      assert {:ok, v2_after} =
               Storage.record_telemetry(
                 "GH-V1-TUP",
                 v2_telemetry(%{"b" => @boot_id, "seq" => 0, "up" => 200}),
                 1_700_000_003_000
               )

      assert v2_after.v == 2
      assert v2_after.b == @boot_id

      GenServer.stop(pid)
    end

    test "restart with lowered max_history_per_device trims pre-existing DETS and ETS history" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "gh_storage_trim_#{System.unique_integer([:positive])}"
        )

      Helpers.detach_supervised_child(Storage, tmp_dir: tmp_dir)

      {:ok, pid1} =
        Storage.start_link(persist: true, data_dir: tmp_dir, max_history_per_device: 20)

      for i <- 1..15 do
        {:ok, _} =
          Storage.record_telemetry(
            "GH-TRIM",
            v2_telemetry(%{"seq" => i, "up" => i * 5}),
            20_000 + i
          )
      end

      GenServer.stop(pid1)

      {:ok, pid2} =
        Storage.start_link(persist: true, data_dir: tmp_dir, max_history_per_device: 4)

      assert {:ok, trimmed} = Storage.get_telemetry_history("GH-TRIM", order: :asc, limit: 20)
      assert trimmed.total == 4
      assert Enum.map(trimmed.items, & &1.seq) == [12, 13, 14, 15]
      assert :ets.info(:gh_telemetry_history, :size) == 4
      GenServer.stop(pid2)

      {:ok, pid3} =
        Storage.start_link(
          persist: true,
          data_dir: tmp_dir,
          max_history_per_device: 50,
          hibernate_after_ms: 25
        )

      assert {:ok, persisted} = Storage.get_telemetry_history("GH-TRIM", order: :asc, limit: 20)
      assert persisted.total == 4
      assert Enum.map(persisted.items, & &1.seq) == [12, 13, 14, 15]

      assert Helpers.eventually(fn ->
               Process.info(pid3, :current_function) ==
                 {:current_function, {:gen_server, :loop_hibernate, 4}}
             end)

      GenServer.stop(pid3)
    end

    test "max_history_per_device: 0 skips history storage while keeping latest telemetry" do
      Helpers.detach_supervised_child(Storage)

      {:ok, pid} = Storage.start_link(persist: false, max_history_per_device: 0)

      assert {:ok, :recorded} =
               Storage.record_telemetry_compact(
                 "GH-ZERO",
                 v2_telemetry(%{"seq" => 1, "up" => 10}),
                 30_000
               )

      assert :ets.info(:gh_telemetry_history, :size) == 0
      assert {:ok, latest} = Storage.get_latest_telemetry("GH-ZERO")
      assert latest.seq == 1
      assert latest.b == @boot_id

      assert {:ok, hist} = Storage.get_telemetry_history("GH-ZERO", limit: 10)
      assert hist.total == 0
      assert hist.items == []

      GenServer.stop(pid)
    end

    test "legacy DETS migration handles nil raw and metric fields safely" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "gh_storage_nil_legacy_#{System.unique_integer([:positive])}"
        )

      Helpers.detach_supervised_child(Storage, tmp_dir: tmp_dir)

      nil_legacy = %{
        device_id: "GH-NIL",
        v: nil,
        seq: nil,
        up: nil,
        temperature: nil,
        air_humidity: nil,
        soil_humidity: nil,
        lux: nil,
        water: nil,
        fan: nil,
        light: nil,
        heat: nil,
        received_at_ms: nil,
        raw: nil
      }

      hist_file = tmp_dir |> Path.join("telemetry_history.dets") |> String.to_charlist()
      {:ok, :legacy_nil_hist} = :dets.open_file(:legacy_nil_hist, file: hist_file, type: :set)
      :ok = :dets.insert(:legacy_nil_hist, {{"GH-NIL", 0, 1}, nil_legacy})
      :ok = :dets.close(:legacy_nil_hist)

      {:ok, pid} = Storage.start_link(persist: true, data_dir: tmp_dir)
      assert {:ok, hist} = Storage.get_telemetry_history("GH-NIL", limit: 5)
      assert hist.total == 1
      item = hd(hist.items)
      assert item.v == 1
      assert item.b == nil
      assert item.temperature == 0.0
      assert item.air_humidity == 0.0
      assert item.soil_humidity == 0.0
      GenServer.stop(pid)
    end
  end

  describe "Storage.Codec, Storage.Query, and Support direct helpers" do
    test "pack_flags/4 and unpack_flags/1 roundtrip binary and non-0/1 values accurately" do
      packed = Codec.pack_flags(1, 0, 1, 0)
      assert {1, 0, 1, 0} == Codec.unpack_flags(packed)

      packed_fallback = Codec.pack_flags(2, 3, 1, 0)
      assert {2, 3, 1, 0} == Codec.unpack_flags(packed_fallback)
    end

    test "normalize_boot_id/1, parse_time_bound/1, and detach_term/1 handle valid/invalid inputs cleanly" do
      assert {:ok, "7f3a91c4"} == Support.normalize_boot_id("7F3A91C4")
      assert {:ok, "00000000"} == Support.normalize_boot_id("00000000")
      assert :error == Support.normalize_boot_id(nil)
      assert :error == Support.normalize_boot_id("")
      assert :error == Support.normalize_boot_id("7f3a91c")
      assert :error == Support.normalize_boot_id("7f3a91c40")
      assert :error == Support.normalize_boot_id("7f3a91zz")
      assert :error == Support.normalize_boot_id(12_345_678)

      assert Query.parse_time_bound(nil) == nil
      assert Query.parse_time_bound(123_456) == 123_456
      assert {:ok, dt, _} = DateTime.from_iso8601("2026-01-01T00:00:00Z")

      assert Query.parse_time_bound("2026-01-01T00:00:00Z") ==
               DateTime.to_unix(dt, :millisecond)

      assert Query.parse_time_bound("not-a-timestamp") == nil

      big_bin = :binary.part(String.duplicate("a", 8_192), 10, 100)
      detached = Support.detach_term(%{nested: [big_bin, {big_bin}]})
      %{nested: [b1, {b2}]} = detached
      assert :binary.referenced_byte_size(b1) == 100
      assert :binary.referenced_byte_size(b2) == 100
    end
  end
end
