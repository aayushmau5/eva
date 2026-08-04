defmodule Eva.Extension do
  @moduledoc """
  The contract between Eva and extension.
  The extension file lives as an elixir script(.exs).

  Context is passed to each functions of the extension.

  Usage:
  ```
  use Eva.Extension

  def setup(ctx) do
    spec = %Spec{
      tools: [....],
      guidelines: [....],
      hooks: [..., ...]
    }

    {:ok, spec}
  end
  ```
  """

  use TypedStruct

  # Context gets passed to the extension callback functions
  typedstruct module: Context do
    field :name, String.t()
    field :cwd, String.t()
    field :model, String.t()
    # Passing provider_config so a subagent extension can spawn its own provider.
    # Opaque on purpose: an extension hands it straight back to the host rather than
    # reading it, so the type does not have to survive the move to `eva_core`.
    field :provider_config, term()
    field :session_pid, pid()
    field :extension_dir, String.t()
    # This extension's own entries, oldest first, replayed from the transcript.
    field :entries, [map()], default: []
    # The host half of the capability API. `Eva.Extension.UI` and friends dispatch
    # through this rather than naming a host module, so the same extension works
    # unchanged when it runs somewhere other than Eva's own VM.
    field :capabilities, module()
  end

  @callback setup(Context.t()) :: {:ok, Eva.Extension.Spec.t()} | {:error, term()}
  @callback init(Context.t()) :: {:ok, state :: term()} | {:error, term()}
  @callback handle_event(event :: struct(), state :: term()) ::
              {:ok, state :: term()}
  @callback handle_hook(hook :: atom(), payload :: term(), state :: term()) ::
              {result :: term(), state :: term()}
  @callback handle_command(
              name :: String.t(),
              args :: String.t(),
              state :: term()
            ) ::
              {reply :: term(), state :: term()}

  @callback handle_request(request :: term(), state :: term()) ::
              {reply :: term(), state :: term()}

  @typedoc """
  Why an extension is being stopped.
  """
  @type terminate_reason :: :shutdown | :reload | :disabled

  @callback terminate(reason :: terminate_reason(), state :: term()) :: :ok

  @optional_callbacks init: 1,
                      handle_event: 2,
                      handle_hook: 3,
                      handle_command: 3,
                      handle_request: 2,
                      terminate: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Eva.Extension

      alias Eva.Extension.{Spec, API}
      alias Eva.Agent.{Messages, Tools}

      @doc false
      def __eva_extension__, do: true

      @impl true
      def init(_ctx), do: {:ok, nil}

      @impl true
      def handle_event(_event, state), do: {:ok, state}

      @impl true
      def handle_hook(_hook, _payload, state), do: {:proceed, state}

      @impl true
      def handle_command(_name, _args, state), do: {{:error, :not_implemented}, state}

      @impl true
      def handle_request(_request, state), do: {{:error, :not_implemented}, state}

      @impl true
      def terminate(_reason, _state), do: :ok

      defoverridable init: 1,
                     handle_event: 2,
                     handle_hook: 3,
                     handle_command: 3,
                     handle_request: 2,
                     terminate: 2
    end
  end
end
