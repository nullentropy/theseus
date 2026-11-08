defmodule Sample.Pricing.Spec do
  use Theseus.Spec

  spec Sample.Pricing, deterministic: true do
    prose """
    Computes subtotal, discount, shipping and total in cents.
    Shipping is 599 cents, free when subtotal is 10000 or more, or with the :free_shipping rule.
    Discount comes from the coupon rule and never exceeds the subtotal.
    """

    example "no coupon, under free shipping",
      total: [[%{qty: 2, unit_cents: 1000}], nil],
      expect: %{subtotal_cents: 2000, discount_cents: 0, shipping_cents: 599, total_cents: 2599}

    example "free shipping at the threshold",
      total: [[%{qty: 1, unit_cents: 10_000}], nil],
      expect: %{subtotal_cents: 10_000, discount_cents: 0, shipping_cents: 0, total_cents: 10_000}

    example "percent coupon",
      total: [[%{qty: 4, unit_cents: 2500}], {:percent, 10}],
      expect: %{
        subtotal_cents: 10_000,
        discount_cents: 1000,
        shipping_cents: 0,
        total_cents: 9000
      }

    example "amount off is capped at the subtotal",
      total: [[%{qty: 1, unit_cents: 300}], {:amount_off, 500}],
      expect: %{subtotal_cents: 300, discount_cents: 300, shipping_cents: 599, total_cents: 599}

    example "free shipping coupon",
      total: [[%{qty: 1, unit_cents: 1500}], :free_shipping],
      expect: %{subtotal_cents: 1500, discount_cents: 0, shipping_cents: 0, total_cents: 1500}

    property "The total is never negative.",
      total: [list_of(item_gen()), rule_gen()],
      check: fn %{total_cents: t} -> t >= 0 end

    property "The discount never exceeds the subtotal.",
      total: [list_of(item_gen()), rule_gen()],
      check: fn %{discount_cents: d, subtotal_cents: s} -> d <= s end

    property "The total is the subtotal minus the discount plus shipping.",
      total: [list_of(item_gen()), rule_gen()],
      check: fn %{subtotal_cents: s, discount_cents: d, shipping_cents: sh, total_cents: t} ->
        t == s - d + sh
      end

    invariant "An empty basket costs only shipping.",
      check: fn call -> call.(:total, [[], nil]).total_cents == 599 end

    equivalence &==/2
  end

  defp item_gen do
    fixed_map(%{
      sku: string(:alphanumeric, min_length: 1, max_length: 12),
      qty: integer(1..20),
      unit_cents: integer(0..50_000)
    })
  end

  defp rule_gen do
    one_of([
      constant(nil),
      tuple({constant(:percent), integer(0..100)}),
      tuple({constant(:amount_off), integer(0..20_000)}),
      constant(:free_shipping)
    ])
  end
end
