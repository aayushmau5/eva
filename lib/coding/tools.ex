defmodule Eva.Coding.Tools do
  alias Eva.Agent.Tools
  alias Eva.Coding.Diff
  alias Eva.Coding.ShellExec

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
      prompt_guidelines: ["Use read to examine files instead of cat or sed."],
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

  def write_tool(cwd) do
    %Tools.AgentTool{
      name: "write",
      description: """
      Write content to a file. Creates the file if it doesn't exist, overwrites if it does.
      Automatically creates parent directories.
      """,
      prompt_snippet: "Create or overwrite files",
      prompt_guidelines: ["Use write only for new files or complete rewrites."],
      input_schema: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file to write"},
          content: %{type: "string", description: "Content to write to the file"}
        },
        required: ["path", "content"]
      },
      executor: fn arguments ->
        path = path_arg(arguments, "path", cwd)
        content = string_arg(arguments, "content")

        path |> Path.dirname() |> File.mkdir_p!()
        File.write!(path, content)

        %Tools.AgentToolResult{
          tool_call_id: "",
          name: "write",
          ok: true,
          content: "Successfully wrote to #{path}.",
          data: %{path: path, characters: String.length(content)}
        }
      end
    }
  end

  def edit_tool(cwd) do
    %Tools.AgentTool{
      name: "edit",
      description: """
      Edit a single file using exact text replacement. Every edits[].oldText must match
      a unique, non-overlapping region of the original file. If two changes affect the
      same block or nearby lines, merge them into one edit instead of emitting overlapping
      edits. Do not include large unchanged regions just to connect distant changes.
      """,
      prompt_snippet:
        "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
      prompt_guidelines: [
        "Use edit for precise changes (edits[].oldText must match exactly)",
        "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls",
        "Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
        "Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions."
      ],
      input_schema: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file to edit"},
          edits: %{
            type: "array",
            description: "One or more targeted replacements.",
            items: %{
              type: "object",
              properties: %{
                oldText: %{type: "string"},
                newText: %{type: "string"}
              },
              required: ["oldText", "newText"],
              additionalProperties: false
            }
          }
        },
        required: ["path", "edits"],
        additionalProperties: false
      },
      executor: fn arguments ->
        arguments = prepare_edit_args(arguments)
        path = path_arg(arguments, "path", cwd)
        edits = edits_arg(arguments)

        if not File.exists?(path), do: raise("Could not edit file: #{path}. File not found.")
        if File.dir?(path), do: raise("Could not edit file: #{path}. Path is a directory")

        {bom, content} = File.read!(path) |> strip_bom()
        line_ending = detect_line_ending(content)
        normalized = normalize_to_lf(content)
        {base_content, new_content} = apply_edits(normalized, edits, path)
        final_content = bom <> restore_line_endings(new_content, line_ending)
        File.write!(path, final_content)

        {diff, first_changed_line} = Diff.diff_string(base_content, new_content)
        patch = Diff.unified_patch(Path.relative_to(path, cwd), base_content, new_content)

        %Tools.AgentToolResult{
          tool_call_id: "",
          name: "edit",
          ok: true,
          content: "Successfully replaced #{length(edits)} block(s) in #{path}.",
          data: %{
            path: path,
            edits: length(edits),
            diff: diff,
            patch: patch,
            first_changed_line: first_changed_line
          }
        }
      end
    }
  end

  def bash_tool(cwd) do
    %Tools.AgentTool{
      name: "bash",
      description: """
      Execute a bash command in the current working directory. Returns stdout and stderr.
      Output is truncated to last #{@default_max_output_lines} lines or #{@default_max_output_kb}KB (whichever is hit first).
      If truncated, full output is saved to a temp file.
      Optionally provide a timeout in seconds.
      """,
      prompt_snippet: "Execute bash commands (ls, grep, find, etc.)",
      prompt_guidelines: [],
      input_schema: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Bash command to execute"},
          timeout: %{
            type: "number",
            description: "Timeout in seconds (optional, no default timeout)"
          }
        },
        required: ["command"]
      },
      executor: fn arguments ->
        command = string_arg(arguments, "command")
        timeout_sec = optional_float_arg(arguments, "timeout")

        if timeout_sec != nil and timeout_sec <= 0 do
          raise "timeout must be greater than 0"
        end

        timeout_ms = if timeout_sec, do: trunc(timeout_sec * 1000)
        start_ms = System.monotonic_time(:millisecond)

        result = ShellExec.run(command, cwd: cwd, timeout: timeout_ms)

        duration_sec = (System.monotonic_time(:millisecond) - start_ms) / 1000
        truncation = truncate_tail(result.output)
        output_text = if truncation.content == "", do: "(no output)", else: truncation.content
        exit_code = result.exit_status

        {output_text, full_output_path} =
          if truncation.truncated do
            path = write_temp_output(result.output)
            {output_text <> build_truncation_suffix(truncation, path), path}
          else
            {output_text, nil}
          end

        status =
          cond do
            result.timed_out ->
              if timeout_sec do
                formatted =
                  timeout_sec
                  |> Float.round(3)
                  |> to_string()
                  |> String.replace_suffix(".0", "")

                "Command timed out after #{formatted} seconds"
              else
                "Command timed out"
              end

            result.cancelled ->
              "Command cancelled"

            is_integer(exit_code) and exit_code != 0 ->
              "Command exited with code #{exit_code}"

            not is_integer(exit_code) ->
              "Command failed: #{inspect(exit_code)}"

            true ->
              nil
          end

        output_text = if status, do: output_text <> "\n\n[#{status}]", else: output_text

        ok? =
          is_integer(exit_code) and
            exit_code == 0 and
            not result.timed_out and
            not result.cancelled

        %Tools.AgentToolResult{
          tool_call_id: "",
          name: "bash",
          ok: ok?,
          content: output_text,
          error: if(ok?, do: nil, else: status),
          data: %{
            "command" => command,
            "exit_code" => exit_code,
            "timed_out" => result.timed_out,
            "cancelled" => result.cancelled,
            "duration_seconds" => Float.round(duration_sec, 3),
            "truncation" => truncation,
            "full_output_path" => full_output_path
          }
        }
      end
    }
  end

  # Internal helpers

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

  defp edits_arg(arguments) do
    value = Map.get(arguments, "edits")

    if not is_list(value) or value == [] do
      raise "Edit tool input is invalid. edits must contain at least one replacement."
    end

    value
    |> Enum.with_index()
    |> Enum.reduce([], fn {edit, i}, edits ->
      if not is_map(edit) do
        raise "edits[#{i}] must be an object"
      end

      old_text = Map.get(edit, "oldText")
      new_text = Map.get(edit, "newText")

      if not is_binary(old_text) or not is_binary(new_text) do
        raise "edits[#{i}].oldText and edits[#{i}].newText must be strings"
      end

      [%{old_text: old_text, new_text: new_text} | edits]
    end)
    |> Enum.reverse()
  end

  defp detect_line_ending(content) do
    crlf_index = :binary.match(content, "\r\n")
    lf_index = :binary.match(content, "\n")

    cond do
      crlf_index == :nomatch or lf_index == :nomatch -> "\n"
      elem(crlf_index, 0) < elem(lf_index, 0) -> "\r\n"
      true -> "\n"
    end
  end

  defp normalize_to_lf(text) do
    text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
  end

  defp restore_line_endings(text, ending) do
    if ending == "\r\n" do
      String.replace(text, "\n", "\r\n")
    else
      text
    end
  end

  defp prepare_edit_args(arguments) do
    edits_values = Map.get(arguments, "edits")

    cond do
      is_binary(edits_values) ->
        case JSON.decode(edits_values) do
          {:ok, parsed} -> Map.put(arguments, "edits", parsed)
          {:error, _} -> arguments
        end

      true ->
        arguments
    end
  end

  defp optional_int_arg(arguments, name) do
    case Map.get(arguments, name) do
      nil -> nil
      val when is_integer(val) -> val
      _ -> raise "Argument \"#{name}\" is not an integer"
    end
  end

  defp optional_float_arg(arguments, name) do
    case Map.get(arguments, name) do
      nil -> nil
      val when is_float(val) or is_integer(val) -> val * 1.0
      _ -> raise "Argument \"#{name}\" is not a number"
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

  defp truncate_tail(
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

      true ->
        {kept, _bytes, why, partial} = collect_upto_from_end(lines, max_lines, max_bytes)
        output = Enum.join(kept, "\n")

        truncation_result(
          content: output,
          truncated: true,
          truncated_by: why,
          total_lines: total_lines,
          total_bytes: total_bytes,
          output_lines: length(kept),
          output_bytes: byte_size(output),
          last_line_partial: partial
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

  defp collect_upto_from_end(lines, max_lines, max_bytes) do
    lines
    |> Enum.reverse()
    |> Enum.take(max_lines)
    |> Enum.with_index()
    |> Enum.reduce_while(
      {[], 0, "lines", false},
      fn {line, index}, {kept_lines, kept_bytes, _, _} ->
        newline_separator_bytes = if index == 0, do: 0, else: 1
        line_bytes = byte_size(line) + newline_separator_bytes

        cond do
          index == 0 and line_bytes > max_bytes ->
            clipped = truncate_string_to_bytes_from_end(line, max_bytes)
            {:halt, {[clipped | kept_lines], byte_size(clipped), "bytes", true}}

          kept_bytes + line_bytes > max_bytes ->
            {:halt, {kept_lines, kept_bytes, "bytes", false}}

          true ->
            {:cont, {[line | kept_lines], kept_bytes + line_bytes, "lines", false}}
        end
      end
    )
  end

  defp truncate_string_to_bytes_from_end(str, max_bytes) do
    str_bytes = byte_size(str)

    if str_bytes <= max_bytes do
      str
    else
      skip = str_bytes - max_bytes
      <<_::binary-size(^skip), rest::binary>> = str
      rest
    end
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

  # Some editors (notably on Windows) prepend \ufeff to UTF-8 files.
  # It's an invisible character at position 0.
  # If you don't strip it, exact oldText matching fails — the user's oldText won't include the BOM, so it won't match the file content that starts with it.
  # This strips it before matching edits and restores it after, so BOM'd files behave identically to non-BOM'd ones for matching purposes.
  defp strip_bom(content) do
    utf8_bom = "\uFEFF"

    if String.starts_with?(content, utf8_bom) do
      {utf8_bom, String.replace_prefix(content, utf8_bom, "")}
    else
      {"", content}
    end
  end

  defp apply_edits(content, edits, path) do
    edits =
      Enum.map(edits, fn edit ->
        %{old_text: normalize_to_lf(edit.old_text), new_text: normalize_to_lf(edit.new_text)}
      end)

    matches =
      edits
      |> Enum.with_index()
      |> Enum.reduce([], fn {edit, i}, matches ->
        old_text = edit.old_text
        occurences = count_occurrences(content, old_text)

        cond do
          occurences == 0 ->
            raise "Could not find edits[#{i}] in #{path}. The oldText must match exactly including all whitespace and newlines."

          occurences > 1 ->
            raise "Found #{occurences} occurrences of edits[#{i}] in #{path}. Each oldText must be unique. Please provide more context to make it unique."

          true ->
            {start, len} = :binary.match(content, old_text)
            [{start, start + len, edit.new_text} | matches]
        end
      end)
      |> Enum.reverse()

    validate_non_overlapping(matches)

    new_content =
      matches
      |> Enum.sort_by(fn {start, _, _} -> start end, :desc)
      |> Enum.reduce(content, fn {start, end_pos, new_text}, acc ->
        String.slice(acc, 0, start) <> new_text <> String.slice(acc, end_pos..-1//1)
      end)

    if content == new_content do
      raise "No changes made to #{path}. The replacements produced identical content."
    end

    {content, new_content}
  end

  defp count_occurrences(content, text, start \\ 0, count \\ 0) do
    case :binary.match(content, text, [{:scope, {start, byte_size(content) - start}}]) do
      :nomatch -> count
      {index, len} -> count_occurrences(content, text, index + len, count + 1)
    end
  end

  defp validate_non_overlapping(spans) do
    sorted = Enum.sort_by(spans, fn {start, _, _} -> start end)

    {_, :ok} =
      Enum.reduce(sorted, {-1, :ok}, fn {start, end_pos, _}, {previous_end, :ok} ->
        if start < previous_end do
          raise "Edits must not overlap"
        end

        {end_pos, :ok}
      end)
  end

  defp write_temp_output(output) do
    path =
      Path.join(System.tmp_dir!(), "eva_bash_output_#{System.system_time(:second)}.txt")

    File.write!(path, output)
    path
  end

  defp build_truncation_suffix(truncation, full_path) do
    if truncation.last_line_partial do
      "\n\n[Showing last #{format_size(truncation.output_bytes)} of line #{truncation.total_lines}. Full output: #{full_path}]"
    else
      start_line = truncation.total_lines - truncation.output_lines + 1
      end_line = truncation.total_lines

      if truncation.truncated_by == "lines" do
        "\n\n[Showing lines #{start_line}-#{end_line} of #{truncation.total_lines}. Full output: #{full_path}]"
      else
        "\n\n[Showing lines #{start_line}-#{end_line} of #{truncation.total_lines} (#{format_size(@default_max_output_bytes)} limit). Full output: #{full_path}]"
      end
    end
  end
end
