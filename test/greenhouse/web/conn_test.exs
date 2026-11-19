defmodule Greenhouse.Web.ConnTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Greenhouse.Web.{Params, Respond}

  describe "Greenhouse.Web.Respond" do
    test "json/3 sets status, utf-8 content-type, body, halts, and preserves custom headers" do
      conn =
        conn(:get, "/")
        |> put_resp_header("x-custom-header", "value")
        |> Respond.json(201, %{ok: true, count: 3})

      assert conn.status == 201
      assert conn.halted == true
      assert get_resp_header(conn, "x-custom-header") == ["value"]
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert JSON.decode!(conn.resp_body) == %{"ok" => true, "count" => 3}
    end

    test "decode_json_object/1 and decode_json_object!/1 validate JSON objects" do
      assert Respond.decode_json_object("") == {:ok, %{}}
      assert Respond.decode_json_object("   \r\n\t ") == {:ok, %{}}
      assert Respond.decode_json_object(~s({"tMin":1000})) == {:ok, %{"tMin" => 1000}}
      assert Respond.decode_json_object("{invalid") == {:error, :invalid_json}
      assert Respond.decode_json_object("[1, 2]") == {:error, :invalid_json}
      assert Respond.decode_json_object("123") == {:error, :invalid_json}

      assert Respond.decode_json_object!("") == %{}
      assert Respond.decode_json_object!(~s({"tMin":1000})) == %{"tMin" => 1000}

      assert_raise ArgumentError, fn ->
        Respond.decode_json_object!("[1, 2]")
      end
    end

    test "req_header/2 reads lowercase and mixed-case headers cleanly" do
      conn1 = conn(:get, "/") |> put_req_header("authorization", "Bearer tok")
      assert Respond.req_header(conn1, "authorization") == "Bearer tok"
      assert Respond.req_header(conn1, "x-missing") == nil

      conn2 = %Plug.Conn{req_headers: [{"Content-Type", "application/json"}]}
      assert Respond.req_header(conn2, "content-type") == "application/json"
    end
  end

  describe "Greenhouse.Web.Params" do
    test "put_path_params/2 attaches path params and safely handles unfetched conn.params" do
      unfetched_conn = %Plug.Conn{}
      updated = Params.put_path_params(unfetched_conn, %{"device_id" => "GH-0001"})
      assert updated.path_params == %{"device_id" => "GH-0001"}
      assert updated.params == %{"device_id" => "GH-0001"}

      with_params = %{conn(:get, "/?limit=5") | params: %{"limit" => "5"}}
      merged = Params.put_path_params(with_params, %{"device_id" => "GH-0001"})
      assert merged.params == %{"limit" => "5", "device_id" => "GH-0001"}
    end

    test "parse_history_opts/1, parse_bool_param/1, and unit helpers handle edge inputs" do
      assert Params.parse_history_opts(%{
               "from" => "1000",
               "to" => "2026-01-01T00:00:00Z",
               "limit" => "0",
               "offset" => "-1",
               "order" => "ASC"
             }) == [order: :asc, to: "2026-01-01T00:00:00Z", from: 1000]

      assert Params.parse_history_opts(%{"limit" => "25", "offset" => "0", "order" => "desc"}) ==
               [order: :desc, offset: 0, limit: 25]

      assert Params.parse_bool_param("TRUE") == true
      assert Params.parse_bool_param(" false ") == false
      assert Params.parse_bool_param(true) == true
      assert Params.parse_bool_param(nil) == false

      assert Params.parse_unit_opts(%{"unit" => "HUMAN"}, %{}) == [unit: :human]
      assert Params.parse_unit_opts(%{}, %{unit: :human}) == [unit: :human]
      assert Params.parse_unit_opts(%{}, %{}) == []

      assert Params.strip_unit_param(%{"unit" => "human", :unit => :human, "tMin" => 20}) == %{
               "tMin" => 20
             }
    end

    test "Params handles integer, atom, and unexpected non-binary query values safely" do
      assert Params.parse_history_opts(%{
               "from" => 1_000,
               "to" => 2_000,
               "limit" => 10,
               "offset" => 5,
               "order" => :asc
             }) == [order: :asc, offset: 5, limit: 10, to: 2_000, from: 1_000]

      assert Params.parse_history_opts(%{
               "from" => :invalid,
               "to" => %{},
               "limit" => 0,
               "offset" => -3,
               "order" => 123
             }) == []

      assert Params.parse_time_range_opts(%{"from" => 500, "to" => :invalid}) == [from: 500]

      assert Params.parse_history_opts(%{
               "from" => "1000",
               "b" => " 7F3A91C4 ",
               "limit" => "5"
             }) == [limit: 5, b: "7F3A91C4", from: 1000]

      assert Params.parse_stats_opts(%{"from" => "1000", "to" => "2000", "b" => "1c04be77"}) == [
               b: "1c04be77",
               to: 2000,
               from: 1000
             ]

      assert Params.parse_stats_opts(%{"b" => "   ", "from" => 100}) == [from: 100]
      assert Params.parse_stats_opts(%{"b" => 123}) == []
    end
  end
end
