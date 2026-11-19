defmodule Greenhouse.Web.Respond do
  @moduledoc """
  JSON response encoding and request JSON-object decoding helpers for `Plug.Conn`.
  """

  import Plug.Conn

  @doc """
  Sends a UTF-8 JSON response with `status` and halts the connection pipeline.
  """
  @spec json(Plug.Conn.t(), Plug.Conn.status(), term()) :: Plug.Conn.t()
  def json(%Plug.Conn{} = conn, status, payload) when is_integer(status) or is_atom(status) do
    conn
    |> put_resp_content_type("application/json", "utf-8")
    |> send_resp(status, JSON.encode!(payload))
    |> halt()
  end

  @doc """
  Decodes `raw` JSON into a map, treating empty/whitespace-only payloads as `%{}`.
  Rejects syntactically invalid JSON and non-object JSON values.
  """
  @spec decode_json_object(binary()) :: {:ok, Greenhouse.json_map()} | {:error, :invalid_json}
  def decode_json_object(raw) when is_binary(raw) do
    if String.trim(raw) == "" do
      {:ok, %{}}
    else
      case JSON.decode(raw) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        _ -> {:error, :invalid_json}
      end
    end
  end

  @doc """
  Raising variant of `decode_json_object/1` used as the `Plug.Parsers` `:json` decoder.
  """
  @spec decode_json_object!(binary()) :: Greenhouse.json_map()
  def decode_json_object!(raw) when is_binary(raw) do
    case decode_json_object(raw) do
      {:ok, decoded} -> decoded
      {:error, :invalid_json} -> raise ArgumentError, "invalid JSON object payload"
    end
  end

  @doc """
  Reads the first value of request header `downcase_key`, falling back to
  case-insensitive matching for direct unit tests with mixed-case headers.
  """
  @spec req_header(Plug.Conn.t(), String.t()) :: String.t() | nil
  def req_header(%Plug.Conn{req_headers: headers} = conn, downcase_key)
      when is_list(headers) and is_binary(downcase_key) do
    case Plug.Conn.get_req_header(conn, downcase_key) do
      [value | _] ->
        value

      [] ->
        Enum.find_value(headers, fn
          {key, value} when is_binary(key) ->
            if String.downcase(key) == downcase_key, do: value

          _ ->
            nil
        end)
    end
  end
end
