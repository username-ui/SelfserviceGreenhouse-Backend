defmodule Greenhouse.TestSupport.MockBroker do
  @moduledoc false

  use GenServer

  require Record

  @type_connect 1
  @type_connack 2
  @type_publish 3
  @type_puback 4
  @type_subscribe 8
  @type_suback 9
  @type_pingreq 12
  @type_pingresp 13
  @type_disconnect 14

  @emqtt_hrl "emqtt/include/emqtt.hrl"
  Record.defrecordp(:mqtt_packet, Record.extract(:mqtt_packet, from_lib: @emqtt_hrl))

  Record.defrecordp(
    :mqtt_packet_header,
    Record.extract(:mqtt_packet_header, from_lib: @emqtt_hrl)
  )

  Record.defrecordp(
    :mqtt_packet_connect,
    Record.extract(:mqtt_packet_connect, from_lib: @emqtt_hrl)
  )

  Record.defrecordp(
    :mqtt_packet_connack,
    Record.extract(:mqtt_packet_connack, from_lib: @emqtt_hrl)
  )

  Record.defrecordp(
    :mqtt_packet_publish,
    Record.extract(:mqtt_packet_publish, from_lib: @emqtt_hrl)
  )

  Record.defrecordp(
    :mqtt_packet_puback,
    Record.extract(:mqtt_packet_puback, from_lib: @emqtt_hrl)
  )

  Record.defrecordp(
    :mqtt_packet_subscribe,
    Record.extract(:mqtt_packet_subscribe, from_lib: @emqtt_hrl)
  )

  Record.defrecordp(
    :mqtt_packet_suback,
    Record.extract(:mqtt_packet_suback, from_lib: @emqtt_hrl)
  )

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def port(broker), do: GenServer.call(broker, :port)

  def send_publish(broker, opts) do
    GenServer.call(broker, {:send_publish, opts})
  end

  def send_publish_chunked(broker, opts, chunk_size) do
    GenServer.call(broker, {:send_publish_chunked, opts, chunk_size})
  end

  def drop_connection(broker) do
    GenServer.call(broker, :drop_connection)
  end

  @impl true
  def init(opts) do
    {:ok, listen_sock} =
      :gen_tcp.listen(0, [
        :binary,
        {:packet, :raw},
        {:active, false},
        {:reuseaddr, true},
        {:ip, {127, 0, 0, 1}}
      ])

    {:ok, port} = :inet.port(listen_sock)
    parent = self()

    acceptor =
      spawn_link(fn ->
        accept_loop(listen_sock, parent)
      end)

    {:ok,
     %{
       listen_sock: listen_sock,
       port: port,
       acceptor: acceptor,
       test_pid: Keyword.fetch!(opts, :test_pid),
       connack_codes: Keyword.get(opts, :connack_codes, [0]),
       client_sock: nil,
       parse_state: :emqtt_frame.initial_parse_state(%{version: 4})
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:send_publish, _opts}, _from, %{client_sock: nil} = state) do
    {:reply, {:error, :no_client}, state}
  end

  def handle_call({:send_publish, opts}, _from, state) do
    frame = encode_publish(opts)
    res = :gen_tcp.send(state.client_sock, frame)
    {:reply, res, state}
  end

  def handle_call(
        {:send_publish_chunked, _opts, _chunk_size},
        _from,
        %{client_sock: nil} = state
      ) do
    {:reply, {:error, :no_client}, state}
  end

  def handle_call({:send_publish_chunked, opts, chunk_size}, _from, state) do
    bin = opts |> encode_publish() |> IO.iodata_to_binary()

    res =
      chunk_binary(bin, chunk_size)
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        case :gen_tcp.send(state.client_sock, chunk) do
          :ok ->
            Process.sleep(2)
            {:cont, :ok}

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    {:reply, res, state}
  end

  def handle_call(:drop_connection, _from, state) do
    if state.client_sock do
      :gen_tcp.close(state.client_sock)
    end

    {:reply, :ok, %{state | client_sock: nil}}
  end

  @impl true
  def handle_info({:accepted, sock}, state) do
    if state.client_sock do
      :gen_tcp.close(state.client_sock)
    end

    :inet.setopts(sock, active: :once)

    {:noreply,
     %{
       state
       | client_sock: sock,
         parse_state: :emqtt_frame.initial_parse_state(%{version: 4})
     }}
  end

  def handle_info({:tcp, sock, data}, %{client_sock: sock} = state) do
    {packets, next_parse_state} = parse_frames(data, state.parse_state, [])
    state = %{state | parse_state: next_parse_state}
    state = Enum.reduce(packets, state, &handle_packet/2)

    if state.client_sock == sock do
      :inet.setopts(sock, active: :once)
    end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, sock}, %{client_sock: sock} = state) do
    send(state.test_pid, :broker_tcp_closed)
    {:noreply, %{state | client_sock: nil}}
  end

  def handle_info({:tcp_error, sock, _reason}, %{client_sock: sock} = state) do
    {:noreply, %{state | client_sock: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.client_sock, do: :gen_tcp.close(state.client_sock)
    :gen_tcp.close(state.listen_sock)
    :ok
  end

  defp accept_loop(listen_sock, parent) do
    case :gen_tcp.accept(listen_sock) do
      {:ok, sock} ->
        :ok = :gen_tcp.controlling_process(sock, parent)
        send(parent, {:accepted, sock})
        accept_loop(listen_sock, parent)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp parse_frames(<<>>, parse_state, acc), do: {Enum.reverse(acc), parse_state}

  defp parse_frames(bin, parse_state, acc) do
    case :emqtt_frame.parse(bin, parse_state) do
      {:ok, packet, rest, next_state} ->
        parse_frames(rest, next_state, [packet | acc])

      {:more, next_state} ->
        {Enum.reverse(acc), next_state}
    end
  end

  defp handle_packet(
         mqtt_packet(
           header: mqtt_packet_header(type: @type_connect),
           variable:
             mqtt_packet_connect(
               proto_name: proto_name,
               proto_ver: proto_ver,
               clean_start: clean_start,
               keepalive: keepalive,
               clientid: client_id,
               username: username,
               password: password
             )
         ),
         state
       ) do
    send(
      state.test_pid,
      {:broker_connect,
       %{
         protocol_name: proto_name,
         protocol_level: proto_ver,
         clean_session: clean_start,
         keep_alive: keepalive,
         client_id: client_id,
         username: username,
         password: password
       }}
    )

    {code, rest_codes} =
      case state.connack_codes do
        [c | rest] -> {c, rest}
        [] -> {0, []}
      end

    connack =
      :emqtt_frame.serialize(
        mqtt_packet(
          header: mqtt_packet_header(type: @type_connack),
          variable: mqtt_packet_connack(ack_flags: 0, reason_code: code)
        ),
        4
      )

    :ok = :gen_tcp.send(state.client_sock, connack)
    %{state | connack_codes: rest_codes}
  end

  defp handle_packet(
         mqtt_packet(
           header: mqtt_packet_header(type: @type_subscribe),
           variable: mqtt_packet_subscribe(packet_id: packet_id, topic_filters: filters)
         ),
         state
       ) do
    topics = Enum.map(filters, fn {topic, %{qos: qos}} -> {topic, qos} end)
    send(state.test_pid, {:broker_subscribe, packet_id, topics})
    reason_codes = Enum.map(topics, fn {_t, qos} -> qos end)

    suback =
      :emqtt_frame.serialize(
        mqtt_packet(
          header: mqtt_packet_header(type: @type_suback),
          variable: mqtt_packet_suback(packet_id: packet_id, reason_codes: reason_codes)
        ),
        4
      )

    :ok = :gen_tcp.send(state.client_sock, suback)
    state
  end

  defp handle_packet(
         mqtt_packet(
           header: mqtt_packet_header(type: @type_publish, qos: qos, retain: retain),
           variable: mqtt_packet_publish(topic_name: topic, packet_id: packet_id),
           payload: payload
         ),
         state
       ) do
    send(
      state.test_pid,
      {:broker_publish,
       %{
         topic: topic,
         payload: payload,
         qos: qos,
         retain: retain,
         packet_id: packet_id
       }}
    )

    if qos == 1 and is_integer(packet_id) do
      puback =
        :emqtt_frame.serialize(
          mqtt_packet(
            header: mqtt_packet_header(type: @type_puback),
            variable: mqtt_packet_puback(packet_id: packet_id, reason_code: 0)
          ),
          4
        )

      :ok = :gen_tcp.send(state.client_sock, puback)
    end

    state
  end

  defp handle_packet(
         mqtt_packet(
           header: mqtt_packet_header(type: @type_puback),
           variable: mqtt_packet_puback(packet_id: packet_id)
         ),
         state
       ) do
    send(state.test_pid, {:broker_puback, packet_id})
    state
  end

  defp handle_packet(mqtt_packet(header: mqtt_packet_header(type: @type_pingreq)), state) do
    pingresp =
      :emqtt_frame.serialize(mqtt_packet(header: mqtt_packet_header(type: @type_pingresp)), 4)

    :ok = :gen_tcp.send(state.client_sock, pingresp)
    send(state.test_pid, :broker_pingreq)
    state
  end

  defp handle_packet(mqtt_packet(header: mqtt_packet_header(type: @type_disconnect)), state) do
    send(state.test_pid, :broker_disconnect)
    state
  end

  defp encode_publish(opts) do
    topic = Keyword.fetch!(opts, :topic)
    payload = Keyword.get(opts, :payload, "")
    qos = Keyword.get(opts, :qos, 0)
    retain = Keyword.get(opts, :retain, false)
    dup = Keyword.get(opts, :dup, false)

    packet_id =
      if qos == 0 do
        :undefined
      else
        Keyword.get(opts, :packet_id, 1)
      end

    :emqtt_frame.serialize(
      mqtt_packet(
        header: mqtt_packet_header(type: @type_publish, qos: qos, retain: retain, dup: dup),
        variable: mqtt_packet_publish(topic_name: topic, packet_id: packet_id),
        payload: payload
      ),
      4
    )
  end

  defp chunk_binary(<<>>, _size), do: []
  defp chunk_binary(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunk_binary(bin, size) do
    <<chunk::binary-size(^size), rest::binary>> = bin
    [chunk | chunk_binary(rest, size)]
  end
end
