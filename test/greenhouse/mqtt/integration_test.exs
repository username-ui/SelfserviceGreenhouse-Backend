defmodule Greenhouse.MQTT.IntegrationTest do
  use ExUnit.Case, async: false

  alias Greenhouse.{ConfigManager, Storage}
  alias Greenhouse.MQTT.Client
  alias Greenhouse.TestSupport.{Helpers, MockBroker}

  defmodule CrashingHandler do
    @moduledoc false
    def handle_message(_topic, _payload, _meta) do
      raise "boom inside handler"
    end
  end

  setup do
    Storage.reset!()
    :ok
  end

  test "disabled client stays disconnected and rejects publish" do
    {:ok, client} =
      Client.start_link(
        name: nil,
        enabled: false,
        host: "127.0.0.1",
        port: 1883,
        client_id: "disabled-client"
      )

    on_exit(fn -> Helpers.stop_safely(client) end)

    status = Client.status(client)
    assert status.connected == false
    assert status.host == "127.0.0.1"
    assert status.port == 1883
    assert status.client_id == "disabled-client"
    assert status.reconnect_attempts == 0

    assert {:error, :not_connected} = Client.publish(client, "gh/GH-0001/config", "{}")
  end

  test "end-to-end CONNECT auth, 4 QoS-1 subscriptions, retained v2 status & alarms, telemetry + PUBACK, session reboot, LWT, and dropping v > 2" do
    {:ok, broker} = MockBroker.start_link(test_pid: self(), connack_codes: [0])
    port = MockBroker.port(broker)

    {:ok, client} =
      Client.start_link(
        name: nil,
        enabled: true,
        host: "127.0.0.1",
        port: port,
        username: "customer-01",
        password: "secret-password",
        client_id: "gh-backend-test-1",
        keep_alive: 1,
        force_ping: true
      )

    on_exit(fn ->
      Helpers.stop_safely(client)
      Helpers.stop_safely(broker)
    end)

    assert_receive {:broker_connect, connect_pkt}, 1_000
    assert connect_pkt.protocol_name == "MQTT"
    assert connect_pkt.protocol_level == 4
    assert connect_pkt.clean_session == true
    assert connect_pkt.keep_alive == 1
    assert connect_pkt.client_id == "gh-backend-test-1"
    assert connect_pkt.username == "customer-01"
    assert connect_pkt.password == "secret-password"

    assert_receive {:broker_subscribe, _sub_pid, topics}, 1_000

    assert Enum.sort(topics) ==
             Enum.sort([
               {"gh/+/telemetry", 1},
               {"gh/+/alarm/#", 1},
               {"gh/+/status", 1},
               {"gh/+/config/ack", 1}
             ])

    await_connected(client)

    # Broker delivers retained v2 status & alarm messages right after subscription
    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0001/status",
        payload: JSON.encode!(%{"v" => 2, "b" => "7f3a91c4", "online" => true, "up" => 12}),
        qos: 1,
        retain: true,
        packet_id: 10
      )

    assert_receive {:broker_puback, 10}, 1_000

    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0001/alarm/water_lack",
        payload:
          JSON.encode!(%{
            "v" => 2,
            "b" => "7f3a91c4",
            "up" => 12,
            "code" => "water_lack",
            "active" => true
          }),
        qos: 1,
        retain: true,
        packet_id: 11
      )

    assert_receive {:broker_puback, 11}, 1_000

    # Telemetry arrives with QoS 1 -> triggers PUBACK, scales values, and auto-clears water_lack when water=1
    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0001/telemetry",
        payload:
          JSON.encode!(%{
            "v" => 2,
            "b" => "7f3a91c4",
            "seq" => 1,
            "up" => 20,
            "t" => 2540,
            "ah" => 6125,
            "sh" => 4800,
            "lux" => 310,
            "water" => 1,
            "fan" => 0,
            "light" => 1,
            "heat" => 0
          }),
        qos: 1,
        retain: false,
        packet_id: 12
      )

    assert_receive {:broker_puback, 12}, 1_000

    # Keep-alive PINGREQ fires within ~1s because force_ping: true and keep_alive: 1
    assert_receive :broker_pingreq, 2_500

    # v=2 telemetry missing b must get PUBACK (QoS 1) and be rejected safely without overwriting seq=1
    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0001/telemetry",
        payload:
          JSON.encode!(%{
            "v" => 2,
            "seq" => 2,
            "up" => 22,
            "t" => 2600,
            "ah" => 6100,
            "sh" => 4800,
            "lux" => 300,
            "water" => 0,
            "fan" => 0,
            "light" => 1,
            "heat" => 0
          }),
        qos: 1,
        retain: false,
        packet_id: 13
      )

    assert_receive {:broker_puback, 13}, 1_000

    # Unsupported v=3 message must still get PUBACK (at QoS 1) and be dropped safely by Handler.
    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0001/telemetry",
        payload:
          JSON.encode!(%{"v" => 3, "b" => "7f3a91c4", "seq" => 2, "up" => 25, "t" => 9999}),
        qos: 1,
        retain: false,
        packet_id: 14
      )

    assert_receive {:broker_puback, 14}, 1_000

    Helpers.await_until(fn ->
      {:ok, latest} = Storage.get_latest_telemetry("GH-0001")
      latest.seq == 1
    end)

    {:ok, status_info} = Storage.get_device_status("GH-0001")
    assert status_info.online == true
    assert status_info.b == "7f3a91c4"

    {:ok, latest} = Storage.get_latest_telemetry("GH-0001")
    assert latest.v == 2
    assert latest.b == "7f3a91c4"
    assert_in_delta latest.temperature, 25.4, 0.001
    assert_in_delta latest.air_humidity, 61.25, 0.001
    assert_in_delta latest.soil_humidity, 48.0, 0.001
    assert latest.water == 1

    # v=2 missing-b & v=3 frames were dropped so water_lack stayed resolved from telemetry seq=1
    {:ok, alarms} = Storage.get_alarms("GH-0001")
    water_lack = Enum.find(alarms, &(&1.code == "water_lack"))
    assert water_lack.active == false
    assert water_lack.b == "7f3a91c4"

    # LWT offline status without b
    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0001/status",
        payload: JSON.encode!(%{"v" => 2, "online" => false}),
        qos: 1,
        retain: true,
        packet_id: 15
      )

    assert_receive {:broker_puback, 15}, 1_000

    Helpers.await_until(fn ->
      {:ok, st} = Storage.get_device_status("GH-0001")
      st.online == false
    end)

    {:ok, lwt_status} = Storage.get_device_status("GH-0001")
    assert lwt_status.b == nil

    # Device reboots with new boot session b -> seq=0 is accepted as a new session
    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0001/telemetry",
        payload:
          JSON.encode!(%{
            "v" => 2,
            "b" => "1c04be77",
            "seq" => 0,
            "up" => 2,
            "t" => 2400,
            "ah" => 5800,
            "sh" => 4100,
            "lux" => 220,
            "water" => 1,
            "fan" => 0,
            "light" => 0,
            "heat" => 0
          }),
        qos: 1,
        retain: false,
        packet_id: 16
      )

    assert_receive {:broker_puback, 16}, 1_000

    Helpers.await_until(fn ->
      {:ok, latest_reboot} = Storage.get_latest_telemetry("GH-0001")
      latest_reboot.b == "1c04be77" and latest_reboot.seq == 0
    end)

    # Clean shutdown sends DISCONNECT frame via :emqtt.disconnect/1
    GenServer.stop(client)
    assert_receive :broker_disconnect, 1_000
  end

  test "config publish + ack ok / rejected / timeout marks device offline over TCP" do
    {:ok, broker} = MockBroker.start_link(test_pid: self(), connack_codes: [0])
    port = MockBroker.port(broker)

    {:ok, cm} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn topic, payload, opts ->
          Client.publish(:test_mqtt_cfg_client, topic, payload, opts)
        end,
        config_ack_timeout_ms: 150
      )

    {:ok, client} =
      Client.start_link(
        name: :test_mqtt_cfg_client,
        enabled: true,
        host: "127.0.0.1",
        port: port,
        client_id: "gh-backend-cfg-test",
        config_manager: cm
      )

    on_exit(fn ->
      Helpers.stop_safely(cm)
      Helpers.stop_safely(client)
      Helpers.stop_safely(broker)
    end)

    assert_receive {:broker_connect, _}, 1_000
    assert_receive {:broker_subscribe, _, _}, 1_000
    await_connected(client)

    Storage.record_status("GH-0002", %{"v" => 2, "b" => "7f3a91c4", "online" => true, "up" => 5})

    # 1. Successful config apply + MQTT ack (without b per Protocol v2 §4.2)
    task1 =
      Task.async(fn ->
        ConfigManager.apply_config(
          cm,
          "GH-0002",
          %{"tMin" => 20.0, "tMax" => 30.0, "tHys" => 1.5},
          unit: :human
        )
      end)

    assert_receive {:broker_publish, pub1}, 1_000
    assert pub1.topic == "gh/GH-0002/config"
    assert pub1.qos == 1
    assert pub1.retain == false
    assert JSON.decode!(pub1.payload) == %{"tMin" => 2000, "tMax" => 3000, "tHys" => 150}

    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0002/config/ack",
        payload: JSON.encode!(%{"ok" => true}),
        qos: 1,
        packet_id: 20
      )

    assert_receive {:broker_puback, 20}, 1_000
    assert {:ok, cfg} = Task.await(task1, 1_000)
    assert cfg.raw["tMin"] == 2000
    assert is_binary(cfg.updated_at)
    assert is_integer(cfg.updated_at_ms)

    # 2. Rejected config ack
    task2 =
      Task.async(fn ->
        ConfigManager.apply_config(cm, "GH-0002", %{"tMin" => 2100})
      end)

    assert_receive {:broker_publish, pub2}, 1_000
    assert pub2.topic == "gh/GH-0002/config"

    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0002/config/ack",
        payload: JSON.encode!(%{"ok" => false, "reason" => "rejected"}),
        qos: 1,
        packet_id: 21
      )

    assert_receive {:broker_puback, 21}, 1_000
    assert {:error, {:device_rejected, "rejected"}} = Task.await(task2, 1_000)

    # 3. Client.publish/3 defaults to QoS 1, retain: false per Protocol v2 §5
    assert :ok = Client.publish(client, "gh/GH-0002/config", JSON.encode!(%{"tMin" => 1950}))
    assert_receive {:broker_publish, default_pub}, 1_000
    assert default_pub.topic == "gh/GH-0002/config"
    assert default_pub.qos == 1
    assert default_pub.retain == false

    # 4. Ack timeout marks device offline without blindly resending
    assert {:error, :ack_timeout} =
             ConfigManager.apply_config(cm, "GH-0002", %{"tMin" => 2200})

    assert_receive {:broker_publish, pub3}, 1_000
    assert pub3.topic == "gh/GH-0002/config"
    refute_receive {:broker_publish, _}, 200

    {:ok, status_after} = Storage.get_device_status("GH-0002")
    assert status_after.online == false
    assert status_after.offline_reason == "config_ack_timeout"
  end

  test "handler crash does not crash MQTT client loop and still sends PUBACK" do
    {:ok, broker} = MockBroker.start_link(test_pid: self(), connack_codes: [0])
    port = MockBroker.port(broker)

    {:ok, client} =
      Client.start_link(
        name: nil,
        enabled: true,
        host: "127.0.0.1",
        port: port,
        client_id: "gh-crash-resilience",
        handler_mod: CrashingHandler
      )

    on_exit(fn ->
      Helpers.stop_safely(client)
      Helpers.stop_safely(broker)
    end)

    assert_receive {:broker_connect, _}, 1_000
    assert_receive {:broker_subscribe, _, _}, 1_000
    await_connected(client)

    :ok =
      MockBroker.send_publish(broker,
        topic: "gh/GH-0003/telemetry",
        payload: JSON.encode!(%{"v" => 1, "seq" => 1}),
        qos: 1,
        packet_id: 30
      )

    assert_receive {:broker_puback, 30}, 1_000
    Process.sleep(30)
    assert Process.alive?(client)
    assert Client.status(client).connected == true
  end

  test "ConfigManager returns :mqtt_disconnected when MQTT client is not connected" do
    {:ok, client} = Client.start_link(name: nil, enabled: false)

    {:ok, cm} =
      ConfigManager.start_link(
        name: nil,
        publish_fn: fn topic, payload, opts ->
          Client.publish(client, topic, payload, opts)
        end
      )

    on_exit(fn ->
      Helpers.stop_safely(cm)
      Helpers.stop_safely(client)
    end)

    assert {:error, :mqtt_disconnected} =
             ConfigManager.apply_config(cm, "GH-0004", %{"tMin" => 2000, "tMax" => 3000})
  end

  test "reconnects with exponential backoff on non-zero CONNACK and TCP drops, then resets backoff on CONNACK(0)" do
    {:ok, broker} = MockBroker.start_link(test_pid: self(), connack_codes: [5, 5, 0, 0])
    port = MockBroker.port(broker)

    {:ok, client} =
      Client.start_link(
        name: nil,
        enabled: true,
        host: "127.0.0.1",
        port: port,
        client_id: "gh-backoff-test",
        initial_backoff_ms: 40,
        max_backoff_ms: 160
      )

    on_exit(fn ->
      Helpers.stop_safely(client)
      Helpers.stop_safely(broker)
    end)

    # First two attempts rejected with CONNACK rc=5 -> third attempt accepted (rc=0)
    assert_receive {:broker_connect, _}, 1_000
    assert_receive {:broker_connect, _}, 1_000
    assert_receive {:broker_connect, _}, 1_000
    assert_receive {:broker_subscribe, _, _}, 1_000

    await_connected(client)
    assert Client.status(client).reconnect_attempts == 0

    # Simulate broker TCP drop -> client reconnects and re-subscribes automatically
    MockBroker.drop_connection(broker)

    assert_receive {:broker_connect, _}, 1_000
    assert_receive {:broker_subscribe, _, _}, 1_000
    await_connected(client)
    assert Client.status(client).reconnect_attempts == 0
  end

  describe ":emqtt frame reassembly and low-mem handling" do
    test "reassembles QoS 1 PUBLISH fragmented across tiny TCP chunks and sends PUBACK" do
      {:ok, broker} = MockBroker.start_link(test_pid: self(), connack_codes: [0])
      port = MockBroker.port(broker)

      {:ok, client} =
        Client.start_link(
          name: nil,
          enabled: true,
          host: "127.0.0.1",
          port: port,
          client_id: "gh-fragment-test",
          low_mem: true
        )

      on_exit(fn ->
        Helpers.stop_safely(client)
        Helpers.stop_safely(broker)
      end)

      assert_receive {:broker_connect, _}, 1_000
      assert_receive {:broker_subscribe, _, _}, 1_000
      await_connected(client)

      payload =
        JSON.encode!(%{
          "v" => 2,
          "b" => "7f3a91c4",
          "seq" => 9,
          "up" => 100,
          "t" => 2350,
          "ah" => 5500,
          "sh" => 4200,
          "lux" => 180,
          "water" => 1,
          "fan" => 0,
          "light" => 0,
          "heat" => 0
        })

      :ok =
        MockBroker.send_publish_chunked(
          broker,
          [topic: "gh/GH-0006/telemetry", payload: payload, qos: 1, packet_id: 41],
          5
        )

      assert_receive {:broker_puback, 41}, 1_500

      Helpers.await_until(fn ->
        case Storage.get_latest_telemetry("GH-0006") do
          {:ok, latest} -> latest.seq == 9
          _ -> false
        end
      end)
    end
  end

  defp await_connected(client) do
    Helpers.await_until(fn -> Client.status(client).connected == true end)
  end
end
