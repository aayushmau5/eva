defmodule Eva.Coding.Paths do
  use TypedStruct

  typedstruct do
    field :home, String.t(), default: Path.join([Path.expand("~"), ".eva"])
    field :agents_home, String.t(), default: Path.join([Path.expand("~"), ".eva", "agents"])
  end

  @spec sessions_dir(t()) :: String.t()
  def sessions_dir(%__MODULE__{} = paths) do
    # ~/.eva/sessions/
    Path.join(paths.home, "sessions")
  end

  @spec logs_dir(t()) :: String.t()
  def logs_dir(%__MODULE__{} = paths) do
    # ~/.eva/logs/
    Path.join(paths.home, "logs")
  end

  @spec project_session_dir(t(), cwd :: String.t()) :: String.t()
  def project_session_dir(%__MODULE__{} = paths, cwd) do
    # ~/.eva/sessions/<slug>-<digest>/
    resolved = Path.expand(cwd)
    digest = :crypto.hash(:sha256, resolved) |> Base.encode16(case: :lower) |> String.slice(0..5)
    slug = slugify_path(resolved)
    slug = if slug == "", do: "project", else: slug
    Path.join(sessions_dir(paths), "#{slug}-#{digest}")
  end

  @spec default_session_path(t(), cwd :: String.t()) :: String.t()
  def default_session_path(%__MODULE__{} = paths, cwd) do
    # ~/.eva/sessions/<slug>-<digest>/default.jsonl
    session_file = Path.join(project_session_dir(paths, cwd), "default.jsonl")
    session_file |> Path.dirname() |> File.mkdir_p!()
    session_file
  end

  @spec index_path(t(), cwd :: String.t()) :: String.t()
  def index_path(%__MODULE__{} = paths, cwd) do
    # ~/.eva/sessions/<slug>-<digest>/index.jsonl
    project_session_dir(paths, cwd)
    |> Path.join("index.jsonl")
  end

  # Converts a filesystem path into a short, filesystem-safe slug string.
  # Replaces the home directory prefix with "home", normalises each path segment
  # (lowercase, non-alphanumeric characters become hyphens), and joins them
  # together. If the result exceeds `max_length`, the rightmost segments that
  # fit within the limit are kept.
  @spec slugify_path(path :: String.t(), max_length :: non_neg_integer()) :: String.t()
  def slugify_path(path, max_length \\ 72) do
    home = Path.expand("~")

    parts =
      if String.starts_with?(path, home) do
        relative = path |> String.replace_prefix(home, "") |> String.trim_leading("/")
        ["home" | if(relative == "", do: [], else: Path.split(relative))]
      else
        path |> Path.split() |> Enum.reject(&(&1 in ["/", ""]))
      end

    slug_parts =
      for part <- parts,
          slugged = normalize_part(part),
          slugged != "",
          do: slugged

    slug = Enum.join(slug_parts, "-")

    if byte_size(slug) <= max_length do
      slug
    else
      slug_parts
      |> suffix_that_fits(max_length)
      |> case do
        [] -> slug |> String.slice(-max_length..-1) |> String.trim("-")
        parts -> Enum.join(parts, "-")
      end
    end
  end

  defp normalize_part(part) do
    part
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.replace(~r/^[-._]+|[-._]+$/, "")
  end

  defp suffix_that_fits(parts, max_length) do
    parts
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn part, {acc, len} ->
      next = len + byte_size(part) + if acc == [], do: 0, else: 1
      if next > max_length, do: {:halt, acc}, else: {:cont, {[part | acc], next}}
    end)
    |> elem(0)
  end
end
