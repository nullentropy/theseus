defmodule Theseus.Keys do
  @moduledoc """
  The engine's secret keys. Each is 32 random bytes, read from an
  environment variable (base64) or from a key file created on first use and
  readable only by its owner. Keys never enter the ledger, traces or
  prompts, and application code cannot read them.

    * trace key: `THESEUS_TRACE_KEY`, or config `:trace_key_path`
      (default `~/.config/theseus/trace.key`). Encrypts the trace file.
    * session key: `THESEUS_SESSION_KEY`, or config `:session_key_path`
      (default `~/.config/theseus/session.key`). Encrypts sign-in cookies.
    * state key: `THESEUS_STATE_KEY`, or config `:state_key_path`
      (default `~/.config/theseus/state.key`). Encrypts the state file.
  """

  require Logger

  @spec trace() :: binary()
  def trace, do: fetch("THESEUS_TRACE_KEY", :trace_key_path, "trace.key")

  @spec session() :: binary()
  def session, do: fetch("THESEUS_SESSION_KEY", :session_key_path, "session.key")

  @spec state() :: binary()
  def state, do: fetch("THESEUS_STATE_KEY", :state_key_path, "state.key")

  defp fetch(env, config_key, file) do
    case System.get_env(env) do
      nil ->
        key_file(
          Application.get_env(:theseus, config_key) ||
            Path.join([System.user_home!(), ".config", "theseus", file])
        )

      encoded ->
        decode!(encoded, env)
    end
  end

  defp key_file(path) do
    case File.read(path) do
      {:ok, encoded} ->
        decode!(encoded, path)

      {:error, :enoent} ->
        key = :crypto.strong_rand_bytes(32)
        dir = Path.dirname(path)
        File.mkdir_p!(dir)
        File.chmod!(dir, 0o700)
        File.touch!(path)
        File.chmod!(path, 0o600)
        File.write!(path, Base.encode64(key))
        Logger.info("created the key file #{path}")
        key
    end
  end

  defp decode!(encoded, source) do
    encoded = String.trim(encoded)

    case Base.decode64(encoded, padding: false) do
      {:ok, <<_::binary-32>> = key} ->
        key

      _ ->
        case Base.url_decode64(encoded, padding: false) do
          {:ok, <<_::binary-32>> = key} -> key
          _ -> raise "#{source} must hold a base64-encoded 32-byte key"
        end
    end
  end
end
