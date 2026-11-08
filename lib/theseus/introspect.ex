defmodule Theseus.Introspect do
  @moduledoc """
  Read-only view of the running system: units, specs, history, traces.
  """

  alias Theseus.{Ledger, Registry, Traces, Version}

  @doc "Application units, not specs."
  def units, do: Registry.units()

  @doc """
  Who calls whom on a branch: for each unit, the units it names (and so
  may call through `Theseus.call/3`) and the units that name it.
  """
  @spec graph(String.t()) :: %{module() => %{calls: [module()], called_by: [module()]}}
  def graph(branch) do
    units = for u <- Theseus.Branches.units(branch), u.kind != :spec, do: u
    names = MapSet.new(units, & &1.module)

    calls =
      for %{module: m, current_version: hash} <- units, into: %{} do
        refs =
          case Ledger.version(m, hash) do
            {:ok, %Version{ast: ast}} -> Theseus.Unit.references(ast)
            _ -> MapSet.new()
          end

        {m, refs |> Enum.filter(&MapSet.member?(names, &1)) |> Enum.sort()}
      end

    Map.new(calls, fn {m, out} ->
      called_by = for {other, list} <- calls, m in list, do: other
      {m, %{calls: out, called_by: Enum.sort(called_by)}}
    end)
  end

  @doc "Current source of a unit or spec module. For agents, never for people."
  @spec source(module()) :: String.t() | nil
  def source(module) do
    with {:ok, record} <- Registry.fetch(module),
         {:ok, version} <- Ledger.version(module, record.current_version) do
      version.source
    else
      _ -> nil
    end
  end

  def spec(unit), do: Registry.spec(unit)

  def history(unit, limit \\ 50), do: Ledger.events_for(unit, limit: limit)

  def traces(unit, opts \\ []), do: Traces.list(unit, opts)

  @spec versions(module()) :: [Version.t()]
  def versions(module), do: Ledger.versions_for(module)

  @doc """
  What the in-process proposer needs to fix a crash in `unit`: its source,
  its readable spec, recent history, and recorded calls (failing ones with
  `signature` first), each capped in size. Recorded calls and history are
  data from outside the system; the proposer wraps them as untrusted.
  """
  @spec context_for(module(), Theseus.Signature.t() | nil) :: map()
  def context_for(unit, signature) do
    replay = Traces.replay_set(unit)

    # Without a signature (a consolidation), every failing call counts.
    failing =
      for %{result: {:error, error, _}} = t <- replay,
          signature == nil or
            Theseus.Signature.matches?(signature, unit, t.fun, length(t.args), error),
          do: t

    ok = for %{result: {:ok, _}} = t <- replay, do: t
    record = Registry.fetch!(unit)

    %{
      unit: unit,
      kind: record.kind,
      version: record.current_version,
      source: source(unit),
      spec: with(%Theseus.Spec{} = s <- Registry.spec(unit), do: Theseus.Spec.describe(s)),
      history: Theseus.Describe.history_lines(unit, 15),
      failing: failing |> Enum.take(10) |> Enum.map(&line/1),
      succeeding: ok |> Enum.take(10) |> Enum.map(&line/1)
    }
  end

  defp line(trace), do: trace |> Theseus.Describe.trace_line() |> String.slice(0, 400)
end
