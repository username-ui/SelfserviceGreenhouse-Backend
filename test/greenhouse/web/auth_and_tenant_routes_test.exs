defmodule Greenhouse.Web.AuthAndTenantRoutesTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Greenhouse.{AccountStore, Storage}
  alias Greenhouse.Web.Router

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

  test "auth login, me, logout, and user device CRUD enforce tenant isolation" do
    # Unauthenticated
    assert Router.call(conn(:get, "/api/v1/auth/me")).status == 401
    assert Router.call(conn(:get, "/api/v1/user/devices")).status == 401

    # Missing credentials -> 400
    assert Router.call(
             conn(:post, "/api/v1/auth/login", %{"username" => "   ", "password" => ""})
           ).status == 400

    # Login as alice
    login_conn =
      Router.call(
        conn(:post, "/api/v1/auth/login", %{"username" => "alice", "password" => "alice123"})
      )

    assert login_conn.status == 200
    login_data = JSON.decode!(login_conn.resp_body)["data"]
    alice_token = login_data["token"]
    assert login_data["user"]["username"] == "alice"

    # /me via Bearer header (including lowercase bearer scheme)
    me_conn =
      conn(:get, "/api/v1/auth/me")
      |> put_req_header("authorization", "bearer #{alice_token}")
      |> Router.call()

    assert me_conn.status == 200
    assert JSON.decode!(me_conn.resp_body)["data"]["user"]["id"] == "user-alice"

    # Alice lists only GH-0001
    list_conn =
      conn(:get, "/api/v1/user/devices")
      |> put_req_header("authorization", "Bearer #{alice_token}")
      |> Router.call()

    assert list_conn.status == 200
    devices = JSON.decode!(list_conn.resp_body)["data"]
    assert Enum.map(devices, & &1["device_id"]) == ["GH-0001"]
    assert hd(devices)["simulated"] == true

    # Alice forbidden from GH-0002
    forbidden_conn =
      conn(:get, "/api/v1/user/devices/GH-0002")
      |> put_req_header("x-session-token", alice_token)
      |> Router.call()

    assert forbidden_conn.status == 403

    # Register new user and verify empty list + bind unknown GH-0003 + 409 on GH-0001
    reg_conn =
      Router.call(
        conn(:post, "/api/v1/auth/register", %{
          "username" => "tester_01",
          "password" => "pass1234"
        })
      )

    assert reg_conn.status == 201
    tester_token = JSON.decode!(reg_conn.resp_body)["data"]["token"]

    conflict_conn =
      conn(:post, "/api/v1/user/devices", %{"deviceId" => "GH-0001"})
      |> put_req_header("authorization", "Bearer #{tester_token}")
      |> Router.call()

    assert conflict_conn.status == 409

    bind_conn =
      conn(:post, "/api/v1/user/devices", %{
        "deviceId" => "GH-0003",
        "name" => "3号试验棚",
        "notes" => "初始备注"
      })
      |> put_req_header("authorization", "Bearer #{tester_token}")
      |> Router.call()

    assert bind_conn.status == 201
    bind_snap = JSON.decode!(bind_conn.resp_body)["data"]
    assert bind_snap["device_id"] == "GH-0003"
    assert bind_snap["simulated"] == false
    assert bind_snap["online"] == false
    assert bind_snap["latest_telemetry"] == nil
    assert bind_snap["config"]["raw"] == %{}

    # Update binding
    patch_conn =
      conn(:patch, "/api/v1/user/devices/GH-0003", %{"notes" => "已更新备注"})
      |> put_req_header("authorization", "Bearer #{tester_token}")
      |> Router.call()

    assert patch_conn.status == 200
    assert JSON.decode!(patch_conn.resp_body)["data"]["notes"] == "已更新备注"

    # Delete binding
    del_conn =
      conn(:delete, "/api/v1/user/devices/GH-0003")
      |> put_req_header("authorization", "Bearer #{tester_token}")
      |> Router.call()

    assert del_conn.status == 200
    assert JSON.decode!(del_conn.resp_body)["data"]["unbound"] == true

    # Logout invalidates session
    logout_conn =
      conn(:post, "/api/v1/auth/logout")
      |> put_req_header("authorization", "Bearer #{tester_token}")
      |> Router.call()

    assert logout_conn.status == 200

    unauth_after_logout =
      conn(:get, "/api/v1/auth/me")
      |> put_req_header("authorization", "Bearer #{tester_token}")
      |> Router.call()

    assert unauth_after_logout.status == 401
  end

  test "simulate endpoint, dev reset, and config cache_fallback=true work as expected" do
    # Simulate GH-0001 succeeds (v2 + b + reboot rotation), GH-0002 fails 400
    sim_ok =
      Router.call(conn(:post, "/api/v1/devices/GH-0001/simulate", %{"scenario" => "hot"}))

    assert sim_ok.status == 200
    sim_data = JSON.decode!(sim_ok.resp_body)["data"]
    first_b = sim_data["status"]["b"]
    assert Regex.match?(~r/^[0-9a-f]{8}$/, first_b)
    assert sim_data["latest_telemetry"]["v"] == 2
    assert sim_data["latest_telemetry"]["b"] == first_b
    assert is_binary(sim_data["latest_telemetry"]["received_at"])
    assert is_binary(sim_data["status"]["updated_at"])
    assert sim_data["latest_telemetry"]["fan"] == 1

    sim_offline =
      Router.call(conn(:post, "/api/v1/devices/GH-0001/simulate", %{"scenario" => "offline"}))

    assert sim_offline.status == 200
    assert JSON.decode!(sim_offline.resp_body)["data"]["online"] == false

    sim_reboot =
      Router.call(conn(:post, "/api/v1/devices/GH-0001/simulate", %{"scenario" => "normal"}))

    assert sim_reboot.status == 200
    reboot_data = JSON.decode!(sim_reboot.resp_body)["data"]
    assert reboot_data["online"] == true
    assert reboot_data["status"]["b"] != first_b
    assert reboot_data["latest_telemetry"]["b"] == reboot_data["status"]["b"]
    assert reboot_data["latest_telemetry"]["seq"] == 0

    sim_err =
      Router.call(conn(:post, "/api/v1/devices/GH-0002/simulate", %{"scenario" => "normal"}))

    assert sim_err.status == 400
    assert JSON.decode!(sim_err.resp_body)["error"] == "not_simulated_device"

    # Config without cache_fallback=true still returns 503 when MQTT is disconnected
    no_fallback_conn =
      Router.call(
        conn(:patch, "/api/v1/devices/GH-0003/config?unit=human", %{
          "tMin" => 18.0,
          "tMax" => 28.0,
          "tHys" => 1.5
        })
      )

    assert no_fallback_conn.status == 503

    # Config with cache_fallback=true validates and updates storage cache
    invalid_fallback_conn =
      Router.call(
        conn(:patch, "/api/v1/devices/GH-0003/config?unit=human&cache_fallback=true", %{
          "tMin" => 35.0,
          "tMax" => 25.0
        })
      )

    assert invalid_fallback_conn.status == 422

    valid_fallback_conn =
      Router.call(
        conn(:patch, "/api/v1/devices/GH-0003/config?unit=human&cache_fallback=true", %{
          "tMin" => 18.5,
          "tMax" => 28.5,
          "tHys" => 1.5
        })
      )

    assert valid_fallback_conn.status == 200
    fb_body = JSON.decode!(valid_fallback_conn.resp_body)
    assert fb_body["simulated_ack"] == true
    assert fb_body["data"]["raw"]["tMin"] == 1850
    assert fb_body["data"]["human"]["tMin"] == 18.5

    # Partial patch via cache_fallback cross-validates against stored raw config
    cross_invalid_conn =
      Router.call(
        conn(:patch, "/api/v1/devices/GH-0003/config?unit=human&cache_fallback=true", %{
          "tMax" => 15.0
        })
      )

    assert cross_invalid_conn.status == 422

    # Reset demo cleans up GH-0003 config cache and restores GH-0001
    reset_conn = Router.call(conn(:post, "/api/v1/dev/reset"))
    assert reset_conn.status == 200
    assert {:ok, %{raw: %{}}} = Storage.get_config("GH-0003")
    assert {:ok, _} = Storage.get_device("GH-0001")
  end
end
