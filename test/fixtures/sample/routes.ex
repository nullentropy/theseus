defmodule Sample.Routes do
  use Theseus.Endpoint

  def handle(%{method: "POST", path: ["price"], body: body}) do
    case Theseus.call(Sample.Input, :parse, [body]) do
      {:ok, request} ->
        rule =
          if active?(request.coupon), do: Theseus.call(Sample.Coupons, :rule, [request.coupon])

        {200, Theseus.call(Sample.Pricing, :total, [request.items, rule])}

      {:error, reason} ->
        {422, %{error: inspect(reason)}}
    end
  end

  def handle(%{method: "POST", path: ["coupons", code]}) do
    :ok = Theseus.call(Sample.CouponStore, :activate, [code])
    {200, %{active: code}}
  end

  def handle(_request), do: {404, %{error: "not found"}}

  defp active?(nil), do: false
  defp active?(code), do: Theseus.call(Sample.CouponStore, :active?, [code])
end
