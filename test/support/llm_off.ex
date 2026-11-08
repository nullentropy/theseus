defmodule Theseus.LLM.Off do
  @moduledoc false
  # A model that is never available: crashes are recorded and no repair
  # run starts, so a test does not spend the run limit.
  @behaviour Theseus.LLM

  @impl true
  def available?, do: false

  @impl true
  def name, do: "off"

  @impl true
  def setup, do: "turn it on"

  @impl true
  def complete(_system, _messages, _opts), do: {:error, :off}
end
