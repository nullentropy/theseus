defmodule Theseus.GateTest do
  @moduledoc "The automatic gate's rules."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Change, Report, Version}
  alias Theseus.Gate.AutoBounded

  defp crash_fix do
    source =
      String.replace(
        fixture("input.ex"),
        "defmodule Sample.Input do",
        "defmodule Sample.Input do\n  @moduledoc false"
      )

    {:ok, version} = Version.build(Sample.Input, source, current(Sample.Input))

    %Change{
      id: "chg_gate",
      trigger: %{kind: :crash, payload: %{attempt: 1, signature: nil}, untrusted: true},
      proposer: %{kind: :in_process, client: "stub"},
      intent: "fix",
      unit: Sample.Input,
      candidates: [version],
      at: DateTime.utc_now()
    }
  end

  defp report(shadow) do
    %Report{
      change_id: "chg_gate",
      passed: true,
      stages: [
        %{
          name: :replay,
          result: :pass,
          detail: %{compared: 3, differ: 0, counts: %{fixed: 1}},
          ms: 0
        },
        shadow
      ]
    }
  end

  test "a crash fix with no live traffic waits for a person unless told otherwise" do
    quiet = %{
      name: :shadow,
      result: :skip,
      detail: %{reason: "no live calls arrived in 60 s"},
      ms: 0
    }

    assert {:hold, {:shadow, :skip}} = AutoBounded.decide(crash_fix(), report(quiet))

    config = Application.get_env(:theseus, :crash_repair)
    Application.put_env(:theseus, :crash_repair, Keyword.put(config, :without_traffic, true))
    on_exit(fn -> Application.put_env(:theseus, :crash_repair, config) end)

    assert :promote = AutoBounded.decide(crash_fix(), report(quiet))

    # A shadow run that failed still holds it.
    failed = %{name: :shadow, result: :fail, detail: %{compared: 3, differ: 1}, ms: 0}
    assert {:hold, {:shadow, :fail}} = AutoBounded.decide(crash_fix(), report(failed))
  end
end
