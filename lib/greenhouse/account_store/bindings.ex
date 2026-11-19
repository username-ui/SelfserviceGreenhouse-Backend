defmodule Greenhouse.AccountStore.Bindings do
  @moduledoc """
  Device ID normalization, exclusive multi-tenant device binding CRUD, and
  user-facing snapshot assembly for `Greenhouse.AccountStore`.
  """

  alias Greenhouse.AccountStore.Simulator
  alias Greenhouse.{Storage, Support}
  alias Greenhouse.Support.DETS

  @users_table :gh_users
  @bindings_table :gh_bindings
  @device_id_regex ~r/^[A-Z0-9_-]{2,32}$/

  @typedoc "Exclusive user device binding record stored in ETS/DETS."
  @type binding :: %{
          deviceId: Greenhouse.device_id(),
          userId: Greenhouse.user_id() | nil,
          name: String.t(),
          location: String.t(),
          cropType: String.t(),
          notes: String.t(),
          boundAt: Greenhouse.iso8601_timestamp(),
          updatedAt: Greenhouse.iso8601_timestamp()
        }

  @typedoc "Tenant-facing device snapshot combining `binding` with `Greenhouse.Storage` state."
  @type user_device_snapshot :: %{
          binding: binding(),
          device_id: Greenhouse.device_id(),
          simulated: boolean(),
          online: boolean(),
          status: map() | nil,
          latest_telemetry: map() | nil,
          active_alarms: [map()],
          active_alarm_count: non_neg_integer(),
          all_alarms: [map()],
          config: map(),
          last_seen_at: Greenhouse.iso8601_timestamp() | nil,
          last_seen_at_ms: Greenhouse.timestamp_ms() | nil,
          source: String.t()
        }

  @doc """
  Normalizes a raw device ID (`trim` + `upcase`) and validates against `^[A-Z0-9_-]{2,32}$`.
  Returns `""` when invalid.
  """
  @spec normalize_device_id(term()) :: String.t()
  def normalize_device_id(raw_id) when is_binary(raw_id) do
    normalized = raw_id |> String.trim() |> String.upcase()
    if Regex.match?(@device_id_regex, normalized), do: normalized, else: ""
  end

  def normalize_device_id(_), do: ""

  @doc """
  Lists all device bindings owned by `user_id`, sorted by `deviceId`.
  """
  @spec list_user_bindings(term()) :: [binding()]
  def list_user_bindings(user_id) when is_binary(user_id) do
    @bindings_table
    |> :ets.select([{{:_, :"$1"}, [{:==, {:map_get, :userId, :"$1"}, user_id}], [:"$1"]}])
    |> Enum.sort_by(& &1.deviceId)
  end

  def list_user_bindings(_), do: []

  @doc """
  Returns the binding for `raw_device_id` only if it belongs to `user_id`.
  """
  @spec get_user_binding(term(), term()) :: {:ok, binding()} | {:error, :not_found}
  def get_user_binding(user_id, raw_device_id) when is_binary(user_id) do
    case normalize_device_id(raw_device_id) do
      "" ->
        {:error, :not_found}

      device_id ->
        case :ets.lookup(@bindings_table, device_id) do
          [{^device_id, %{userId: ^user_id} = binding}] -> {:ok, binding}
          _ -> {:error, :not_found}
        end
    end
  end

  def get_user_binding(_, _), do: {:error, :not_found}

  @doc """
  Looks up the owner binding record for `raw_device_id` regardless of user.
  """
  @spec get_device_owner(term()) :: {:ok, binding()} | {:error, :not_found}
  def get_device_owner(raw_device_id) do
    case normalize_device_id(raw_device_id) do
      "" ->
        {:error, :not_found}

      device_id ->
        case :ets.lookup(@bindings_table, device_id) do
          [{^device_id, binding}] -> {:ok, binding}
          [] -> {:error, :not_found}
        end
    end
  end

  @doc """
  Exclusively binds `device_id` to `user_id`.
  """
  @spec bind_device(
          Greenhouse.user_id(),
          Greenhouse.device_id(),
          map(),
          boolean(),
          DETS.dets_map()
        ) :: {:ok, binding()} | {:error, pos_integer(), String.t(), String.t()}
  def bind_device(user_id, device_id, params, persist?, dets_tables)
      when is_binary(user_id) and is_binary(device_id) and is_map(params) and
             is_boolean(persist?) and is_map(dets_tables) do
    if :ets.lookup(@users_table, user_id) == [] do
      {:error, 401, "unauthorized", "用户会话无效，请重新登录"}
    else
      case :ets.lookup(@bindings_table, device_id) do
        [{^device_id, %{userId: ^user_id}}] ->
          {:error, 409, "already_bound_by_you", "您已添加过该设备"}

        [{^device_id, _other_owner}] ->
          {:error, 409, "device_already_bound", "该设备已被其他用户绑定，无法重复添加"}

        [] ->
          now_iso = Support.iso8601(System.system_time(:millisecond))
          name = params |> Support.fetch_str("name", :name) |> String.trim()
          location = params |> Support.fetch_str("location", :location) |> String.trim()
          crop_type = params |> Support.fetch_str("cropType", :cropType) |> String.trim()
          notes = params |> Support.fetch_str("notes", :notes) |> String.trim()

          binding = %{
            deviceId: device_id,
            userId: user_id,
            name: if(name == "", do: "智能温室 #{device_id}", else: Support.detach_binary(name)),
            location: if(location == "", do: "未指定区域", else: Support.detach_binary(location)),
            cropType: if(crop_type == "", do: "通用温室作物", else: Support.detach_binary(crop_type)),
            notes: Support.detach_binary(notes),
            boundAt: now_iso,
            updatedAt: now_iso
          }

          DETS.put_record(@bindings_table, {device_id, binding}, persist?, dets_tables)

          if device_id == Simulator.simulated_device_id() and
               Storage.get_device(device_id) == {:error, :not_found} do
            Simulator.seed_simulated_device!()
          end

          {:ok, binding}
      end
    end
  end

  @doc """
  Updates editable metadata (`name`, `location`, `cropType`, `notes`) on a user's binding.
  """
  @spec update_binding(
          Greenhouse.user_id(),
          Greenhouse.device_id(),
          map(),
          boolean(),
          DETS.dets_map()
        ) :: {:ok, binding()} | {:error, :forbidden}
  def update_binding(user_id, device_id, patch, persist?, dets_tables)
      when is_binary(user_id) and is_binary(device_id) and is_map(patch) and
             is_boolean(persist?) and is_map(dets_tables) do
    case :ets.lookup(@bindings_table, device_id) do
      [{^device_id, %{userId: ^user_id} = current}] ->
        now_iso = Support.iso8601(System.system_time(:millisecond))

        updated = %{
          current
          | name:
              case Support.fetch_optional_str(patch, "name", :name) do
                nil ->
                  current.name

                val ->
                  trimmed = String.trim(val)
                  if trimmed == "", do: current.name, else: Support.detach_binary(trimmed)
              end,
            location:
              case Support.fetch_optional_str(patch, "location", :location) do
                nil -> current.location
                val -> val |> String.trim() |> Support.detach_binary()
              end,
            cropType:
              case Support.fetch_optional_str(patch, "cropType", :cropType) do
                nil -> current.cropType
                val -> val |> String.trim() |> Support.detach_binary()
              end,
            notes:
              case Support.fetch_optional_str(patch, "notes", :notes) do
                nil -> current.notes
                val -> val |> String.trim() |> Support.detach_binary()
              end,
            updatedAt: now_iso
        }

        DETS.put_record(@bindings_table, {device_id, updated}, persist?, dets_tables)
        {:ok, updated}

      _ ->
        {:error, :forbidden}
    end
  end

  @doc """
  Removes a device binding owned by `user_id`.
  """
  @spec unbind_device(Greenhouse.user_id(), Greenhouse.device_id(), boolean(), DETS.dets_map()) ::
          :ok | {:error, :forbidden}
  def unbind_device(user_id, device_id, persist?, dets_tables)
      when is_binary(user_id) and is_binary(device_id) and is_boolean(persist?) and
             is_map(dets_tables) do
    case :ets.lookup(@bindings_table, device_id) do
      [{^device_id, %{userId: ^user_id}}] ->
        DETS.delete_record(@bindings_table, device_id, persist?, dets_tables)
        :ok

      _ ->
        {:error, :forbidden}
    end
  end

  @doc """
  Builds a user-facing device snapshot combining `binding` with real `Greenhouse.Storage`
  device state without fabricating data for unknown/unreported devices.
  """
  @spec build_user_device_snapshot(binding()) :: user_device_snapshot()
  def build_user_device_snapshot(%{deviceId: device_id} = binding) when is_binary(device_id) do
    is_sim = Simulator.simulated_device?(device_id)
    source = if is_sim, do: "local", else: "backend"

    case Storage.get_device_with_all_alarms(device_id) do
      {:ok, dev, all_alarms} ->
        %{
          binding: binding,
          device_id: device_id,
          simulated: is_sim,
          online: dev.status != nil and dev.status.online == true,
          status: dev.status,
          latest_telemetry: dev.latest_telemetry,
          active_alarms: dev.active_alarms,
          active_alarm_count: length(dev.active_alarms),
          all_alarms: all_alarms,
          config: dev.config,
          last_seen_at: dev.last_seen_at,
          last_seen_at_ms: dev.last_seen_at_ms,
          source: source
        }

      {:error, :not_found} ->
        {:ok, all_alarms} = Storage.get_alarms(device_id, active_only: false)
        active_alarms = Enum.filter(all_alarms, & &1.active)
        {:ok, config} = Storage.get_config(device_id)

        %{
          binding: binding,
          device_id: device_id,
          simulated: is_sim,
          online: false,
          status: nil,
          latest_telemetry: nil,
          active_alarms: active_alarms,
          active_alarm_count: length(active_alarms),
          all_alarms: all_alarms,
          config: config,
          last_seen_at: nil,
          last_seen_at_ms: nil,
          source: source
        }
    end
  end

  @doc """
  Resolves the existing binding for `device_id` or synthesizes a fallback metadata map
  for snapshot rendering.
  """
  @spec resolve_binding_for_snapshot(Greenhouse.device_id()) :: binding()
  def resolve_binding_for_snapshot(device_id) when is_binary(device_id) do
    case :ets.lookup(@bindings_table, device_id) do
      [{^device_id, binding}] ->
        binding

      [] ->
        now_iso = Support.iso8601(System.system_time(:millisecond))

        %{
          deviceId: device_id,
          userId: nil,
          name: "智能温室 #{device_id}",
          location: "未绑定",
          cropType: "通用作物",
          notes: "",
          boundAt: now_iso,
          updatedAt: now_iso
        }
    end
  end
end
