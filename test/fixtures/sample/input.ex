defmodule Sample.Input do
  def parse(%{"items" => items} = body) when is_list(items) do
    {:ok, %{items: Enum.map(items, &item/1), coupon: Map.get(body, "coupon")}}
  end

  defp item(%{"sku" => sku, "qty" => qty, "unit_cents" => unit_cents})
       when is_integer(qty) and is_integer(unit_cents) do
    %{sku: sku(sku), qty: qty, unit_cents: unit_cents}
  end

  defp sku(raw) do
    for <<char <- String.upcase(raw)>>, into: "", do: sku_char(char)
  end

  defp sku_char(char) when char in ?A..?Z or char in ?0..?9 or char == ?-, do: <<char>>
end
