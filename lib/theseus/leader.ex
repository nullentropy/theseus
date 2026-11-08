defmodule Theseus.Leader do
  @moduledoc """
  Which node does the work that must happen once, when more than one node
  runs an app (`docs/multi-node-design.md`).

  With the ledger in Postgres, the node that holds its lock is the leader:
  it writes the ledger, runs the server units, ticks, sends messages and
  requests, repairs crashes and answers the admin port. A node started with
  Erlang distribution (`--name` or `--sname`, and the leader's cookie) that
  does not get the lock is a follower: it serves the app's HTTP port with
  the same units, reads the ledger as the leader writes it, and sends the
  rest to the leader (see `name/1`), its admin port's requests included
  (`Theseus.Admin.Forward`). A follower takes over when the lock
  frees. Config `:ledger_follow` (default true) set to false keeps a second
  node a standby that serves nothing until it holds the lock.

  Every node needs the same session and state keys (`Theseus.Keys`), so a
  person signed in on one node is signed in on all, and a follower that
  takes over can read the leader's records. Each node keeps its own
  recorded calls (`Theseus.TraceFile.path/0`).

  Without a database, or on one node, this node is the leader.
  """

  import Kernel, except: [node: 0]

  @scope __MODULE__
  @group :followers

  @doc "Whether this node does the once-only work."
  @spec leader?() :: boolean()
  def leader?, do: :persistent_term.get({__MODULE__, :role}, :leader) == :leader

  @doc "Whether this node serves requests for a leader on another node."
  @spec follower?() :: boolean()
  def follower?, do: :persistent_term.get({__MODULE__, :role}, :leader) == :follower

  @doc "Whether this node waits for the lock and runs nothing until it holds it."
  @spec standby?() :: boolean()
  def standby?, do: :persistent_term.get({__MODULE__, :role}, :leader) == :standby

  @doc "The leader's node: this one, or the one a follower sends to."
  @spec node() :: node() | nil
  def node,
    do: if(leader?(), do: Kernel.node(), else: :persistent_term.get({__MODULE__, :node}, nil))

  @doc """
  Where to call an engine process that runs on the leader only: its name
  here, or `{name, leader}` on a follower.
  """
  @spec name(atom()) :: atom() | {atom(), node()}
  def name(name) do
    case node() do
      n when n == Kernel.node() or n == nil -> name
      n -> {name, n}
    end
  end

  @doc "Like `Process.whereis/1` for a process on the leader: nil when it cannot be reached."
  @spec whereis(atom()) :: pid() | {atom(), node()} | nil
  def whereis(name) do
    cond do
      leader?() -> Process.whereis(name)
      (n = node()) && n in Node.list() -> {name, n}
      true -> nil
    end
  end

  @doc "Every follower's node, as the leader sees them."
  @spec followers() :: [node()]
  def followers do
    if Process.whereis(@scope),
      do: @scope |> :pg.get_members(@group) |> Enum.map(&Kernel.node/1) |> Enum.uniq(),
      else: []
  end

  @doc false
  # Whether this node may follow another rather than wait for the lock.
  def can_follow?, do: Application.get_env(:theseus, :ledger_follow, true) and Node.alive?()

  @doc false
  # Called by the ledger process as it opens.
  def became(:leader) do
    :persistent_term.put({__MODULE__, :role}, :leader)
    :persistent_term.erase({__MODULE__, :node})
  end

  def became(role) when role in [:follower, :standby],
    do: :persistent_term.put({__MODULE__, :role}, role)

  @doc false
  # A follower's ledger process joins the group, so the leader can find it.
  def join(pid), do: :pg.join(@scope, @group, pid)

  @doc false
  def following(node), do: :persistent_term.put({__MODULE__, :node}, node)

  @doc false
  def child_spec(_opts), do: %{id: @scope, start: {:pg, :start_link, [@scope]}}

  @doc false
  # A child of `Theseus.Supervisor` that runs on the leader only: on a
  # follower its start returns :ignore.
  def only(child) do
    spec = Supervisor.child_spec(child, [])
    %{spec | start: {__MODULE__, :start_only, [spec.start]}}
  end

  @doc false
  def start_only({m, f, a}), do: if(leader?(), do: apply(m, f, a), else: :ignore)
end
