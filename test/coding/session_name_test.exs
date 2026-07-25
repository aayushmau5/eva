defmodule Eva.Coding.SessionNameTest do
  use ExUnit.Case

  alias Eva.Coding.SessionName
  alias Eva.AI.Config.OpenAICompatible

  @lm_studio_url Application.compile_env(:eva, :lm_studio_url, "http://localhost:1234")
  @nemotron_model "nvidia/nemotron-3-nano-4b"

  defp name_opts do
    %{
      config: %OpenAICompatible{
        base_url: @lm_studio_url,
        api: "openai-completions",
        provider_name: "lm-studio"
      },
      model: @nemotron_model
    }
  end

  defp lm_studio_alive? do
    uri = URI.parse(@lm_studio_url)
    host = uri.host |> String.to_charlist()
    port = uri.port

    case :gen_tcp.connect(host, port, [], 500) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  describe "sanitize_session_name/1" do
    test "strips quotes and punctuation, takes max four words" do
      assert SessionName.sanitize_session_name(~s("Create a new React component")) ==
               "Create a new React"

      assert SessionName.sanitize_session_name(~s(Hello, world! This is a test.)) ==
               "Hello world This is"

      assert SessionName.sanitize_session_name(~s(`code` block)) == "code block"

      assert SessionName.sanitize_session_name("ok") == "ok"
    end

    test "returns nil when no words remain after sanitizing" do
      assert SessionName.sanitize_session_name(~s("...")) == nil
      assert SessionName.sanitize_session_name("") == nil
    end
  end

  describe "name_session/2 via nemotron" do
    @tag :external
    @tag timeout: 60_000

    test "returns a short name for a user message" do
      unless lm_studio_alive?() do
        IO.puts(
          :stderr,
          "Skipping integration test: LM Studio not reachable at #{@lm_studio_url}"
        )
      else
        name =
          SessionName.name_session("Debug a timeout in my Phoenix LiveView app", name_opts())

        assert is_binary(name)
        assert String.length(name) > 0

        word_count = name |> String.split() |> length()
        assert word_count <= 4
      end
    end

    @tag :external
    @tag timeout: 60_000

    test "returns a short name for a different user message" do
      unless lm_studio_alive?() do
        IO.puts(
          :stderr,
          "Skipping integration test: LM Studio not reachable at #{@lm_studio_url}"
        )
      else
        name = SessionName.name_session("Add rate limiting to the API gateway", name_opts())

        assert is_binary(name)
        assert String.length(name) > 0

        word_count = name |> String.split() |> length()
        assert word_count <= 4
      end
    end
  end
end
