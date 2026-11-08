defmodule Theseus.Unit do
  @moduledoc """
  A registered module that Theseus is allowed to change: an application unit,
  or the spec of one (`kind: :spec`). The spec of `Sample.Pricing` is the
  module `Sample.Pricing.Spec`.
  """

  @type kind :: :pure | :server | :endpoint | :store | :spec

  @type t :: %__MODULE__{
          module: module(),
          kind: kind(),
          current_version: String.t() | nil,
          spec: module() | nil,
          tags: [atom()]
        }

  @enforce_keys [:module]
  defstruct [:module, :current_version, :spec, kind: :pure, tags: []]

  @doc "The spec module for a unit."
  @spec spec_module(module()) :: module()
  def spec_module(unit), do: Module.concat(unit, Spec)

  @doc "Whether a module name is a spec module name."
  @spec spec_name?(module()) :: boolean()
  def spec_name?(module), do: module |> Module.split() |> List.last() == "Spec"

  @doc """
  The kind a new module should be registered as: `:spec` for spec modules,
  `:server` for modules that `use GenServer`, `:endpoint` for modules that
  `use Theseus.Endpoint`, `:store` for modules that `use Theseus.Store`,
  otherwise `:pure`.
  """
  @spec infer_kind(module(), Macro.t()) :: kind()
  def infer_kind(module, ast) do
    cond do
      spec_name?(module) -> :spec
      uses?(ast, [:GenServer]) -> :server
      uses?(ast, [:Theseus, :Endpoint]) -> :endpoint
      uses?(ast, [:Theseus, :Store]) -> :store
      true -> :pure
    end
  end

  defp uses?(ast, parts) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, ^parts} | _]} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  @doc """
  The modules named in a unit's syntax tree, as aliases or atoms, other
  than the unit itself. Units name other units only to pass them to
  `Theseus.call/3`, so these are the units it may call.
  """
  @spec references(Macro.t()) :: MapSet.t(module())
  def references({:defmodule, _, [name, body]}) do
    self = alias_module(name)

    {_, found} =
      Macro.prewalk(body, MapSet.new(), fn
        {:__aliases__, _, _} = node, acc ->
          case alias_module(node) do
            nil -> {node, acc}
            module -> {node, MapSet.put(acc, module)}
          end

        atom, acc when is_atom(atom) ->
          if module_atom?(atom), do: {atom, MapSet.put(acc, atom)}, else: {atom, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.delete(found, self)
  end

  def references(_ast), do: MapSet.new()

  defp alias_module({:__aliases__, _, parts}) when is_list(parts) and parts != [] do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp alias_module(atom) when is_atom(atom), do: atom
  defp alias_module(_), do: nil

  defp module_atom?(atom), do: String.starts_with?(Atom.to_string(atom), "Elixir.")

  @doc """
  Replaces the names of the modules in `mapping` with their mapped names
  throughout a syntax tree, as aliases or atoms.
  """
  @spec rename_references(Macro.t(), %{module() => module()}) :: Macro.t()
  def rename_references(ast, mapping) when map_size(mapping) == 0, do: ast

  def rename_references(ast, mapping) do
    Macro.prewalk(ast, fn
      {:__aliases__, _, parts} = node when is_list(parts) ->
        case alias_module(node) do
          nil -> node
          module -> Map.get(mapping, module, node)
        end

      atom when is_atom(atom) ->
        Map.get(mapping, atom, atom)

      node ->
        node
    end)
  end

  @doc "The unit a spec module specifies."
  @spec specified_unit(module()) :: module()
  def specified_unit(spec_module),
    do: spec_module |> Module.split() |> Enum.drop(-1) |> Module.concat()
end
