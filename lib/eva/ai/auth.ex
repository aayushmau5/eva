defmodule Eva.AI.Auth do
  alias Eva.AI.Config

  @doc """
  Resolve auth for providers.
  """
  @spec resolve(Config.OpenAICompatible.t()) :: Config.RuntimeProviderAuth.t()
  def resolve(%Config.OpenAICompatible{} = config) do
    # TODO: handle error here because `credential_resolver` can raise
    auth =
      if config.credential_resolver,
        do: config.credential_resolver.(),
        else: %Config.RuntimeProviderAuth{}

    %Config.RuntimeProviderAuth{
      base_url: auth.base_url || config.base_url,
      api_key: auth.api_key || config.api_key,
      headers: Map.merge(config.headers || %{}, auth.headers || %{})
    }
  end

  @doc """
  Converts RuntimeProviderAuth.headers into a List
  """
  @spec headers(Config.RuntimeProviderAuth.t(), boolean()) :: [{String.t(), String.t()}]
  def headers(%Config.RuntimeProviderAuth{} = auth, omit_authorization?) do
    %{"content-type" => "application/json"}
    |> maybe_put_authorization(auth.api_key, omit_authorization?)
    |> merge_extra(auth.headers)
    |> Map.to_list()
  end

  defp maybe_put_authorization(headers, _api_key, true), do: headers

  defp maybe_put_authorization(headers, api_key, _omit) when is_binary(api_key) do
    case String.trim(api_key) do
      "" -> headers
      api_key -> Map.put(headers, "authorization", "Bearer #{api_key}")
    end
  end

  defp maybe_put_authorization(headers, _api_key, _omit), do: headers

  defp merge_extra(headers, nil), do: headers

  defp merge_extra(headers, extra) when is_map(extra) do
    Enum.into(extra, headers, fn {name, value} ->
      {to_string(name) |> String.downcase(), to_string(value)}
    end)
  end
end
