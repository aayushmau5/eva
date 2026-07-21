defmodule Eva.Agent.Utils do
  @doc """
  UUIDv4 hex
  """
  @spec new_entry_id() :: String.t()
  def new_entry_id() do
    UUID.uuid4(:hex)
  end

  @doc """
  Timestamp in float.
  """
  @spec timestamp() :: float()
  def timestamp() do
    System.os_time(:millisecond) / 1000
  end

  @doc "Return the current Unix timestamp in milliseconds."
  @spec current_timestamp_ms() :: integer()
  def current_timestamp_ms, do: System.system_time(:millisecond)

  @doc """
  Converts map string keys into (existing) atoms.
  """
  @spec to_atom_keys(map()) :: map()
  def to_atom_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  @typep metadata_map :: %{String.t() => String.t()}

  @doc """
  Parses minimal YAML-like frontmatter from a markdown resource.

  Returns `{metadata, body}` where metadata is a map of string keys to string
  values, and body is the markdown content after the frontmatter delimiter.
  If no frontmatter is present, returns `{%{}, text}`.
  """
  @spec parse_markdown_resource(String.t()) :: {metadata_map(), String.t()}
  def parse_markdown_resource(text) do
    normalized = String.replace(text, ~r/\r\n?/, "\n")

    case normalized do
      "---\n" <> rest ->
        case String.split(rest, "\n---", parts: 2) do
          [frontmatter, body] ->
            metadata = parse_frontmatter_lines(frontmatter)
            {metadata, String.trim_leading(body, "\n")}

          [_] ->
            {%{}, normalized}
        end

      _ ->
        {%{}, normalized}
    end
  end

  @doc """
  Derives a short description from markdown content.

  Returns the first non-blank line of content, stripping any leading `#`
  heading markers. Returns `nil` if no content is found.
  """
  @spec derive_description(String.t()) :: String.t() | nil
  def derive_description(content) do
    content
    |> String.split("\n")
    |> Enum.reduce_while(nil, fn line, nil ->
      stripped = String.trim(line)

      cond do
        stripped == "" ->
          {:cont, nil}

        String.starts_with?(stripped, "#") ->
          desc = stripped |> String.trim_leading("#") |> String.trim()
          if desc == "", do: {:cont, nil}, else: {:halt, desc}

        true ->
          {:halt, stripped}
      end
    end)
  end

  defp parse_frontmatter_lines(frontmatter) do
    frontmatter
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      trimmed = String.trim(line)

      if trimmed == "" or String.starts_with?(trimmed, "#") do
        acc
      else
        case String.split(trimmed, ":", parts: 2) do
          [key, value] ->
            Map.put(acc, String.trim(key), value |> String.trim() |> String.trim(~s|"'|))

          _ ->
            acc
        end
      end
    end)
  end
end
