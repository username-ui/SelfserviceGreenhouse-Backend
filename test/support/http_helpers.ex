defmodule Greenhouse.TestSupport.HTTP do
  @moduledoc false

  import ExUnit.Assertions, only: [assert: 1]

  def assert_cors_headers(headers) do
    assert headers["access-control-allow-origin"] == "*"

    assert headers["access-control-allow-methods"] ==
             "GET, POST, PUT, PATCH, DELETE, OPTIONS"

    assert headers["access-control-allow-headers"] == "Content-Type, Authorization"
  end

  def httpc_request(method, url) when method in [:get, :delete] do
    {:ok, {{_http_v, status, _reason}, resp_headers, body}} =
      :httpc.request(
        method,
        {String.to_charlist(url), []},
        [timeout: 5_000, ssl: [verify: :verify_none]],
        body_format: :binary
      )

    {status, normalize_httpc_headers(resp_headers), decode_or_raw(body)}
  end

  def httpc_request(:post, url, json_body) do
    {:ok, {{_http_v, status, _reason}, resp_headers, body}} =
      :httpc.request(
        :post,
        {String.to_charlist(url), [], ~c"application/json", json_body},
        [timeout: 5_000, ssl: [verify: :verify_none]],
        body_format: :binary
      )

    {status, normalize_httpc_headers(resp_headers), decode_or_raw(body)}
  end

  def raw_http_json(port, method, path, body) do
    req =
      [
        method,
        " ",
        path,
        " HTTP/1.1\r\n",
        "Host: 127.0.0.1:",
        Integer.to_string(port),
        "\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n",
        "Connection: close\r\n\r\n",
        body
      ]

    raw_http_request(port, req)
  end

  def raw_http_request(port, request_iodata) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    :ok = :gen_tcp.send(socket, request_iodata)
    raw_resp = recv_all(socket, [])
    :gen_tcp.close(socket)

    [head, resp_body] = String.split(raw_resp, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/" <> _version, status_str | _rest] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {k |> String.trim() |> String.downcase(), String.trim(v)}
      end)

    {String.to_integer(status_str), headers, resp_body}
  end

  defp normalize_httpc_headers(headers) do
    Map.new(headers, fn {k, v} ->
      {k |> to_string() |> String.downcase(), to_string(v)}
    end)
  end

  defp decode_or_raw(""), do: ""

  defp decode_or_raw(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> recv_all(socket, [chunk | acc])
      {:error, :closed} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
