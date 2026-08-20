import Config

# For erlexec
if System.get_env("SHELL") in [nil, ""] do
  System.put_env("SHELL", "/bin/sh")
end

config :erlexec, default_shell: "/bin/sh"

# Distributed tests must not share the developer's real Eva cluster cookie. Otherwise every
# registered extension on the machine can join the test VM and make the suite depend on live
# external topology.
if config_env() == :test do
  config :eva_core,
    cookie_path: Path.expand("../_build/test/cluster.cookie", __DIR__)
end
