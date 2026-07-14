defmodule Eva.AI.Config do
  use TypedStruct

  typedstruct do
    field :base_url, String.t(), enforce: true
    field :endpoint, String.t(), enforce: true
    field :model, String.t(), enforce: true
    field :reasoning_effort, String.t(), default: "none"
    field :system_prompt, String.t()
    field :provider_name, String.t()
  end
end
