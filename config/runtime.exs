import Config

config :eva, :provider, :lmstudio
config :eva, :opencode_api_key, System.get_env("OPENCODE_API_KEY")
