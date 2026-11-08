defmodule Theseus.FilesTest do
  @moduledoc "Uploaded files: kept by the engine, passed to the app as references, sent back safely."

  use ExUnit.Case, async: false

  import Plug.Conn
  import Theseus.TestHelpers

  @routes_extra """
    def handle(%{method: "POST", path: ["upload"], body: body}), do: {200, %{got: body}}

    def handle(%{method: "GET", path: ["files", id]}), do: {200, {:upload, id}}

    def handle(_request), do: {404, %{error: "not found"}}
  """

  setup_all do
    before = snapshot()

    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}\n",
        @routes_extra
      )

    approve_settled(unit: "Sample.Routes", intent: "routes for file tests", unit_source: routes)
    on_exit(fn -> restore(before) end)
    :ok
  end

  setup do
    dir = Path.expand("../../tmp/files_#{System.unique_integer([:positive])}", __DIR__)
    Application.put_env(:theseus, :files_path, dir)
    on_exit(fn -> Application.delete_env(:theseus, :files_path) && File.rm_rf!(dir) end)
    :ok
  end

  defp upload(name, type, data) do
    path = Path.join(System.tmp_dir!(), "up_#{System.unique_integer([:positive])}")
    File.write!(path, data)
    %Plug.Upload{path: path, filename: name, content_type: type}
  end

  defp call(conn), do: Theseus.Web.call(conn, Theseus.Web.init([]))

  test "an upload reaches the app as a reference, and the file comes back with safe headers" do
    params = %{"title" => "me", "photo" => upload("../me \"x\".png", "image/png", "PNGDATA")}
    conn = call(Plug.Test.conn(:post, "/upload", params))
    %{"got" => got} = JSON.decode!(conn.resp_body)

    assert %{
             "title" => "me",
             "photo" => %{
               "file" => "fil_" <> _ = id,
               "name" => "me x.png",
               "type" => "image/png",
               "size" => 7
             }
           } = got

    conn = call(Plug.Test.conn(:get, "/files/" <> id))
    assert conn.resp_body == "PNGDATA"
    assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="me x.png")]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "sandbox"
  end

  @tag :postgres
  test "with a database, files are kept there" do
    Application.put_env(:theseus, :records, :database)
    on_exit(fn -> Application.put_env(:theseus, :records, :files) end)

    conn =
      call(Plug.Test.conn(:post, "/upload", %{"f" => upload("a.txt", "text/plain", "hello")}))

    id = JSON.decode!(conn.resp_body)["got"]["f"]["file"]

    %{rows: [[size]]} =
      Postgrex.query!(
        Theseus.Store.Pool,
        ~s|SELECT size FROM "theseus_test"."_theseus_files" WHERE id = $1|,
        [id]
      )

    assert size == 5
    assert call(Plug.Test.conn(:get, "/files/" <> id)).resp_body == "hello"
  end

  test "a file that is not an image is downloaded, never shown as a page" do
    params = %{"doc" => upload("page.html", "text/html", "<script>alert(1)</script>")}
    conn = call(Plug.Test.conn(:post, "/upload", params))
    id = JSON.decode!(conn.resp_body)["got"]["doc"]["file"]

    conn = call(Plug.Test.conn(:get, "/files/" <> id))
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="page.html")]

    conn = call(Plug.Test.conn(:get, "/files/fil_nope"))
    assert conn.status == 404
  end
end
