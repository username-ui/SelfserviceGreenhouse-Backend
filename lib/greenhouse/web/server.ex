defmodule Greenhouse.Web.Server do
  @moduledoc """
  HTTP server lifecycle wrapper around `Bandit` and `ThousandIsland`.

  Starts and supervises the HTTP/1.1 listener for `Greenhouse.Web.Router` (or a
  custom `:plug` / `:router` in tests) and exposes helpers to inspect the bound
  port and stop the supervisor cleanly.
  """

  @default_http_1_options [max_header_count: 64, max_header_length: 16_384]

  @typedoc "Supervisor reference for a running `Bandit` HTTP server."
  @type server :: Supervisor.supervisor()

  @typedoc "IP address option accepted by `child_spec/1` and `start_link/1`."
  @type ip_opt :: String.t() | :inet.ip_address() | :loopback | :any | nil

  @typedoc "Server options accepted by `child_spec/1` and `start_link/1`."
  @type option ::
          {:plug, module()}
          | {:router, module()}
          | {:scheme, :http | :https}
          | {:port, :inet.port_number()}
          | {:ip, ip_opt()}
          | {:name, atom() | nil}
          | {:http_1_options, keyword()}
          | {:thousand_island_options, keyword()}
          | {:http_options, keyword() | nil}
          | {:startup_log, boolean() | atom() | nil}

  @doc """
  Returns the `Bandit` supervisor child specification for `opts`.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts \\ []) when is_list(opts) do
    opts
    |> build_bandit_opts()
    |> Bandit.child_spec()
  end

  @doc """
  Starts the `Bandit` HTTP server linked to the calling process.
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    opts
    |> build_bandit_opts()
    |> Bandit.start_link()
  end

  @doc """
  Returns the TCP port the listener is currently bound to.
  """
  @spec port(server()) :: :inet.port_number()
  def port(server \\ __MODULE__) do
    case ThousandIsland.listener_info(server) do
      {:ok, {_address, port}} ->
        port

      :error ->
        raise "unable to read listener port for #{inspect(server)}"
    end
  end

  @doc """
  Stops the running `Bandit` server supervisor cleanly.
  """
  @spec stop(server(), term(), timeout()) :: :ok
  def stop(server \\ __MODULE__, reason \\ :normal, timeout \\ 5_000) do
    Supervisor.stop(server, reason, timeout)
  end

  @spec build_bandit_opts([option()]) :: keyword()
  defp build_bandit_opts(opts) when is_list(opts) do
    plug = Keyword.get(opts, :plug) || Keyword.get(opts, :router, Greenhouse.Web.Router)

    http_1_options =
      Keyword.merge(@default_http_1_options, Keyword.get(opts, :http_1_options, []))

    thousand_island_options = build_thousand_island_options(opts)

    [
      plug: plug,
      scheme: Keyword.get(opts, :scheme, :http),
      port: Keyword.get(opts, :port, 4000),
      http_1_options: http_1_options,
      thousand_island_options: thousand_island_options
    ]
    |> maybe_put(:ip, parse_ip(Keyword.get(opts, :ip)))
    |> maybe_put(:startup_log, Keyword.get(opts, :startup_log))
    |> maybe_put(:http_options, Keyword.get(opts, :http_options))
  end

  @spec build_thousand_island_options([option()]) :: keyword()
  defp build_thousand_island_options(opts) when is_list(opts) do
    base = Keyword.get(opts, :thousand_island_options, [])

    case Keyword.get(opts, :name, __MODULE__) do
      nil ->
        base

      name when is_atom(name) ->
        supervisor_opts =
          base
          |> Keyword.get(:supervisor_options, [])
          |> Keyword.put_new(:name, name)

        Keyword.put(base, :supervisor_options, supervisor_opts)
    end
  end

  @spec parse_ip(ip_opt()) :: :inet.ip_address() | :loopback | :any | nil
  defp parse_ip(nil), do: nil
  defp parse_ip(ip) when ip in [:loopback, :any], do: ip
  defp parse_ip(ip) when is_tuple(ip), do: ip

  defp parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, address} -> address
      {:error, _reason} -> raise ArgumentError, "invalid IP address: #{inspect(ip)}"
    end
  end

  @spec maybe_put(
          nonempty_list({atom(), term()}),
          :ip | :startup_log | :http_options,
          term()
        ) :: nonempty_list({atom(), term()})
  defp maybe_put(opts, _key, nil) when is_list(opts), do: opts

  defp maybe_put(opts, key, value) when is_list(opts) and is_atom(key),
    do: Keyword.put(opts, key, value)
end
