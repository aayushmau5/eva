defmodule Eva.Extension.MCP.Transport.Http do
  @moduledoc """
  Talks to an MCP server over Streamable HTTP.

  Each outbound message runs its own request in a supervised, unlinked `Task`
  so a slow or crashed request can never block or take down `Client`. The
  response — `application/json` (one immediate reply) or `text/event-stream`
  (zero or more progress events followed by the reply, scoped to this one
  request) — is decoded back into the same `{:frames, lines, transport}` shape
  `Transport.Stdio` already produces, so `Client` needs no transport-specific
  branching.
  """
  use TypedStruct

  alias Eva.Extension.MCP.Config

  typedstruct do
    field :config, Config.t()
    field :session_id, String.t(), default: nil
    field :listening_pid, pid(), default: nil
  end

  @spec connect(Config.t()) :: {:ok, t()} | {:error, term()}
  def connect(%Config{config: %Config.Http{}} = config) do
    {:ok, %__MODULE__{config: config}}
  end
end

defimpl Eva.Extension.MCP.Transport, for: Eva.Extension.MCP.Transport.Http do
  require Logger

  alias Eva.Extension.MCP.{Config, Protocol, SSE}
  alias Eva.Extension.MCP.Transport.Http

  @receive_timeout 60_000
  @listen_retry_ms 2_000

  @spec send_message(Http.t(), iodata()) :: :ok | {:error, term()}
  def send_message(%Http{} = transport, message) do
    client_pid = self()
    ref = make_ref()

    # sending a message and handling responses work in their own process.
    case Task.Supervisor.start_child(Eva.Extension.MCP.TaskSupervisor, fn ->
           run(transport, message, client_pid, ref)
         end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Guarded on `listening_pid`, not `session_id` — a server that never
  # assigns one would leave `session_id` nil forever and re-trigger this on
  # every response otherwise.
  def handle_message(%Http{listening_pid: nil} = transport, {:mcp_http_headers, _ref, headers}) do
    client_pid = self()
    transport = %Http{transport | session_id: session_id(headers)}
    listening_pid = start_listening(transport, client_pid)
    {:ignore, %Http{transport | listening_pid: listening_pid}}
  end

  def handle_message(%Http{}, {:mcp_http_headers, _ref, _headers}), do: :ignore

  def handle_message(%Http{} = transport, {:mcp_http_frame, _ref, line}) do
    {:frames, [line], transport}
  end

  def handle_message(_transport, _message), do: :ignore

  def close(%Http{listening_pid: nil}), do: :ok

  def close(%Http{listening_pid: pid}) do
    Task.Supervisor.terminate_child(Eva.Extension.MCP.TaskSupervisor, pid)
    :ok
  end

  # -- Private --

  defp run(%Http{} = transport, message, client_pid, ref) do
    %Config{config: %Config.Http{url: url}} = transport.config

    Finch.build(:post, url, request_headers(transport), IO.iodata_to_binary(message))
    |> Finch.stream(
      Eva.Extension.MCP.Finch,
      %{status: nil, content_type: nil, buffer: ""},
      fn event, acc -> handle_event(event, acc, client_pid, ref) end,
      receive_timeout: @receive_timeout
    )
    |> finalize(message, client_pid, ref)
  end

  defp handle_event({:status, status}, acc, _client_pid, _ref), do: %{acc | status: status}

  defp handle_event({:headers, headers}, acc, client_pid, ref) do
    send(client_pid, {:mcp_http_headers, ref, headers})
    %{acc | content_type: content_type(headers)}
  end

  defp handle_event({:trailers, _}, acc, _client_pid, _ref), do: acc

  defp handle_event({:data, chunk}, %{content_type: :event_stream} = acc, client_pid, ref) do
    {events, remainder} = SSE.feed(acc.buffer, chunk)
    Enum.each(events, fn {_id, data} -> send(client_pid, {:mcp_http_frame, ref, data}) end)
    %{acc | buffer: remainder}
  end

  defp handle_event({:data, chunk}, acc, _client_pid, _ref) do
    %{acc | buffer: acc.buffer <> chunk}
  end

  # A non-2xx status always means failure, regardless of what Content-Type it
  # claims — checked before branching on content type.
  defp finalize({:ok, %{status: status} = acc}, message, client_pid, ref)
       when status not in 200..299 do
    emit_error(message, client_pid, ref, "HTTP #{status}" <> body_suffix(acc.buffer))
  end

  # 202 with an empty body — the response to a notification we sent. Success
  # with nothing to decode, not an error.
  defp finalize({:ok, %{content_type: :json, buffer: ""}}, _message, _client_pid, _ref), do: :ok

  defp finalize({:ok, %{content_type: :json, buffer: buffer}}, _message, client_pid, ref) do
    send(client_pid, {:mcp_http_frame, ref, buffer})
    :ok
  end

  # SSE frames were already forwarded as they arrived — nothing left to flush.
  defp finalize({:ok, %{content_type: :event_stream}}, _message, _client_pid, _ref), do: :ok

  defp finalize({:ok, _acc}, message, client_pid, ref) do
    emit_error(message, client_pid, ref, "Unexpected response Content-Type")
  end

  defp finalize({:error, reason, _acc}, message, client_pid, ref) do
    emit_error(message, client_pid, ref, "Transport error: #{inspect(reason)}")
  end

  # A request failure has no server-sent frame to route through `Client`'s
  # normal decode path — synthesize one. Reusing `Protocol.encode_error/3`
  # means this flows through exactly the same `decode/1` -> `route_response/3`
  # path a genuine server error would, so nothing downstream needs to know
  # the difference. A failed notification (no `id`) has no pending waiter to
  # reach either way, so it's just logged.
  defp emit_error(message, client_pid, ref, description) do
    case request_id(message) do
      nil ->
        Logger.warning("MCP HTTP request failed: #{description}")

      id ->
        error_line = Protocol.encode_error(id, -32_000, description) |> IO.iodata_to_binary()
        send(client_pid, {:mcp_http_frame, ref, error_line})
    end
  end

  defp request_id(message) do
    case JSON.decode(IO.iodata_to_binary(message)) do
      {:ok, %{"id" => id}} -> id
      _ -> nil
    end
  end

  defp body_suffix(""), do: ""
  defp body_suffix(body), do: ": #{body}"

  defp content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, value} ->
        cond do
          String.contains?(value, "text/event-stream") -> :event_stream
          String.contains?(value, "application/json") -> :json
          true -> :unknown
        end

      nil ->
        :unknown
    end
  end

  defp session_id(headers) do
    case List.keyfind(headers, "mcp-session-id", 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp request_headers(%Http{config: config, session_id: session_id}) do
    %Config{config: %Config.Http{headers: extra_headers}} = config

    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]
    |> maybe_put_session_id(session_id)
    |> merge_headers(extra_headers)
  end

  defp maybe_put_session_id(headers, nil), do: headers
  defp maybe_put_session_id(headers, session_id), do: [{"mcp-session-id", session_id} | headers]

  defp maybe_put_last_event_id(headers, nil), do: headers
  defp maybe_put_last_event_id(headers, id), do: [{"last-event-id", id} | headers]

  # -- Listening stream --
  #
  # Standalone `GET`, not tied to any outgoing message — how a server pushes
  # something (e.g. `notifications/tools/list_changed`) while we have no
  # request in flight. Runs for the connection's whole life, in its own Task,
  # separate from `Client`'s connection-level backoff: a drop here just means
  # a short reconnect of this one stream, not a `ServerError`.
  defp start_listening(%Http{} = transport, client_pid) do
    case Task.Supervisor.start_child(Eva.Extension.MCP.TaskSupervisor, fn ->
           listen(transport, client_pid, nil)
         end) do
      {:ok, pid} -> pid
      {:error, _reason} -> nil
    end
  end

  defp listen(%Http{} = transport, client_pid, last_event_id) do
    %Config{config: %Config.Http{url: url}} = transport.config
    ref = make_ref()

    Finch.build(:get, url, listen_headers(transport, last_event_id))
    |> Finch.stream(
      Eva.Extension.MCP.Finch,
      %{status: nil, buffer: "", last_id: last_event_id},
      fn event, acc -> handle_listen_event(event, acc, client_pid, ref) end,
      receive_timeout: :infinity
    )
    |> retry_or_stop(transport, client_pid)
  end

  defp handle_listen_event({:status, status}, acc, _client_pid, _ref), do: %{acc | status: status}
  defp handle_listen_event({:headers, _headers}, acc, _client_pid, _ref), do: acc
  defp handle_listen_event({:trailers, _}, acc, _client_pid, _ref), do: acc

  defp handle_listen_event({:data, chunk}, acc, client_pid, ref) do
    {events, remainder} = SSE.feed(acc.buffer, chunk)

    last_id =
      Enum.reduce(events, acc.last_id, fn
        {nil, _data}, id -> id
        {event_id, _data}, _id -> event_id
      end)

    Enum.each(events, fn {_id, data} -> send(client_pid, {:mcp_http_frame, ref, data}) end)

    %{acc | buffer: remainder, last_id: last_id}
  end

  # Server doesn't support the standalone stream at all (spec permits
  # omitting it) — give up quietly. eva has no roots/sampling, so the only
  # cost is list-changed notifications arriving late, on the next unrelated
  # request, rather than not at all.
  defp retry_or_stop({:ok, %{status: status}}, _transport, _client_pid)
       when status in [404, 405] do
    Logger.info(
      "MCP server has no listening stream (HTTP #{status}) — notifications will be late"
    )
  end

  defp retry_or_stop({:ok, %{last_id: last_id}}, transport, client_pid) do
    Process.sleep(@listen_retry_ms)
    listen(transport, client_pid, last_id)
  end

  defp retry_or_stop({:error, _reason, %{last_id: last_id}}, transport, client_pid) do
    Process.sleep(@listen_retry_ms)
    listen(transport, client_pid, last_id)
  end

  defp listen_headers(%Http{config: config, session_id: session_id}, last_event_id) do
    %Config{config: %Config.Http{headers: extra_headers}} = config

    [{"accept", "text/event-stream"}]
    |> maybe_put_session_id(session_id)
    |> maybe_put_last_event_id(last_event_id)
    |> merge_headers(extra_headers)
  end

  defp merge_headers(headers, nil), do: headers

  defp merge_headers(headers, extra) when is_map(extra) do
    Enum.reduce(extra, headers, fn {key, value}, acc ->
      [{String.downcase(to_string(key)), to_string(value)} | acc]
    end)
  end
end
