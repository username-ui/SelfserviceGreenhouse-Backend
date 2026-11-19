defmodule Greenhouse.MQTT.HandlerTest do
  use ExUnit.Case, async: false

  alias Greenhouse.MQTT.Handler
  alias Greenhouse.{ConfigManager, Storage}
  alias Greenhouse.TestSupport.Helpers

  setup do
    Storage.reset!()
    :ok
  end

  describe "Handler topic dispatch and edge cases" do
    test "drops unsupported version (v > 2), invalid versions, non-map JSON, and unexpected topics gracefully" do
      assert {:error, :unsupported_version} =
               Handler.handle_message("gh/GH-0005/telemetry", JSON.encode!(%{"v" => 3}))

      assert {:error, :unsupported_version} =
               Handler.handle_message("gh/GH-0005/telemetry", JSON.encode!(%{"v" => 99}))

      assert {:error, :unsupported_version} =
               Handler.handle_message("gh/GH-0005/alarm/water_lack", JSON.encode!(%{"v" => 3}))

      assert {:error, :unsupported_version} =
               Handler.handle_message("gh/GH-0005/status", JSON.encode!(%{"v" => 3}))

      assert {:error, :unsupported_version} =
               Handler.handle_message("gh/GH-0005/config/ack", JSON.encode!(%{"v" => 3}))

      assert {:error, :invalid_payload} =
               Handler.handle_message("gh/GH-0005/status", JSON.encode!(%{"v" => "2"}))

      assert {:error, :invalid_payload} =
               Handler.handle_message("gh/GH-0005/telemetry", JSON.encode!(%{"v" => 0}))

      assert {:error, :invalid_payload} = Handler.handle_message("gh/GH-0005/telemetry", "[1,2]")

      assert {:error, :invalid_payload} =
               Handler.handle_message("gh/GH-0005/telemetry", "{not-json")

      assert {:error, :invalid_payload} =
               Handler.handle_message("other/topic", JSON.encode!(%{"v" => 2}))

      assert {:error, :not_found} = Storage.get_device("GH-0005")
    end

    test "rejects v2 telemetry and alarms with missing, empty, or malformed b" do
      base_tel =
        Helpers.sample_telemetry_payload(%{
          "v" => 2,
          "seq" => 0,
          "up" => 10
        })
        |> Map.delete("b")

      for bad_b <- [:missing, nil, "", "7f3a91c", "7f3a91c40", "zzzzzzzz"] do
        payload =
          case bad_b do
            :missing -> base_tel
            val -> Map.put(base_tel, "b", val)
          end

        assert {:error, :invalid_telemetry} =
                 Handler.handle_message("gh/GH-BADB/telemetry", JSON.encode!(payload))

        alarm_payload =
          case bad_b do
            :missing -> %{"v" => 2, "up" => 10, "code" => "water_lack", "active" => true}
            val -> %{"v" => 2, "b" => val, "up" => 10, "code" => "water_lack", "active" => true}
          end

        assert {:error, :invalid_alarm} =
                 Handler.handle_message(
                   "gh/GH-BADB/alarm/water_lack",
                   JSON.encode!(alarm_payload)
                 )
      end

      assert {:error, :not_found} = Storage.get_device("GH-BADB")
    end

    test "routes v2 telemetry, status (with/without b for LWT), alarm, and config/ack cleanly" do
      test_pid = self()

      {:ok, cm} =
        ConfigManager.start_link(
          name: nil,
          publish_fn: fn _topic, _payload, _opts ->
            send(test_pid, :published)
            :ok
          end,
          config_ack_timeout_ms: 500
        )

      on_exit(fn -> Helpers.stop_safely(cm) end)

      # Status with uppercase b is normalized to lowercase
      assert {:ok, status_on} =
               Handler.handle_message(
                 "gh/GH-H1/status",
                 JSON.encode!(%{"v" => 2, "b" => "7F3A91C4", "online" => true, "up" => 42})
               )

      assert status_on.online == true
      assert status_on.b == "7f3a91c4"

      # Telemetry v2 with b
      tel_payload =
        Helpers.sample_telemetry_payload(%{
          "v" => 2,
          "b" => "7F3A91C4",
          "seq" => 1,
          "up" => 45
        })

      assert {:ok, :recorded} =
               Handler.handle_message("gh/GH-H1/telemetry", JSON.encode!(tel_payload))

      # Duplicate (device_id, b, seq) within same session is deduplicated
      assert {:duplicate, 1} =
               Handler.handle_message(
                 "gh/GH-H1/telemetry",
                 JSON.encode!(Map.put(tel_payload, "b", "7f3a91c4"))
               )

      # Reboot into new boot session b allows seq to reset to 0
      assert {:ok, :recorded} =
               Handler.handle_message(
                 "gh/GH-H1/telemetry",
                 JSON.encode!(Map.merge(tel_payload, %{"b" => "1c04be77", "seq" => 0, "up" => 2}))
               )

      assert {:ok, latest} = Storage.get_latest_telemetry("GH-H1")
      assert latest.v == 2
      assert latest.b == "1c04be77"
      assert latest.seq == 0

      # Alarm v2 with b
      assert {:ok, alarm} =
               Handler.handle_message(
                 "gh/GH-H1/alarm/turntable_failed",
                 JSON.encode!(%{
                   "v" => 2,
                   "b" => "1C04BE77",
                   "code" => "turntable_failed",
                   "active" => true,
                   "up" => 50
                 })
               )

      assert alarm.b == "1c04be77"
      assert alarm.v == 2

      # LWT status without b
      assert {:ok, lwt_status} =
               Handler.handle_message(
                 "gh/GH-H1/status",
                 JSON.encode!(%{"v" => 2, "online" => false})
               )

      assert lwt_status.online == false
      assert lwt_status.b == nil
      assert lwt_status.up == nil

      # config/ack omits b and records received_at_ms
      ack_ms = 1_731_840_123_456
      task = Task.async(fn -> ConfigManager.apply_config(cm, "GH-H1", %{"tMin" => 1700}) end)
      assert_receive :published, 500

      assert :ok =
               Handler.handle_message(
                 "gh/GH-H1/config/ack",
                 JSON.encode!(%{"ok" => true}),
                 %{config_manager: cm, received_at_ms: ack_ms}
               )

      assert {:ok, %{raw: %{"tMin" => 1700}, updated_at_ms: ^ack_ms}} = Task.await(task, 1_000)
    end

    test "retains v1 compatibility for telemetry, status, and alarm without b" do
      assert {:ok, _} =
               Handler.handle_message(
                 "gh/GH-V1/status",
                 JSON.encode!(%{"v" => 1, "online" => true, "up" => 10})
               )

      v1_tel =
        Helpers.sample_telemetry_payload(%{"v" => 1, "seq" => 1, "up" => 15})
        |> Map.delete("b")

      assert {:ok, :recorded} =
               Handler.handle_message("gh/GH-V1/telemetry", JSON.encode!(v1_tel))

      assert {:ok, _} =
               Handler.handle_message(
                 "gh/GH-V1/alarm/water_lack",
                 JSON.encode!(%{"v" => 1, "active" => true, "up" => 16})
               )

      assert {:ok, latest} = Storage.get_latest_telemetry("GH-V1")
      assert latest.v == 1
      assert latest.b == nil
    end
  end
end
