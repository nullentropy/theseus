defmodule Theseus.SealedLog do
  @moduledoc """
  An append-only file of Erlang terms, each encrypted with AES-256-GCM.
  The trace file and the state file use it.

  The file starts with an 8-byte magic and an 8-byte key id (the start of
  the key's SHA-256). Each record is `<<size::32, iv::12 bytes, tag::16
  bytes, ciphertext>>`, with the key id as associated data. A file written
  with another key is moved aside to `<path>.unreadable-<time>`, never over
  an earlier one. A torn or
  unreadable record ends the file; it and anything after it are dropped.
  """

  require Logger

  @type t :: %{fd: term(), path: Path.t(), key: binary(), key_id: binary(), magic: binary()}

  @doc """
  Opens the file, creating it if needed, and returns the terms in it, oldest
  first. Option `:sync` (default false): when false, writes are buffered for
  up to a second; when true, every append is flushed to disk.
  """
  @spec open(Path.t(), binary(), <<_::64>>, keyword()) :: {t(), [term()]}
  def open(path, key, <<_::binary-8>> = magic, opts \\ []) when byte_size(key) == 32 do
    key_id = binary_part(:crypto.hash(:sha256, key), 0, 8)
    File.mkdir_p!(Path.dirname(path))

    terms =
      case File.read(path) do
        {:ok, <<^magic::binary-8, ^key_id::binary-8, records::binary>>} ->
          {terms, valid} = scan(records, key, key_id, [], 16)
          if valid < byte_size(records) + 16, do: truncate(path, valid)
          terms

        {:ok, _other} ->
          aside = aside_path(path)

          Logger.error(
            "#{path} was written with another key or is damaged; " <>
              "moved to #{aside}, starting empty. Start again with the right key and move it back to keep its contents."
          )

          File.rename!(path, aside)
          []

        {:error, :enoent} ->
          []
      end

    unless File.exists?(path), do: File.write!(path, [magic, key_id])
    {open_fd(path, key, key_id, magic, opts), terms}
  end

  # Never over an earlier one: a second wrong-key start must not destroy
  # what the first moved aside.
  defp aside_path(path) do
    stamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond) |> Integer.to_string()
    aside = "#{path}.unreadable-#{stamp}"
    if File.exists?(aside), do: aside_path(path), else: aside
  end

  @spec append(t(), term()) :: :ok
  def append(%{fd: fd} = file, term) do
    :ok = :file.write(fd, record(file, term))
    if file.sync, do: :ok = :file.datasync(fd)
    :ok
  end

  @doc "Replaces the file's contents with `terms`, through a temporary file."
  @spec rewrite(t(), [term()]) :: t()
  def rewrite(%{fd: fd, path: path, key: key, key_id: key_id, magic: magic} = file, terms) do
    :file.close(fd)
    tmp = path <> ".tmp"
    File.write!(tmp, [magic, key_id | Enum.map(terms, &record(file, &1))])
    File.rename!(tmp, path)
    open_fd(path, key, key_id, magic, sync: file.sync)
  end

  @spec close(t()) :: :ok
  def close(%{fd: fd}), do: :file.close(fd)

  defp open_fd(path, key, key_id, magic, opts) do
    sync = Keyword.get(opts, :sync, false)
    buffering = if sync, do: [], else: [{:delayed_write, 64 * 1024, 1_000}]
    {:ok, fd} = :file.open(String.to_charlist(path), [:append, :raw, :binary | buffering])
    %{fd: fd, path: path, key: key, key_id: key_id, magic: magic, sync: sync}
  end

  defp record(%{key: key, key_id: key_id}, term) do
    payload = seal(term, key, key_id)
    [<<byte_size(payload)::32>>, payload]
  end

  @doc false
  # One record, encrypted: `iv <> tag <> ciphertext`, with the key id as
  # associated data. `Theseus.Records` keeps the same in Postgres.
  @spec seal(term(), binary(), binary()) :: binary()
  def seal(term, key, key_id) do
    iv = :crypto.strong_rand_bytes(12)
    plain = :erlang.term_to_binary(term, [:compressed])
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plain, key_id, true)
    iv <> tag <> cipher
  end

  @doc false
  @spec unseal(binary(), binary(), binary()) :: {:ok, term()} | :error
  def unseal(<<iv::binary-12, tag::binary-16, cipher::binary>>, key, key_id) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, key_id, tag, false) do
      plain when is_binary(plain) -> {:ok, :erlang.binary_to_term(plain)}
      :error -> :error
    end
  end

  def unseal(_data, _key, _key_id), do: :error

  @doc false
  @spec key_id(binary()) :: binary()
  def key_id(key), do: binary_part(:crypto.hash(:sha256, key), 0, 8)

  # Returns the terms and the byte offset where valid records end.
  defp scan(<<size::32, payload::binary-size(size), rest::binary>>, key, key_id, acc, offset)
       when size > 28 do
    <<iv::binary-12, tag::binary-16, cipher::binary>> = payload

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, key_id, tag, false) do
      plain when is_binary(plain) ->
        scan(rest, key, key_id, [:erlang.binary_to_term(plain) | acc], offset + 4 + size)

      :error ->
        {Enum.reverse(acc), offset}
    end
  end

  defp scan(_rest, _key, _key_id, acc, offset), do: {Enum.reverse(acc), offset}

  defp truncate(path, size) do
    Logger.warning("#{path}: dropping damaged records after byte #{size}")
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])
    {:ok, _} = :file.position(fd, size)
    :ok = :file.truncate(fd)
    :file.close(fd)
  end
end
