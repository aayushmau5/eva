defmodule Eva.Test.SseServer do
  @moduledoc """
  Minimal HTTP/1.1 server for streaming tests against
  `Eva.AI.OpenAICompatibleProvider`.

  Listens on a random loopback port, records the most recently received
  request (request line, parsed headers, request body), and replies with a
  configurable raw HTTP response (typically an SSE stream).

  Drives Finch-based streaming without depending on Bypass.
  """

  use GenServer

  defstruct listen_sock: nil,
            port: nil,
            response: "",
            last_request: nil

  @type request :: {String.t(), [{String.t(), String.t()}], String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  def stop(server) do
    GenServer.stop(server, :normal)
  end

  def base_url(server) do
    GenServer.call(server, :base_url)
  end

  def set_response(server, response) when is_binary(response) do
    GenServer.call(server, {:set_response, response})
  end

  def set_responses(server, responses) when is_list(responses) do
    GenServer.call(server, {:set_response, responses})
  end

  @doc "Returns `{request_line, headers, body}` of the most recent request."
  @spec last_request(GenServer.server()) :: request() | nil
  def last_request(server) do
    GenServer.call(server, :last_request)
  end

  def last_request_body(server) do
    case last_request(server) do
      {_, _, body} -> body
      nil -> nil
    end
  end

  @impl true
  def init(opts) do
    {:ok, listen_sock} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        nodelay: true,
        exit_on_close: false
      ])

    {:ok, port} = :inet.port(listen_sock)

    owner = self()

    Task.start(fn -> accept_loop(listen_sock, owner) end)

    {:ok,
     %__MODULE__{
       listen_sock: listen_sock,
       port: port,
       response: Keyword.get(opts, :response, ""),
       last_request: nil
     }}
  end

  @impl true
  def handle_call(:base_url, _from, state) do
    {:reply, "http://127.0.0.1:#{state.port}", state}
  end

  def handle_call({:set_response, response}, _from, state) do
    {:reply, :ok, %{state | response: response}}
  end

  def handle_call({:record_request, req}, _from, state) do
    {:reply, :ok, %{state | last_request: req}}
  end

  def handle_call(:get_response, _from, %{response: [response | rest]} = state) do
    {:reply, response, %{state | response: rest}}
  end

  def handle_call(:get_response, _from, state) do
    {:reply, state.response, state}
  end

  def handle_call(:last_request, _from, state) do
    {:reply, state.last_request, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_sock do
      :gen_tcp.close(state.listen_sock)
    end

    :ok
  end

  defp accept_loop(listen_sock, server) do
    case :gen_tcp.accept(listen_sock, 60_000) do
      {:ok, sock} ->
        Task.start(fn -> serve(sock, server) end)
        accept_loop(listen_sock, server)

      {:error, :timeout} ->
        accept_loop(listen_sock, server)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, server) do
    case read_request(sock) do
      {:ok, request_line, headers, body} ->
        GenServer.call(server, {:record_request, {request_line, headers, body}})
        response = GenServer.call(server, :get_response)
        :ok = :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  defp read_request(sock), do: read_request(sock, "")

  defp read_request(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        case :binary.split(acc, "\r\n\r\n") do
          [head, body_so_far] ->
            headers = parse_headers(head)
            content_length = content_length(headers)
            body = read_body(sock, body_so_far, content_length)
            request_line = head |> String.split("\r\n", parts: 2) |> List.first()
            {:ok, request_line, headers, body}

          _ ->
            read_request(sock, acc)
        end

      {:error, _} = error ->
        error
    end
  end

  defp read_body(_sock, body_so_far, content_length)
       when is_integer(content_length) and byte_size(body_so_far) >= content_length do
    binary_part(body_so_far, 0, content_length)
  end

  defp read_body(sock, body_so_far, content_length) when is_integer(content_length) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        read_body(sock, body_so_far <> data, content_length)

      {:error, _} ->
        binary_part(body_so_far, 0, min(byte_size(body_so_far), max(content_length, 0)))
    end
  end

  defp read_body(_, _, _), do: ""

  defp content_length(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == "content-length" do
        String.to_integer(v)
      end
    end)
  end

  defp parse_headers(head) do
    case String.split(head, "\r\n", trim: true) do
      [_request_line | header_lines] ->
        Enum.map(header_lines, fn line ->
          case String.split(line, ":", parts: 2) do
            [k, v] -> {String.trim(k), String.trim(v)}
            _ -> {line, ""}
          end
        end)

      _ ->
        []
    end
  end
end
