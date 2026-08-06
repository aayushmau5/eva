defmodule Eva.Extension.MCP.Config do
  @moduledoc """
  The `mcp.json` files: where they are, what is in them, and flipping `enabled`.

  Two scopes, global and project, exactly as before this was an extension — the file
  format is the user's, not Eva's, and moving out of core must not move their config.
  """

  use TypedStruct

  typedstruct do
    field :scope_dir, :global | String.t(), default: :global
    field :name, String.t()
    field :type, :stdio | :http
    field :config, Stdio.t() | Http.t()
    field :enabled, boolean()
  end

  typedstruct module: Stdio do
    field :command, String.t()
    field :args, [String.t()], default: []
    field :env, map()
    field :cwd, String.t()
  end

  typedstruct module: Http do
    field :url, String.t()
    field :headers, map()
  end

  typedstruct module: Paths do
    @moduledoc """
    Where to look for `mcp.json`.

    An extension is handed `cwd` in its `Context` and finds `home` for itself; this used
    to be `Eva.Coding.Resources`, which belongs to the host and cannot be named from here.
    """

    field :home, String.t(), default: Path.join(Path.expand("~"), ".eva")
    field :cwd, String.t()
  end

  @spec config_path(Paths.t(), :global | String.t()) :: String.t()
  def config_path(%Paths{home: home}, :global), do: Path.join(home, "mcp.json")
  def config_path(%Paths{}, cwd), do: Path.join([cwd, ".eva", "mcp.json"])

  @doc """
  Flips `enabled` for a server in the `mcp.json` it was defined in.

  Only that one key is touched, but the whole file is re-encoded, so the user's
  key order and formatting do not survive — `:json.format/1` at least keeps the
  result readable, which matters for a file people hand-edit. The write lands on
  a sibling temp file first so a failure part-way through can never leave a
  truncated MCP config behind.
  """
  @spec set_enabled(Paths.t(), t(), boolean()) :: {:ok, t()} | {:error, term()}
  def set_enabled(%Paths{} = paths, %__MODULE__{} = config, flag) do
    path = config_path(paths, config.scope_dir)

    with {:ok, json} <- read_for_write(path),
         {:ok, server} <- fetch_server(json, config.name),
         :ok <- write(path, put_in(json, ["mcpServers", config.name], enable(server, flag))) do
      {:ok, %__MODULE__{config | enabled: flag}}
    end
  end

  @spec parse(Paths.t()) :: {[t()], [JSON.decode_error_reason()]}
  def parse(%Paths{cwd: cwd} = paths) do
    global_mcp_path = config_path(paths, :global)
    project_mcp_path = config_path(paths, cwd)

    global_mcp_config = read(global_mcp_path)
    project_mcp_config = read(project_mcp_path)

    {global_mcps, global_diagnostics} =
      parse_mcp_config_from_json(global_mcp_config, global_mcp_path, :global)

    {project_mcps, project_diagnostics} =
      parse_mcp_config_from_json(project_mcp_config, project_mcp_path, cwd)

    {dedup_and_merge(global_mcps, project_mcps), global_diagnostics ++ project_diagnostics}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> JSON.decode(binary)
      {:error, _} -> nil
    end
  end

  defp parse_mcp_config_from_json(nil, _, _), do: {[], []}
  defp parse_mcp_config_from_json({:error, reason}, _, _), do: {[], [reason]}

  defp parse_mcp_config_from_json({:ok, mcp_config_json}, path, scope) do
    mcps = Map.get(mcp_config_json, "mcpServers")

    if mcps == [] do
      {[], ["Missing `mcpServers` key in #{path}"]}
    else
      {servers, diagnostics} =
        Enum.reduce(mcps, {[], []}, fn {name, config_json}, {servers, diagnostics} ->
          case server_type(config_json) do
            "stdio" ->
              {[make_stdio(name, scope, config_json) | servers], diagnostics}

            "http" ->
              {[make_http(name, scope, config_json) | servers], diagnostics}

            :unknown ->
              {servers, ["Cannot determine MCP server type for #{name}" | diagnostics]}

            type ->
              {servers, ["Unknown type for #{name}: #{type}" | diagnostics]}
          end
        end)

      {Enum.reverse(servers), Enum.reverse(diagnostics)}
    end
  end

  defp server_type(config_json) do
    cond do
      type = Map.get(config_json, "type") ->
        type

      Map.has_key?(config_json, "command") ->
        "stdio"

      Map.has_key?(config_json, "url") ->
        "http"

      true ->
        :unknown
    end
  end

  defp make_stdio(name, scope, config_json) do
    command = Map.get(config_json, "command")
    args = Map.get(config_json, "args", [])
    # TODO: do `${}` interpolation in the env(ex. "${GITHUB_TOKEN}")
    env = Map.get(config_json, "env")
    enabled = Map.get(config_json, "enabled", true)
    cwd = Map.get(config_json, "cwd")
    config = %Stdio{command: command, args: args, env: env, cwd: cwd}

    %__MODULE__{
      scope_dir: scope,
      name: name,
      type: :stdio,
      config: config,
      enabled: enabled
    }
  end

  defp make_http(name, scope, config_json) do
    url = Map.get(config_json, "url")
    headers = Map.get(config_json, "headers")
    enabled = Map.get(config_json, "enabled", true)

    config = %Http{url: url, headers: headers}

    %__MODULE__{
      scope_dir: scope,
      name: name,
      type: :http,
      config: config,
      enabled: enabled
    }
  end

  # Project entries win outright over global ones with the same name
  defp dedup_and_merge(global_mcps, project_mcps) do
    project_names = MapSet.new(project_mcps, & &1.name)

    global_mcps
    |> Enum.reject(&MapSet.member?(project_names, &1.name))
    |> Enum.concat(project_mcps)
  end

  defp read_for_write(path) do
    case read(path) do
      nil -> {:error, :not_found}
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_server(%{"mcpServers" => servers}, name) when is_map(servers) do
    case Map.get(servers, name) do
      server when is_map(server) -> {:ok, server}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_server(_json, _name), do: {:error, :not_found}

  defp enable(server, flag), do: Map.put(server, "enabled", flag)

  defp write(path, json) do
    tmp = path <> ".tmp"

    with :ok <- path |> Path.dirname() |> File.mkdir_p(),
         # `:json.format/1` already ends the document with a newline.
         :ok <- File.write(tmp, :json.format(json)) do
      File.rename(tmp, path)
    end
  end
end
