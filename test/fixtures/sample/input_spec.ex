defmodule Sample.Input.Spec do
  use Theseus.Spec

  spec Sample.Input, deterministic: true do
    prose """
    Turns a decoded JSON request body into a pricing request.
    The body has "items", a list of objects with "sku", "qty" and "unit_cents", and an optional "coupon".
    Returns {:ok, %{items: [%{sku, qty, unit_cents}], coupon: code_or_nil}}.
    SKUs are upper-cased. Quantities and prices are integers.
    """

    example "one item with a coupon",
      parse: [
        %{"items" => [%{"sku" => "ab-1", "qty" => 2, "unit_cents" => 1000}], "coupon" => "SAVE10"}
      ],
      expect: {:ok, %{items: [%{sku: "AB-1", qty: 2, unit_cents: 1000}], coupon: "SAVE10"}}

    example "no coupon",
      parse: [%{"items" => [%{"sku" => "X9", "qty" => 1, "unit_cents" => 250}]}],
      expect: {:ok, %{items: [%{sku: "X9", qty: 1, unit_cents: 250}], coupon: nil}}

    example "empty basket",
      parse: [%{"items" => []}],
      expect: {:ok, %{items: [], coupon: nil}}

    property "A well-formed request keeps every item and its coupon.",
      parse: [request_gen()],
      check: fn [body], {:ok, request} ->
        length(request.items) == length(body["items"]) and request.coupon == body["coupon"]
      end
  end

  defp request_gen do
    item =
      fixed_map(%{
        "sku" => string(:alphanumeric, min_length: 1, max_length: 12),
        "qty" => integer(1..20),
        "unit_cents" => integer(0..50_000)
      })

    coupon = one_of([constant(nil), member_of(["SAVE10", "FIVEOFF", "SHIPFREE"])])
    fixed_map(%{"items" => list_of(item), "coupon" => coupon})
  end
end
