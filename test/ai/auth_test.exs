defmodule Eva.AI.AuthTest do
  use ExUnit.Case, async: true

  alias Eva.AI.{Auth, Config}

  describe "resolve/1" do
    test "uses config values when no credential_resolver is set" do
      config = %Config.OpenAICompatible{
        base_url: "https://api.example.com",
        api_key: "sk-config-key",
        headers: %{"x-custom" => "config-val"}
      }

      auth = Auth.resolve(config)

      assert auth.base_url == "https://api.example.com"
      assert auth.api_key == "sk-config-key"
      assert auth.headers["x-custom"] == "config-val"
    end

    test "uses resolver values over config when credential_resolver is set" do
      config = %Config.OpenAICompatible{
        base_url: "https://api.config.com",
        api_key: "sk-config-key",
        headers: %{"x-custom" => "config-val"},
        credential_resolver: fn ->
          %Config.RuntimeProviderAuth{
            base_url: "https://api.resolved.com",
            api_key: "sk-resolved-key",
            headers: %{"x-custom" => "resolved-val"}
          }
        end
      }

      auth = Auth.resolve(config)

      assert auth.base_url == "https://api.resolved.com"
      assert auth.api_key == "sk-resolved-key"
      assert auth.headers["x-custom"] == "resolved-val"
    end

    test "falls back to config when resolver returns empty auth" do
      config = %Config.OpenAICompatible{
        base_url: "https://api.config.com",
        api_key: "sk-config-key",
        credential_resolver: fn -> %Config.RuntimeProviderAuth{} end
      }

      auth = Auth.resolve(config)

      assert auth.base_url == "https://api.config.com"
      assert auth.api_key == "sk-config-key"
    end

    test "merges resolver and config when resolver returns partial auth" do
      config = %Config.OpenAICompatible{
        base_url: "https://api.config.com",
        api_key: "sk-config-key",
        headers: %{"x-config-only" => "val"},
        credential_resolver: fn ->
          %Config.RuntimeProviderAuth{api_key: "sk-resolved-key"}
        end
      }

      auth = Auth.resolve(config)

      assert auth.base_url == "https://api.config.com"
      assert auth.api_key == "sk-resolved-key"
      assert auth.headers["x-config-only"] == "val"
    end

    test "merges headers from both config and resolver" do
      config = %Config.OpenAICompatible{
        base_url: "https://api.example.com",
        headers: %{"x-config" => "config-val"},
        credential_resolver: fn ->
          %Config.RuntimeProviderAuth{headers: %{"x-resolver" => "resolver-val"}}
        end
      }

      auth = Auth.resolve(config)

      assert auth.headers["x-config"] == "config-val"
      assert auth.headers["x-resolver"] == "resolver-val"
    end

    test "resolver headers override config headers on conflict" do
      config = %Config.OpenAICompatible{
        base_url: "https://api.example.com",
        headers: %{"x-override" => "config-val"},
        credential_resolver: fn ->
          %Config.RuntimeProviderAuth{headers: %{"x-override" => "resolver-val"}}
        end
      }

      auth = Auth.resolve(config)

      assert auth.headers["x-override"] == "resolver-val"
    end

    test "handles nil headers in config" do
      config = %Config.OpenAICompatible{
        base_url: "https://api.example.com",
        api_key: "sk-key"
      }

      auth = Auth.resolve(config)

      assert auth.headers == %{}
    end

    test "handles nil headers in resolver" do
      config = %Config.OpenAICompatible{
        base_url: "https://api.example.com",
        headers: %{"x-config" => "val"},
        credential_resolver: fn ->
          %Config.RuntimeProviderAuth{api_key: "sk-resolved"}
        end
      }

      auth = Auth.resolve(config)

      assert auth.headers["x-config"] == "val"
    end

    test "returns empty struct for minimal config" do
      auth = Auth.resolve(%Config.OpenAICompatible{base_url: "https://api.example.com"})

      assert auth.base_url == "https://api.example.com"
      assert is_nil(auth.api_key)
      assert auth.headers == %{}
    end
  end

  describe "headers/2" do
    test "returns content-type and authorization when api_key is present" do
      auth = %Config.RuntimeProviderAuth{api_key: "sk-test-key"}

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/json"}
      assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer sk-test-key"}
    end

    test "omits authorization when omit_authorization? is true" do
      auth = %Config.RuntimeProviderAuth{api_key: "sk-test-key"}

      headers = Auth.headers(auth, true)

      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/json"}
      refute List.keyfind(headers, "authorization", 0)
    end

    test "omits authorization when api_key is nil" do
      auth = %Config.RuntimeProviderAuth{}

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/json"}
      refute List.keyfind(headers, "authorization", 0)
    end

    test "omits authorization when api_key is blank" do
      auth = %Config.RuntimeProviderAuth{api_key: "   "}

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/json"}
      refute List.keyfind(headers, "authorization", 0)
    end

    test "merges extra headers alongside defaults" do
      auth = %Config.RuntimeProviderAuth{
        api_key: "sk-key",
        headers: %{"x-custom" => "custom-val"}
      }

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/json"}
      assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer sk-key"}
      assert List.keyfind(headers, "x-custom", 0) == {"x-custom", "custom-val"}
    end

    test "extra headers without api_key" do
      auth = %Config.RuntimeProviderAuth{headers: %{"x-custom" => "val"}}

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/json"}
      assert List.keyfind(headers, "x-custom", 0) == {"x-custom", "val"}
      refute List.keyfind(headers, "authorization", 0)
    end

    test "extra headers when api_key is blank" do
      auth = %Config.RuntimeProviderAuth{
        api_key: "",
        headers: %{"x-custom" => "val"}
      }

      headers = Auth.headers(auth, true)

      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/json"}
      assert List.keyfind(headers, "x-custom", 0) == {"x-custom", "val"}
      refute List.keyfind(headers, "authorization", 0)
    end

    test "nil extra headers" do
      auth = %Config.RuntimeProviderAuth{api_key: "sk-key"}

      headers = Auth.headers(auth, false)

      assert length(headers) == 2
      assert List.keyfind(headers, "content-type", 0)
      assert List.keyfind(headers, "authorization", 0)
    end

    test "empty extra headers map" do
      auth = %Config.RuntimeProviderAuth{api_key: "sk-key", headers: %{}}

      headers = Auth.headers(auth, false)

      assert length(headers) == 2
    end

    test "extra headers with string keys are downcased" do
      auth = %Config.RuntimeProviderAuth{
        api_key: "sk-key",
        headers: %{"X-Custom-Header" => "val"}
      }

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "x-custom-header", 0) == {"x-custom-header", "val"}
    end

    test "extra headers with atom keys are downcased" do
      auth = %Config.RuntimeProviderAuth{
        api_key: "sk-key",
        headers: %{x_custom_header: "val"}
      }

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "x_custom_header", 0) == {"x_custom_header", "val"}
    end

    test "extra header values are stringified" do
      auth = %Config.RuntimeProviderAuth{
        api_key: "sk-key",
        headers: %{"x-count" => 42}
      }

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "x-count", 0) == {"x-count", "42"}
    end

    test "extra headers override authorization" do
      auth = %Config.RuntimeProviderAuth{
        api_key: "sk-real",
        headers: %{"authorization" => "Bearer sk-override"}
      }

      headers = Auth.headers(auth, false)

      assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer sk-override"}
    end
  end
end
