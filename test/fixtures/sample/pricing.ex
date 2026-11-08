defmodule Sample.Pricing do
  @shipping_cents 599
  @free_shipping_from 10_000

  def total(items, rule) do
    subtotal =
      Enum.reduce(items, 0, fn %{qty: qty, unit_cents: cents}, acc -> acc + qty * cents end)

    discount = min(discount(rule, subtotal), subtotal)
    shipping = shipping(rule, subtotal)

    %{
      subtotal_cents: subtotal,
      discount_cents: discount,
      shipping_cents: shipping,
      total_cents: subtotal - discount + shipping
    }
  end

  defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)
  defp discount({:amount_off, cents}, _subtotal), do: cents
  defp discount(_rule, _subtotal), do: 0

  defp shipping(:free_shipping, _subtotal), do: 0
  defp shipping(_rule, subtotal) when subtotal >= @free_shipping_from, do: 0
  defp shipping(_rule, _subtotal), do: @shipping_cents
end
