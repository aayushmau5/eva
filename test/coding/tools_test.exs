defmodule Eva.Coding.ToolsTest do
  use ExUnit.Case

  alias Eva.Coding.Tools, as: CodingTools

  @tmp_root Path.expand("tmp/test")

  setup do
    tmp =
      @tmp_root
      |> Path.join("#{System.unique_integer([:positive, :monotonic])}")
      |> tap(&File.mkdir_p!/1)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp write_file(tmp, filename, content) do
    path = Path.join(tmp, filename)
    File.write!(path, content)
    path
  end

  describe "text file reading" do
    test "reads entire file", %{tmp: tmp} do
      path = write_file(tmp, "hello.txt", "line1\nline2\nline3\n")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.content == "line1\nline2\nline3\n"
      refute result.data.truncation.truncated
    end

    test "reads with offset", %{tmp: tmp} do
      path = write_file(tmp, "hello.txt", "a\nb\nc\nd\ne\n")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path, "offset" => 3})

      assert result.ok
      assert result.content == "c\nd\ne\n"
    end

    test "reads with limit and shows remaining hint", %{tmp: tmp} do
      path = write_file(tmp, "hello.txt", "a\nb\nc\nd\ne\n")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path, "limit" => 2})

      assert result.ok
      assert result.content =~ "a\nb"
      assert result.content =~ "more lines in file"
      assert result.content =~ "offset=3"
    end

    test "reads with offset and limit", %{tmp: tmp} do
      path = write_file(tmp, "hello.txt", "a\nb\nc\nd\ne\n")

      result =
        CodingTools.read_tool(tmp).executor.(%{"path" => path, "offset" => 2, "limit" => 2})

      assert result.ok
      assert result.content =~ "b\nc"
      assert result.content =~ "more lines"
    end

    test "reads an empty file", %{tmp: tmp} do
      path = write_file(tmp, "empty.txt", "")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.content == ""
    end

    test "reads a file without trailing newline", %{tmp: tmp} do
      path = write_file(tmp, "noeol.txt", "single line")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.content == "single line"
      assert result.data.truncation.total_lines == 1
    end
  end

  describe "error cases" do
    test "raises on file not found", %{tmp: tmp} do
      tool = CodingTools.read_tool(tmp)

      assert_raise RuntimeError, ~r/File not found/, fn ->
        tool.executor.(%{"path" => Path.join(tmp, "nope.txt")})
      end
    end

    test "raises on directory path", %{tmp: tmp} do
      tool = CodingTools.read_tool(tmp)

      assert_raise RuntimeError, ~r/Path is a directory/, fn ->
        tool.executor.(%{"path" => tmp})
      end
    end

    test "raises on negative offset", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hi\n")
      tool = CodingTools.read_tool(tmp)

      assert_raise RuntimeError, ~r/offset must be atleast 0/, fn ->
        tool.executor.(%{"path" => path, "offset" => -1})
      end
    end

    test "raises on limit less than 1", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hi\n")
      tool = CodingTools.read_tool(tmp)

      assert_raise RuntimeError, ~r/limit must be atleast 1/, fn ->
        tool.executor.(%{"path" => path, "limit" => 0})
      end
    end

    test "raises on offset beyond end of file", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "a\nb\n")
      tool = CodingTools.read_tool(tmp)

      assert_raise RuntimeError, ~r/Offset.*beyond end of file/, fn ->
        tool.executor.(%{"path" => path, "offset" => 10})
      end
    end

    test "raises on non-integer offset", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hi\n")
      tool = CodingTools.read_tool(tmp)

      assert_raise RuntimeError, ~r/is not an integer/, fn ->
        tool.executor.(%{"path" => path, "offset" => "abc"})
      end
    end

    test "raises on non-integer limit", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hi\n")
      tool = CodingTools.read_tool(tmp)

      assert_raise RuntimeError, ~r/is not an integer/, fn ->
        tool.executor.(%{"path" => path, "limit" => "abc"})
      end
    end
  end

  describe "truncation" do
    @default_max_output_lines 2000

    test "truncates when file exceeds max output lines", %{tmp: tmp} do
      content = Enum.map_join(1..(@default_max_output_lines + 5), "\n", &"line #{&1}")
      path = write_file(tmp, "big.txt", content)

      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.data.truncation.truncated
      assert result.data.truncation.truncated_by == "lines"
      assert result.content =~ "Showing lines 1-2000"
    end

    test "first line exceeds max output bytes", %{tmp: tmp} do
      big_line = String.duplicate("x", 51_300)
      path = write_file(tmp, "big_line.txt", "#{big_line}\nline2\n")

      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.data.truncation.first_line_exceeds_limit
      assert result.content =~ "Line 1 is"
      assert result.content =~ "exceeds 50.0KB"
      assert result.content =~ "sed -n '1p'"
    end

    test "truncation metadata is present for small files", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hello\nworld\n")

      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.data.truncation.truncated == false
      assert result.data.truncation.total_lines == 2
      assert result.data.truncation.output_bytes == byte_size("hello\nworld\n")
    end

    test "truncates by bytes when collective lines hit byte limit before line limit", %{tmp: tmp} do
      # 80 lines of ~700 bytes each = ~56KB, exceeds 50KB byte limit but well under 2000 line limit
      line = String.duplicate("x", 690)
      content = Enum.map_join(1..80, "\n", fn _ -> line end)
      path = write_file(tmp, "byte_limit.txt", content)

      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.data.truncation.truncated
      assert result.data.truncation.truncated_by == "bytes"
      assert result.content =~ "50.0KB"
    end

    test "reads last line with offset and limit that reaches EOF", %{tmp: tmp} do
      path = write_file(tmp, "lines.txt", "a\nb\nc")

      result =
        CodingTools.read_tool(tmp).executor.(%{"path" => path, "offset" => 3, "limit" => 1})

      assert result.ok
      assert result.content == "c"
    end

    test "total_lines in truncation strips trailing empty line", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "a\nb\n")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      # split_lines_for_counting drops trailing empty from EOL-terminated files
      assert result.data.truncation.total_lines == 2
    end
  end

  describe "write" do
    test "creates file with content", %{tmp: tmp} do
      path = Path.join(tmp, "new.txt")
      content = "hello write tool\n"
      tool = CodingTools.write_tool(tmp)

      result = tool.executor.(%{"path" => path, "content" => content})

      assert result.ok
      assert result.content =~ "Successfully wrote to #{path}"
      assert result.data.path == path
      assert result.data.characters == String.length(content)
      assert File.exists?(path)
      assert File.read!(path) == content
    end

    test "overwrites existing file", %{tmp: tmp} do
      path = write_file(tmp, "existing.txt", "old content")
      new_content = "new content\n"
      tool = CodingTools.write_tool(tmp)

      result = tool.executor.(%{"path" => path, "content" => new_content})

      assert result.ok
      assert File.read!(path) == new_content
    end

    test "creates parent directories", %{tmp: tmp} do
      path = Path.join([tmp, "nested", "deep", "file.txt"])
      content = "deep content"
      tool = CodingTools.write_tool(tmp)

      result = tool.executor.(%{"path" => path, "content" => content})

      assert result.ok
      assert File.exists?(path)
      assert File.read!(path) == content
    end

    test "writes empty content", %{tmp: tmp} do
      path = Path.join(tmp, "empty.txt")
      tool = CodingTools.write_tool(tmp)

      result = tool.executor.(%{"path" => path, "content" => ""})

      assert result.ok
      assert result.data.characters == 0
      assert File.read!(path) == ""
    end

    test "raises when path is missing", %{tmp: tmp} do
      tool = CodingTools.write_tool(tmp)

      assert_raise RuntimeError, ~r/Missing argument path/, fn ->
        tool.executor.(%{"content" => "x"})
      end
    end

    test "raises when content is missing", %{tmp: tmp} do
      tool = CodingTools.write_tool(tmp)

      assert_raise RuntimeError, ~r/Missing argument content/, fn ->
        tool.executor.(%{"path" => Path.join(tmp, "f.txt")})
      end
    end

    test "resolves relative paths against process cwd", %{tmp: tmp} do
      tool = CodingTools.write_tool(tmp)

      result = tool.executor.(%{"path" => "relative.txt", "content" => "relative content"})

      assert result.ok
      assert result.data.path =~ ~r/relative\.txt$/
      assert File.exists?(result.data.path)
      assert File.read!(result.data.path) == "relative content"
      File.rm!(result.data.path)
    end
  end

  describe "image files" do
    test "returns image metadata for png", %{tmp: tmp} do
      path = write_file(tmp, "img.png", "fake-image-data")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.content == "Read image file [image/png]"
      assert result.data.mime_type == "image/png"
      assert result.data.image_base64 != nil
      assert result.data.bytes == byte_size("fake-image-data")
    end

    test "returns image metadata for jpg", %{tmp: tmp} do
      path = write_file(tmp, "photo.jpg", "not-real-jpg")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.content == "Read image file [image/jpeg]"
      assert result.data.mime_type == "image/jpeg"
    end

    test "returns image metadata for gif", %{tmp: tmp} do
      path = write_file(tmp, "anim.gif", "fake-gif-data")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.content == "Read image file [image/gif]"
      assert result.data.mime_type == "image/gif"
      assert result.data.image_base64 != nil
    end

    test "returns image metadata for webp", %{tmp: tmp} do
      path = write_file(tmp, "img.webp", "fake-webp-data")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      assert result.ok
      assert result.content == "Read image file [image/webp]"
      assert result.data.mime_type == "image/webp"
      assert result.data.image_base64 != nil
    end
  end

  describe "edit" do
    test "populates diff, patch, and first_changed_line", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "alpha\nbeta\ngamma\n")
      tool = CodingTools.edit_tool(tmp)

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "beta", "newText" => "BETA"}]
        })

      assert result.ok
      assert result.data.first_changed_line == 2
      assert result.data.diff =~ "- beta"
      assert result.data.diff =~ "+ BETA"
      assert result.data.patch =~ "--- x.txt\n"
      assert result.data.patch =~ "@@ -1,3 +1,3 @@"
      assert result.data.patch =~ "-beta"
      assert result.data.patch =~ "+BETA"
      assert File.read!(path) == "alpha\nBETA\ngamma\n"
    end

    test "applies multiple disjoint edits in one call", %{tmp: tmp} do
      path = write_file(tmp, "multi.txt", "alpha\nbeta\ngamma\ndelta\nepsilon\n")
      tool = CodingTools.edit_tool(tmp)

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => [
            %{"oldText" => "beta", "newText" => "BETA"},
            %{"oldText" => "delta", "newText" => "DELTA"}
          ]
        })

      assert result.ok
      assert result.data.edits == 2
      assert result.data.first_changed_line == 2
      assert result.data.diff =~ "- beta"
      assert result.data.diff =~ "+ BETA"
      assert result.data.diff =~ "- delta"
      assert result.data.diff =~ "+ DELTA"
      assert File.read!(path) == "alpha\nBETA\ngamma\nDELTA\nepsilon\n"
    end

    test "edit at beginning of file", %{tmp: tmp} do
      path = write_file(tmp, "start.txt", "alpha\nbeta\ngamma\n")
      tool = CodingTools.edit_tool(tmp)

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "alpha", "newText" => "ALPHA"}]
        })

      assert result.ok
      assert result.data.first_changed_line == 1
      assert result.data.diff =~ "- alpha"
      assert result.data.diff =~ "+ ALPHA"
      assert File.read!(path) == "ALPHA\nbeta\ngamma\n"
    end

    test "edit at end of file", %{tmp: tmp} do
      path = write_file(tmp, "end.txt", "alpha\nbeta\ngamma\n")
      tool = CodingTools.edit_tool(tmp)

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "gamma", "newText" => "GAMMA"}]
        })

      assert result.ok
      assert result.data.first_changed_line == 3
      assert result.data.diff =~ "- gamma"
      assert result.data.diff =~ "+ GAMMA"
      assert File.read!(path) == "alpha\nbeta\nGAMMA\n"
    end

    test "deletes a line when newText is empty", %{tmp: tmp} do
      path = write_file(tmp, "del.txt", "alpha\nbeta\ngamma\n")
      tool = CodingTools.edit_tool(tmp)

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "beta\n", "newText" => ""}]
        })

      assert result.ok
      assert result.data.first_changed_line == 2
      assert result.data.diff =~ "- beta"
      assert File.read!(path) == "alpha\ngamma\n"
    end

    test "inserts new text between lines", %{tmp: tmp} do
      path = write_file(tmp, "ins.txt", "alpha\ngamma\n")
      tool = CodingTools.edit_tool(tmp)

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "alpha\n", "newText" => "alpha\nbeta\n"}]
        })

      assert result.ok
      assert result.data.diff =~ "+ beta"
      assert File.read!(path) == "alpha\nbeta\ngamma\n"
    end

    test "handles edits passed as JSON string", %{tmp: tmp} do
      path = write_file(tmp, "json.txt", "alpha\nbeta\ngamma\n")
      tool = CodingTools.edit_tool(tmp)
      edits_json = JSON.encode!([%{"oldText" => "beta", "newText" => "BETA"}])

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => edits_json
        })

      assert result.ok
      assert File.read!(path) == "alpha\nBETA\ngamma\n"
    end

    test "preserves CRLF line endings", %{tmp: tmp} do
      content = "line1\r\nline2\r\nline3\r\n"
      path = write_file(tmp, "crlf.txt", content)
      tool = CodingTools.edit_tool(tmp)

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "line2", "newText" => "LINE2"}]
        })

      assert result.ok
      assert File.read!(path) == "line1\r\nLINE2\r\nline3\r\n"
      assert result.data.diff =~ "- line2"
      assert result.data.diff =~ "+ LINE2"
    end

    test "handles UTF-8 BOM", %{tmp: tmp} do
      content = "\uFEFFalpha\nbeta\ngamma\n"
      path = write_file(tmp, "bom.txt", content)
      tool = CodingTools.edit_tool(tmp)

      result =
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "beta", "newText" => "BETA"}]
        })

      assert result.ok
      assert File.read!(path) == "\uFEFFalpha\nBETA\ngamma\n"
      assert result.data.diff =~ "- beta"
      assert result.data.diff =~ "+ BETA"
    end

    test "raises when oldText not found", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hello\nworld\n")
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/Could not find edits\[0\]/, fn ->
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "not-here", "newText" => "x"}]
        })
      end
    end

    test "raises when oldText matches multiple times", %{tmp: tmp} do
      path = write_file(tmp, "dup.txt", "beta\nbeta\nbeta\n")
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/Found 3 occurrences/, fn ->
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "beta", "newText" => "BETA"}]
        })
      end
    end

    test "raises on overlapping edits", %{tmp: tmp} do
      path = write_file(tmp, "overlap.txt", "hello world")
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/must not overlap/, fn ->
        tool.executor.(%{
          "path" => path,
          "edits" => [
            %{"oldText" => "hello w", "newText" => "x"},
            %{"oldText" => "hello", "newText" => "y"}
          ]
        })
      end
    end

    test "raises on identical replacement", %{tmp: tmp} do
      path = write_file(tmp, "same.txt", "hello\n")
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/No changes made/, fn ->
        tool.executor.(%{
          "path" => path,
          "edits" => [%{"oldText" => "hello", "newText" => "hello"}]
        })
      end
    end

    test "raises when file not found", %{tmp: tmp} do
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/File not found/, fn ->
        tool.executor.(%{
          "path" => Path.join(tmp, "nope.txt"),
          "edits" => [%{"oldText" => "x", "newText" => "y"}]
        })
      end
    end

    test "raises on directory path", %{tmp: tmp} do
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/Path is a directory/, fn ->
        tool.executor.(%{
          "path" => tmp,
          "edits" => [%{"oldText" => "x", "newText" => "y"}]
        })
      end
    end

    test "raises on empty edits array", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hello\n")
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/must contain at least one replacement/, fn ->
        tool.executor.(%{"path" => path, "edits" => []})
      end
    end

    test "raises on missing path", %{tmp: tmp} do
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/Missing argument path/, fn ->
        tool.executor.(%{"edits" => [%{"oldText" => "x", "newText" => "y"}]})
      end
    end

    test "raises on missing edits", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hello\n")
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/must contain at least one replacement/, fn ->
        tool.executor.(%{"path" => path})
      end
    end

    test "raises when edits entry is not a map", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hello\n")
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/must be an object/, fn ->
        tool.executor.(%{"path" => path, "edits" => ["not a map"]})
      end
    end

    test "raises when oldText or newText missing from edit entry", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "hello\n")
      tool = CodingTools.edit_tool(tmp)

      assert_raise RuntimeError, ~r/must be strings/, fn ->
        tool.executor.(%{"path" => path, "edits" => [%{"oldText" => "x"}]})
      end
    end
  end

  describe "bash" do
    test "executes a simple command", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)
      result = tool.executor.(%{"command" => "echo hello"})

      assert result.ok
      assert result.content =~ "hello"
      assert result.data["exit_code"] == 0
      assert result.data["timed_out"] == false
      assert result.data["cancelled"] == false
      assert is_number(result.data["duration_seconds"])
      refute result.data["truncation"].truncated
    end

    test "captures stderr in output", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)
      result = tool.executor.(%{"command" => "echo err >&2"})

      assert result.ok
      assert result.content =~ "err"
    end

    test "returns non-zero exit code", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)
      result = tool.executor.(%{"command" => "exit 42"})

      refute result.ok
      assert result.data["exit_code"] == 42
      assert result.content =~ "exited with code 42"
      assert result.error =~ "exited with code 42"
    end

    test "returns (no output) for empty stdout", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)
      result = tool.executor.(%{"command" => "true"})

      assert result.ok
      assert result.content == "(no output)"
    end

    test "runs in the given cwd", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)
      result = tool.executor.(%{"command" => "pwd"})

      assert result.ok
      assert String.trim(result.content) == tmp
    end

    test "truncates long output", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)
      result = tool.executor.(%{"command" => "yes 'x' | head -n 3000"})

      assert result.ok
      assert result.data["truncation"].truncated
      assert result.content =~ "Full output:"
      assert result.data["full_output_path"] != nil
      assert File.exists?(result.data["full_output_path"])
    end

    test "raises on missing command", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)

      assert_raise RuntimeError, ~r/Missing argument command/, fn ->
        tool.executor.(%{})
      end
    end

    test "raises on non-string command", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)

      assert_raise RuntimeError, ~r/is not a string/, fn ->
        tool.executor.(%{"command" => 123})
      end
    end

    test "raises on zero timeout", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)

      assert_raise RuntimeError, ~r/timeout must be greater than 0/, fn ->
        tool.executor.(%{"command" => "echo hi", "timeout" => 0})
      end
    end

    test "raises on negative timeout", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)

      assert_raise RuntimeError, ~r/timeout must be greater than 0/, fn ->
        tool.executor.(%{"command" => "echo hi", "timeout" => -1})
      end
    end

    test "raises on non-number timeout", %{tmp: tmp} do
      tool = CodingTools.bash_tool(tmp)

      assert_raise RuntimeError, ~r/is not a number/, fn ->
        tool.executor.(%{"command" => "echo hi", "timeout" => "abc"})
      end
    end
  end
end
