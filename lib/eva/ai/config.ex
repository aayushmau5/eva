defmodule Eva.AI.Config do
  use TypedStruct

  typedstruct module: RuntimeProviderAuth do
    field :api_key, String.t()
    field :base_url, String.t()
    field :headers, map()
  end

  typedstruct module: OpenAICompatible do
    field :api_key, String.t()
    field :base_url, String.t(), enforce: true
    field :headers, map()
    field :timeout_seconds, non_neg_integer(), default: 60
    field :max_retries, non_neg_integer(), default: 2
    field :max_retry_delay_seconds, float(), default: 1.0
    field :api, String.t(), default: "openai-completions"
    field :max_tokens, integer()
    field :reasoning_effort, String.t()
    field :thinking_format, String.t(), default: "openai"
    field :compat, map(), default: %{}
    field :include_reasoning_effort_none_in_payload, boolean(), default: false
    field :provider_name, String.t(), default: "OpenAI-compatible provider"
    field :omit_authorization_header, boolean(), default: false
    field :credential_resolver, (-> Eva.AI.Config.RuntimeProviderAuth.t()), default: nil
  end
end
