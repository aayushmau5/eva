defmodule Eva.Extension.Capabilities do
  @moduledoc """
  The host half of the capability API.

  Extensions never call into Eva directly. They hold a `Context`, and `Context`
  carries this module — so `Eva.Extension.UI` and anything like it dispatches
  through a module reference rather than naming a host module. That indirection is
  what lets the same extension run somewhere other than Eva's own VM later without
  a line changing.

  Right now the only capability is asking the user, and it is a stub that always
  answers with the caller's default. The real implementation — publishing a prompt
  on the bus and waiting for a frontend — lands with the UI work.
  """

  @doc """
  Asks the user a question and returns their answer.

  Until the UI capability is built this always returns `default` immediately, which
  is also the correct behaviour whenever no frontend is attached: print mode,
  scripts, and tests must never block on a dialog nobody can see.
  """
  @spec ask(map(), term(), keyword()) :: term()
  def ask(_question, default, _opts \\ []), do: default
end
