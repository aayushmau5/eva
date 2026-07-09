import Config

# For erlexec
if System.get_env("SHELL") in [nil, ""] do
  System.put_env("SHELL", "/bin/sh")
end

config :erlexec, default_shell: "/bin/sh"
