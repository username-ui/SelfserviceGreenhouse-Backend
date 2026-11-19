defmodule Greenhouse.Web.Router do
  @moduledoc """
  HTTP request router built on `Plug.Router` for the Greenhouse REST API.

  Applies CORS headers to every response, validates body size and JSON object
  payloads, and dispatches requests to `Greenhouse.Web.Handlers`.
  """

  use Plug.Router, copy_opts_to_assign: :greenhouse_opts

  import Plug.Conn

  alias Greenhouse.Web.Respond
  alias Greenhouse.Web.Handlers.{Auth, Devices, UserDevices}

  @max_body_bytes 1_048_576
  @json_methods ~w(POST PUT PATCH)
  @parser_methods ~w(POST PUT PATCH DELETE)

  @cors_headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS"},
    {"access-control-allow-headers", "Content-Type, Authorization"}
  ]

  @parsers_opts Plug.Parsers.init(
                  parsers: [{:json, json_decoder: {Respond, :decode_json_object!, []}}],
                  pass: ["*/*"],
                  length: @max_body_bytes
                )

  @typedoc "Dependency injection options accepted by router and Web handlers."
  @type handler_option ::
          {:storage, module()}
          | {:config_manager, Greenhouse.server_ref()}
          | {:account_store, module()}
          | {:mqtt_client, Greenhouse.server_ref()}

  plug :attach_cors_headers
  plug :handle_cors_preflight
  plug :reject_oversized_content_length
  plug :parse_body
  plug :match
  plug :dispatch

  @doc """
  Routes a `%Plug.Conn{}` using default router options (`[]`).
  """
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn), do: call(conn, [])

  @doc """
  Applies standard CORS headers onto `conn`.
  """
  @spec put_cors_headers(Plug.Conn.t()) :: Plug.Conn.t()
  def put_cors_headers(%Plug.Conn{} = conn) do
    merge_resp_headers(conn, @cors_headers)
  end

  # CORS preflight (including `OPTIONS *`) is handled before `:match` so it works
  # uniformly across all paths without parsing or reading a request body.
  @spec attach_cors_headers(Plug.Conn.t(), term()) :: Plug.Conn.t()
  defp attach_cors_headers(%Plug.Conn{} = conn, _opts) do
    register_before_send(conn, &put_cors_headers/1)
  end

  @spec handle_cors_preflight(Plug.Conn.t(), term()) :: Plug.Conn.t()
  defp handle_cors_preflight(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> send_resp(204, "")
    |> halt()
  end

  defp handle_cors_preflight(%Plug.Conn{} = conn, _opts), do: conn

  # Reject oversized `Content-Length` before `Bandit` tries to read or drain it,
  # and force `connection: close` so keep-alive loops terminate cleanly.
  @spec reject_oversized_content_length(Plug.Conn.t(), term()) :: Plug.Conn.t()
  defp reject_oversized_content_length(%Plug.Conn{} = conn, _opts) do
    case Respond.req_header(conn, "content-length") do
      nil ->
        conn

      raw_len when is_binary(raw_len) ->
        case Integer.parse(String.trim(raw_len)) do
          {len, ""} when len > @max_body_bytes ->
            payload_too_large(conn)

          _ ->
            conn
        end
    end
  end

  @spec parse_body(Plug.Conn.t(), term()) :: Plug.Conn.t()
  defp parse_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn, _opts) do
    has_json_ct = has_json_content_type?(conn)

    cond do
      conn.method in @parser_methods and has_json_ct ->
        run_plug_parsers(conn)

      conn.method in @json_methods or has_json_ct ->
        parse_untyped_or_get_json(conn)

      true ->
        run_plug_parsers(conn)
    end
  end

  defp parse_body(%Plug.Conn{} = conn, _opts), do: run_plug_parsers(conn)

  @spec run_plug_parsers(Plug.Conn.t()) :: Plug.Conn.t()
  defp run_plug_parsers(%Plug.Conn{} = conn) do
    Plug.Parsers.call(conn, @parsers_opts)
  rescue
    Plug.Parsers.RequestTooLargeError ->
      payload_too_large(conn)

    Plug.Parsers.ParseError ->
      Respond.json(conn, 400, %{ok: false, error: "invalid_json"})
  end

  @spec parse_untyped_or_get_json(Plug.Conn.t()) :: Plug.Conn.t()
  defp parse_untyped_or_get_json(%Plug.Conn{} = conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        case Respond.decode_json_object(body) do
          {:ok, decoded} ->
            conn
            |> Map.put(:body_params, decoded)
            |> run_plug_parsers()

          {:error, :invalid_json} ->
            Respond.json(conn, 400, %{ok: false, error: "invalid_json"})
        end

      {:more, _partial, conn} ->
        payload_too_large(conn)

      {:error, _reason} ->
        Respond.json(conn, 400, %{ok: false, error: "invalid_json"})
    end
  end

  @spec has_json_content_type?(Plug.Conn.t()) :: boolean()
  defp has_json_content_type?(%Plug.Conn{} = conn) do
    case Respond.req_header(conn, "content-type") do
      ct when is_binary(ct) -> String.contains?(String.downcase(ct), "application/json")
      _ -> false
    end
  end

  @spec payload_too_large(Plug.Conn.t()) :: Plug.Conn.t()
  defp payload_too_large(%Plug.Conn{} = conn) do
    conn
    |> put_resp_header("connection", "close")
    |> Respond.json(413, %{ok: false, error: "payload_too_large"})
  end

  @spec router_opts(Plug.Conn.t()) :: [handler_option()]
  defp router_opts(%Plug.Conn{assigns: assigns}),
    do: Map.get(assigns, :greenhouse_opts, [])

  # Health
  get "/health", do: Devices.health(conn, router_opts(conn))
  get "/api/v1/health", do: Devices.health(conn, router_opts(conn))

  # Authentication
  post "/api/v1/auth/login", do: Auth.login(conn, router_opts(conn))
  post "/api/v1/auth/register", do: Auth.register(conn, router_opts(conn))
  post "/api/v1/auth/logout", do: Auth.logout(conn, router_opts(conn))
  get "/api/v1/auth/me", do: Auth.me(conn, router_opts(conn))

  # User-bound devices
  get "/api/v1/user/devices", do: UserDevices.index(conn, router_opts(conn))
  post "/api/v1/user/devices", do: UserDevices.create(conn, router_opts(conn))
  get "/api/v1/user/devices/:device_id", do: UserDevices.show(conn, device_id, router_opts(conn))

  match "/api/v1/user/devices/:device_id",
    via: [:patch, :put],
    do: UserDevices.update(conn, device_id, router_opts(conn))

  delete "/api/v1/user/devices/:device_id",
    do: UserDevices.delete(conn, device_id, router_opts(conn))

  # Development utilities
  post "/api/v1/dev/reset", do: Devices.dev_reset(conn, router_opts(conn))

  # Devices, telemetry, alarms, config, simulation
  get "/api/v1/devices", do: Devices.list_devices(conn, router_opts(conn))
  get "/api/v1/devices/:device_id", do: Devices.show_device(conn, device_id, router_opts(conn))

  get "/api/v1/devices/:device_id/status",
    do: Devices.show_status(conn, device_id, router_opts(conn))

  get "/api/v1/devices/:device_id/telemetry/latest",
    do: Devices.latest_telemetry(conn, device_id, router_opts(conn))

  get "/api/v1/devices/:device_id/telemetry/current",
    do: Devices.latest_telemetry(conn, device_id, router_opts(conn))

  get "/api/v1/devices/:device_id/telemetry",
    do: Devices.telemetry_history(conn, device_id, router_opts(conn))

  get "/api/v1/devices/:device_id/telemetry/history",
    do: Devices.telemetry_history(conn, device_id, router_opts(conn))

  get "/api/v1/devices/:device_id/telemetry/stats",
    do: Devices.telemetry_stats(conn, device_id, router_opts(conn))

  get "/api/v1/devices/:device_id/alarms",
    do: Devices.list_alarms(conn, device_id, router_opts(conn))

  post "/api/v1/devices/:device_id/alarms/:code/clear",
    do: Devices.clear_alarm(conn, device_id, code, router_opts(conn))

  delete "/api/v1/devices/:device_id/alarms/:code",
    do: Devices.clear_alarm(conn, device_id, code, router_opts(conn))

  get "/api/v1/devices/:device_id/config",
    do: Devices.show_config(conn, device_id, router_opts(conn))

  match "/api/v1/devices/:device_id/config",
    via: [:patch, :put, :post],
    do: Devices.update_config(conn, device_id, router_opts(conn))

  post "/api/v1/devices/:device_id/simulate",
    do: Devices.simulate(conn, device_id, router_opts(conn))

  match _ do
    Respond.json(conn, 404, %{ok: false, error: "route_not_found"})
  end
end
