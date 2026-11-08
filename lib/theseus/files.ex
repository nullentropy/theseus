defmodule Theseus.Files do
  @moduledoc """
  Files people upload to the app. A form posted as `multipart/form-data`
  reaches the endpoint unit with each file replaced by a reference, a map
  in the body:

      %{"file" => "fil_...", "name" => "photo.png", "type" => "image/png", "size" => 48213}

  The engine keeps the file; the unit keeps the reference in its tables and
  never sees the bytes, so recorded calls stay small and replay the same.
  A unit answers `{status, {:upload, id}}` to send a file back: images
  (PNG, JPEG, GIF, WebP) are shown in the page, anything else is
  downloaded under its name, never run as a page.

  With a database the files are kept in the app's schema, in
  `_theseus_files`; without one, in a folder next to the ledger
  (`<ledger>.files`), as `Theseus.Records` decides. Config `:uploads`: `max_bytes` (10 MB) for a whole
  request. Files are not removed yet.
  """

  @table "_theseus_files"
  @inline ~w(image/png image/jpeg image/gif image/webp)

  @doc "Keeps an uploaded file. Returns its reference."
  @spec put(Plug.Upload.t()) :: map()
  def put(%Plug.Upload{path: path, filename: filename, content_type: type}) do
    data = File.read!(path)
    id = "fil_" <> Base.encode32(:crypto.strong_rand_bytes(15), case: :lower, padding: false)
    name = clean_name(filename)
    type = clean_type(type)
    meta = %{name: name, type: type, size: byte_size(data), at: DateTime.utc_now()}

    if database?() do
      ensure_table()

      Postgrex.query!(
        pool(),
        "INSERT INTO #{table()} (id, name, type, size, at, data) VALUES ($1, $2, $3, $4, $5, $6)",
        [id, name, type, meta.size, meta.at, data]
      )
    else
      dir = dir()
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, id), data)
      File.write!(Path.join(dir, id <> ".meta"), :erlang.term_to_binary(meta))
    end

    %{"file" => id, "name" => name, "type" => type, "size" => meta.size}
  end

  @doc "A kept file: `{:ok, %{name, type, size, data}}`, or `:error`."
  @spec get(term()) :: {:ok, map()} | :error
  def get("fil_" <> rest = id) when byte_size(rest) == 24 do
    if database?() do
      ensure_table()

      case Postgrex.query!(
             pool(),
             "SELECT name, type, size, data FROM #{table()} WHERE id = $1",
             [id]
           ) do
        %{rows: [[name, type, size, data]]} ->
          {:ok, %{name: name, type: type, size: size, data: data}}

        _ ->
          :error
      end
    else
      with {:ok, data} <- File.read(Path.join(dir(), id)),
           {:ok, meta} <- File.read(Path.join(dir(), id <> ".meta")) do
        {:ok, Map.put(:erlang.binary_to_term(meta, [:safe]), :data, data)}
      else
        _ -> :error
      end
    end
  end

  def get(_id), do: :error

  @doc "Whether a file of this type is shown in the page rather than downloaded."
  @spec inline?(String.t()) :: boolean()
  def inline?(type), do: type in @inline

  @doc "The most a request with files may carry, in bytes."
  def max_bytes,
    do: Keyword.get(Application.get_env(:theseus, :uploads, []), :max_bytes, 10_000_000)

  @doc "A body with every upload in it kept and replaced by its reference."
  @spec take(term()) :: term()
  def take(%Plug.Upload{} = upload), do: put(upload)
  def take(%{} = map) when not is_struct(map), do: Map.new(map, fn {k, v} -> {k, take(v)} end)
  def take(list) when is_list(list), do: Enum.map(list, &take/1)
  def take(other), do: other

  defp clean_name(nil), do: "file"

  defp clean_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f\x7f"\\\/]/, "")
    |> String.slice(0, 200)
    |> then(&if(&1 == "", do: "file", else: &1))
  end

  defp clean_type(type) when is_binary(type) do
    if Regex.match?(~r{^[a-z0-9.+-]+/[a-z0-9.+-]+$}, type),
      do: type,
      else: "application/octet-stream"
  end

  defp clean_type(_), do: "application/octet-stream"

  # Kept where the engine keeps its records (Theseus.Records).
  defp database?, do: Theseus.Records.database?()

  defp dir do
    Application.get_env(:theseus, :files_path) ||
      Application.fetch_env!(:theseus, :ledger_path) <> ".files"
  end

  defp ensure_table do
    unless :persistent_term.get({__MODULE__, :table}, false) do
      schema = Theseus.Schema.quote_name(Theseus.Store.DB.prefix())
      Postgrex.query!(pool(), "CREATE SCHEMA IF NOT EXISTS #{schema}", [])

      Postgrex.query!(
        pool(),
        "CREATE TABLE IF NOT EXISTS #{table()} (id text PRIMARY KEY, name text NOT NULL, " <>
          "type text NOT NULL, size bigint NOT NULL, at timestamptz NOT NULL, data bytea NOT NULL)",
        []
      )

      :persistent_term.put({__MODULE__, :table}, true)
    end
  end

  defp table,
    do:
      Theseus.Schema.quote_name(Theseus.Store.DB.prefix()) <>
        "." <> Theseus.Schema.quote_name(@table)

  defp pool, do: Theseus.Store.Pool
end
