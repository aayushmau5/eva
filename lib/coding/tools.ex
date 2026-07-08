defmodule Eva.Coding.Tools do
  alias Eva.Agent.Tools

  @default_max_output_kb 50
  @default_max_output_bytes @default_max_output_kb * 1024
  @default_max_output_lines 2_000
  @supported_image_mime_types ["image/jpeg", "image/png", "image/gif", "image/webp"]

  def read_tool(cwd) do
    %Tools.AgentTool{
      name: "read",
      description: """
      Read the contents of a file. Supports text files and images (jpg, png, gif, webp).
      Images are returned as base64 metadata. For text files, output is truncated to #{@default_max_output_lines} line
      or #{@default_max_output_kb}KB (whichever is hit first). Use offset/limit for large files. When you need the
      full file, continue with offset until complete.
      """,
      # prompt_snippet & prompt_guidelines are used while building the system prompt.
      prompt_snippet: "Read file contents",
      prompt_guidelines: "Use read to examine files instead of cat or sed.",
      input_schema: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file to read"},
          offset: %{type: "integer", description: "Line number to start reading from"},
          limit: %{type: "integer", description: "Maximum number of lines to read"}
        },
        required: ["path"]
      },
      executor: fn arguments ->
        # arguments is basically a map with string keys(JSON.decode doesn't convert map keys to atoms)
        # example: arguments -> %{"path" => "...", "offset" => .., "limit" => ..}
        path = path_arg(arguments, "path", cwd)
        offset = optional_int_arg(arguments, "offset")
        limit = optional_int_arg(arguments, "limit")

        if offset != nil and offset < 0, do: raise("offset must be atleast 0")
        if limit != nil and limit < 1, do: raise("limit must be atleast 1")
        if not File.exists?(path), do: raise("File not found: #{path}")
        if File.dir?(path), do: raise("Path is a directory: #{path}")

        mime_type = get_supported_image_mime_type(path)

        if mime_type do
          data = File.read!(path)

          %Tools.AgentToolResult{
            tool_call_id: "",
            name: "read",
            ok: true,
            content: "Read image file [#{mime_type}]",
            data: %{
              path: path,
              mime_type: mime_type,
              bytes: byte_size(data),
              image_base64: base64_text(data)
            }
          }
        else
          raw_path = Map.get(arguments, "path")
          text = File.read!(path)
          lines = String.split(text, "\n")
          total_lines = length(lines)

          # offset is 1-indexed by the caller; convert to 0-indexed
          start_line = if offset == nil or offset == 0, do: 0, else: offset - 1

          if start_line >= total_lines do
            raise "Offset #{offset} is beyond end of file (#{total_lines} lines total)"
          end

          # Slice to the user-requested range; track how many lines the limit actually yielded
          {sliced, user_limited_lines} =
            if limit do
              end_line = min(start_line + limit, total_lines)
              count = end_line - start_line
              {Enum.slice(lines, start_line, count) |> Enum.join("\n"), count}
            else
              {Enum.slice(lines, start_line..-1//1) |> Enum.join("\n"), nil}
            end

          # Apply output cap (max lines / max bytes) on top of the user's slice
          truncation = truncate_head(sliced)
          start_display = start_line + 1

          # Build the output message based on what triggered truncation
          output =
            cond do
              # The first line alone exceeds the byte limit — giving a bash fallback
              truncation.first_line_exceeds_limit ->
                first_line_size =
                  lines |> Enum.at(start_line) |> byte_size() |> format_size()

                ~s"""
                [Line #{start_display} is #{first_line_size}, \
                exceeds #{format_size(@default_max_output_bytes)} limit. \
                Use bash: sed -n '#{start_display}p' #{raw_path} | head -c #{@default_max_output_bytes}]\
                """

              # Content was trimmed by the line or byte cap
              truncation.truncated ->
                end_display = start_display + truncation.output_lines - 1
                next_offset = end_display + 1

                suffix =
                  if truncation.truncated_by == "lines" do
                    ~s"""
                    \n\n[Showing lines #{start_display}-#{end_display} \
                    of #{total_lines}. Use offset=#{next_offset} to continue.]\
                    """
                  else
                    ~s"""
                    \n\n[Showing lines #{start_display}-#{end_display} \
                    of #{total_lines} (#{format_size(@default_max_output_bytes)} limit). \
                    Use offset=#{next_offset} to continue.]\
                    """
                  end

                truncation.content <> suffix

              # User's own limit didn't reach end of file — remind them there's more
              user_limited_lines && start_line + user_limited_lines < total_lines ->
                remaining = total_lines - (start_line + user_limited_lines)
                next_offset = start_line + user_limited_lines + 1

                ~s"""
                #{truncation.content}\n\n\
                [#{remaining} more lines in file. \
                Use offset=#{next_offset} to continue.]\
                """

              # No truncation, no limit, or the user limit covered everything
              true ->
                truncation.content
            end

          %Tools.AgentToolResult{
            tool_call_id: "",
            name: "read",
            ok: true,
            content: output,
            data: %{
              path: path,
              truncation: truncation
            }
          }
        end
      end
    }
  end

  defp string_arg(arguments, name) do
    case Map.get(arguments, name) do
      nil -> raise "Missing argument #{name}"
      val when is_binary(val) -> val
      _ -> raise "Argument \"#{name}\" is not a string"
    end
  end

  defp path_arg(arguments, name, cwd) do
    string_arg(arguments, name) |> Path.expand() |> Path.absname(cwd)
  end

  defp optional_int_arg(arguments, name) do
    case Map.get(arguments, name) do
      nil -> nil
      val when is_integer(val) -> val
      _ -> raise "Argument \"#{name}\" is not an integer"
    end
  end

  defp get_supported_image_mime_type(path) do
    mime_type = MIME.from_path(path)
    if mime_type in @supported_image_mime_types, do: mime_type, else: nil
  end

  defp base64_text(data) when is_binary(data) do
    Base.encode64(data)
  end

  defp split_lines_for_counting(content) do
    lines = String.split(content, "\n")
    if String.ends_with?(content, "\n"), do: Enum.drop(lines, -1), else: lines
  end

  defp truncate_head(
         content,
         max_lines \\ @default_max_output_lines,
         max_bytes \\ @default_max_output_bytes
       ) do
    lines = split_lines_for_counting(content)
    total_lines = length(lines)
    total_bytes = byte_size(content)

    cond do
      total_lines <= max_lines and total_bytes <= max_bytes ->
        truncation_result(
          content: content,
          truncated: false,
          total_lines: total_lines,
          total_bytes: total_bytes,
          output_lines: total_lines,
          output_bytes: total_bytes
        )

      (first = List.first(lines)) && byte_size(first) > max_bytes ->
        truncation_result(
          content: "",
          truncated: true,
          truncated_by: "bytes",
          total_lines: total_lines,
          total_bytes: total_bytes,
          output_lines: 0,
          output_bytes: 0,
          first_line: true
        )

      true ->
        {kept, _, why} = collect_upto(lines, max_lines, max_bytes)
        output = kept |> Enum.reverse() |> Enum.join("\n")

        truncation_result(
          content: output,
          truncated: true,
          truncated_by: why,
          total_lines: total_lines,
          total_bytes: total_bytes,
          output_lines: length(kept),
          output_bytes: byte_size(output)
        )
    end
  end

  defp collect_upto(lines, max_lines, max_bytes) do
    lines
    |> Enum.take(max_lines)
    |> Enum.with_index()
    |> Enum.reduce_while({[], 0, "lines"}, fn {line, index}, {acc, acc_bytes, _} ->
      sep = if index == 0, do: 0, else: 1
      line_bytes = byte_size(line) + sep

      if acc_bytes + line_bytes > max_bytes do
        {:halt, {acc, acc_bytes, "bytes"}}
      else
        {:cont, {[line | acc], acc_bytes + line_bytes, "lines"}}
      end
    end)
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)}KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)}MB"

  defp truncation_result(opts) do
    %{
      content: Keyword.fetch!(opts, :content),
      truncated: Keyword.fetch!(opts, :truncated),
      truncated_by: Keyword.get(opts, :truncated_by),
      total_lines: Keyword.fetch!(opts, :total_lines),
      total_bytes: Keyword.fetch!(opts, :total_bytes),
      output_lines: Keyword.fetch!(opts, :output_lines),
      output_bytes: Keyword.fetch!(opts, :output_bytes),
      last_line_partial: Keyword.get(opts, :last_line_partial, false),
      first_line_exceeds_limit: Keyword.get(opts, :first_line, false),
      max_lines: @default_max_output_lines,
      max_bytes: @default_max_output_bytes
    }
  end
end
