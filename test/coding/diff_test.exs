defmodule Eva.Coding.DiffTest do
  use ExUnit.Case, async: true

  alias Eva.Coding.Diff

  describe "diff_string/2" do
    test "identical texts yield an all-context diff and nil first changed line" do
      text = "alpha\nbeta\ngamma\n"
      assert {diff, nil} = Diff.diff_string(text, text)
      assert diff == "  alpha\n  beta\n  gamma"
    end

    test "pure insertion at the end" do
      {diff, first} = Diff.diff_string("a\nb\n", "a\nb\nc\n")
      assert diff == "  a\n  b\n+ c"
      assert first == 3
    end

    test "pure insertion at the start" do
      {diff, first} = Diff.diff_string("b\nc\n", "a\nb\nc\n")
      assert diff == "+ a\n  b\n  c"
      assert first == 1
    end

    test "pure deletion" do
      {diff, first} = Diff.diff_string("a\nb\nc\n", "a\nc\n")
      assert diff == "  a\n- b\n  c"
      assert first == 2
    end

    test "replace points at the changed line in new" do
      {diff, first} = Diff.diff_string("x\na\n", "x\nb\n")
      assert diff == "  x\n- a\n+ b"
      assert first == 2
    end

    test "both empty" do
      assert {"", nil} = Diff.diff_string("", "")
    end

    test "empty to single line" do
      {diff, first} = Diff.diff_string("", "x\n")
      assert diff == "+ x"
      assert first == 1
    end

    test "single line to empty" do
      {diff, first} = Diff.diff_string("x\n", "")
      assert diff == "- x"
      assert first == 1
    end

    test "file without a trailing newline" do
      {diff, first} = Diff.diff_string("a\nb\nc", "a\nB\nc")
      assert diff == "  a\n- b\n+ B\n  c"
      assert first == 2
    end
  end

  describe "unified_patch/3" do
    test "identical texts yield an empty patch" do
      text = "alpha\nbeta\ngamma\n"
      assert Diff.unified_patch("f.txt", text, text) == ""
    end

    test "both empty yields an empty patch" do
      assert Diff.unified_patch("f.txt", "", "") == ""
    end

    test "single line replace" do
      patch = Diff.unified_patch("f.txt", "x\na\n", "x\nb\n")

      expected =
        "--- f.txt\n" <>
          "+++ f.txt\n" <>
          "@@ -1,2 +1,2 @@\n" <>
          " x\n" <>
          "-a\n" <>
          "+b\n"

      assert patch == expected
    end

    test "empty file to single line" do
      patch = Diff.unified_patch("f.txt", "", "x\n")

      expected =
        "--- f.txt\n" <>
          "+++ f.txt\n" <>
          "@@ -0,0 +1 @@\n" <>
          "+x\n"

      assert patch == expected
    end

    test "single line deletion" do
      patch = Diff.unified_patch("f.txt", "x\n", "")

      expected =
        "--- f.txt\n" <>
          "+++ f.txt\n" <>
          "@@ -1 +0,0 @@\n" <>
          "-x\n"

      assert patch == expected
    end

    test "trims to three lines of context around a middle change" do
      old = Enum.map_join(1..10, "", &"L#{&1}\n")
      new = "L1\nL2\nL3\nL4\nCHANGED\nL6\nL7\nL8\nL9\nL10\n"

      patch = Diff.unified_patch("f.txt", old, new)

      expected =
        "--- f.txt\n" <>
          "+++ f.txt\n" <>
          "@@ -2,7 +2,7 @@\n" <>
          " L2\n" <>
          " L3\n" <>
          " L4\n" <>
          "-L5\n" <>
          "+CHANGED\n" <>
          " L6\n" <>
          " L7\n" <>
          " L8\n"

      assert patch == expected
    end

    test "splits distant changes into separate hunks" do
      old = Enum.map_join(1..20, "", &"L#{&1}\n")

      new =
        "L1\nL2\nL3\nL4\nX1\n" <>
          "L6\nL7\nL8\nL9\nL10\nL11\nL12\nL13\nL14\nX2\n" <>
          "L16\nL17\nL18\nL19\nL20\n"

      patch = Diff.unified_patch("f.txt", old, new)

      expected =
        "--- f.txt\n" <>
          "+++ f.txt\n" <>
          "@@ -2,7 +2,7 @@\n" <>
          " L2\n" <>
          " L3\n" <>
          " L4\n" <>
          "-L5\n" <>
          "+X1\n" <>
          " L6\n" <>
          " L7\n" <>
          " L8\n" <>
          "@@ -12,7 +12,7 @@\n" <>
          " L12\n" <>
          " L13\n" <>
          " L14\n" <>
          "-L15\n" <>
          "+X2\n" <>
          " L16\n" <>
          " L17\n" <>
          " L18\n"

      assert patch == expected
    end

    test "no trailing newline on the last changed line" do
      patch = Diff.unified_patch("f.txt", "a\nb\nc", "a\nB\nc")

      expected =
        "--- f.txt\n" <>
          "+++ f.txt\n" <>
          "@@ -1,3 +1,3 @@\n" <>
          " a\n" <>
          "-b\n" <>
          "+B\n" <>
          " c"

      assert patch == expected
    end
  end
end
