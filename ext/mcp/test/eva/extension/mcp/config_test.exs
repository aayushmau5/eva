defmodule Eva.Extension.MCP.ConfigTest do
  use ExUnit.Case, async: false

  alias Eva.Extension.MCP.Config.Paths
  alias Eva.Extension.MCP.Config

  describe "parse/1" do
    test "returns empty list when no config files exist" do
      dir = mktmp()
      paths = %Paths{home: dir, cwd: dir}

      {mcps, diagnostics} = Config.parse(paths)

      assert mcps == []
      assert diagnostics == []
    end

    test "parses a global stdio server" do
      tmp = mktmp()

      write_mcp_json(tmp, "mcp.json", %{
        "mcpServers" => %{
          "my-server" => %{
            "type" => "stdio",
            "command" => "node",
            "args" => ["server.js"]
          }
        }
      })

      paths = %Paths{home: tmp, cwd: tmp}

      {mcps, diagnostics} = Config.parse(paths)
      assert diagnostics == []
      assert length(mcps) == 1

      mcp = List.first(mcps)
      assert mcp.scope_dir == :global
      assert mcp.name == "my-server"
      assert mcp.type == :stdio
      assert mcp.enabled == true
      assert mcp.config.command == "node"
      assert mcp.config.args == ["server.js"]
    end

    test "parses a global http server" do
      tmp = mktmp()

      write_mcp_json(tmp, "mcp.json", %{
        "mcpServers" => %{
          "http-server" => %{
            "type" => "http",
            "url" => "https://api.example.com/mcp",
            "headers" => %{"Authorization" => "Bearer token"}
          }
        }
      })

      paths = %Paths{home: tmp, cwd: tmp}

      {mcps, _diagnostics} = Config.parse(paths)
      assert length(mcps) == 1

      mcp = List.first(mcps)
      assert mcp.name == "http-server"
      assert mcp.type == :http
      assert mcp.config.url == "https://api.example.com/mcp"
      assert mcp.config.headers == %{"Authorization" => "Bearer token"}
    end

    test "parses a project-level stdio server" do
      tmp = mktmp()
      eva_dir = Path.join(tmp, ".eva")
      File.mkdir_p!(eva_dir)

      write_mcp_json(eva_dir, "mcp.json", %{
        "mcpServers" => %{
          "project-server" => %{
            "type" => "stdio",
            "command" => "python",
            "args" => ["-m", "mcp_server"]
          }
        }
      })

      # root has no mcp.json; project (.eva/mcp.json) provides the server
      root_dir = mktmp()
      paths = %Paths{home: root_dir, cwd: tmp}

      {mcps, _diagnostics} = Config.parse(paths)
      assert length(mcps) == 1

      mcp = List.first(mcps)
      assert mcp.scope_dir == tmp
      assert mcp.name == "project-server"
      assert mcp.config.command == "python"
      assert mcp.config.args == ["-m", "mcp_server"]
    end

    test "project config overrides global config for the same server name" do
      root = mktmp()
      cwd = mktmp()
      eva_dir = Path.join(cwd, ".eva")
      File.mkdir_p!(eva_dir)

      write_mcp_json(root, "mcp.json", %{
        "mcpServers" => %{
          "shared-server" => %{
            "type" => "stdio",
            "command" => "global-cmd"
          }
        }
      })

      write_mcp_json(eva_dir, "mcp.json", %{
        "mcpServers" => %{
          "shared-server" => %{
            "type" => "stdio",
            "command" => "project-cmd"
          }
        }
      })

      paths = %Paths{home: root, cwd: cwd}

      {mcps, diagnostics} = Config.parse(paths)
      assert diagnostics == []
      assert length(mcps) == 1

      mcp = List.first(mcps)
      assert mcp.name == "shared-server"
      assert mcp.config.command == "project-cmd"
      assert mcp.scope_dir == cwd
    end

    test "project and global servers merge when names differ" do
      root = mktmp()
      cwd = mktmp()
      eva_dir = Path.join(cwd, ".eva")
      File.mkdir_p!(eva_dir)

      write_mcp_json(root, "mcp.json", %{
        "mcpServers" => %{
          "global-server" => %{
            "type" => "stdio",
            "command" => "global-cmd"
          }
        }
      })

      write_mcp_json(eva_dir, "mcp.json", %{
        "mcpServers" => %{
          "project-server" => %{
            "type" => "stdio",
            "command" => "project-cmd"
          }
        }
      })

      paths = %Paths{home: root, cwd: cwd}

      {mcps, _diagnostics} = Config.parse(paths)
      assert length(mcps) == 2

      names = Enum.map(mcps, & &1.name) |> Enum.sort()
      assert names == ["global-server", "project-server"]
    end

    # Disabled servers are returned, not dropped — a frontend has to be able to list
    # and re-enable them. Honouring `enabled` is the caller's job.
    test "flags disabled servers instead of dropping them" do
      tmp = mktmp()

      write_mcp_json(tmp, "mcp.json", %{
        "mcpServers" => %{
          "enabled-server" => %{
            "type" => "stdio",
            "command" => "enabled-cmd"
          },
          "disabled-server" => %{
            "type" => "stdio",
            "command" => "disabled-cmd",
            "enabled" => false
          }
        }
      })

      paths = %Paths{home: tmp, cwd: tmp}

      {mcps, _diagnostics} = Config.parse(paths)

      assert %{"enabled-server" => true, "disabled-server" => false} =
               Map.new(mcps, &{&1.name, &1.enabled})
    end

    test "returns diagnostics for JSON decode errors" do
      tmp = mktmp()
      File.write!(Path.join(tmp, "mcp.json"), "{not valid json")

      paths = %Paths{home: tmp, cwd: tmp}

      {mcps, diagnostics} = Config.parse(paths)

      assert mcps == []
      assert length(diagnostics) == 1
    end
  end

  # `System.unique_integer/0` restarts from the same values on each VM boot, so
  # without the cleanup a run inherits whatever the previous run left in the dir
  # it happens to draw.
  defp mktmp do
    dir = Path.join(System.tmp_dir!(), "eva_config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_mcp_json(dir, filename, content) do
    path = Path.join(dir, filename)
    json = JSON.encode_to_iodata!(content) |> IO.iodata_to_binary()
    File.write!(path, json)
  end
end
