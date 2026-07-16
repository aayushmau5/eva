defmodule Eva.Coding.SessionNameTest do
  use ExUnit.Case

  alias Eva.Coding.SessionName

  @nemotron_model "nvidia/nemotron-3-nano-4b"

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
      name =
        SessionName.name_session("Debug a timeout in my Phoenix LiveView app", @nemotron_model)

      assert is_binary(name)
      assert String.length(name) > 0

      word_count = name |> String.split() |> length()
      assert word_count <= 4
    end

    @tag :external
    @tag timeout: 60_000

    test "returns a short name for a different user message" do
      name = SessionName.name_session("Add rate limiting to the API gateway", @nemotron_model)

      assert is_binary(name)
      assert String.length(name) > 0

      word_count = name |> String.split() |> length()
      assert word_count <= 4
    end
  end
end
