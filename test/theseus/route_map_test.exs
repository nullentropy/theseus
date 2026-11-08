defmodule Theseus.RouteMapTest do
  @moduledoc "The routes page reads an app's paths from its endpoint units' patterns."

  use ExUnit.Case, async: false

  alias Theseus.{RouteMap, Version}

  defp routes(source) do
    {:ok, v} = Version.build(Toy.Router, source)
    for r <- RouteMap.of_ast(Toy.Router, v.ast), do: {r.method, r.path, r.who, r.hands_on}
  end

  test "literal segments, variables, guards on attributes, tails and hand-ons" do
    source = """
    defmodule Toy.Router do
      use Theseus.Endpoint
      @admin ["people", "tasks"]

      def handle(%{path: ["api" | _]} = request), do: Theseus.call(Toy.Api, :handle, [request])
      def handle(%{path: [first | _]} = request) when first in @admin, do: hand_on(Toy.Admin, request)
      def handle(%{method: "GET", path: [], user: nil}), do: {:redirect, "/login"}
      def handle(%{method: "GET", path: []}), do: {200, %{}}
      def handle(%{method: "POST", path: ["items", _id, action]} = r) when action in ["keep", "drop"], do: route(r, r.user)
      def handle(%{path: path}), do: {404, %{missing: path}}

      defp route(%{method: "POST", path: ["items"]}, %{role: "admin"} = _viewer), do: {200, %{}}
      defp route(%{method: "POST", path: ["items"]}, _viewer), do: {403, %{}}
      defp route(_r, _viewer), do: {404, %{}}

      defp hand_on(unit, request), do: Theseus.call(unit, :handle, [request])
    end
    """

    assert routes(source) == [
             {"any", "/api/...", nil, Toy.Api},
             {"any", "/{people,tasks}/...", nil, Toy.Admin},
             {"GET", "/", "signed out", nil},
             {"GET", "/", "everyone else", nil},
             {"POST", "/items/:id/{keep,drop}", nil, nil},
             {"POST", "/items", "admins", nil},
             {"POST", "/items", "everyone else", nil}
           ]
  end

  test "a clause that refuses everyone but admins makes the later routes admins only" do
    source = """
    defmodule Toy.Router do
      use Theseus.Endpoint
      def handle(%{viewer: nil}), do: {:redirect, "/login"}
      def handle(%{viewer: %{role: role}}) when role != "admin", do: {403, %{}}
      def handle(%{method: "GET", path: ["reports", "x.csv"]}), do: {200, %{}}
    end
    """

    assert routes(source) == [{"GET", "/reports/x.csv", "admins", nil}]

    # A gate with more conditions, or a `not in`, is not read as more than it says.
    source = """
    defmodule Toy.Router do
      use Theseus.Endpoint
      def handle(%{method: m, viewer: %{role: role}}) when role != "admin" and m != "GET", do: {403, %{}}
      def handle(%{method: "GET", path: [first | _]}) when first not in ["admin", "api"], do: {200, %{}}
    end
    """

    assert routes(source) == [{"GET", "/:first/...", nil, nil}]
  end

  test "the sample app's routes, and the review site's page" do
    assert [
             %{method: "POST", path: "/price", unit: Sample.Routes},
             %{method: "POST", path: "/coupons/:code", unit: Sample.Routes}
           ] =
             RouteMap.routes(Theseus.Branches.live(), Theseus.Web.endpoint())
             |> Enum.filter(&(&1.unit == Sample.Routes))

    html =
      Plug.Test.conn(:get, "/routes") |> Theseus.Admin.Router.call([]) |> Map.fetch!(:resp_body)

    assert html =~ "<code>/coupons/:code</code>"
    refute html =~ "defmodule"
  end
end
