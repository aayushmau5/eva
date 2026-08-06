# `:distributed` tests need a named VM, which a booted one cannot become — `mix test.dist`
# starts one and includes them, and `mix test.all` runs both halves.
ExUnit.start(exclude: [:distributed])
Application.ensure_all_started(:eva)
