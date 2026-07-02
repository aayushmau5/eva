defmodule EvaTest do
  use ExUnit.Case
  doctest Eva

  test "greets the world" do
    assert Eva.hello() == :world
  end
end
