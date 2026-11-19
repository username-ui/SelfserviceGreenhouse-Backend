defmodule Greenhouse.Web.Handlers.Auth do
  @moduledoc """
  HTTP handlers for session authentication (`/api/v1/auth/*`) and bearer token extraction.
  """

  alias Greenhouse.Support
  alias Greenhouse.Web.{Respond, Router}

  @typedoc "Handler dependency injection options."
  @type options :: [Router.handler_option()]

  @doc """
  Handles `POST /api/v1/auth/login`.
  """
  @spec login(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def login(%Plug.Conn{} = conn, opts) when is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)
    username = Support.get_body_string(conn.body_params, "username")
    password = Support.get_body_string(conn.body_params, "password")

    if String.trim(username) == "" or password == "" do
      Respond.json(conn, 400, %{
        ok: false,
        error: "invalid_credentials",
        message: "请输入用户名和密码"
      })
    else
      case account_store.verify_credentials(username, password) do
        {:ok, user} ->
          {:ok, token} = account_store.create_session(user.id)
          Respond.json(conn, 200, %{ok: true, data: %{user: user, token: token}})

        {:error, :invalid_credentials} ->
          Respond.json(conn, 401, %{
            ok: false,
            error: "invalid_credentials",
            message: "用户名或密码错误"
          })
      end
    end
  end

  @doc """
  Handles `POST /api/v1/auth/register`.
  """
  @spec register(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def register(%Plug.Conn{} = conn, opts) when is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)

    case account_store.register_user(conn.body_params) do
      {:ok, payload} ->
        Respond.json(conn, 201, %{ok: true, data: payload})

      {:error, status, error_code, message} ->
        Respond.json(conn, status, %{ok: false, error: error_code, message: message})
    end
  end

  @doc """
  Handles `POST /api/v1/auth/logout`.
  """
  @spec logout(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def logout(%Plug.Conn{} = conn, opts) when is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)

    case extract_session_token(conn) do
      nil -> :ok
      token -> account_store.delete_session(token)
    end

    Respond.json(conn, 200, %{ok: true})
  end

  @doc """
  Handles `GET /api/v1/auth/me`.
  """
  @spec me(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def me(%Plug.Conn{} = conn, opts) when is_list(opts) do
    with {:ok, user, _token} <- require_auth(conn, opts) do
      Respond.json(conn, 200, %{ok: true, data: %{user: user}})
    else
      {:error, resp_conn} -> resp_conn
    end
  end

  @doc """
  Authenticates the caller using `Authorization: Bearer ...` or `X-Session-Token`.
  """
  @spec require_auth(Plug.Conn.t(), options()) ::
          {:ok, map(), Greenhouse.session_token()} | {:error, Plug.Conn.t()}
  def require_auth(%Plug.Conn{} = conn, opts) when is_list(opts) do
    account_store = Keyword.get(opts, :account_store, Greenhouse.AccountStore)

    case extract_session_token(conn) do
      nil ->
        {:error, Respond.json(conn, 401, %{ok: false, error: "unauthorized", message: "请先登录"})}

      token ->
        case account_store.get_session_user(token) do
          {:ok, user} ->
            {:ok, user, token}

          {:error, :unauthorized} ->
            {:error,
             Respond.json(conn, 401, %{ok: false, error: "unauthorized", message: "请先登录"})}
        end
    end
  end

  @doc """
  Extracts a session token from `authorization` or `x-session-token` request headers.
  """
  @spec extract_session_token(Plug.Conn.t() | term()) :: Greenhouse.session_token() | nil
  def extract_session_token(%Plug.Conn{req_headers: headers} = conn) when is_list(headers) do
    case Respond.req_header(conn, "authorization") do
      val when is_binary(val) ->
        case extract_bearer_token(val) do
          nil -> extract_header_token(conn)
          token -> token
        end

      _ ->
        extract_header_token(conn)
    end
  end

  def extract_session_token(_), do: nil

  @spec extract_header_token(Plug.Conn.t()) :: String.t() | nil
  defp extract_header_token(%Plug.Conn{} = conn) do
    conn
    |> Respond.req_header("x-session-token")
    |> normalize_non_empty()
  end

  @spec extract_bearer_token(String.t()) :: String.t() | nil
  defp extract_bearer_token(<<"Bearer ", rest::binary>>), do: normalize_non_empty(rest)
  defp extract_bearer_token(<<"bearer ", rest::binary>>), do: normalize_non_empty(rest)

  defp extract_bearer_token(raw) when is_binary(raw) do
    case Regex.run(~r/^bearer\s+(.+)$/i, String.trim(raw)) do
      [_, token] -> normalize_non_empty(token)
      _ -> nil
    end
  end

  @spec normalize_non_empty(String.t() | {integer(), integer()} | nil) :: String.t() | nil
  defp normalize_non_empty(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_non_empty(_), do: nil
end
