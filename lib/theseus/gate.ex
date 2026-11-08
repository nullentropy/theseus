defmodule Theseus.Gate do
  @moduledoc """
  Decides what happens to a validated change: `:promote`, `:reject`, or
  `{:hold, reason}` for a person to decide.

  Crash fixes and consolidations from the in-process proposer go to the
  automatic gate (config `:crash_repair, :gate`, default
  `Theseus.Gate.AutoBounded`). Every other change, including everything
  proposed over MCP, goes to `Theseus.Gate.Manual`.
  """

  alias Theseus.{Change, Report}

  @callback decide(Change.t(), Report.t()) :: :promote | :reject | {:hold, term()}

  @spec decide(Change.t(), Report.t()) :: :promote | :reject | {:hold, term()}
  def decide(change, report), do: gate_for(change).decide(change, report)

  defp gate_for(%Change{trigger: %{kind: kind}, proposer: %{kind: :in_process}})
       when kind in [:crash, :consolidate] do
    Application.get_env(:theseus, :crash_repair, [])
    |> Keyword.get(:gate, Theseus.Gate.AutoBounded)
  end

  defp gate_for(_change), do: Theseus.Gate.Manual
end

defmodule Theseus.Gate.Manual do
  @moduledoc "Rejects changes that failed validation and holds the rest for a person."

  @behaviour Theseus.Gate

  @impl true
  def decide(_change, %Theseus.Report{passed: false}), do: :reject
  def decide(_change, _report), do: {:hold, :awaiting_human}
end

defmodule Theseus.Gate.AutoBounded do
  @moduledoc """
  Promotes a change from the in-process proposer with no person present
  only when all of these hold:

    * validation passed, including replay and shadow (a skipped shadow,
      for example with no live traffic, is not enough, unless
      `crash_repair: [without_traffic: true]` and recorded calls reproduced
      the crash and now work);
    * it changes only the unit, not its spec, and does not create a unit;
    * it is not a schema or services unit: what tables the app has and
      which outside services it may reach are decided by a person;
    * it is not a server unit, unless `crash_repair: [server_units: true]`:
      a server unit holds state, so by default a person decides;
    * for a crash fix: it is the signature's first attempt, and the source
      diff is at most `:max_diff_lines` changed lines (default 40). A
      consolidation rewrites the whole unit, so it has no size limit; it
      must show no differences at all instead, which replay and shadow
      already require.

  Everything else that passed is held for a person.
  """

  @behaviour Theseus.Gate

  alias Theseus.{Change, Ledger, Report, Version}

  @impl true
  def decide(_change, %Report{passed: false}), do: :reject

  def decide(%Change{} = change, %Report{} = report) do
    cond do
      change.trigger.kind not in [:crash, :consolidate] or change.proposer.kind != :in_process ->
        {:hold, :not_automatic}

      Change.creates?(change) ->
        {:hold, :creates_a_unit}

      Change.spec_candidate(change) != nil ->
        {:hold, :changes_the_spec}

      declares?(change) ->
        {:hold, :declares_tables_or_services}

      server?(change.unit) and not server_units?() ->
        {:hold, :server_unit}

      change.trigger.kind == :crash and change.trigger.payload[:attempt] != 1 ->
        {:hold, :not_the_first_attempt}

      result(report, :replay) != :pass ->
        {:hold, {:replay, result(report, :replay)}}

      result(report, :shadow) != :pass and not quiet_fix?(change, report) ->
        {:hold, {:shadow, result(report, :shadow)}}

      change.trigger.kind == :crash and diff_lines(change) > max_diff_lines() ->
        {:hold, {:diff_too_large, diff_lines(change)}}

      true ->
        :promote
    end
  end

  defp result(report, name), do: with(%{result: r} <- Report.stage(report, name), do: r)

  # With `crash_repair: [without_traffic: true]`, a crash fix whose shadow
  # run saw no live calls may go on replay alone, when recorded calls
  # reproduced the crash and now work.
  defp quiet_fix?(%Change{trigger: %{kind: :crash}}, report) do
    without_traffic? =
      Application.get_env(:theseus, :crash_repair, []) |> Keyword.get(:without_traffic, false)

    without_traffic? and
      match?(
        %{result: :skip, detail: %{reason: "no live calls" <> _}},
        Report.stage(report, :shadow)
      ) and
      match?(
        %{result: :pass, detail: %{counts: %{fixed: f}}} when f > 0,
        Report.stage(report, :replay)
      )
  end

  defp quiet_fix?(_change, _report), do: false

  defp declares?(%Change{candidates: candidates}) do
    Enum.any?(candidates, fn v ->
      v.ast != nil and
        (Theseus.Schema.schema_unit?(v.ast) or Theseus.Services.services_unit?(v.ast))
    end)
  end

  defp server?(unit), do: match?({:ok, %{kind: :server}}, Theseus.Registry.fetch(unit))

  # Server units hold state, so their fixes wait for a person unless
  # `crash_repair: [server_units: true]`.
  defp server_units?,
    do: Application.get_env(:theseus, :crash_repair, []) |> Keyword.get(:server_units, false)

  defp max_diff_lines,
    do: Application.get_env(:theseus, :crash_repair, []) |> Keyword.get(:max_diff_lines, 40)

  @doc "Lines added plus lines removed between the base version and the candidate."
  def diff_lines(change) do
    %Version{unit: unit, parent: parent, source: source} = Change.unit_candidate(change)

    case Ledger.version(unit, parent) do
      {:ok, %Version{source: base}} ->
        String.split(base, "\n")
        |> List.myers_difference(String.split(source, "\n"))
        |> Enum.reduce(0, fn
          {:eq, _}, acc -> acc
          {_op, lines}, acc -> acc + length(lines)
        end)

      :error ->
        :infinity
    end
  end
end
