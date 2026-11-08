defmodule Theseus.VersionTest do
  use ExUnit.Case, async: true

  alias Theseus.Version

  @source """
  defmodule Demo.Unit do
    def double(x), do: x * 2
  end
  """

  test "the hash ignores line numbers and formatting" do
    {:ok, a} = Version.build(Demo.Unit, @source)

    {:ok, b} =
      Version.build(Demo.Unit, "\n\n\ndefmodule Demo.Unit do def double(x) do\n x * 2 end end")

    assert a.hash == b.hash
  end

  test "a quoted module and the same parsed source hash the same" do
    quoted =
      quote do
        defmodule Demo.Unit do
          def double(x), do: x * 2
        end
      end

    {:ok, a} = Version.build(Demo.Unit, @source)
    {:ok, b} = Version.build(Demo.Unit, quoted)
    assert a.hash == b.hash
  end

  test "a behaviour change changes the hash" do
    {:ok, a} = Version.build(Demo.Unit, @source)
    {:ok, b} = Version.build(Demo.Unit, String.replace(@source, "x * 2", "x * 3"))
    refute a.hash == b.hash
  end

  test "rebuilding the hash from the stored AST is stable" do
    {:ok, v} = Version.build(Demo.Unit, @source)
    assert Version.hash(v.ast) == v.hash
    assert Version.hash(Version.canonicalize(v.ast)) == v.hash
  end

  test "map field access stays field access after canonicalization" do
    {:ok, v} = Version.build(Demo.Unit, "defmodule Demo.Unit do\n  def f(m), do: m.items\nend")
    assert v.source =~ "m.items\n"
    refute v.source =~ "m.items()"

    {:ok, call} =
      Version.build(Demo.Unit, "defmodule Demo.Unit do\n  def f(m), do: m.items()\nend")

    refute call.hash == v.hash
  end

  test "only a single defmodule with the expected name is accepted" do
    assert {:error, {:wrong_module, Demo.Other}} =
             Version.build(Demo.Unit, String.replace(@source, "Demo.Unit", "Demo.Other"))

    assert {:error, :not_a_single_defmodule} = Version.build(Demo.Unit, @source <> @source)
    assert {:error, :not_a_single_defmodule} = Version.build(Demo.Unit, "def x, do: 1")
    assert {:error, {:parse, _, _, _}} = Version.build(Demo.Unit, "defmodule Demo.Unit do")
  end
end
