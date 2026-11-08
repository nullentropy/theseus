defmodule Sample.Coupons do
  def rule("SAVE10"), do: {:percent, 10}
  def rule("FIVEOFF"), do: {:amount_off, 500}
  def rule("SHIPFREE"), do: :free_shipping
  def rule(_code), do: nil
end
