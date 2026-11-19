defmodule Greenhouse.AccountStore.Auth do
  @moduledoc """
  User account registration, credential hashing/verification, and bearer session
  lifecycle helpers for `Greenhouse.AccountStore`.
  """

  alias Greenhouse.Support
  alias Greenhouse.Support.DETS

  @users_table :gh_users
  @usernames_table :gh_usernames
  @sessions_table :gh_sessions
  @sessions_dets_table :gh_sessions_dets

  @username_regex ~r/^[a-zA-Z0-9_]{3,24}$/
  @session_ttl_ms 7 * 24 * 60 * 60 * 1_000

  @typedoc "Public user projection without credential fields."
  @type user_public :: %{
          id: Greenhouse.user_id(),
          username: String.t(),
          displayName: String.t(),
          role: String.t(),
          createdAt: Greenhouse.iso8601_timestamp()
        }

  @typedoc "Internal user record persisted in ETS/DETS."
  @type user_record :: %{
          id: Greenhouse.user_id(),
          username: String.t(),
          displayName: String.t(),
          role: String.t(),
          createdAt: Greenhouse.iso8601_timestamp(),
          passwordSalt: String.t(),
          passwordHashes: [binary()]
        }

  @doc """
  Verifies a username/password pair against `:gh_users` and returns the public user map.
  """
  @spec verify_credentials(term(), term()) ::
          {:ok, user_public()} | {:error, :invalid_credentials}
  def verify_credentials(username, password) when is_binary(username) and is_binary(password) do
    normalized = username |> String.trim() |> String.downcase()

    if normalized == "" or password == "" do
      {:error, :invalid_credentials}
    else
      case find_user_by_username(normalized) do
        nil ->
          {:error, :invalid_credentials}

        user ->
          if verify_password(password, user.passwordSalt, user.passwordHashes) do
            {:ok, to_public_user(user)}
          else
            {:error, :invalid_credentials}
          end
      end
    end
  end

  def verify_credentials(_username, _password), do: {:error, :invalid_credentials}

  @doc """
  Validates user registration parameters and returns `{:ok, username, password, display_name}`
  or an API error tuple.
  """
  @spec validate_registration(term()) ::
          {:ok, String.t(), String.t(), String.t()}
          | {:error, pos_integer(), String.t(), String.t()}
  def validate_registration(params) when is_map(params) do
    username = params |> Support.fetch_str("username", :username) |> String.trim()
    password = Support.fetch_str(params, "password", :password)
    display_name = params |> Support.fetch_str("displayName", :displayName) |> String.trim()

    cond do
      not Regex.match?(@username_regex, username) ->
        {:error, 400, "invalid_username", "用户名须为 3~24 位字母、数字或下划线"}

      String.length(password) < 6 or String.length(password) > 128 ->
        {:error, 400, "invalid_password", "密码长度须为 6~128 个字符"}

      String.length(display_name) > 64 ->
        {:error, 400, "invalid_display_name", "显示名称不能超过 64 个字符"}

      true ->
        {:ok, username, password, display_name}
    end
  end

  def validate_registration(_), do: {:error, 400, "invalid_payload", "请求体格式无效"}

  @doc """
  Inserts a new user and initial session into ETS and optional DETS.
  """
  @spec register_user(String.t(), String.t(), String.t(), boolean(), DETS.dets_map()) ::
          {:ok, %{user: user_public(), token: Greenhouse.session_token()}}
          | {:error, pos_integer(), String.t(), String.t()}
  def register_user(username, password, display_name, persist?, dets_tables)
      when is_binary(username) and is_binary(password) and is_binary(display_name) and
             is_boolean(persist?) and is_map(dets_tables) do
    normalized_username = String.downcase(username)

    case find_user_by_username(normalized_username) do
      nil ->
        now_ms = System.system_time(:millisecond)
        now_iso = Support.iso8601(now_ms)
        salt = random_hex(16)
        user_id = "user-" <> random_hex(12)
        clean_username = Support.detach_binary(username)

        clean_display_name =
          if display_name == "", do: clean_username, else: Support.detach_binary(display_name)

        user_record = %{
          id: user_id,
          username: clean_username,
          displayName: clean_display_name,
          role: "温室管理员",
          createdAt: now_iso,
          passwordSalt: salt,
          passwordHashes: [hash_password(salt, password)]
        }

        DETS.put_record(@users_table, {user_id, user_record}, persist?, dets_tables)
        :ets.insert(@usernames_table, {normalized_username, user_id})
        prune_expired_sessions(now_ms, persist?, dets_tables)
        token = insert_session(user_id, now_ms, persist?, dets_tables)

        {:ok, %{user: to_public_user(user_record), token: token}}

      _existing ->
        {:error, 409, "username_taken", "该用户名已被注册，请更换用户名或直接登录"}
    end
  end

  @doc """
  Creates a session token for an existing `user_id`.
  """
  @spec create_session(Greenhouse.user_id(), boolean(), DETS.dets_map()) ::
          {:ok, Greenhouse.session_token()} | {:error, :user_not_found}
  def create_session(user_id, persist?, dets_tables)
      when is_binary(user_id) and is_boolean(persist?) and is_map(dets_tables) do
    case :ets.lookup(@users_table, user_id) do
      [{^user_id, _user}] ->
        now_ms = System.system_time(:millisecond)
        prune_expired_sessions(now_ms, persist?, dets_tables)
        token = insert_session(user_id, now_ms, persist?, dets_tables)
        {:ok, token}

      [] ->
        {:error, :user_not_found}
    end
  end

  @doc """
  Looks up the active user associated with `token`, lazily removing expired sessions.
  """
  @spec get_session_user(term()) :: {:ok, user_public()} | {:error, :unauthorized}
  def get_session_user(token) when is_binary(token) do
    clean_token = String.trim(token)

    if clean_token == "" do
      {:error, :unauthorized}
    else
      now_ms = System.system_time(:millisecond)

      case :ets.lookup(@sessions_table, clean_token) do
        [{^clean_token, user_id, expires_at_ms}] when expires_at_ms > now_ms ->
          lookup_public_user(user_id)

        [{^clean_token, %{user_id: user_id, expires_at_ms: expires_at_ms}}]
        when expires_at_ms > now_ms ->
          lookup_public_user(user_id)

        [{^clean_token, _}] ->
          cleanup_expired_session(clean_token)
          {:error, :unauthorized}

        [{^clean_token, _, _}] ->
          cleanup_expired_session(clean_token)
          {:error, :unauthorized}

        [] ->
          {:error, :unauthorized}
      end
    end
  end

  def get_session_user(_), do: {:error, :unauthorized}

  @doc """
  Rebuilds the `:gh_usernames` secondary index from `:gh_users`.
  """
  @spec rebuild_username_index() :: :ok
  def rebuild_username_index do
    :ets.delete_all_objects(@usernames_table)

    entries =
      :ets.foldl(
        fn {_user_id, user}, acc ->
          [{String.downcase(user.username), user.id} | acc]
        end,
        [],
        @users_table
      )

    if entries != [] do
      :ets.insert(@usernames_table, entries)
    end

    :ok
  end

  @doc """
  Migrates legacy map-format sessions and removes expired sessions loaded from DETS.
  """
  @spec normalize_loaded_sessions(DETS.dets_map()) :: :ok
  def normalize_loaded_sessions(dets_tables) when is_map(dets_tables) do
    now_ms = System.system_time(:millisecond)
    dets_table = Map.get(dets_tables, @sessions_table)

    {expired_tokens, migrated_records} =
      :ets.foldl(
        fn
          {token, %{user_id: user_id, expires_at_ms: expires_at_ms}}, {expired, migrated} ->
            if expires_at_ms <= now_ms do
              {[token | expired], migrated}
            else
              {expired, [{token, user_id, expires_at_ms} | migrated]}
            end

          {token, _user_id, expires_at_ms}, {expired, migrated} when expires_at_ms <= now_ms ->
            {[token | expired], migrated}

          _other, acc ->
            acc
        end,
        {[], []},
        @sessions_table
      )

    Enum.each(expired_tokens, fn token ->
      :ets.delete(@sessions_table, token)
      if dets_table != nil, do: :ok = :dets.delete(dets_table, token)
    end)

    _ =
      if migrated_records != [] do
        :ets.insert(@sessions_table, migrated_records)
        if dets_table != nil, do: :ok = :dets.insert(dets_table, migrated_records)
      end

    :ok
  end

  @doc """
  Prunes all expired sessions from ETS and optional DETS.
  """
  @spec prune_expired_sessions(Greenhouse.timestamp_ms(), boolean(), DETS.dets_map()) :: :ok
  def prune_expired_sessions(now_ms, true, dets_tables)
      when is_integer(now_ms) and is_map(dets_tables) do
    expired_tokens =
      :ets.select(@sessions_table, [
        {{:"$1", :_, :"$2"}, [{:"=<", :"$2", now_ms}], [:"$1"]},
        {{:"$1", %{expires_at_ms: :"$2"}}, [{:"=<", :"$2", now_ms}], [:"$1"]}
      ])

    Enum.each(expired_tokens, &DETS.delete_record(@sessions_table, &1, true, dets_tables))
    :ok
  end

  def prune_expired_sessions(now_ms, false, dets_tables)
      when is_integer(now_ms) and is_map(dets_tables) do
    :ets.select_delete(@sessions_table, [
      {{:_, :_, :"$1"}, [{:"=<", :"$1", now_ms}], [true]},
      {{:_, %{expires_at_ms: :"$1"}}, [{:"=<", :"$1", now_ms}], [true]}
    ])

    :ok
  end

  @doc """
  Hashes a password using a per-user salt (`SHA-256`).
  """
  @spec hash_password(String.t(), String.t()) :: binary()
  def hash_password(salt, password) when is_binary(salt) and is_binary(password) do
    :crypto.hash(:sha256, salt <> ":" <> password)
  end

  @doc """
  Generates `num_bytes` cryptographically random bytes encoded as lowercase hex.
  """
  @spec random_hex(pos_integer()) :: String.t()
  def random_hex(num_bytes) when is_integer(num_bytes) and num_bytes > 0 do
    num_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  @spec find_user_by_username(String.t()) :: user_record() | nil
  defp find_user_by_username(normalized_username) when is_binary(normalized_username) do
    case :ets.lookup(@usernames_table, normalized_username) do
      [{^normalized_username, user_id}] ->
        case :ets.lookup(@users_table, user_id) do
          [{^user_id, user}] -> user
          [] -> nil
        end

      [] ->
        nil
    end
  end

  @spec lookup_public_user(Greenhouse.user_id()) :: {:ok, user_public()} | {:error, :unauthorized}
  defp lookup_public_user(user_id) when is_binary(user_id) do
    case :ets.lookup(@users_table, user_id) do
      [{^user_id, user}] -> {:ok, to_public_user(user)}
      [] -> {:error, :unauthorized}
    end
  end

  @spec cleanup_expired_session(Greenhouse.session_token()) :: :ok
  defp cleanup_expired_session(token) when is_binary(token) do
    :ets.delete(@sessions_table, token)

    if :dets.info(@sessions_dets_table, :size) != :undefined and
         Process.whereis(Greenhouse.AccountStore) != nil do
      GenServer.cast(Greenhouse.AccountStore, {:delete_persisted_session, token})
    end

    :ok
  end

  @spec insert_session(
          Greenhouse.user_id(),
          Greenhouse.timestamp_ms(),
          boolean(),
          DETS.dets_map()
        ) :: Greenhouse.session_token()
  defp insert_session(user_id, now_ms, persist?, dets_tables)
       when is_binary(user_id) and is_integer(now_ms) and is_boolean(persist?) and
              is_map(dets_tables) do
    token = random_hex(32)

    DETS.put_record(
      @sessions_table,
      {token, user_id, now_ms + @session_ttl_ms},
      persist?,
      dets_tables
    )

    token
  end

  @spec verify_password(String.t(), String.t(), [binary()]) :: boolean()
  defp verify_password(password, salt, expected_hashes)
       when is_binary(password) and is_binary(salt) and is_list(expected_hashes) do
    candidate = hash_password(salt, password)

    Enum.any?(expected_hashes, fn expected ->
      is_binary(expected) and byte_size(candidate) == byte_size(expected) and
        :crypto.hash_equals(candidate, expected)
    end)
  end

  @spec to_public_user(user_record()) :: user_public()
  defp to_public_user(user) when is_map(user) do
    %{
      id: user.id,
      username: user.username,
      displayName: user.displayName,
      role: user.role,
      createdAt: user.createdAt
    }
  end
end
