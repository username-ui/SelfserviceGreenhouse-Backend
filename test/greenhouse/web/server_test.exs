defmodule Greenhouse.Web.ServerTest do
  use ExUnit.Case, async: false

  alias Greenhouse.{AccountStore, ConfigManager, Storage}
  alias Greenhouse.TestSupport.{Helpers, HTTP}
  alias Greenhouse.Web.{Router, Server}

  defmodule LiveTestRouter do
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      cm = Application.get_env(:greenhouse, :test_live_config_manager, ConfigManager)
      Router.call(conn, config_manager: cm)
    end
  end

  setup do
    Storage.reset!()
    :ok
  end

  describe "live HTTP/1.1 Bandit server" do
    test "exposes bound integer port and handles GET, POST, DELETE, OPTIONS *, 400, 404, 503, and concurrency" do
      port = Server.port(Server)
      assert is_integer(port) and port > 0

      Helpers.seed_device!("GH-0001")

      {:ok, _} =
        Storage.record_alarm("GH-0001", "turntable_failed", %{
          "v" => 2,
          "b" => "7f3a91c4",
          "up" => 100,
          "code" => "turntable_failed",
          "active" => true
        })

      # Raw TCP OPTIONS *
      {status, headers, raw_body} =
        HTTP.raw_http_request(
          port,
          "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )

      assert status == 204
      assert raw_body == ""
      assert headers["access-control-allow-origin"] == "*"
      assert headers["connection"] == "close"

      # :httpc GET /health and /api/v1/health
      {status, headers, body} = HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/api/v1/health")
      assert status == 200
      assert headers["access-control-allow-origin"] == "*"
      assert body["ok"] == true
      assert body["device_count"] == 1

      # :httpc GET /api/v1/devices and /devices/:id and /status
      {200, _h, dev_list} = HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/api/v1/devices")
      assert length(dev_list["data"]) == 1

      {200, _h, dev_detail} =
        HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/api/v1/devices/GH-0001")

      assert dev_detail["data"]["device_id"] == "GH-0001"

      {200, _h, dev_status} =
        HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/status")

      assert dev_status["data"]["online"] == true
      assert dev_status["data"]["b"] == "7f3a91c4"
      assert is_binary(dev_status["data"]["updated_at"])

      # :httpc GET telemetry latest, current, history, stats
      {200, _h, latest} =
        HTTP.httpc_request(
          :get,
          "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/telemetry/latest"
        )

      assert latest["data"]["v"] == 2
      assert latest["data"]["b"] == "7f3a91c4"
      assert is_binary(latest["data"]["received_at"])
      assert_in_delta latest["data"]["temperature"], 23.5, 0.001

      {200, _h, current} =
        HTTP.httpc_request(
          :get,
          "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/telemetry/current"
        )

      assert_in_delta current["data"]["temperature"], 23.5, 0.001

      {200, _h, hist} =
        HTTP.httpc_request(
          :get,
          "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/telemetry/history?limit=5&order=asc"
        )

      assert hist["data"]["total"] == 1
      assert hist["data"]["order"] == "asc"

      {200, _h, stats} =
        HTTP.httpc_request(
          :get,
          "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/telemetry/stats"
        )

      assert stats["data"]["count"] == 1

      # :httpc GET alarms, POST clear, and DELETE alias
      {200, _h, alarms} =
        HTTP.httpc_request(
          :get,
          "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/alarms?active_only=true"
        )

      assert length(alarms["data"]) == 1

      {200, _h, cleared} =
        HTTP.httpc_request(
          :post,
          "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/alarms/turntable_failed/clear",
          "{}"
        )

      assert cleared["data"]["active"] == false

      {:ok, _} =
        Storage.record_alarm("GH-0001", "turntable_failed", %{
          "v" => 2,
          "b" => "7f3a91c4",
          "up" => 110,
          "code" => "turntable_failed",
          "active" => true
        })

      {200, _h, deleted_alarm} =
        HTTP.httpc_request(
          :delete,
          "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/alarms/turntable_failed"
        )

      assert deleted_alarm["data"]["active"] == false

      # :httpc GET config
      {200, _h, cfg} =
        HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/config")

      assert cfg["data"]["device_id"] == "GH-0001"

      # Invalid JSON over TCP -> 400 with CORS headers
      {400, err_headers, err_body} =
        HTTP.raw_http_json(port, "PATCH", "/api/v1/devices/GH-0001/config", "{bad-json")

      assert err_headers["access-control-allow-origin"] == "*"
      assert JSON.decode!(err_body) == %{"ok" => false, "error" => "invalid_json"}

      # Default MQTT disabled -> live PATCH returns 503 mqtt_disconnected
      {503, _h, disc_body} =
        HTTP.raw_http_json(port, "PATCH", "/api/v1/devices/GH-0001/config", ~s({"tMin":1500}))

      assert JSON.decode!(disc_body)["error"] == "mqtt_disconnected"

      # Unknown route -> 404
      {404, _h, not_found_body} =
        HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/does/not/exist")

      assert not_found_body["error"] == "route_not_found"

      # Concurrent HTTP requests
      results =
        1..10
        |> Task.async_stream(
          fn _ -> HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/health") end,
          max_concurrency: 10,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, {code, _h, payload}} -> {code, payload["ok"]} end)

      assert Enum.all?(results, fn res -> res == {200, true} end)
    end

    test "live HTTP config PATCH/PUT/POST with real ConfigManager ack, unit=human, validation, rejection, and timeout" do
      test_pid = self()

      publish_fn = fn topic, payload, opts ->
        send(test_pid, {:mqtt_publish, topic, payload, opts})
        :ok
      end

      {:ok, cm} =
        ConfigManager.start_link(
          name: nil,
          publish_fn: publish_fn,
          config_ack_timeout_ms: 120
        )

      on_exit(fn -> Helpers.stop_safely(cm) end)

      Application.put_env(:greenhouse, :test_live_config_manager, cm)
      on_exit(fn -> Application.delete_env(:greenhouse, :test_live_config_manager) end)

      {:ok, server} =
        Server.start_link(
          name: nil,
          port: 0,
          ip: "127.0.0.1",
          router: LiveTestRouter,
          startup_log: false
        )

      on_exit(fn -> Helpers.stop_safely(server) end)

      port = Server.port(server)
      assert is_integer(port) and port > 0

      Helpers.seed_device!("GH-0001")

      # 1. PATCH with ?unit=human and positive ack
      task1 =
        Task.async(fn ->
          HTTP.raw_http_json(
            port,
            "PATCH",
            "/api/v1/devices/GH-0001/config?unit=human",
            ~s({"tMin":18.5,"tMax":28.5,"tHys":1.5})
          )
        end)

      assert_receive {:mqtt_publish, "gh/GH-0001/config", raw_payload, [qos: 1, retain: false]},
                     1_000

      assert JSON.decode!(raw_payload) == %{"tMin" => 1850, "tMax" => 2850, "tHys" => 150}
      :ok = ConfigManager.handle_ack(cm, "GH-0001", %{"ok" => true})

      {200, _h, resp1} = Task.await(task1, 2_000)
      decoded1 = JSON.decode!(resp1)
      assert decoded1["ok"] == true
      assert decoded1["data"]["raw"] == %{"tMin" => 1850, "tMax" => 2850, "tHys" => 150}
      assert decoded1["data"]["human"] == %{"tMin" => 18.5, "tMax" => 28.5, "tHys" => 1.5}

      # 2. Validation error (tMin >= existing tMax) -> 422 without publishing
      {422, _h, resp2} =
        HTTP.raw_http_json(port, "PUT", "/api/v1/devices/GH-0001/config", ~s({"tMin":3000}))

      assert JSON.decode!(resp2)["error"] == "validation_failed"
      refute_received {:mqtt_publish, _, _, _}

      # 3. Device syntax rejection -> 400
      task3 =
        Task.async(fn ->
          HTTP.raw_http_json(port, "POST", "/api/v1/devices/GH-0001/config", ~s({"tMin":1900}))
        end)

      assert_receive {:mqtt_publish, "gh/GH-0001/config", _, _}, 1_000
      :ok = ConfigManager.handle_ack(cm, "GH-0001", %{"ok" => false, "reason" => "syntax"})
      {400, _h, resp3} = Task.await(task3, 2_000)
      assert JSON.decode!(resp3)["error"] == "device_syntax_error"

      # 4. Device semantic rejection -> 422
      task4 =
        Task.async(fn ->
          HTTP.raw_http_json(port, "PATCH", "/api/v1/devices/GH-0001/config", ~s({"tMin":1900}))
        end)

      assert_receive {:mqtt_publish, "gh/GH-0001/config", _, _}, 1_000
      :ok = ConfigManager.handle_ack(cm, "GH-0001", %{"ok" => false, "reason" => "rejected"})
      {422, _h, resp4} = Task.await(task4, 2_000)
      assert JSON.decode!(resp4)["error"] == "device_rejected"

      # 5. Ack timeout -> 504 and device marked offline
      task5 =
        Task.async(fn ->
          HTTP.raw_http_json(port, "PATCH", "/api/v1/devices/GH-0001/config", ~s({"tMin":1950}))
        end)

      assert_receive {:mqtt_publish, "gh/GH-0001/config", _, _}, 1_000
      {504, _h, resp5} = Task.await(task5, 2_000)
      assert JSON.decode!(resp5)["error"] == "ack_timeout"

      {200, _h, status_after} =
        HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/api/v1/devices/GH-0001/status")

      assert status_after["data"]["online"] == false
      assert status_after["data"]["offline_reason"] == "config_ack_timeout"
    end

    test "enforces 64-header limit, 16KB header-line limit, 1MB body limit, and mixed-case headers" do
      AccountStore.reset!()

      {:ok, %{token: token}} =
        AccountStore.register_user(%{
          "username" => "hdr_user",
          "password" => "secret123"
        })

      {:ok, server} =
        Server.start_link(
          name: nil,
          port: 0,
          ip: {127, 0, 0, 1},
          router: LiveTestRouter,
          startup_log: false
        )

      on_exit(fn ->
        Helpers.stop_safely(server)
      end)

      port = Server.port(server)
      assert {:ok, {_addr, ^port}} = ThousandIsland.listener_info(server)

      # 1. Exactly 64 headers succeeds (Host + Connection + 62 custom headers)
      headers_62 = Enum.map(1..62, fn i -> "X-Test-#{i}: v#{i}\r\n" end)

      req_64 = [
        "GET /health HTTP/1.1\r\n",
        "Host: 127.0.0.1:",
        Integer.to_string(port),
        "\r\n",
        "Connection: close\r\n",
        headers_62,
        "\r\n"
      ]

      assert {200, _h, resp_64} = HTTP.raw_http_request(port, req_64)
      assert JSON.decode!(resp_64)["ok"] == true

      # 2. 65 headers fails with 431 Request Header Fields Too Large
      headers_63 = Enum.map(1..63, fn i -> "X-Test-#{i}: v#{i}\r\n" end)

      req_65 = [
        "GET /health HTTP/1.1\r\n",
        "Host: 127.0.0.1:",
        Integer.to_string(port),
        "\r\n",
        "Connection: close\r\n",
        headers_63,
        "\r\n"
      ]

      assert {431, _h, _resp_65} = HTTP.raw_http_request(port, req_65)

      # 3. Single header exceeding 16KB limit returns 431 without affecting subsequent requests
      req_huge_hdr = [
        "GET /health HTTP/1.1\r\n",
        "Host: 127.0.0.1:",
        Integer.to_string(port),
        "\r\n",
        "X-Oversized: ",
        String.duplicate("a", 17_000),
        "\r\nConnection: close\r\n\r\n"
      ]

      assert {431, _h, _resp_huge} = HTTP.raw_http_request(port, req_huge_hdr)

      assert {200, _h, %{"ok" => true}} =
               HTTP.httpc_request(:get, "http://127.0.0.1:#{port}/health")

      # 4. Exact 1_048_576 byte JSON body is accepted (login fails cleanly with 401, not 413)
      prefix = ~s({"username":"nobody","password":"bad","pad":")
      suffix = ~s("})
      pad_len = 1_048_576 - byte_size(prefix) - byte_size(suffix)
      exact_max_body = prefix <> String.duplicate("z", pad_len) <> suffix
      assert byte_size(exact_max_body) == 1_048_576

      assert {401, _h, resp_exact} =
               HTTP.raw_http_json(port, "POST", "/api/v1/auth/login", exact_max_body)

      assert JSON.decode!(resp_exact)["error"] == "invalid_credentials"

      # 5. Content-Length > 1_048_576 returns 413 payload_too_large with CORS headers
      req_too_large = [
        "POST /api/v1/auth/login HTTP/1.1\r\n",
        "Host: 127.0.0.1:",
        Integer.to_string(port),
        "\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: 1048577\r\n",
        "Connection: close\r\n\r\n"
      ]

      assert {413, too_large_headers, resp_too_large} = HTTP.raw_http_request(port, req_too_large)
      HTTP.assert_cors_headers(too_large_headers)
      assert JSON.decode!(resp_too_large)["error"] == "payload_too_large"

      # 6. Mixed-case X-SeSsIoN-ToKeN and canonical X-Session-Token both normalize properly
      for hdr_name <- ["X-Session-Token", "X-SeSsIoN-ToKeN"] do
        req_auth = [
          "GET /api/v1/auth/me HTTP/1.1\r\n",
          "Host: 127.0.0.1:",
          Integer.to_string(port),
          "\r\n",
          hdr_name,
          ": ",
          token,
          "\r\n",
          "Connection: close\r\n\r\n"
        ]

        assert {200, _h, resp_auth} = HTTP.raw_http_request(port, req_auth)
        assert JSON.decode!(resp_auth)["data"]["user"]["username"] == "hdr_user"
      end

      # 7. Idle hibernation check for ConfigManager and MQTT.Client while Bandit supervisor runs
      {:ok, cm} = ConfigManager.start_link(name: nil, hibernate_after_ms: 25)
      on_exit(fn -> Helpers.stop_safely(cm) end)

      {:ok, mqtt} =
        Greenhouse.MQTT.Client.start_link(name: nil, enabled: false, hibernate_after_ms: 25)

      on_exit(fn -> Helpers.stop_safely(mqtt) end)

      assert Process.alive?(server)
      _ = :sys.get_state(cm)
      _ = Greenhouse.MQTT.Client.status(mqtt)

      assert Helpers.eventually(fn ->
               Process.info(cm, :current_function) ==
                 {:current_function, {:gen_server, :loop_hibernate, 4}}
             end)

      assert Helpers.eventually(fn ->
               Process.info(mqtt, :current_function) ==
                 {:current_function, {:gen_server, :loop_hibernate, 4}}
             end)
    end
  end
end
