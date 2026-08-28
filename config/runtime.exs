import Config

config :eva, :provider, :lmstudio
config :eva, :opencode_api_key, System.get_env("OPENCODE_API_KEY")

epmd =
  case System.get_env("EVA_EPMD", "true") do
    value when value in ["1", "true"] -> true
    value when value in ["0", "false"] -> false
    value -> raise "EVA_EPMD must be true or false, got: #{inspect(value)}"
  end

distribution =
  case System.get_env("EVA_DISTRIBUTION_PORT") do
    nil ->
      case System.get_env("EVA_DISTRIBUTION") do
        value when value in ["1", "true"] -> [epmd: epmd]
        value when value in [nil, "", "0", "false"] -> false
        value -> raise "EVA_DISTRIBUTION must be true or false, got: #{inspect(value)}"
      end

    value ->
      port =
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 ->
            port

          _other ->
            raise "EVA_DISTRIBUTION_PORT must be an integer from 1 to 65535, got: #{inspect(value)}"
        end

      case System.get_env("EVA_DISTRIBUTION_NAME") do
        name when name not in [nil, ""] -> [port: port, name: name, epmd: epmd]
        _unset -> [port: port, epmd: epmd]
      end
  end

config :eva, distribution: distribution
