defmodule Sample.CouponStore.Spec do
  use Theseus.Spec

  spec Sample.CouponStore, deterministic: true do
    prose """
    Holds the coupon codes that are active right now.
    SAVE10, FIVEOFF and SHIPFREE are active when the store starts.
    Codes can be activated and deactivated while the app runs, and stay active when the store's code changes.
    """

    invariant "The default coupons are active when the store starts.",
      check: fn call ->
        {:ok, store} = call.(:start_link, [[name: nil]])
        call.(:codes, [store]) == ["FIVEOFF", "SAVE10", "SHIPFREE"]
      end

    invariant "An activated code is active until it is deactivated.",
      check: fn call ->
        {:ok, store} = call.(:start_link, [[name: nil]])
        :ok = call.(:activate, [store, "WELCOME"])
        active = call.(:active?, [store, "WELCOME"])
        :ok = call.(:deactivate, [store, "WELCOME"])
        active and not call.(:active?, [store, "WELCOME"])
      end

    invariant "Unknown codes are not active.",
      check: fn call ->
        {:ok, store} = call.(:start_link, [[name: nil]])
        call.(:active?, [store, "NOPE"]) == false
      end
  end
end
