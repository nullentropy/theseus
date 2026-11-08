defmodule Theseus.Version do
  @moduledoc """
  One version of a unit, identified by the hash of its canonical AST.

  The canonical AST is the module rendered to source, parsed again, and
  stripped of all metadata except `no_parens: true`, which separates
  `map.field` from `mod.fun()`. That makes the hash independent of line
  numbers, formatting, and whether the AST came from `quote` or from parsing
  a string.
  """

  @type t :: %__MODULE__{
          unit: module(),
          hash: String.t(),
          ast: Macro.t(),
          source: String.t(),
          beam: binary() | nil,
          parent: String.t() | nil
        }

  @enforce_keys [:unit, :hash, :ast, :source]
  defstruct [:unit, :hash, :ast, :source, :beam, :parent]

  @doc """
  Builds a version of `unit` from a source string or a quoted module.

  Returns an error unless the input is exactly one `defmodule` named `unit`.
  The returned version has no beam yet.
  """
  @spec build(module(), String.t() | Macro.t(), String.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def build(unit, source_or_ast, parent \\ nil) do
    with {:ok, ast} <- to_ast(source_or_ast),
         :ok <- check_module(ast, unit) do
      ast = canonicalize(ast)

      {:ok,
       %__MODULE__{
         unit: unit,
         hash: hash(ast),
         ast: ast,
         source: render(ast),
         parent: parent
       }}
    end
  end

  # Spec DSL calls render without parentheses, as they are written.
  @dsl [spec: 2, spec: 3, prose: 1, example: 2, property: 2, invariant: 2, equivalence: 1]

  @doc "Renders an AST to formatted source."
  @spec render(Macro.t()) :: String.t()
  def render(ast) do
    ast
    |> Code.quoted_to_algebra(locals_without_parens: @dsl)
    |> Inspect.Algebra.format(98)
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  @doc "Round-trips an AST through source and strips metadata."
  @spec canonicalize(Macro.t()) :: Macro.t()
  def canonicalize(ast) do
    ast |> render() |> Code.string_to_quoted!() |> strip_meta()
  end

  @doc "sha256 hex of a canonical AST."
  @spec hash(Macro.t()) :: String.t()
  def hash(ast) do
    bin = :erlang.term_to_binary(strip_meta(ast), [:deterministic, minor_version: 2])
    :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  end

  @doc """
  Whether compaction removed this version's code. Its hash and parent stay;
  the archived ledger has the rest (see `Theseus.Compact`).
  """
  @spec compacted?(t()) :: boolean()
  def compacted?(%__MODULE__{source: source}), do: source == nil

  @doc "First 12 characters of a hash, for display."
  @spec short(String.t() | nil) :: String.t() | nil
  def short(nil), do: nil
  def short(hash), do: binary_part(hash, 0, 12)

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        if meta[:no_parens] == true,
          do: {form, [no_parens: true], args},
          else: {form, [], args}

      other ->
        other
    end)
  end

  defp to_ast(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, {meta, message, token}} -> {:error, {:parse, meta, message, token}}
    end
  end

  defp to_ast(ast), do: {:ok, ast}

  defp check_module({:defmodule, _, [{:__aliases__, _, parts}, [do: _]]}, unit) do
    case Module.concat(parts) do
      ^unit -> :ok
      other -> {:error, {:wrong_module, other}}
    end
  end

  defp check_module(_ast, _unit), do: {:error, :not_a_single_defmodule}
end
