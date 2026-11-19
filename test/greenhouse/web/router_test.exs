defmodule Greenhouse.Web.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Greenhouse.Storage
  alias Greenhouse.TestSupport.{Helpers, HTTP}
  alias Greenhouse.Web.Router

  defmodule StubConfigManager do
    def apply_config(device_id, params, opts \\ []) do
      case Process.get({__MODULE__, :responder}) do
        fun when is_function(fun, 3) -> fun.(device_id, params, opts)
        nil -> {:error, :mqtt_disconnected}
      end
    end
  end

  setup do
    Storage.reset!()
    Process.delete({StubConfigManager, :responder})
    :ok
  end

  describe "Router.call/1 unit routing" do
    test "adds CORS headers on every response including OPTIONS *" do
      options_conn =
        %{conn(:options, "/") | request_path: "*", path_info: ["*"]}
        |> Router.call()

      assert options_conn.status == 204
      assert options_conn.resp_body == ""
      HTTP.assert_cors_headers(Map.new(options_conn.resp_headers))

      preflight_conn = Router.call(conn(:options, "/api/v1/devices/GH-0001/config"))
      assert preflight_conn.status == 204
      HTTP.assert_cors_headers(Map.new(preflight_conn.resp_headers))

      not_found = Router.call(conn(:get, "/nonexistent"))
      assert not_found.status == 404
      assert JSON.decode!(not_found.resp_body) == %{"ok" => false, "error" => "route_not_found"}
      HTTP.assert_cors_headers(Map.new(not_found.resp_headers))
    end

    test "GET /health and GET /api/v1/health return status, mqtt info, device_count, and timestamp" do
      Helpers.seed_device!("GH-0001")

      for path <- ["/health", "/api/v1/health"] do
        conn = Router.call(conn(:get, path))
        assert conn.status == 200
        HTTP.assert_cors_headers(Map.new(conn.resp_headers))

        body = JSON.decode!(conn.resp_body)
        assert body["ok"] == true
        assert body["status"] == "healthy"
        assert is_map(body["mqtt"])
        assert body["mqtt"]["connected"] == false
        assert body["device_count"] == 1
        assert {:ok, _dt, _offset} = DateTime.from_iso8601(body["timestamp"])
      end
    end

    test "devices, status, and telemetry endpoints return expected payloads and 404s" do
      assert Router.call(conn(:get, "/api/v1/devices/GH-9999")).status == 404
      assert Router.call(conn(:get, "/api/v1/devices/GH-9999/status")).status == 404
      assert Router.call(conn(:get, "/api/v1/devices/GH-9999/telemetry/latest")).status == 404
      assert Router.call(conn(:get, "/api/v1/devices/GH-9999/telemetry/current")).status == 404

      Helpers.seed_device!("GH-0001")

      list_conn = Router.call(conn(:get, "/api/v1/devices"))
      assert list_conn.status == 200
      list_body = JSON.decode!(list_conn.resp_body)
      assert list_body["ok"] == true
      assert length(list_body["data"]) == 1
      list_item = hd(list_body["data"])
      assert list_item["device_id"] == "GH-0001"
      assert list_item["status"]["b"] == "7f3a91c4"
      assert is_binary(list_item["status"]["updated_at"])
      assert is_integer(list_item["status"]["updated_at_ms"])
      assert list_item["latest_telemetry"]["v"] == 2
      assert list_item["latest_telemetry"]["b"] == "7f3a91c4"
      assert is_binary(list_item["latest_telemetry"]["received_at"])

      dev_conn = Router.call(conn(:get, "/api/v1/devices/GH-0001"))
      assert dev_conn.status == 200
      dev_body = JSON.decode!(dev_conn.resp_body)
      assert dev_body["data"]["device_id"] == "GH-0001"
      assert dev_body["data"]["status"]["online"] == true
      assert dev_body["data"]["status"]["b"] == "7f3a91c4"
      assert dev_body["data"]["latest_telemetry"]["b"] == "7f3a91c4"

      status_conn = Router.call(conn(:get, "/api/v1/devices/GH-0001/status"))
      assert status_conn.status == 200
      status_data = JSON.decode!(status_conn.resp_body)["data"]
      assert status_data["up"] == 86_400
      assert status_data["b"] == "7f3a91c4"
      assert is_binary(status_data["updated_at"])
      assert is_integer(status_data["updated_at_ms"])

      # LWT offline status without b preserves freshness timestamp and surfaces b: nil
      {:ok, _} = Storage.record_status("GH-LWT", %{"v" => 2, "online" => false})
      lwt_conn = Router.call(conn(:get, "/api/v1/devices/GH-LWT/status"))
      assert lwt_conn.status == 200
      lwt_data = JSON.decode!(lwt_conn.resp_body)["data"]
      assert lwt_data["online"] == false
      assert lwt_data["b"] == nil
      assert is_binary(lwt_data["updated_at"])
      assert is_integer(lwt_data["updated_at_ms"])

      for path <- [
            "/api/v1/devices/GH-0001/telemetry/latest",
            "/api/v1/devices/GH-0001/telemetry/current"
          ] do
        tel_conn = Router.call(conn(:get, path))
        assert tel_conn.status == 200
        tel_data = JSON.decode!(tel_conn.resp_body)["data"]
        assert tel_data["v"] == 2
        assert tel_data["b"] == "7f3a91c4"
        assert tel_data["raw"]["b"] == "7f3a91c4"
        assert is_binary(tel_data["received_at"])
        assert is_integer(tel_data["received_at_ms"])
        assert_in_delta tel_data["temperature"], 23.5, 0.001
        assert_in_delta tel_data["air_humidity"], 56.8, 0.001
        assert_in_delta tel_data["soil_humidity"], 31.2, 0.001
        assert tel_data["lux"] == 812
      end
    end

    test "telemetry history and stats support query filters including b and handle invalid params gracefully" do
      base_ms = 1_700_000_000_000

      for {b, seq, offset_ms, t} <- [
            {"7f3a91c4", 1, 0, 2000},
            {"7f3a91c4", 2, 1000, 2200},
            {"1c04be77", 0, 2000, 2600}
          ] do
        {:ok, _} =
          Storage.record_telemetry(
            "GH-0001",
            Helpers.sample_v2_telemetry_payload(%{
              "b" => b,
              "seq" => seq,
              "up" => 100 + seq,
              "t" => t,
              "ah" => 5000,
              "sh" => 3000,
              "lux" => 500 + seq * 100
            }),
            base_ms + offset_ms
          )
      end

      for path <- [
            "/api/v1/devices/GH-0001/telemetry/history",
            "/api/v1/devices/GH-0001/telemetry"
          ] do
        conn =
          Router.call(
            conn(
              :get,
              "#{path}?from=#{base_ms + 500}&to=#{base_ms + 2500}&limit=1&offset=1&order=asc"
            )
          )

        assert conn.status == 200
        data = JSON.decode!(conn.resp_body)["data"]
        assert data["total"] == 2
        assert data["limit"] == 1
        assert data["offset"] == 1
        assert data["order"] == "asc"
        assert length(data["items"]) == 1
        assert hd(data["items"])["seq"] == 0
        assert hd(data["items"])["b"] == "1c04be77"
      end

      # Filter history and stats by boot session b (case-insensitive)
      boot_hist_conn =
        Router.call(conn(:get, "/api/v1/devices/GH-0001/telemetry/history?b=7F3A91C4&order=asc"))

      assert boot_hist_conn.status == 200
      boot_hist = JSON.decode!(boot_hist_conn.resp_body)["data"]
      assert boot_hist["total"] == 2
      assert Enum.map(boot_hist["items"], & &1["seq"]) == [1, 2]
      assert Enum.all?(boot_hist["items"], &(&1["b"] == "7f3a91c4"))

      boot_stats_conn =
        Router.call(conn(:get, "/api/v1/devices/GH-0001/telemetry/stats?b=1c04be77"))

      assert boot_stats_conn.status == 200
      boot_stats = JSON.decode!(boot_stats_conn.resp_body)["data"]
      assert boot_stats["count"] == 1
      assert_in_delta boot_stats["temperature"]["avg"], 26.0, 0.001

      bad_boot_conn = Router.call(conn(:get, "/api/v1/devices/GH-0001/telemetry/stats?b=not_hex"))
      assert bad_boot_conn.status == 200
      assert JSON.decode!(bad_boot_conn.resp_body)["data"]["count"] == 0

      graceful_conn =
        Router.call(
          conn(
            :get,
            "/api/v1/devices/GH-0001/telemetry/history?limit=not_int&offset=-10&order=invalid"
          )
        )

      assert graceful_conn.status == 200
      graceful_data = JSON.decode!(graceful_conn.resp_body)["data"]
      assert graceful_data["limit"] == 100
      assert graceful_data["offset"] == 0
      assert graceful_data["order"] == "desc"
      assert length(graceful_data["items"]) == 3

      stats_conn =
        Router.call(
          conn(
            :get,
            "/api/v1/devices/GH-0001/telemetry/stats?from=#{base_ms}&to=#{base_ms + 1000}"
          )
        )

      assert stats_conn.status == 200
      stats_data = JSON.decode!(stats_conn.resp_body)["data"]
      assert stats_data["count"] == 2
      assert_in_delta stats_data["temperature"]["min"], 20.0, 0.001
      assert_in_delta stats_data["temperature"]["max"], 22.0, 0.001
      assert_in_delta stats_data["temperature"]["avg"], 21.0, 0.001
    end

    test "alarms list, active_only filter, and POST/DELETE manual clear" do
      {:ok, _} =
        Storage.record_alarm("GH-0001", "water_lack", %{
          "v" => 2,
          "b" => "7f3a91c4",
          "up" => 50,
          "code" => "water_lack",
          "active" => true
        })

      {:ok, _} =
        Storage.record_alarm("GH-0001", "turntable_failed", %{
          "v" => 2,
          "b" => "7f3a91c4",
          "up" => 60,
          "code" => "turntable_failed",
          "active" => true
        })

      {:ok, _} = Storage.clear_alarm("GH-0001", "water_lack", "telemetry_water_normal")

      all_conn = Router.call(conn(:get, "/api/v1/devices/GH-0001/alarms"))
      assert all_conn.status == 200
      assert length(JSON.decode!(all_conn.resp_body)["data"]) == 2

      active_conn = Router.call(conn(:get, "/api/v1/devices/GH-0001/alarms?active_only=true"))
      assert active_conn.status == 200
      active_alarms = JSON.decode!(active_conn.resp_body)["data"]
      assert length(active_alarms) == 1
      active_alarm = hd(active_alarms)
      assert active_alarm["code"] == "turntable_failed"
      assert active_alarm["v"] == 2
      assert active_alarm["b"] == "7f3a91c4"
      assert is_binary(active_alarm["received_at"])
      assert is_binary(active_alarm["updated_at"])

      clear_conn =
        Router.call(conn(:post, "/api/v1/devices/GH-0001/alarms/turntable_failed/clear"))

      assert clear_conn.status == 200
      cleared = JSON.decode!(clear_conn.resp_body)["data"]
      assert cleared["active"] == false
      assert cleared["b"] == "7f3a91c4"
      assert cleared["clear_reason"] == "manual_api"

      {:ok, _} =
        Storage.record_alarm("GH-0001", "turntable_failed", %{
          "v" => 2,
          "b" => "7f3a91c4",
          "up" => 80,
          "code" => "turntable_failed",
          "active" => true
        })

      del_conn = Router.call(conn(:delete, "/api/v1/devices/GH-0001/alarms/turntable_failed"))
      assert del_conn.status == 200
      assert JSON.decode!(del_conn.resp_body)["data"]["active"] == false

      missing_conn =
        Router.call(conn(:post, "/api/v1/devices/GH-0001/alarms/no_such_alarm/clear"))

      assert missing_conn.status == 404
      assert JSON.decode!(missing_conn.resp_body)["error"] == "not_found"
    end

    test "config GET and PATCH/PUT/POST unit=human, invalid JSON, and all error mappings" do
      {:ok, _} = Storage.update_config_cache("GH-0001", %{"tMin" => 1000, "tMax" => 3000})

      get_conn = Router.call(conn(:get, "/api/v1/devices/GH-0001/config"))
      assert get_conn.status == 200
      cfg = JSON.decode!(get_conn.resp_body)["data"]
      assert cfg["raw"] == %{"tMin" => 1000, "tMax" => 3000}
      assert cfg["human"] == %{"tMin" => 10.0, "tMax" => 30.0}

      bad_json_conn =
        conn(:patch, "/api/v1/devices/GH-0001/config", "{broken")
        |> put_req_header("content-type", "application/json")
        |> Router.call()

      assert bad_json_conn.status == 400
      assert JSON.decode!(bad_json_conn.resp_body) == %{"ok" => false, "error" => "invalid_json"}
      HTTP.assert_cors_headers(Map.new(bad_json_conn.resp_headers))

      bad_untyped_json_conn =
        Router.call(conn(:patch, "/api/v1/devices/GH-0001/config", "{broken"))

      assert bad_untyped_json_conn.status == 400

      assert JSON.decode!(bad_untyped_json_conn.resp_body) == %{
               "ok" => false,
               "error" => "invalid_json"
             }

      array_json_conn =
        conn(:patch, "/api/v1/devices/GH-0001/config", "[1, 2]")
        |> put_req_header("content-type", "application/json")
        |> Router.call()

      assert array_json_conn.status == 400

      assert JSON.decode!(array_json_conn.resp_body) == %{
               "ok" => false,
               "error" => "invalid_json"
             }

      test_pid = self()

      Process.put({StubConfigManager, :responder}, fn device_id, params, opts ->
        send(test_pid, {:called, device_id, params, opts})
        {:ok, %{device_id: device_id, raw: %{"tMin" => 2000}, human: %{"tMin" => 20.0}}}
      end)

      ok_query_conn =
        conn(:patch, "/api/v1/devices/GH-0001/config?unit=human", ~s({"tMin":20.0}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(config_manager: StubConfigManager)

      assert ok_query_conn.status == 200
      assert_received {:called, "GH-0001", %{"tMin" => 20.0}, [unit: :human]}

      ok_body_unit_conn =
        conn(:put, "/api/v1/devices/GH-0001/config", ~s({"unit":"human","tMin":21.5}))
        |> Router.call(config_manager: StubConfigManager)

      assert ok_body_unit_conn.status == 200
      assert_received {:called, "GH-0001", %{"tMin" => 21.5}, [unit: :human]}

      # Validation failed -> 422
      Process.put({StubConfigManager, :responder}, fn _id, _p, _o ->
        {:error, {:validation_failed, ["tMin must be less than tMax"]}}
      end)

      val_conn =
        Router.call(
          conn(:post, "/api/v1/devices/GH-0001/config", ~s({"tMin":4000})),
          config_manager: StubConfigManager
        )

      assert val_conn.status == 422
      val_body = JSON.decode!(val_conn.resp_body)
      assert val_body["ok"] == false
      assert val_body["error"] == "validation_failed"
      assert val_body["details"] == ["tMin must be less than tMax"]

      # Device syntax error -> 400
      Process.put({StubConfigManager, :responder}, fn _id, _p, _o ->
        {:error, {:device_rejected, "syntax"}}
      end)

      syn_conn =
        Router.call(
          conn(:patch, "/api/v1/devices/GH-0001/config", ~s({"tMin":1200})),
          config_manager: StubConfigManager
        )

      assert syn_conn.status == 400

      assert JSON.decode!(syn_conn.resp_body) == %{
               "ok" => false,
               "error" => "device_syntax_error",
               "reason" => "syntax"
             }

      # Device rejected -> 422
      Process.put({StubConfigManager, :responder}, fn _id, _p, _o ->
        {:error, {:device_rejected, "rejected"}}
      end)

      rej_conn =
        Router.call(
          conn(:patch, "/api/v1/devices/GH-0001/config", ~s({"tMin":1200})),
          config_manager: StubConfigManager
        )

      assert rej_conn.status == 422

      assert JSON.decode!(rej_conn.resp_body) == %{
               "ok" => false,
               "error" => "device_rejected",
               "reason" => "rejected"
             }

      # Ack timeout -> 504
      Process.put({StubConfigManager, :responder}, fn _id, _p, _o ->
        {:error, :ack_timeout}
      end)

      timeout_conn =
        Router.call(
          conn(:patch, "/api/v1/devices/GH-0001/config", ~s({"tMin":1200})),
          config_manager: StubConfigManager
        )

      assert timeout_conn.status == 504
      assert JSON.decode!(timeout_conn.resp_body)["error"] == "ack_timeout"

      # MQTT disconnected -> 503
      Process.put({StubConfigManager, :responder}, fn _id, _p, _o ->
        {:error, :mqtt_disconnected}
      end)

      disc_conn =
        Router.call(
          conn(:patch, "/api/v1/devices/GH-0001/config", ~s({"tMin":1200})),
          config_manager: StubConfigManager
        )

      assert disc_conn.status == 503
      assert JSON.decode!(disc_conn.resp_body)["error"] == "mqtt_disconnected"

      # Config in progress -> 409
      Process.put({StubConfigManager, :responder}, fn _id, _p, _o ->
        {:error, :config_in_progress}
      end)

      conflict_conn =
        Router.call(
          conn(:patch, "/api/v1/devices/GH-0001/config", ~s({"tMin":1200})),
          config_manager: StubConfigManager
        )

      assert conflict_conn.status == 409
      assert JSON.decode!(conflict_conn.resp_body)["error"] == "config_in_progress"
    end

    test "supports Content-Type on GET, pre-populated non-binary query_params, and empty JSON POST" do
      bad_get =
        conn(:get, "/api/v1/devices", "[1, 2]")
        |> put_req_header("content-type", "application/json")
        |> Router.call()

      assert bad_get.status == 400
      assert JSON.decode!(bad_get.resp_body) == %{"ok" => false, "error" => "invalid_json"}

      {:ok, _} =
        Storage.record_telemetry(
          "GH-DIRECT-Q",
          Helpers.sample_telemetry_payload(%{"seq" => 1, "up" => 10}),
          1_000
        )

      {:ok, _} =
        Storage.record_telemetry(
          "GH-DIRECT-Q",
          Helpers.sample_telemetry_payload(%{"seq" => 2, "up" => 20}),
          2_000
        )

      hist_conn =
        %{
          conn(:get, "/api/v1/devices/GH-DIRECT-Q/telemetry/history")
          | query_params: %{"limit" => 1, "from" => 1_000, "order" => :asc, "offset" => :bad}
        }
        |> Router.call()

      assert hist_conn.status == 200
      body = JSON.decode!(hist_conn.resp_body)
      assert body["data"]["total"] == 2
      assert body["data"]["limit"] == 1
      assert body["data"]["order"] == "asc"
      assert [item] = body["data"]["items"]
      assert item["seq"] == 1

      empty_json_post =
        conn(:post, "/api/v1/auth/login", "{}")
        |> put_req_header("content-type", "application/json")
        |> Router.call()

      assert empty_json_post.status == 400
      assert JSON.decode!(empty_json_post.resp_body)["error"] == "invalid_credentials"
    end
  end
end
