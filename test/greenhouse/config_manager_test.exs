defmodule Greenhouse.ConfigManagerTest do
  use ExUnit.Case, async: false

  alias Greenhouse.{ConfigManager, Storage}
  alias Greenhouse.TestSupport.Helpers

  setup do
    Storage.reset!()
    :ok
  end

  test "rejects empty device_id and non-map configuration patches before publishing" do
    test_pid = self()

    {:ok, cm} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn topic, payload, opts ->
          send(test_pid, {:published, topic, payload, opts})
          :ok
        end
      )

    on_exit(fn -> Helpers.stop_safely(cm) end)

    assert {:error, {:validation_failed, ["device_id must be a non-empty string"]}} =
             ConfigManager.apply_config(cm, "", %{"tMin" => 1500})

    assert {:error, {:validation_failed, ["configuration patch must be a map"]}} =
             ConfigManager.apply_config(cm, "GH-0001", "not_a_map")

    refute_received {:published, _, _, _}
  end

  test "returns :config_in_progress when a concurrent update is already pending for the same device" do
    test_pid = self()

    {:ok, cm} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn topic, payload, opts ->
          send(test_pid, {:published, topic, payload, opts})
          :ok
        end,
        config_ack_timeout_ms: 500
      )

    on_exit(fn -> Helpers.stop_safely(cm) end)

    task1 = Task.async(fn -> ConfigManager.apply_config(cm, "GH-CONC", %{"tMin" => 1800}) end)

    assert_receive {:published, "gh/GH-CONC/config", _, _}, 500

    assert {:error, :config_in_progress} =
             ConfigManager.apply_config(cm, "GH-CONC", %{"tMin" => 1900})

    :ok = ConfigManager.handle_ack(cm, "GH-CONC", %{"ok" => true})
    assert {:ok, %{raw: %{"tMin" => 1800}}} = Task.await(task1, 1_000)

    # Different device is not blocked by GH-CONC (and stale handle_ack is safely ignored)
    :ok = ConfigManager.handle_ack(cm, "GH-OTHER", %{"ok" => true})
    _ = :sys.get_state(cm)
    assert Process.alive?(cm)
  end

  test "ignores malformed config/ack payloads and falls back cleanly on unknown publish errors" do
    test_pid = self()

    {:ok, cm} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn _topic, _payload, _opts ->
          send(test_pid, :published)
          :ok
        end,
        config_ack_timeout_ms: 80
      )

    {:ok, cm_err} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn _topic, _payload, _opts -> {:error, :socket_closed} end
      )

    on_exit(fn ->
      Helpers.stop_safely(cm)
      Helpers.stop_safely(cm_err)
    end)

    task = Task.async(fn -> ConfigManager.apply_config(cm, "GH-MAL", %{"tMin" => 1500}) end)
    assert_receive :published, 500

    # Malformed ack should be ignored so timeout still fires cleanly
    :ok = ConfigManager.handle_ack(cm, "GH-MAL", %{"unexpected" => true})
    assert {:error, :ack_timeout} = Task.await(task, 500)

    assert {:error, :mqtt_disconnected} =
             ConfigManager.apply_config(cm_err, "GH-ERR", %{"tMin" => 1500})
  end

  test "records config/ack receipt timestamp without b and rejects syntax/rejected acks" do
    test_pid = self()

    {:ok, cm} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn topic, payload, opts ->
          send(test_pid, {:published, topic, payload, opts})
          :ok
        end,
        config_ack_timeout_ms: 500
      )

    on_exit(fn -> Helpers.stop_safely(cm) end)

    received_at_ms = 1_731_840_000_123

    task_ok = Task.async(fn -> ConfigManager.apply_config(cm, "GH-ACK", %{"tMin" => 1600}) end)
    assert_receive {:published, "gh/GH-ACK/config", _, [qos: 1, retain: false]}, 500

    :ok = ConfigManager.handle_ack(cm, "GH-ACK", %{"ok" => true}, received_at_ms)
    assert {:ok, updated} = Task.await(task_ok, 1_000)
    assert updated.raw == %{"tMin" => 1600}
    assert updated.updated_at_ms == received_at_ms

    assert updated.updated_at ==
             DateTime.to_iso8601(DateTime.from_unix!(received_at_ms, :millisecond))

    for reason <- ["syntax", "rejected"] do
      task_err = Task.async(fn -> ConfigManager.apply_config(cm, "GH-ACK", %{"tMax" => 3200}) end)
      assert_receive {:published, "gh/GH-ACK/config", _, [qos: 1, retain: false]}, 500
      :ok = ConfigManager.handle_ack(cm, "GH-ACK", %{"ok" => false, "reason" => reason})
      assert {:error, {:device_rejected, ^reason}} = Task.await(task_err, 1_000)
    end

    assert {:ok, %{raw: %{"tMin" => 1600}}} = Storage.get_config("GH-ACK")
  end

  test "splits oversized full-config patches into cross-field-coherent small chunks sequentially" do
    test_pid = self()

    {:ok, cm} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn topic, payload, opts ->
          send(test_pid, {:published, topic, payload, opts})
          :ok
        end,
        config_ack_timeout_ms: 500
      )

    on_exit(fn -> Helpers.stop_safely(cm) end)

    full_patch = %{
      "tMin" => 2000,
      "tMax" => 3200,
      "tHys" => 200,
      "ahMin" => 4500,
      "ahMax" => 7000,
      "ahHys" => 300,
      "shMin" => 3500,
      "shMax" => 6500,
      "luxMin" => 800,
      "luxMax" => 35_000,
      "luxOnMs" => 3_600_000,
      "dayStartMs" => 19_800_000,
      "dayLenMs" => 50_400_000,
      "pumpMs" => 8000,
      "pumpIntervalMs" => 240_000,
      "pumpMaxPerDay" => 6,
      "sampleMs" => 3000,
      "turnPerDay" => 45,
      "turnMax" => 180,
      "turnStep" => 15,
      "turnIntervalMs" => 20_000
    }

    task = Task.async(fn -> ConfigManager.apply_config(cm, "GH-FULL", full_patch) end)

    chunks =
      Enum.reduce_while(1..10, [], fn _i, acc ->
        receive do
          {:published, "gh/GH-FULL/config", payload, [qos: 1, retain: false]} ->
            assert byte_size(payload) <= 128
            decoded = JSON.decode!(payload)
            assert map_size(decoded) in 1..6
            :ok = ConfigManager.handle_ack(cm, "GH-FULL", %{"ok" => true})

            acc = [decoded | acc]
            merged_keys = acc |> Enum.reduce(%{}, &Map.merge(&2, &1)) |> map_size()

            if merged_keys == map_size(full_patch) do
              {:halt, Enum.reverse(acc)}
            else
              {:cont, acc}
            end
        after
          500 -> flunk("expected next config chunk publish, got #{length(acc)} chunks so far")
        end
      end)

    assert length(chunks) == 4
    assert {:ok, updated} = Task.await(task, 1_000)
    assert updated.raw == full_patch

    # Coupled temperature fields stay together in the first chunk
    first = Enum.at(chunks, 0)
    assert Map.has_key?(first, "tMin")
    assert Map.has_key?(first, "tMax")
    assert Map.has_key?(first, "tHys")
  end

  test "stops chunked config publish immediately when an intermediate chunk is rejected" do
    test_pid = self()

    {:ok, cm} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn topic, payload, _opts ->
          send(test_pid, {:published, topic, payload})
          :ok
        end,
        config_ack_timeout_ms: 500
      )

    on_exit(fn -> Helpers.stop_safely(cm) end)

    patch = %{
      "tMin" => 2000,
      "tMax" => 3200,
      "tHys" => 200,
      "ahMin" => 4500,
      "ahMax" => 7000,
      "ahHys" => 300,
      "luxMin" => 800,
      "luxMax" => 35_000,
      "dayStartMs" => 19_800_000,
      "dayLenMs" => 50_400_000
    }

    task = Task.async(fn -> ConfigManager.apply_config(cm, "GH-PARTIAL", patch) end)

    assert_receive {:published, "gh/GH-PARTIAL/config", payload1}, 500
    chunk1 = JSON.decode!(payload1)
    :ok = ConfigManager.handle_ack(cm, "GH-PARTIAL", %{"ok" => true})

    assert_receive {:published, "gh/GH-PARTIAL/config", _payload2}, 500
    :ok = ConfigManager.handle_ack(cm, "GH-PARTIAL", %{"ok" => false, "reason" => "rejected"})

    assert {:error, {:device_rejected, "rejected"}} = Task.await(task, 1_000)
    refute_received {:published, "gh/GH-PARTIAL/config", _}

    assert {:ok, %{raw: ^chunk1}} = Storage.get_config("GH-PARTIAL")
  end
end
