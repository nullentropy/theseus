defmodule Theseus.Import do
  @moduledoc """
  One-time bootstrap: registers units and specs from `.ex` files. After an
  import the modules live only in the ledger; the files are not read again.
  Used for test fixtures and demos. Agents create units through changes.
  """

  alias Theseus.{Loader, Unit, Version}

  @doc """
  Registers every module in `dir`. Specs are modules named `<Unit>.Spec`.
  Returns `[{module, {:ok, hash} | {:error, reason}}]`.
  """
  @spec dir(Path.t()) :: [{module(), {:ok, String.t()} | {:error, term()}}]
  def dir(dir) do
    dir
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&File.read!/1)
    |> Enum.map(&register/1)
  end

  @doc "Registers one module from its source."
  @spec register(String.t()) :: {module(), {:ok, String.t()} | {:error, term()}}
  def register(source) do
    case Code.string_to_quoted(source) do
      {:ok, {:defmodule, _, [{:__aliases__, _, parts}, _]}} ->
        module = Module.concat(parts)

        result =
          with {:ok, version} <- Version.build(module, source),
               {:ok, version} <-
                 Loader.register(version,
                   kind: Unit.infer_kind(module, version.ast),
                   actor: :human
                 ) do
            {:ok, version.hash}
          end

        {module, result}

      _ ->
        {:unknown, {:error, :not_a_single_defmodule}}
    end
  end
end
