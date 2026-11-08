defmodule Theseus.ServicesTest do
  @moduledoc "Services units: what they may declare, and how changes to them are described."

  use ExUnit.Case, async: false

  alias Theseus.{Fetch, Services, Version}

  defp unit(map) do
    "defmodule Sample.Svc do\n  use Theseus.Services\n  def services do\n    #{map}\n  end\nend\n"
  end

  defp parse(map), do: map |> unit() |> Code.string_to_quoted!() |> Services.from_ast()

  @good """
  %{
    acme: %{
      authorize_url: "https://accounts.example/auth",
      token_url: "https://oauth.example/token",
      issuers: ["https://accounts.example"],
      sign_in: %{scopes: ["openid", "email"], params: %{prompt: "select_account"}},
      connect: %{scopes: ["openid", "read"], required_scopes: ["read"]},
      urls: ["https://api.example/v1/"]
    },
    plain: %{urls: ["https://status.example/"]}
  }
  """

  test "a services unit declares services as a literal map, read without running it" do
    assert {:ok, %{"acme" => acme, "plain" => plain}} = parse(@good)
    assert acme.sign_in == %{scopes: ["openid", "email"], params: %{"prompt" => "select_account"}}
    assert acme.connect.required_scopes == ["read"]
    assert acme.domain_claim == nil and acme.revoke_url == nil
    assert plain.sign_in == nil and plain.urls == ["https://status.example/"]

    {:ok, v} = Version.build(Sample.Svc, unit(@good))
    assert Services.services_unit?(v.ast)
    assert :ok = Theseus.Validator.Static.check(v, :pure)
  end

  test "what a services unit may not declare is refused with the reason" do
    for {map, reason} <- [
          {"%{acme: %{urls: [\"http://api.example/\"]}}", "https URLs ending in /"},
          {"%{acme: %{urls: [\"https://api.example\"]}}", "ending in /"},
          {"%{acme: %{client_secret: \"x\"}}", "unknown fields: :client_secret"},
          {"%{Acme: %{}}", "not a service name"},
          {"%{dev: %{}}", "a path the engine takes"},
          {"%{acme: %{sign_in: %{scopes: [\"openid\"]}}}",
           "needs authorize_url, token_url and issuers"},
          {"%{acme: %{authorize_url: \"https://a.example/\", token_url: \"https://a.example/t\", issuers: [\"x\"], sign_in: %{scopes: [\"email\"]}}}",
           "must include \"openid\""},
          {"%{acme: %{authorize_url: \"https://a.example/\", token_url: \"https://a.example/t\", issuers: [\"x\"], connect: %{scopes: [\"openid\"], required_scopes: [\"read\"]}}}",
           "required_scopes must be among"},
          {"%{acme: %{authorize_url: \"https://a.example/\", token_url: \"https://a.example/t\", issuers: [\"x\"], sign_in: %{scopes: [\"openid\"], params: %{redirect_uri: \"https://evil.example/\"}}}}",
           "may not set redirect_uri"},
          {"%{acme: %{urls: [base()]}}", "literal map"}
        ] do
      assert {:error, why} = parse(map), map
      assert why =~ reason, "#{map}: #{why}"
    end
  end

  test "changes to services are described in sentences, and requests in results too" do
    {:ok, old} = parse(@good)

    {:ok, new} =
      parse(
        String.replace(
          @good,
          ~s(urls: ["https://api.example/v1/"]),
          ~s(urls: ["https://api.example/v2/"])
        )
      )

    assert [line] = Services.describe_changes(old, new)
    assert line =~ "changes the service acme: now people sign in with it (openid, email)"
    assert line =~ "the app's requests may go to https://api.example/v2/"

    assert ["adds the service plain: the app's requests may go to https://status.example/"] =
             Services.describe_changes(Map.delete(old, "plain"), old)

    assert ["removes the service plain"] =
             Services.describe_changes(old, Map.delete(old, "plain"))
  end

  test "a request is a map the engine checks before it sends anything" do
    assert {:ok,
            %{
              method: "GET",
              query: %{"page" => "2"},
              headers: %{"accept" => "x"},
              service: "acme"
            }} =
             Fetch.normalize(%{
               service: :acme,
               url: "https://api.example/v1/",
               query: %{page: 2},
               headers: %{"Accept" => "x"}
             })

    for {request, reason} <- [
          {%{url: "https://api.example/"}, "names its service"},
          {%{service: "acme"}, "has a url"},
          {%{service: "acme", url: "https://x/", method: "TRACE"}, "not a method"},
          {%{service: "acme", url: "https://x/", headers: %{"cookie" => "a"}},
           "sets the cookie header"},
          {%{service: "acme", url: "https://x/", context: :binary.copy("a", 70_000)},
           "at most 64 KB"},
          {%{service: "acme", url: "https://x/", secret: 1}, "has no :secret"},
          {"GET /", "is a map"}
        ] do
      assert {:error, why} = Fetch.normalize(request)
      assert why =~ reason, inspect(request)
    end

    service = %{name: "acme", urls: ["https://api.example/v1/"]}

    {:ok, r} =
      Fetch.normalize(%{service: "acme", url: "https://api.example/v1/users?a=1", query: %{b: 2}})

    assert {:ok, "https://api.example/v1/users?a=1&b=2"} = Fetch.url(r, service)
    {:ok, r} = Fetch.normalize(%{service: "acme", url: "https://api.example/v1/%2e%2e/admin"})
    assert {:error, "a request's path may not have . or .. in it"} = Fetch.url(r, service)
    {:ok, r} = Fetch.normalize(%{service: "acme", url: "https://api.example/v10/"})
    assert {:error, _} = Fetch.url(r, service)
  end

  test "requests and messages around a result come apart through every layer" do
    result = {:write, [:w], {:send, [:m], {:fetch, [:r1], {:htmx, %{}, {:fetch, [:r2], :ok}}}}}

    assert {[:r1, :r2], {:write, [:w], {:send, [:m], {:htmx, %{}, :ok}}}} =
             Fetch.unwrap(result, [])

    assert {[:m], {:write, [:w], {:fetch, [:r1], {:htmx, %{}, {:fetch, [:r2], :ok}}}}} =
             Theseus.Outbox.unwrap(result, [])

    assert {[:w], {:send, [:m], _}} = Theseus.Store.take_writes(result)
  end
end
