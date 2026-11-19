defmodule Greenhouse.Web.Handlers.UserDevices do
  @moduledoc """
  HTTP handlers for tenant-scoped user device bindings (`/api/v1/user/devices*`).
  """

  alias Greenhouse.Web.{Params, Respond, Router}
  alias Greenhouse.Web.Handlers.Auth

  @typedoc "Handler dependency injection options."
  @type options :: [Router.handler_option()]

  @doc """
  Handles `GET /api/v1/user/devices`.
  """
  @spec index(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def index(%Plug.Conn{} = conn, opts) when is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)

    with {:ok, user, _token} <- Auth.require_auth(conn, opts) do
      snapshots =
        user.id
        |> account_store.list_user_bindings()
        |> Enum.map(&account_store.build_user_device_snapshot/1)

      Respond.json(conn, 200, %{ok: true, data: snapshots})
    else
      {:error, resp_conn} -> resp_conn
    end
  end

  @doc """
  Handles `POST /api/v1/user/devices`.
  """
  @spec create(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def create(%Plug.Conn{} = conn, opts) when is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)

    with {:ok, user, _token} <- Auth.require_auth(conn, opts) do
      case account_store.bind_device(user.id, conn.body_params) do
        {:ok, binding} ->
          snapshot = account_store.build_user_device_snapshot(binding)
          Respond.json(conn, 201, %{ok: true, data: snapshot})

        {:error, status, error_code, message} ->
          Respond.json(conn, status, %{ok: false, error: error_code, message: message})
      end
    else
      {:error, resp_conn} -> resp_conn
    end
  end

  @doc """
  Handles `GET /api/v1/user/devices/:device_id`.
  """
  @spec show(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def show(%Plug.Conn{} = conn, device_id, opts) when is_binary(device_id) and is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})

    with {:ok, user, _token} <- Auth.require_auth(conn, opts) do
      case account_store.get_user_binding(user.id, device_id) do
        {:ok, binding} ->
          Respond.json(conn, 200, %{
            ok: true,
            data: account_store.build_user_device_snapshot(binding)
          })

        {:error, :not_found} ->
          forbidden_response(conn)
      end
    else
      {:error, resp_conn} -> resp_conn
    end
  end

  @doc """
  Handles `PATCH / PUT /api/v1/user/devices/:device_id`.
  """
  @spec update(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def update(%Plug.Conn{} = conn, device_id, opts) when is_binary(device_id) and is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})

    with {:ok, user, _token} <- Auth.require_auth(conn, opts) do
      case account_store.update_binding(user.id, device_id, conn.body_params) do
        {:ok, updated_binding} ->
          Respond.json(conn, 200, %{ok: true, data: updated_binding})

        {:error, :forbidden} ->
          forbidden_response(conn)

        {:error, status, error_code, message} ->
          Respond.json(conn, status, %{ok: false, error: error_code, message: message})
      end
    else
      {:error, resp_conn} -> resp_conn
    end
  end

  @doc """
  Handles `DELETE /api/v1/user/devices/:device_id`.
  """
  @spec delete(Plug.Conn.t(), Greenhouse.device_id(), options()) :: Plug.Conn.t()
  def delete(%Plug.Conn{} = conn, device_id, opts) when is_binary(device_id) and is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)
    conn = Params.put_path_params(conn, %{"device_id" => device_id})

    with {:ok, user, _token} <- Auth.require_auth(conn, opts) do
      case account_store.unbind_device(user.id, device_id) do
        :ok ->
          Respond.json(conn, 200, %{
            ok: true,
            data: %{deviceId: account_store.normalize_device_id(device_id), unbound: true}
          })

        {:error, :forbidden} ->
          forbidden_response(conn)
      end
    else
      {:error, resp_conn} -> resp_conn
    end
  end

  @spec forbidden_response(Plug.Conn.t()) :: Plug.Conn.t()
  defp forbidden_response(%Plug.Conn{} = conn) do
    Respond.json(conn, 403, %{
      ok: false,
      error: "forbidden",
      message: "无权访问或操作该设备"
    })
  end
end
