defmodule Theseus.SignatureTest do
  use ExUnit.Case, async: true

  alias Theseus.{Proposer, Signature}

  test "the same bug on different inputs has one signature" do
    a = Signature.of(U, :f, 1, %KeyError{key: :a, term: %{a: 1}, message: nil})
    b = Signature.of(U, :f, 1, %KeyError{key: :a, term: %{b: 2, c: 3}, message: nil})
    assert a.id == b.id

    a = Signature.of(U, :f, 1, %ArgumentError{message: ~s(bad "x" at 12)})
    b = Signature.of(U, :f, 1, %ArgumentError{message: ~s(bad "something else" at 99)})
    assert a.id == b.id

    refute Signature.of(U, :f, 1, %ArgumentError{message: "x"}).id ==
             Signature.of(U, :g, 1, %ArgumentError{message: "x"}).id
  end

  test "a candidate's renamed module does not change the signature" do
    live = %FunctionClauseError{module: Sample.Input, function: :sku_char, arity: 1}

    candidate = %FunctionClauseError{
      module: Module.concat([Theseus.Candidate, "Vabc123x7", Sample.Input]),
      function: :sku_char,
      arity: 1
    }

    assert Signature.of(Sample.Input, :parse, 1, live).id ==
             Signature.of(Sample.Input, :parse, 1, candidate).id
  end

  test "a model reply is parsed into a module and a rationale" do
    reply = """
    Here you go.
    ```elixir
    defmodule A do
    end
    ```
    ```json
    {"rationale": "Because."}
    ```
    """

    assert {:ok, "defmodule A do\nend\n", "Because."} = Proposer.parse(reply)
    assert {:error, :no_module_in_reply} = Proposer.parse("I could not do it.")
  end
end
