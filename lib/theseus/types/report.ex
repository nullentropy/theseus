defmodule Theseus.Report do
  @moduledoc """
  The result of validating a change. Stages run in order and stop at the
  first failure. `:info` stages report evidence and never fail. A
  `:running` stage (the shadow run) is still collecting evidence; the gate
  waits for it.
  """

  @type stage :: %{
          name: atom(),
          result: :pass | :fail | :skip | :info | :running,
          detail: term(),
          ms: non_neg_integer()
        }

  @type t :: %__MODULE__{change_id: String.t() | nil, stages: [stage()], passed: boolean()}

  defstruct [:change_id, stages: [], passed: false]

  @doc "The first failed stage, if any."
  def failure(%__MODULE__{stages: stages}), do: Enum.find(stages, &(&1.result == :fail))

  @doc "The stage with this name, if the report has it."
  def stage(%__MODULE__{stages: stages}, name), do: Enum.find(stages, &(&1.name == name))

  @doc "Whether a stage is still collecting evidence."
  def running?(%__MODULE__{stages: stages}), do: Enum.any?(stages, &(&1.result == :running))

  @doc "Replaces the stage of the same name, or adds it, and recomputes `passed`."
  def put_stage(%__MODULE__{stages: stages} = report, %{name: name} = stage) do
    stages =
      if Enum.any?(stages, &(&1.name == name)),
        do: Enum.map(stages, &if(&1.name == name, do: stage, else: &1)),
        else: stages ++ [stage]

    %{report | stages: stages, passed: not Enum.any?(stages, &(&1.result == :fail))}
  end
end
