defmodule Sample.Coupons.Spec do
  use Theseus.Spec

  spec Sample.Coupons, deterministic: true do
    prose """
    Maps a coupon code to a discount rule.
    Rules are {:percent, 0..100}, {:amount_off, cents}, :free_shipping, or nil for no discount.
    Unknown codes and nil give nil.
    """

    example "percent", rule: ["SAVE10"], expect: {:percent, 10}
    example "amount off", rule: ["FIVEOFF"], expect: {:amount_off, 500}
    example "free shipping", rule: ["SHIPFREE"], expect: :free_shipping
    example "no code", rule: [nil], expect: nil
    example "unknown code", rule: ["BOGUS"], expect: nil

    property "Every code gives a well-formed rule.",
      rule: [code_gen()],
      check: fn
        nil -> true
        :free_shipping -> true
        {:percent, pct} -> pct in 0..100
        {:amount_off, cents} -> is_integer(cents) and cents >= 0
      end
  end

  defp code_gen do
    one_of([constant(nil), member_of(["SAVE10", "FIVEOFF", "SHIPFREE"]), string(:printable)])
  end
end
