defmodule Sample.Routes.Spec do
  use Theseus.Spec

  spec Sample.Routes, deterministic: true do
    prose """
    The pricing app's HTTP interface.
    POST /price with a JSON basket returns its subtotal, discount, shipping and total in cents; a coupon counts only while it is active.
    POST /coupons/CODE activates a coupon. Any other request gets 404.
    """

    example "prices a basket",
      handle: [
        %{
          method: "POST",
          path: ["price"],
          query: %{},
          body: %{"items" => [%{"sku" => "a", "qty" => 2, "unit_cents" => 1000}]}
        }
      ],
      expect:
        {200, %{subtotal_cents: 2000, discount_cents: 0, shipping_cents: 599, total_cents: 2599}}

    example "applies an active coupon",
      handle: [
        %{
          method: "POST",
          path: ["price"],
          query: %{},
          body: %{
            "items" => [%{"sku" => "a", "qty" => 4, "unit_cents" => 2500}],
            "coupon" => "SAVE10"
          }
        }
      ],
      expect:
        {200,
         %{subtotal_cents: 10_000, discount_cents: 1000, shipping_cents: 0, total_cents: 9000}}

    example "ignores an unknown coupon",
      handle: [
        %{
          method: "POST",
          path: ["price"],
          query: %{},
          body: %{
            "items" => [%{"sku" => "a", "qty" => 1, "unit_cents" => 1000}],
            "coupon" => "NOPE"
          }
        }
      ],
      expect:
        {200, %{subtotal_cents: 1000, discount_cents: 0, shipping_cents: 599, total_cents: 1599}}

    example "other requests are not found",
      handle: [%{method: "GET", path: ["nope"], query: %{}, body: %{}}],
      expect: {404, %{error: "not found"}}
  end
end
