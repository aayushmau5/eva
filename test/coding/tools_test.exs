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

    test "total_lines in truncation strips trailing empty line", %{tmp: tmp} do
      path = write_file(tmp, "x.txt", "a\nb\n")
      result = CodingTools.read_tool(tmp).executor.(%{"path" => path})

      # split_lines_for_counting drops trailing empty from EOL-terminated files
      assert result.data.truncation.total_lines == 2
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
  end
end
