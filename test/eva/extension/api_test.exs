defmodule Eva.Extension.ApiTest do
  use ExUnit.Case, async: true

  alias Eva.Extension.{API, Context}
  alias Eva.Agent.Messages

  defp build_context(attrs \\ []) do
    %Context{
      name: Keyword.get(attrs, :name, "test_ext"),
      cwd: Keyword.get(attrs, :cwd, "/tmp"),
      model: Keyword.get(attrs, :model, "gpt-4"),
      provider_config: Keyword.get(attrs, :provider_config) || build_config(),
      session_pid: Keyword.get(attrs, :session_pid, self()),
      resources: Keyword.get(attrs, :resources) || build_resources(),
      extension_dir: Keyword.get(attrs, :extension_dir, "/tmp/ext")
    }
  end

  defp build_config do
    %Eva.AI.Config.OpenAICompatible{
      base_url: "http://localhost:1/v1",
      provider_name: "test"
    }
  end

  defp build_resources do
    %Eva.Coding.Resources{root: "/tmp/eva"}
  end

  describe "send_user_message/2" do
    test "sends {:extension_user_message, name, text} to session" do
      ctx = build_context()

      API.send_user_message(ctx, "hello from extension")

      assert_receive {:extension_user_message, "test_ext", "hello from extension"}
    end

    test "returns :ok" do
      ctx = build_context()

      assert API.send_user_message(ctx, "hello") == :ok
    end
  end

  describe "send_custom_message/4" do
    test "sends {:extension_custom_message, name, %CustomMessage{}} to session" do
      ctx = build_context()

      API.send_custom_message(ctx, "alert", "warning", %{code: 42})

      assert_receive {:extension_custom_message, "test_ext", %Messages.CustomMessage{} = msg}
      assert msg.custom_type == "warning"
      assert msg.content == "alert"
      assert msg.details == %{code: 42}
    end

    test "details default to empty map" do
      ctx = build_context()

      API.send_custom_message(ctx, "msg", "info")

      assert_receive {:extension_custom_message, "test_ext", %Messages.CustomMessage{} = msg}
      assert msg.details == %{}
    end

    test "returns :ok" do
      ctx = build_context()

      assert API.send_custom_message(ctx, "msg", "info") == :ok
    end
  end

  describe "append_entry/2" do
    test "sends {:extension_entry, name, data} to session" do
      ctx = build_context()

      API.append_entry(ctx, %{key: "value", number: 1})

      assert_receive {:extension_entry, "test_ext", %{key: "value", number: 1}}
    end

    test "returns :ok" do
      ctx = build_context()

      assert API.append_entry(ctx, %{}) == :ok
    end
  end

  describe "notify/3" do
    test "defaults to :info level" do
      ctx = build_context()

      API.notify(ctx, "something happened")

      assert_receive {:extension_notify, :info, "test_ext", "something happened"}
    end

    test "accepts :warning level" do
      ctx = build_context()

      API.notify(ctx, "be careful", :warning)

      assert_receive {:extension_notify, :warning, "test_ext", "be careful"}
    end

    test "accepts :error level" do
      ctx = build_context()

      API.notify(ctx, "it broke", :error)

      assert_receive {:extension_notify, :error, "test_ext", "it broke"}
    end

    test "returns :ok" do
      ctx = build_context()

      assert API.notify(ctx, "note") == :ok
    end
  end

  describe "whereis/2" do
    test "returns nil for unknown extension" do
      ctx = build_context()

      assert API.whereis(ctx, "noext") == nil
    end
  end

  describe "call/4" do
    test "raises when extension has no running process" do
      ctx = build_context()

      assert_raise RuntimeError, ~r/has no running process/, fn ->
        API.call(ctx, "noext", :ping)
      end
    end
  end

  describe "cast/2" do
    test "returns :ok when extension has no running process" do
      ctx = build_context()

      assert API.cast(ctx, "noext", :ping) == :ok
    end
  end
end
