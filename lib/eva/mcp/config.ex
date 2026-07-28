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
    global_mcp_config = Path.join(root, "mcp.json") |> read()
    project_mcp_config = Path.join([cwd, ".eva", "mcp.json"]) |> read()

    {global_mcps, global_diagnostics} =
      parse_mcp_config_from_json(global_mcp_config, :global)

    {project_mcps, project_diagnostics} =
      parse_mcp_config_from_json(project_mcp_config, cwd)

    {dedup_and_merge(global_mcps, project_mcps) |> Enum.filter(& &1.enabled),
     global_diagnostics ++ project_diagnostics}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> JSON.decode(binary)
      {:error, _} -> nil
    end
  end

  defp parse_mcp_config_from_json(nil, _), do: {[], []}
  defp parse_mcp_config_from_json({:error, reason}, _), do: {[], [reason]}

  defp parse_mcp_config_from_json({:ok, mcp_config_json}, scope) do
    mcps = Map.fetch!(mcp_config_json, "mcpServers")

    servers =
      Enum.map(mcps, fn {name, config_json} ->
        type = Map.fetch!(config_json, "type")

        case type do
          "stdio" ->
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

          "http" ->
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
      end)

    {servers, []}
  end

  # Project entries win outright over global ones with the same name
  defp dedup_and_merge(global_mcps, project_mcps) do
    project_names = MapSet.new(project_mcps, & &1.name)

    global_mcps
    |> Enum.reject(&MapSet.member?(project_names, &1.name))
    |> Enum.concat(project_mcps)
  end
end
