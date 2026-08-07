defmodule Eva.Extension.Hooks do
  @moduledoc """
  Asks extension processes about a tool call, a tool result, or user input, and merges
  their answers into the single value the caller expects.

  Takes the `hook_targets` map from `Eva.Extension.Set` — a plain
  `%{hook => [{name, pid}]}` in discovery order — so nothing here knows what an
  extension is.
  """

  alias Eva.Core.Agent.Tools

  @timeout 5_000

  @type targets :: %{atom() => [{String.t(), pid()}]}

  @doc """
  Builds the function `Loop` calls before each tool runs.

  First blocker wins: the walk stops at the first `{:block, _}` and no later extension
  is asked. A `{:rewrite, args}` swaps the arguments and the next extension sees the
  new ones.
  """
  @spec before_tool_call_fun(targets()) :: (term() -> term())
  def before_tool_call_fun(targets) do
    case Map.get(targets, :tool_call, []) do
      [] -> fn _tool_call -> :proceed end
      listeners -> fn tool_call -> run_tool_call(listeners, tool_call) end
    end
  end

  @doc """
  Builds the function `Loop` calls after each tool runs.

  Every extension runs; each one transforms what the previous produced.
  """
  @spec after_tool_call_fun(targets()) :: (term(), term(), boolean() -> {term(), boolean()})
  def after_tool_call_fun(targets) do
    case Map.get(targets, :tool_result, []) do
      [] ->
        fn _tool_call, result, is_error -> {result, is_error} end

      listeners ->
        fn tool_call, result, is_error ->
          run_tool_result(listeners, tool_call, result, is_error)
        end
    end
  end

  @doc """
  Builds the function the loop calls before each request to the model.

  Every extension runs, each transforming what the previous one produced, like
  `:tool_result`. An extension returns `{:ok, messages}` to change the list;
  anything else leaves it as it was.

  **A failure here is neutral, not fatal.** A crashed or slow `:context` hook passes
  the messages through untouched — unlike `:tool_call`, where an unreachable
  extension blocks the tool. Injecting context is additive, so a memory plugin
  having a bad day must never be able to stop a turn.

  The result is *not* persisted. It shapes what the provider sees for one request;
  the transcript keeps the real messages, so injected context is recomputed each
  time rather than accumulating.
  """
  @spec context_fun(targets()) :: ([term()] -> [term()])
  def context_fun(targets) do
    case Map.get(targets, :context, []) do
      [] ->
        fn messages -> messages end

      listeners ->
        fn messages ->
          Enum.reduce(listeners, messages, fn {_name, pid}, current ->
            case safe_call(pid, {:hook, :context, current}) do
              {:ok, new_messages} when is_list(new_messages) -> new_messages
              _ -> current
            end
          end)
        end
    end
  end

  @doc """
  Runs user input through every extension that registered `:input`.

  `{:transform, text}` feeds forward to the next extension; the first
  `{:handled, message}` stops the chain and means no turn should start.
  """
  @spec run_input(targets(), String.t()) :: {:continue, String.t()} | {:handled, term()}
  def run_input(targets, text) do
    case Map.get(targets, :input, []) do
      [] ->
        {:continue, text}

      listeners ->
        Enum.reduce_while(listeners, {:continue, text}, fn {_name, pid}, {:continue, current} ->
          case safe_call(pid, {:hook, :input, current}) do
            {:transform, new_text} when is_binary(new_text) -> {:cont, {:continue, new_text}}
            {:handled, message} -> {:halt, {:handled, message}}
            _ -> {:cont, {:continue, current}}
          end
        end)
    end
  end

  @doc """
  Calls an extension process with a bounded wait.

  The extension's own `Server` rescues its exceptions, so this only catches a timeout
  or a dead process.
  """
  @spec safe_call(pid(), term()) :: term() | {:error, term()}
  def safe_call(pid, message) do
    GenServer.call(pid, message, @timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  # -- Private --

  defp run_tool_call(listeners, tool_call) do
    listeners
    |> Enum.reduce_while({:ok, tool_call}, fn {name, pid}, {:ok, current} ->
      case safe_call(pid, {:hook, :tool_call, current}) do
        :proceed -> {:cont, {:ok, current}}
        {:rewrite, arguments} -> {:cont, {:ok, %{current | arguments: arguments}}}
        {:block, reason} -> {:halt, {:block, "#{name}: #{reason}"}}
        other -> {:halt, {:block, "#{name}: bad hook return #{inspect(other)}"}}
      end
    end)
    |> case do
      {:ok, ^tool_call} -> :proceed
      {:ok, rewritten} -> {:proceed, rewritten}
      {:block, reason} -> {:block, reason}
    end
  end

  defp run_tool_result(listeners, tool_call, result, is_error) do
    Enum.reduce(listeners, {result, is_error}, fn {_name, pid}, {current, error?} ->
      case safe_call(pid, {:hook, :tool_result, {tool_call, current, error?}}) do
        {%Tools.AgentToolResult{} = new_result, new_error?} when is_boolean(new_error?) ->
          {new_result, new_error?}

        _ ->
          {current, error?}
      end
    end)
  end
end
