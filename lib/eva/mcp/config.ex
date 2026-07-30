defmodule Eva.MCP.Config do
  use TypedStruct
  alias Eva.Coding.Resources

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

  @spec parse(Resources.t()) :: {[t()], [JSON.decode_error_reason()]}
  def parse(%Resources{cwd: cwd, root: root}) do
    global_mcp_path = Path.join(root, "mcp.json")
    project_mcp_path = Path.join([cwd, ".eva", "mcp.json"])

    global_mcp_config = read(global_mcp_path)
    project_mcp_config = read(project_mcp_path)

    {global_mcps, global_diagnostics} =
      parse_mcp_config_from_json(global_mcp_config, global_mcp_path, :global)

    {project_mcps, project_diagnostics} =
      parse_mcp_config_from_json(project_mcp_config, project_mcp_path, cwd)

    {dedup_and_merge(global_mcps, project_mcps) |> Enum.filter(& &1.enabled),
     global_diagnostics ++ project_diagnostics}
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
end
