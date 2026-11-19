defmodule Greenhouse.AccountStore do
  @moduledoc """
  GenServer managing multi-tenant user accounts, bearer session tokens, exclusive
  device bindings, single reserved simulation device (`GH-0000`), and snapshot assembly
  backed by ETS + optional DETS persistence.

  Delegates domain logic to `Greenhouse.AccountStore.Auth`,
  `Greenhouse.AccountStore.Bindings`, and `Greenhouse.AccountStore.Simulator`.
  """

  use GenServer

  alias Greenhouse.AccountStore.{Auth, Bindings, Simulator}
  alias Greenhouse.{Storage, Support}
  alias Greenhouse.Support.DETS

  @users_table :gh_users
  @usernames_table :gh_usernames
  @sessions_table :gh_sessions
  @bindings_table :gh_bindings

  @all_ets_tables [@users_table, @usernames_table, @sessions_table, @bindings_table]

  @dets_table_specs [
    {@users_table, :gh_users_dets, "users.dets"},
    {@sessions_table, :gh_sessions_dets, "sessions.dets"},
    {@bindings_table, :gh_bindings_dets, "bindings.dets"}
  ]

  @session_prune_interval_ms 3_600_000
  @hibernate_after_ms 15_000

  @typedoc "Startup options accepted by `start_link/1`."
  @type option ::
          {:name, GenServer.name() | nil}
          | {:persist, boolean()}
          | {:data_dir, Path.t()}
          | {:seed_demo, boolean()}
          | {:hibernate_after_ms, pos_integer()}

  @typedoc "Standard REST API error tuple returned by account and binding mutations."
  @type api_error :: {:error, pos_integer(), String.t(), String.t()}

  @typedoc "Public user projection safe for API responses and session lookups."
  @type user_public :: Auth.user_public()

  @typedoc "Device binding metadata stored per exclusively bound device."
  @type binding :: Bindings.binding()

  @typedoc "User-scoped device snapshot merging binding metadata with live storage state."
  @type user_device_snapshot :: Bindings.user_device_snapshot()

  defstruct persist: false,
            data_dir: "priv/data",
            seed_demo: false,
            dets_tables: %{}

  @typedoc "Internal GenServer state struct for `Greenhouse.AccountStore`."
  @type state :: %__MODULE__{
          persist: boolean(),
          data_dir: Path.t(),
          seed_demo: boolean(),
          dets_tables: DETS.dets_map()
        }

  # --- Public Helpers ---

  @doc """
  Returns the sole device ID reserved for local telemetry/alarm simulation (`"GH-0000"`).
  """
  @spec simulated_device_id() :: Greenhouse.device_id()
  defdelegate simulated_device_id(), to: Simulator

  @doc """
  Returns `true` if `device_id` matches the sole reserved simulated device (`"GH-0000"`).
  """
  @spec simulated_device?(term()) :: boolean()
  defdelegate simulated_device?(device_id), to: Simulator

  @doc """
  Normalizes a raw device ID (`trim` + `upcase`) and validates against `^[A-Z0-9_-]{2,32}$`.
  Returns `""` when invalid.
  """
  @spec normalize_device_id(term()) :: String.t()
  defdelegate normalize_device_id(raw_id), to: Bindings

  # --- Client API ---

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {hibernate_after, opts} = Keyword.pop(opts, :hibernate_after_ms, @hibernate_after_ms)

    case Keyword.get(opts, :name, __MODULE__) do
      nil ->
        GenServer.start_link(__MODULE__, opts, hibernate_after: hibernate_after)

      name ->
        GenServer.start_link(__MODULE__, opts, name: name, hibernate_after: hibernate_after)
    end
  end

  @spec reset!() :: :ok
  def reset! do
    GenServer.call(__MODULE__, :reset)
  end

  @spec reset_demo!() :: :ok
  def reset_demo! do
    Storage.reset!()
    GenServer.call(__MODULE__, :reset_demo)
  end

  @spec verify_credentials(term(), term()) ::
          {:ok, user_public()} | {:error, :invalid_credentials}
  defdelegate verify_credentials(username, password), to: Auth

  @spec register_user(term()) ::
          {:ok, %{user: user_public(), token: Greenhouse.session_token()}} | api_error()
  def register_user(params) do
    case Auth.validate_registration(params) do
      {:ok, username, password, display_name} ->
        GenServer.call(__MODULE__, {:register_user, username, password, display_name})

      {:error, _status, _code, _message} = err ->
        err
    end
  end

  @spec create_session(Greenhouse.user_id() | term()) ::
          {:ok, Greenhouse.session_token()} | {:error, :user_not_found}
  def create_session(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:create_session, user_id})
  end

  def create_session(_), do: {:error, :user_not_found}

  @spec get_session_user(term()) :: {:ok, user_public()} | {:error, :unauthorized}
  defdelegate get_session_user(token), to: Auth

  @spec delete_session(term()) :: :ok
  def delete_session(token) when is_binary(token) do
    clean_token = String.trim(token)

    if clean_token == "",
      do: :ok,
      else: GenServer.call(__MODULE__, {:delete_session, clean_token})
  end

  def delete_session(_), do: :ok

  @spec list_user_bindings(Greenhouse.user_id() | term()) :: [binding()]
  defdelegate list_user_bindings(user_id), to: Bindings

  @spec get_user_binding(Greenhouse.user_id() | term(), term()) ::
          {:ok, binding()} | {:error, :not_found}
  defdelegate get_user_binding(user_id, raw_device_id), to: Bindings

  @spec get_device_owner(term()) :: {:ok, binding()} | {:error, :not_found}
  defdelegate get_device_owner(raw_device_id), to: Bindings

  @spec bind_device(Greenhouse.user_id() | term(), term()) ::
          {:ok, binding()} | api_error()
  def bind_device(user_id, params) when is_binary(user_id) and is_map(params) do
    raw_device_id =
      case Support.fetch_optional_str(params, "deviceId", :deviceId) do
        nil -> Support.fetch_str(params, "device_id", :device_id)
        val -> val
      end

    case Bindings.normalize_device_id(raw_device_id) do
      "" ->
        {:error, 400, "invalid_device_id", "设备 ID 格式无效，须为 2~32 位字母、数字、连字符(-)或下划线(_)"}

      device_id ->
        GenServer.call(
          __MODULE__,
          {:bind_device, user_id, Support.detach_binary(device_id), params}
        )
    end
  end

  def bind_device(_, _), do: {:error, 400, "invalid_payload", "请求体格式无效"}

  @spec update_binding(Greenhouse.user_id() | term(), term(), term()) ::
          {:ok, binding()} | {:error, :forbidden} | api_error()
  def update_binding(user_id, raw_device_id, patch) when is_binary(user_id) and is_map(patch) do
    case Bindings.normalize_device_id(raw_device_id) do
      "" -> {:error, :forbidden}
      device_id -> GenServer.call(__MODULE__, {:update_binding, user_id, device_id, patch})
    end
  end

  def update_binding(_, _, _), do: {:error, :forbidden}

  @spec unbind_device(Greenhouse.user_id() | term(), term()) :: :ok | {:error, :forbidden}
  def unbind_device(user_id, raw_device_id) when is_binary(user_id) do
    case Bindings.normalize_device_id(raw_device_id) do
      "" -> {:error, :forbidden}
      device_id -> GenServer.call(__MODULE__, {:unbind_device, user_id, device_id})
    end
  end

  def unbind_device(_, _), do: {:error, :forbidden}

  @doc """
  Builds a user-facing device snapshot combining `binding` with real `Greenhouse.Storage`
  device state. Unknown/unreported devices return `online: false`, `latest_telemetry: nil`,
  and empty `config.raw`/`config.human` without fabricating fake data.
  """
  @spec build_user_device_snapshot(binding()) :: user_device_snapshot()
  defdelegate build_user_device_snapshot(binding), to: Bindings

  @doc """
  Triggers a simulated scenario on the sole reserved simulated device (`GH-0000`).
  Returns `{:error, 400, "not_simulated_device", ...}` for all other device IDs.
  """
  @spec simulate_scenario(term(), term()) :: {:ok, user_device_snapshot()} | api_error()
  def simulate_scenario(raw_device_id, scenario) do
    case Simulator.validate_scenario(raw_device_id, scenario) do
      {:ok, device_id} ->
        GenServer.call(__MODULE__, {:simulate_scenario, device_id, scenario})

      {:error, _status, _code, _msg} = err ->
        err
    end
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  @spec init([option()]) :: {:ok, state()}
  def init(opts) when is_list(opts) do
    persist = Keyword.get(opts, :persist, false)
    data_dir = Keyword.get(opts, :data_dir, "priv/data")
    seed_demo = Keyword.get(opts, :seed_demo, false)

    init_ets_tables()

    dets_tables =
      if persist do
        tables = DETS.open_tables(data_dir, @dets_table_specs)
        DETS.load_into_ets(tables)
        Auth.normalize_loaded_sessions(tables)
        tables
      else
        %{}
      end

    Auth.rebuild_username_index()

    state = %__MODULE__{
      persist: persist,
      data_dir: data_dir,
      seed_demo: seed_demo,
      dets_tables: dets_tables
    }

    if seed_demo and :ets.info(@users_table, :size) == 0 do
      Simulator.seed_demo_data!(state.persist, state.dets_tables)
    end

    schedule_session_prune()
    {:ok, state}
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call(:reset, _from, %__MODULE__{} = state) do
    DETS.clear_tables(@all_ets_tables, state.persist, state.dets_tables)
    {:reply, :ok, state}
  end

  def handle_call(:reset_demo, _from, %__MODULE__{} = state) do
    DETS.clear_tables(@all_ets_tables, state.persist, state.dets_tables)
    Simulator.seed_demo_data!(state.persist, state.dets_tables)
    {:reply, :ok, state}
  end

  def handle_call(
        {:register_user, username, password, display_name},
        _from,
        %__MODULE__{} = state
      ) do
    result =
      Auth.register_user(username, password, display_name, state.persist, state.dets_tables)

    {:reply, result, state}
  end

  def handle_call({:create_session, user_id}, _from, %__MODULE__{} = state) do
    result = Auth.create_session(user_id, state.persist, state.dets_tables)
    {:reply, result, state}
  end

  def handle_call({:delete_session, token}, _from, %__MODULE__{} = state) do
    DETS.delete_record(@sessions_table, token, state.persist, state.dets_tables)
    {:reply, :ok, state}
  end

  def handle_call({:bind_device, user_id, device_id, params}, _from, %__MODULE__{} = state) do
    result = Bindings.bind_device(user_id, device_id, params, state.persist, state.dets_tables)
    {:reply, result, state}
  end

  def handle_call({:update_binding, user_id, device_id, patch}, _from, %__MODULE__{} = state) do
    result = Bindings.update_binding(user_id, device_id, patch, state.persist, state.dets_tables)
    {:reply, result, state}
  end

  def handle_call({:unbind_device, user_id, device_id}, _from, %__MODULE__{} = state) do
    result = Bindings.unbind_device(user_id, device_id, state.persist, state.dets_tables)
    {:reply, result, state}
  end

  def handle_call({:simulate_scenario, device_id, scenario}, _from, %__MODULE__{} = state) do
    Simulator.run_simulation(device_id, scenario)
    binding = Bindings.resolve_binding_for_snapshot(device_id)
    {:reply, {:ok, Bindings.build_user_device_snapshot(binding)}, state}
  end

  @impl GenServer
  @spec handle_cast({:delete_persisted_session, Greenhouse.session_token()}, state()) ::
          {:noreply, state()}
  def handle_cast({:delete_persisted_session, token}, %__MODULE__{} = state)
      when is_binary(token) do
    DETS.delete_record(@sessions_table, token, state.persist, state.dets_tables)
    {:noreply, state}
  end

  @impl GenServer
  @spec handle_info(:prune_sessions, state()) :: {:noreply, state()}
  def handle_info(:prune_sessions, %__MODULE__{} = state) do
    Auth.prune_expired_sessions(
      System.system_time(:millisecond),
      state.persist,
      state.dets_tables
    )

    schedule_session_prune()
    {:noreply, state}
  end

  @impl GenServer
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, %__MODULE__{} = state) do
    DETS.close_tables(state.persist, state.dets_tables)
  end

  # --- Private Helpers ---

  @spec init_ets_tables() :: :ok
  defp init_ets_tables do
    Enum.each(@all_ets_tables, fn table ->
      _ = :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    end)
  end

  @spec schedule_session_prune() :: reference()
  defp schedule_session_prune do
    Process.send_after(self(), :prune_sessions, @session_prune_interval_ms)
  end
end
