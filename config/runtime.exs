import Config

config :eva, :provider, :lmstudio
config :eva, :opencode_api_key, System.get_env("OPENCODE_API_KEY")

if value = System.get_env("EVA_DISTRIBUTION_PORT") do
  port =
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 ->
        port

      _other ->
        raise "EVA_DISTRIBUTION_PORT must be an integer from 1 to 65535, got: #{inspect(value)}"
    end

  distribution =
    case System.get_env("EVA_DISTRIBUTION_NAME") do
      name when name not in [nil, ""] -> [port: port, name: name]
      _unset -> [port: port]
    end

  config :eva, distribution: distribution
end
