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
end
