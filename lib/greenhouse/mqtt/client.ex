defmodule Greenhouse.MQTT.Client do
  @moduledoc """
  Managed MQTT 3.1.1 TCP client built on `:emqtt`.

  Features:
  - Plaintext TCP connection with MQTT 3.1.1 (`proto_ver: :v4`), optional
    username/password authentication, and unique `client_id`
  - Automatic QoS 1 subscriptions to all `PROTOCOL.md` device topics upon
    successful `CONNACK(0)`
  - Routing incoming `PUBLISH` messages to `Greenhouse.MQTT.Handler` with
    crash protection and automatic QoS 1 `PUBACK` handled by `:emqtt`
  - Exponential backoff reconnect on connection failure, broker rejection,
    or socket disconnect
  - Memory-conscious defaults (`low_mem: true` on `:emqtt` and idle
    hibernation on this coordinator process)
  """

  use GenServer
  require Logger

  @subscribe_topics [
    {"gh/+/telemetry", 1},
    {"gh/+/alarm/#", 1},
    {"gh/+/status", 1},
    {"gh/+/config/ack", 1}
  ]

  @default_keep_alive 60
  @default_connect_timeout_ms 5_000
  @default_initial_backoff_ms 1_000
  @default_max_backoff_ms 60_000
  @default_hibernate_after_ms 15_000

  @typedoc "Supported MQTT QoS level values."
  @type qos :: 0 | 1 | 2 | :qos0 | :qos1 | :qos2

  @typedoc "Publish options accepted by `publish/3` and `publish/4`."
  @type publish_option :: {:qos, qos()} | {:retain, boolean()}

  @typedoc "Startup options accepted by `start_link/1`."
  @type option ::
          {:name, GenServer.name() | nil}
          | {:enabled, boolean()}
          | {:host, String.t() | charlist() | :inet.ip_address()}
          | {:port, :inet.port_number()}
          | {:username, String.t() | nil}
          | {:password, String.t() | nil}
          | {:client_id, String.t() | nil}
          | {:keep_alive, non_neg_integer()}
          | {:ping_interval_ms, pos_integer()}
          | {:force_ping, boolean()}
          | {:connect_timeout_ms, pos_integer()}
          | {:initial_backoff_ms, pos_integer()}
          | {:max_backoff_ms, pos_integer()}
          | {:handler_mod, module()}
          | {:config_manager, Greenhouse.server_ref() | nil}
          | {:low_mem, boolean()}
          | {:hibernate_after_ms, pos_integer()}

  @typedoc "Public connection status snapshot returned by `status/1`."
  @type status :: %{
          connected: boolean(),
          host: String.t(),
          port: :inet.port_number(),
          client_id: String.t(),
          reconnect_attempts: non_neg_integer()
        }

  @enforce_keys [
    :enabled,
    :host,
    :port,
    :client_id,
    :keep_alive,
    :force_ping,
    :connect_timeout_ms,
    :initial_backoff_ms,
    :max_backoff_ms,
    :current_backoff_ms,
    :reconnect_attempts,
    :handler_mod,
    :low_mem,
    :connected
  ]
  defstruct [
    :enabled,
    :host,
    :port,
    :username,
    :password,
    :client_id,
    :keep_alive,
    :force_ping,
    :connect_timeout_ms,
    :initial_backoff_ms,
    :max_backoff_ms,
    :current_backoff_ms,
    :reconnect_attempts,
    :reconnect_timer,
    :handler_mod,
    :config_manager,
    :low_mem,
    :emqtt_pid,
    :connector_pid,
    :connector_ref,
    :connected
  ]

  @typedoc "Internal GenServer state struct for `Greenhouse.MQTT.Client`."
  @type state :: %__MODULE__{
          enabled: boolean(),
          host: String.t(),
          port: :inet.port_number(),
          username: String.t() | nil,
          password: String.t() | nil,
          client_id: String.t(),
          keep_alive: non_neg_integer(),
          force_ping: boolean(),
          connect_timeout_ms: pos_integer(),
          initial_backoff_ms: pos_integer(),
          max_backoff_ms: pos_integer(),
          current_backoff_ms: pos_integer(),
          reconnect_attempts: non_neg_integer(),
          reconnect_timer: reference() | nil,
          handler_mod: module(),
          config_manager: Greenhouse.server_ref() | nil,
          low_mem: boolean(),
          emqtt_pid: pid() | nil,
          connector_pid: pid() | nil,
          connector_ref: reference() | nil,
          connected: boolean()
        }

  @doc """
  Starts the `Greenhouse.MQTT.Client` GenServer.

  Options:
  - `:name` - registered process name (`__MODULE__` by default, `nil` for unnamed)
  - `:enabled` - whether to actively maintain an MQTT TCP connection (default `false`)
  - `:host` - broker hostname or IP (default `"mqtt.example.com"`)
  - `:port` - broker TCP port (default `1883`)
  - `:username` - optional MQTT username
  - `:password` - optional MQTT password
  - `:client_id` - MQTT client identifier (defaults to `"greenhouse-backend-<os_pid>-<uniq>"`)
  - `:keep_alive` - MQTT keep-alive interval in seconds (default `60`)
  - `:ping_interval_ms` - legacy millisecond keep-alive override (converted to whole seconds)
  - `:force_ping` - whether `:emqtt` always sends `PINGREQ` every keep-alive tick (default `false`)
  - `:connect_timeout_ms` - TCP/CONNACK timeout in ms (default `5_000`)
  - `:initial_backoff_ms` - initial reconnect backoff delay in ms (default `1_000`)
  - `:max_backoff_ms` - maximum reconnect backoff delay in ms (default `60_000`)
  - `:handler_mod` - module implementing `handle_message/3` (default `Greenhouse.MQTT.Handler`)
  - `:config_manager` - optional `ConfigManager` server forwarded in handler metadata
  - `:low_mem` - enable `:emqtt` `low_mem` heap/hibernation tuning (default `true`)
  - `:hibernate_after_ms` - GenServer idle hibernation timeout in ms (default `15_000`)
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    hibernate_after = Keyword.get(opts, :hibernate_after_ms, @default_hibernate_after_ms)

    gen_opts =
      case name do
        nil -> [hibernate_after: hibernate_after]
        mod_or_name -> [name: mod_or_name, hibernate_after: hibernate_after]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Publishes an MQTT message (`qos: 1`, `retain: false`) via the default client.
  """
  @spec publish(String.t(), binary()) :: :ok | {:error, term()}
  def publish(topic, payload) when is_binary(topic) and is_binary(payload) do
    publish(__MODULE__, topic, payload, [])
  end

  @doc """
  Publishes an MQTT message via the default client (with `opts`) or via `server`.
  """
  @spec publish(String.t(), binary(), [publish_option()]) :: :ok | {:error, term()}
  @spec publish(GenServer.server(), String.t(), binary()) :: :ok | {:error, term()}
  def publish(topic, payload, opts)
      when is_binary(topic) and is_binary(payload) and is_list(opts) do
    publish(__MODULE__, topic, payload, opts)
  end

  def publish(server, topic, payload) when is_binary(topic) and is_binary(payload) do
    publish(server, topic, payload, [])
  end

  @doc """
  Publishes an MQTT message with options (`:qos`, `:retain`) via `server`.
  """
  @spec publish(GenServer.server(), String.t(), binary(), [publish_option()]) ::
          :ok | {:error, term()}
  def publish(server, topic, payload, opts)
      when is_binary(topic) and is_binary(payload) and is_list(opts) do
    case GenServer.call(server, :get_publish_handle) do
      {:ok, emqtt_pid} when is_pid(emqtt_pid) ->
        do_emqtt_publish(emqtt_pid, topic, payload, opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the current MQTT connection status map.
  """
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  @spec init([option()]) :: {:ok, state()}
  def init(opts) when is_list(opts) do
    Process.flag(:trap_exit, true)

    initial_backoff_ms = Keyword.get(opts, :initial_backoff_ms, @default_initial_backoff_ms)

    max_backoff_ms =
      max(Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms), initial_backoff_ms)

    state = %__MODULE__{
      enabled: Keyword.get(opts, :enabled, false),
      host: normalize_host(Keyword.get(opts, :host, "mqtt.example.com")),
      port: Keyword.get(opts, :port, 1883),
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      client_id: normalize_client_id(Keyword.get(opts, :client_id)),
      keep_alive: resolve_keep_alive(opts),
      force_ping: Keyword.get(opts, :force_ping, false),
      connect_timeout_ms: Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms),
      initial_backoff_ms: initial_backoff_ms,
      max_backoff_ms: max_backoff_ms,
      current_backoff_ms: initial_backoff_ms,
      reconnect_attempts: 0,
      reconnect_timer: nil,
      handler_mod: Keyword.get(opts, :handler_mod, Greenhouse.MQTT.Handler),
      config_manager: Keyword.get(opts, :config_manager),
      low_mem: Keyword.get(opts, :low_mem, true),
      emqtt_pid: nil,
      connector_pid: nil,
      connector_ref: nil,
      connected: false
    }

    if state.enabled do
      send(self(), :connect)
    end

    {:ok, state}
  end

  @impl GenServer
  @spec handle_call(:status | :get_publish_handle, GenServer.from(), state()) ::
          {:reply, status() | {:ok, pid()} | {:error, :not_connected}, state()}
  def handle_call(:status, _from, %__MODULE__{} = state) do
    reply = %{
      connected: state.connected,
      host: state.host,
      port: state.port,
      client_id: state.client_id,
      reconnect_attempts: state.reconnect_attempts
    }

    {:reply, reply, state}
  end

  def handle_call(
        :get_publish_handle,
        _from,
        %__MODULE__{connected: true, emqtt_pid: pid} = state
      )
      when is_pid(pid) do
    {:reply, {:ok, pid}, state}
  end

  def handle_call(:get_publish_handle, _from, %__MODULE__{} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl GenServer
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info(:connect, %__MODULE__{enabled: false} = state) do
    {:noreply, %{state | reconnect_timer: nil}}
  end

  def handle_info(:connect, %__MODULE__{emqtt_pid: pid} = state) when is_pid(pid) do
    {:noreply, %{state | reconnect_timer: nil}}
  end

  def handle_info(:connect, %__MODULE__{} = state) do
    state = %{state | reconnect_timer: nil}

    case :emqtt.start_link(emqtt_opts(state)) do
      {:ok, emqtt_pid} ->
        client = self()

        {connector_pid, connector_ref} =
          spawn_monitor(fn ->
            result = connect_and_subscribe(emqtt_pid)
            send(client, {:mqtt_connect_result, emqtt_pid, result})
          end)

        {:noreply,
         %{
           state
           | emqtt_pid: emqtt_pid,
             connector_pid: connector_pid,
             connector_ref: connector_ref,
             connected: false
         }}

      {:error, reason} ->
        Logger.warning("Failed to start :emqtt client: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info({:mqtt_connect_result, pid, {:ok, reason_codes}}, %{emqtt_pid: pid} = state) do
    state = demonitor_connector(state)

    if Enum.any?(reason_codes, &(&1 >= 0x80)) do
      Logger.warning("MQTT broker refused one or more subscriptions: #{inspect(reason_codes)}")
    end

    Logger.info("MQTT connected to #{state.host}:#{state.port} as #{state.client_id}")

    {:noreply,
     %{
       state
       | connected: true,
         reconnect_attempts: 0,
         current_backoff_ms: state.initial_backoff_ms
     }}
  end

  def handle_info({:mqtt_connect_result, pid, {:error, reason}}, %{emqtt_pid: pid} = state) do
    state = demonitor_connector(state)
    safe_stop_emqtt(pid, false)

    Logger.warning("MQTT connection to #{state.host}:#{state.port} failed: #{inspect(reason)}")

    state = %{state | emqtt_pid: nil, connected: false}
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info({:mqtt_connect_result, _stale_pid, _result}, state) do
    {:noreply, state}
  end

  def handle_info({:publish, %{topic: topic, payload: payload} = msg}, state) do
    meta = %{
      qos: Map.get(msg, :qos, 0),
      retain: Map.get(msg, :retain, false),
      dup: Map.get(msg, :dup, false),
      packet_id: Map.get(msg, :packet_id),
      received_at_ms: System.system_time(:millisecond)
    }

    meta =
      if state.config_manager != nil do
        Map.put(meta, :config_manager, state.config_manager)
      else
        meta
      end

    dispatch_publish(state.handler_mod, topic, payload, meta)
    {:noreply, state}
  end

  def handle_info({:disconnected, reason_code, _props}, state) do
    Logger.warning("MQTT broker disconnected with reason code #{inspect(reason_code)}")
    {:noreply, %{state | connected: false}}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{connector_ref: ref} = state) do
    {:noreply, %{state | connector_pid: nil, connector_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{connector_ref: ref} = state) do
    safe_stop_emqtt(state.emqtt_pid, false)

    Logger.warning("MQTT connector process failed: #{inspect(reason)}")

    state =
      %{
        state
        | emqtt_pid: nil,
          connector_pid: nil,
          connector_ref: nil,
          connected: false
      }

    {:noreply, schedule_reconnect(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{emqtt_pid: pid} = state) do
    Logger.warning("MQTT connection closed: #{inspect(reason)}")
    state = demonitor_connector(state)

    state = %{
      state
      | emqtt_pid: nil,
        connected: false
    }

    {:noreply, schedule_reconnect(state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl GenServer
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, %__MODULE__{} = state) do
    cancel_reconnect_timer(state.reconnect_timer)
    connector_pid = state.connector_pid
    state = demonitor_connector(state)

    if is_pid(connector_pid) and Process.alive?(connector_pid) do
      Process.exit(connector_pid, :kill)
    end

    safe_stop_emqtt(state.emqtt_pid, state.connected)
    :ok
  end

  # --- Private helpers ---

  @spec emqtt_opts(state()) :: keyword()
  defp emqtt_opts(%__MODULE__{} = state) do
    connect_timeout_secs = max(1, div(state.connect_timeout_ms + 999, 1000))

    base = [
      {:owner, self()},
      {:host, to_charlist(state.host)},
      {:port, state.port},
      {:proto_ver, :v4},
      {:clean_start, true},
      {:clientid, state.client_id},
      {:keepalive, state.keep_alive},
      {:force_ping, state.force_ping},
      {:connect_timeout, connect_timeout_secs},
      {:auto_ack, true},
      {:reconnect, 0},
      {:low_mem, state.low_mem},
      {:tcp_opts, [packet: :raw, nodelay: true]}
    ]

    add_auth_opts(base, state.username, state.password)
  end

  @spec add_auth_opts(keyword(), String.t() | nil, String.t() | nil) :: keyword()
  defp add_auth_opts(opts, username, password)
       when is_list(opts) and is_binary(username) and username != "" do
    opts = [{:username, username} | opts]

    if is_binary(password) do
      [{:password, password} | opts]
    else
      opts
    end
  end

  defp add_auth_opts(opts, _username, _password) when is_list(opts), do: opts

  @spec connect_and_subscribe(pid()) :: {:ok, [byte()]} | {:error, term()}
  defp connect_and_subscribe(emqtt_pid) when is_pid(emqtt_pid) do
    try do
      with {:ok, _props} <- :emqtt.connect(emqtt_pid),
           {:ok, _props, reason_codes} <- :emqtt.subscribe(emqtt_pid, @subscribe_topics) do
        {:ok, reason_codes}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @spec do_emqtt_publish(pid(), String.t(), binary(), [publish_option()]) ::
          :ok | {:error, term()}
  defp do_emqtt_publish(emqtt_pid, topic, payload, opts)
       when is_pid(emqtt_pid) and is_binary(topic) and is_binary(payload) and is_list(opts) do
    qos = normalize_qos(Keyword.get(opts, :qos, 1))
    retain = Keyword.get(opts, :retain, false) == true

    try do
      case :emqtt.publish(emqtt_pid, topic, %{}, payload, qos: qos, retain: retain) do
        :ok ->
          :ok

        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning("MQTT publish failed on #{topic}: #{inspect(reason)}")
          {:error, reason}
      end
    catch
      :exit, reason ->
        Logger.warning("MQTT publish exited on #{topic}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec dispatch_publish(
          module(),
          String.t(),
          binary(),
          Greenhouse.MQTT.Handler.publish_meta()
        ) :: term()
  defp dispatch_publish(handler_mod, topic, payload, meta)
       when is_atom(handler_mod) and is_binary(topic) and is_binary(payload) and is_map(meta) do
    safe_topic = :binary.copy(topic)
    safe_payload = :binary.copy(payload)
    handler_mod.handle_message(safe_topic, safe_payload, meta)
  rescue
    exception ->
      Logger.error(
        "MQTT handler #{inspect(handler_mod)} crashed on #{inspect(topic)}: #{Exception.message(exception)}"
      )
  catch
    kind, reason ->
      Logger.error(
        "MQTT handler #{inspect(handler_mod)} exited (#{inspect(kind)}) on #{inspect(topic)}: #{inspect(reason)}"
      )
  end

  @spec schedule_reconnect(state()) :: state()
  defp schedule_reconnect(%__MODULE__{enabled: false} = state), do: state

  defp schedule_reconnect(%__MODULE__{reconnect_timer: ref} = state) when is_reference(ref),
    do: state

  defp schedule_reconnect(%__MODULE__{} = state) do
    delay = state.current_backoff_ms
    next_delay = min(delay * 2, state.max_backoff_ms)
    timer_ref = Process.send_after(self(), :connect, delay)

    %{
      state
      | reconnect_attempts: state.reconnect_attempts + 1,
        current_backoff_ms: next_delay,
        reconnect_timer: timer_ref
    }
  end

  @spec cancel_reconnect_timer(reference() | nil) :: :ok
  defp cancel_reconnect_timer(nil), do: :ok

  defp cancel_reconnect_timer(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)

    receive do
      :connect -> :ok
    after
      0 -> :ok
    end
  end

  @spec demonitor_connector(state()) :: state()
  defp demonitor_connector(%__MODULE__{connector_ref: nil} = state) do
    %{state | connector_pid: nil}
  end

  defp demonitor_connector(%__MODULE__{connector_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | connector_pid: nil, connector_ref: nil}
  end

  @spec safe_stop_emqtt(pid() | nil, boolean()) :: :ok
  defp safe_stop_emqtt(nil, _connected), do: :ok

  defp safe_stop_emqtt(pid, connected) when is_pid(pid) and is_boolean(connected) do
    if Process.alive?(pid) do
      try do
        if connected do
          :emqtt.disconnect(pid)
        else
          :emqtt.stop(pid)
        end
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @spec normalize_host(String.t() | charlist() | :inet.ip_address() | atom()) :: String.t()
  defp normalize_host(host) when is_tuple(host), do: host |> :inet.ntoa() |> to_string()
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  @spec normalize_client_id(term()) :: String.t()
  defp normalize_client_id(id) when is_binary(id) and id != "", do: id

  defp normalize_client_id(_) do
    "greenhouse-backend-#{System.pid()}-#{System.unique_integer([:positive])}"
  end

  @spec resolve_keep_alive([option()]) :: non_neg_integer()
  defp resolve_keep_alive(opts) when is_list(opts) do
    case Keyword.get(opts, :keep_alive) do
      secs when is_integer(secs) and secs >= 0 ->
        secs

      _ ->
        case Keyword.get(opts, :ping_interval_ms) do
          ms when is_integer(ms) and ms > 0 -> max(1, div(ms + 999, 1000))
          _ -> @default_keep_alive
        end
    end
  end

  @spec normalize_qos(qos()) :: 0 | 1 | 2
  defp normalize_qos(qos) when qos in [0, 1, 2], do: qos
  defp normalize_qos(:qos0), do: 0
  defp normalize_qos(:qos1), do: 1
  defp normalize_qos(:qos2), do: 2
end
