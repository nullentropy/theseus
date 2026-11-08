defmodule Theseus.Changes do
  @moduledoc """
  The life of a change: proposed, validated, shadowed on live calls, gated,
  then held for a person, promoted or rejected. Every step is a ledger
  event; this process keeps an ETS view of them, rebuilt from the ledger at
  boot.

  A change whose shadow run is going is `:shadowing`. The gate decides when
  the shadow result arrives (`shadowed/2`). A person can reject a shadowing
  change but not approve it: validation has not finished.

  Agents call `check/1` and `propose/1`, or `check_group/1` and
  `propose_group/1` for changes to several units made together. Only people
  call `approve/2` and `reject/3` (review page or iex).

  A group's changes are validated in one candidate world (see
  `Theseus.Validator`), so each sees the others' new versions. They share
  one fate: if one is rejected, the rest are rejected; approving one
  approves all, once all are held; they are loaded together, and if one
  fails to load, the ones already loaded are rolled back.
  """

  use GenServer

  alias Theseus.{Branches, Change, Event, Gate, Ledger, Loader, Report, Shadow, Unit}
  alias Theseus.{Validator, Version}

  @table :theseus_changes
  @unit_name ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @typedoc """
  A proposal. `unit` is a module name. `unit_source` and `spec_source` are
  complete modules; at least one is required, and both when creating a unit.
  `branch` is the branch to change (default: the live branch). `merge_from`
  marks the change as reconciling a merge conflict with that branch: the
  change then counts as having that branch's versions of the unit.
  """
  @type proposal :: %{
          required(:unit) => String.t() | module(),
          required(:intent) => String.t(),
          optional(:unit_source) => String.t() | nil,
          optional(:spec_source) => String.t() | nil,
          optional(:rationale) => String.t(),
          optional(:behaviour_change) => boolean(),
          optional(:proposer) => %{kind: atom(), client: String.t() | nil},
          optional(:trigger) => %{kind: atom(), payload: term(), untrusted: boolean()},
          optional(:branch) => String.t(),
          optional(:merge_from) => String.t()
        }

  @doc "Validates a proposal without recording anything."
  @spec check(proposal()) :: {:ok, Change.t(), Report.t()} | {:error, term()}
  def check(proposal) do
    with {:ok, change} <- build(proposal) do
      {:ok, change, Validator.run(change)}
    end
  end

  @doc """
  Validates a proposal, records it, and applies the gate's decision. Only
  in-process callers pass `:trigger`; MCP proposals are always `:human`.
  """
  @spec propose(proposal()) :: {:ok, Change.t(), Report.t()} | {:error, term()}
  def propose(proposal) do
    with {:ok, change} <- build(proposal) do
      {report, shadow} = Validator.validate(change, shadow: true)
      GenServer.call(__MODULE__, {:record, change, report, shadow}, 60_000)
    end
  end

  @typedoc """
  Changes to several units made together: `units` lists `%{unit,
  unit_source, spec_source}` (each as in `t:proposal/0`), and the other
  fields are shared by all of them.
  """
  @type group_proposal :: %{
          required(:units) => [map()],
          required(:intent) => String.t(),
          optional(:rationale) => String.t(),
          optional(:behaviour_change) => boolean(),
          optional(:proposer) => %{kind: atom(), client: String.t() | nil},
          optional(:branch) => String.t()
        }

  @max_group 12

  @doc "Validates a group of changes without recording anything."
  @spec check_group(group_proposal()) :: {:ok, [{Change.t(), Report.t()}]} | {:error, term()}
  def check_group(proposal) do
    with {:ok, changes} <- build_group(proposal) do
      {:ok, for(c <- changes, do: {c, Validator.run(c, group: changes)})}
    end
  end

  @doc "Validates a group of changes, records them, and applies the gate's decisions."
  @spec propose_group(group_proposal()) :: {:ok, [{Change.t(), Report.t()}]} | {:error, term()}
  def propose_group(proposal) do
    with {:ok, changes} <- build_group(proposal) do
      validated =
        for c <- changes do
          {report, shadow} = Validator.validate(c, shadow: true, group: changes)
          {c, report, shadow}
        end

      GenServer.call(__MODULE__, {:record_group, validated}, 120_000)
    end
  end

  @doc "The changes of a group, in the order they were proposed."
  @spec group(String.t()) :: [{Change.t(), Report.t() | nil}]
  def group(id) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, c, _r} -> c.group == id end)
    |> Enum.map(fn {_id, c, r} -> {c, r} end)
    |> Enum.sort_by(fn {c, _} -> c.at end, DateTime)
  end

  @doc "Promotes a held change. A person's action."
  @spec approve(String.t(), keyword()) :: {:ok, Change.t()} | {:error, term()}
  def approve(id, opts \\ []), do: GenServer.call(__MODULE__, {:approve, id, opts}, 120_000)

  @doc "Rejects a held change. A person's action."
  @spec reject(String.t(), String.t(), keyword()) :: {:ok, Change.t()} | {:error, term()}
  def reject(id, reason, opts \\ []), do: GenServer.call(__MODULE__, {:reject, id, reason, opts})

  @doc """
  Undoes an approved group: every unit and spec it changed goes back to the
  version it had before, a unit it created is removed, and a unit it
  removed comes back. Refused, with nothing done, while any of them has
  changed since. Records `{:group_undone, group, reason}`. Options:
  `:actor` (default `:human`), `:reason`.
  """
  @spec undo_group(String.t(), keyword()) :: :ok | {:error, String.t()}
  def undo_group(group, opts \\ []),
    do: GenServer.call(__MODULE__, {:undo_group, group, opts}, 120_000)

  @doc "Whether a group has been undone."
  @spec undone?(String.t()) :: boolean()
  def undone?(group) do
    Ledger.memo({:group_undone, group}, fn ->
      Enum.any?(Ledger.events(), &match?(%Event{body: {:group_undone, ^group, _}}, &1))
    end)
  end

  @doc false
  # The shadow run's result, from `Theseus.Shadow`.
  def shadowed(id, stage), do: GenServer.cast(__MODULE__, {:shadowed, id, stage})

  @spec get(String.t()) :: {:ok, Change.t(), Report.t() | nil} | :error
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, change, report}] -> {:ok, change, report}
      [] -> :error
    end
  end

  @doc "Changes, newest first. Options: `:status`, `:unit`, `:branch`, `:limit`."
  @spec list(keyword()) :: [{Change.t(), Report.t() | nil}]
  def list(opts \\ []) do
    # Ids and times first, filtered in the table, so a short list copies only
    # the changes it returns, not every change with its code and evidence.
    guards =
      for key <- [:status, :unit, :branch],
          opts[key] != nil,
          do: {:==, {:map_get, key, :"$2"}, opts[key]}

    ids =
      @table
      |> :ets.select([{{:"$1", :"$2", :_}, guards, [{{:"$1", {:map_get, :at, :"$2"}}}]}])
      |> Enum.sort_by(fn {_id, at} -> at end, {:desc, DateTime})

    ids =
      case Keyword.get(opts, :limit, 100) do
        :all -> ids
        n -> Enum.take(ids, n)
      end

    for {id, _at} <- ids,
        [{^id, change, report}] <- [:ets.lookup(@table, id)],
        do: {change, report}
  end

  ## Building

  defp build(%{remove: true} = proposal) do
    with {:ok, unit} <- unit_name(proposal[:unit]),
         {:ok, branch} <- branch(proposal[:branch]),
         {:ok, intent} <- required_text(proposal, :intent),
         {:ok, removes} <- removal(unit, proposal, branch) do
      {:ok,
       %Change{
         id: Change.new_id(),
         trigger: %{kind: :human, payload: nil, untrusted: false},
         proposer: proposal[:proposer] || %{kind: :iex, client: nil},
         intent: intent,
         unit: unit,
         candidates: [],
         removes: removes,
         behaviour_change: true,
         branch: branch,
         rationale: proposal[:rationale] || "",
         status: :proposed,
         at: DateTime.utc_now()
       }}
    end
  end

  defp build(proposal) do
    with {:ok, unit} <- unit_name(proposal[:unit]),
         {:ok, branch} <- branch(proposal[:branch]),
         {:ok, intent} <- required_text(proposal, :intent),
         {:ok, candidates} <- candidates(unit, proposal, branch),
         {:ok, trigger} <- trigger(proposal, unit, branch) do
      {:ok,
       %Change{
         id: Change.new_id(),
         trigger: trigger,
         proposer: proposal[:proposer] || %{kind: :iex, client: nil},
         intent: intent,
         unit: unit,
         candidates: candidates,
         # Crash fixes keep behaviour by default; requests from people change it.
         behaviour_change: Map.get(proposal, :behaviour_change, trigger.kind != :crash),
         branch: branch,
         rationale: proposal[:rationale] || "",
         status: :proposed,
         at: DateTime.utc_now()
       }}
    end
  end

  defp build_group(%{units: units} = proposal) when is_list(units) and units != [] do
    common = Map.drop(proposal, [:units, :unit, :unit_source, :spec_source, :merge_from])
    group = Change.new_group_id()

    built =
      Enum.reduce_while(units, {:ok, []}, fn entry, {:ok, acc} ->
        # In-process callers (merges) may give each unit its own trigger.
        entry = Map.take(entry, [:unit, :unit_source, :spec_source, :trigger, :remove])

        case build(Map.merge(common, entry)) do
          {:ok, change} -> {:cont, {:ok, [%{change | group: group} | acc]}}
          {:error, reason} -> {:halt, {:error, "#{entry[:unit]}: #{reason}"}}
        end
      end)

    with {:ok, changes} <- built do
      changes = Enum.reverse(changes)
      names = Enum.map(changes, & &1.unit)

      cond do
        length(changes) > @max_group ->
          {:error, "a group changes at most #{@max_group} units"}

        length(Enum.uniq(names)) < length(names) ->
          {:error, "each unit can appear once in a group"}

        true ->
          {:ok, changes}
      end
    end
  end

  defp build_group(_proposal), do: {:error, "units must list at least one unit"}

  # What a removal takes away: the unit's current version and its spec's.
  defp removal(unit, proposal, branch) do
    current = Ledger.current(unit, branch)

    cond do
      proposal[:unit_source] not in [nil, ""] or proposal[:spec_source] not in [nil, ""] ->
        {:error, "a change that removes #{inspect(unit)} sends no source"}

      branch != Branches.live() ->
        {:error, "units are removed on the live branch only"}

      current == nil ->
        {:error, "there is no unit #{inspect(unit)} on #{branch}"}

      match?({:ok, %Version{ast: ast}} when ast != nil, Ledger.version(unit, current)) and
          Theseus.Schema.schema_unit?(elem(Ledger.version(unit, current), 1).ast) ->
        {:error, "a schema unit cannot be removed: the tables it declares stay"}

      true ->
        {:ok, %{unit: current, spec: Ledger.current(Unit.spec_module(unit), branch)}}
    end
  end

  defp branch(nil), do: {:ok, Branches.live()}

  defp branch(name) do
    cond do
      not Branches.exists?(name) -> {:error, "no branch named #{name}"}
      Branches.closed?(name) -> {:error, "branch #{name} is closed; reopen it first"}
      true -> {:ok, name}
    end
  end

  defp trigger(%{merge_from: from}, unit, branch) when is_binary(from) do
    cond do
      not Branches.exists?(from) ->
        {:error, "no branch named #{from}"}

      from == branch ->
        {:error, "merge_from must be another branch"}

      true ->
        sources =
          for module <- [unit, Unit.spec_module(unit)],
              hash = Branches.current(from, module),
              hash != nil,
              into: %{},
              do: {module, hash}

        {:ok,
         %{
           kind: :merge,
           payload: %{from: from, into: branch, merge: nil, sources: sources},
           untrusted: false
         }}
    end
  end

  defp trigger(proposal, _unit, _branch),
    do: {:ok, proposal[:trigger] || %{kind: :human, payload: nil, untrusted: false}}

  defp unit_name(unit) when is_atom(unit) and unit != nil, do: unit_name(inspect(unit))

  defp unit_name(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      byte_size(name) > 120 or not Regex.match?(@unit_name, name) ->
        {:error, "unit must be a module name like Sample.Pricing"}

      name == "Theseus" or String.starts_with?(name, "Theseus.") ->
        {:error, "Theseus modules can never be changed"}

      true ->
        unit = Module.concat([name])

        if Unit.spec_name?(unit),
          do: {:error, "name the unit, not its spec; send the spec as spec_source"},
          else: {:ok, unit}
    end
  end

  defp unit_name(_), do: {:error, "unit is required"}

  defp required_text(proposal, key) do
    case proposal[key] do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp candidates(unit, proposal, branch) do
    spec_module = Unit.spec_module(unit)
    registered? = Ledger.current(unit, branch) != nil

    with {:ok, unit_version} <- candidate(unit, proposal[:unit_source], branch),
         {:ok, spec_version} <- candidate(spec_module, proposal[:spec_source], branch) do
      sent = Enum.reject([unit_version, spec_version], &is_nil/1)
      # A source identical to the current version is dropped, so an agent
      # can send a whole unit and spec when only one of them changed.
      candidates = Enum.reject(sent, &(&1 == :unchanged))

      cond do
        sent == [] ->
          {:error, "send unit_source, spec_source, or both"}

        candidates == [] ->
          {:error, "#{inspect(unit)}: no change from the current version"}

        not registered? and (unit_version == nil or spec_version == nil) ->
          {:error,
           "#{inspect(unit)} does not exist on #{branch} yet; creating it needs both unit_source and spec_source"}

        true ->
          {:ok, candidates}
      end
    end
  end

  defp candidate(_module, nil, _branch), do: {:ok, nil}
  defp candidate(_module, "", _branch), do: {:ok, nil}

  defp candidate(module, source, branch) when is_binary(source) do
    base = Ledger.current(module, branch)

    case Version.build(module, source, base) do
      {:ok, %Version{hash: ^base}} ->
        {:ok, :unchanged}

      {:ok, version} ->
        {:ok, version}

      {:error, reason} ->
        {:error, "#{inspect(module)}: #{describe_build_error(reason)}"}
    end
  end

  defp describe_build_error({:wrong_module, other}), do: "the source defines #{inspect(other)}"

  defp describe_build_error(:not_a_single_defmodule),
    do: "the source must be exactly one defmodule"

  defp describe_build_error({:parse, meta, message, token}),
    do: "parse error on line #{meta[:line]}: #{inspect(message)} #{inspect(token)}"

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    Enum.each(Ledger.events(), &replay/1)

    # A shadow run lives only in memory. One that is not running any more
    # was cut short by a restart; record that and let the gate decide.
    for {change, report} <- list(status: :shadowing, limit: :all),
        not Shadow.running?(change.id) do
      stage = %{
        name: :shadow,
        result: :skip,
        detail: %{reason: "the app restarted before the shadow run finished"},
        ms: 0
      }

      finish_shadow(change, report, stage)
    end

    {:ok, nil}
  end

  @impl true
  def handle_call({:record, change, report, shadow}, _from, state) do
    {change, report} = record_one(change, report, shadow)
    {:reply, {:ok, change, report}, state}
  end

  def handle_call({:record_group, validated}, _from, state) do
    recorded = for {c, r, shadow} <- validated, do: record_one(c, r, shadow)

    recorded =
      case Enum.find(recorded, fn {c, _} -> c.status == :rejected end) do
        nil ->
          recorded

        {failed, _} ->
          reject_rest_of_group(failed)
          for {c, r} <- recorded, do: {elem(get(c.id), 1), r}
      end

    {:reply, {:ok, recorded}, state}
  end

  def handle_call({:approve, id, opts}, _from, state) do
    actor = Keyword.get(opts, :actor, :human)

    reply =
      Theseus.Team.deciding(opts[:by], fn ->
        with {:ok, change, _} <- get(id),
             reason when is_binary(reason) <- opts[:override] do
          # An admin approving over a rule, with the reason (Theseus.Approvals).
          {:ok, _} =
            Ledger.append({:approval_override, change.group || change.id, reason},
              actor: actor,
              unit: change.unit,
              branch: change.branch
            )
        end

        approve_now(id, actor)
      end)

    {:reply, reply, state}
  end

  def handle_call({:reject, id, reason, opts}, from, state) do
    Theseus.Team.deciding(opts[:by], fn -> do_reject(id, reason, opts, from, state) end)
  end

  def handle_call({:undo_group, group, opts}, from, state) do
    Theseus.Team.deciding(opts[:by], fn -> do_undo_group(group, opts, from, state) end)
  end

  defp approve_now(id, actor) do
    case get(id) do
      {:ok, %Change{status: :held, group: group}, _report} when group != nil ->
        with {:ok, _} <- approve_group(group, actor), do: {:ok, elem(get(id), 1)}

      other ->
        approve_one(other, actor)
    end
  end

  defp do_undo_group(group, opts, _from, state) do
    members = for {c, _} <- group(group), do: c
    actor = Keyword.get(opts, :actor, :human)
    reason = "undo of #{group}" <> if(opts[:reason], do: ": #{opts[:reason]}", else: "")

    reply =
      cond do
        members == [] ->
          {:error, "there is no group #{group}"}

        Enum.any?(members, &(&1.status != :promoted)) ->
          {:error, "only a group whose changes were all approved can be undone"}

        undone?(group) ->
          {:error, "this group was already undone"}

        (moved = Enum.flat_map(members, &moved_since/1)) != [] ->
          {:error,
           "changed since this group: #{Enum.join(moved, ", ")}; undo those changes first"}

        (gone = dropped_data(members)) != [] ->
          {:error, Enum.join(gone, "; ")}

        true ->
          # The reverse of the order the group loaded in.
          for c <- members |> Enum.sort_by(&load_order/1) |> Enum.reverse() do
            undo_one(c, actor, reason)
          end

          {:ok, _} =
            Ledger.append({:group_undone, group, reason},
              actor: actor,
              unit: hd(members).unit,
              branch: hd(members).branch
            )

          :ok
      end

    {:reply, reply, state}
  end

  defp do_reject(id, reason, opts, _from, state) do
    reply =
      case get(id) do
        {:ok, %Change{status: status, group: group} = change, _}
        when group != nil and status in [:held, :shadowing] ->
          actor = Keyword.get(opts, :actor, :human)

          for {c, _} <- group(group),
              c.status in [:held, :shadowing],
              do: reject_one(c.id, reason, actor)

          {:ok, elem(get(change.id), 1)}

        {:ok, %Change{status: status}, _report} when status in [:held, :shadowing] ->
          reject_one(id, reason, Keyword.get(opts, :actor, :human))

        {:ok, change, _} ->
          {:error, {:not_held, change.status}}

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  defp record_one(change, report, shadow) do
    {:ok, _} =
      Ledger.append({:change_proposed, strip(change)},
        by: change.proposer[:person],
        actor: proposer_actor(change.proposer),
        unit: change.unit,
        branch: change.branch
      )

    {:ok, _} =
      Ledger.append({:validated, change.id, report},
        actor: :system,
        unit: change.unit,
        branch: change.branch
      )

    {change, report} =
      case Report.stage(report, :shadow) do
        %{result: :running, detail: limits} when shadow != nil ->
          case Shadow.start(change, limits, shadow) do
            :ok ->
              {%{change | status: :shadowing}, report}

            {:error, reason} ->
              stage = %{name: :shadow, result: :fail, detail: %{error: reason}, ms: 0}

              {:ok, _} =
                Ledger.append({:shadowed, change.id, stage},
                  actor: :system,
                  unit: change.unit,
                  branch: change.branch
                )

              report = Report.put_stage(report, stage)
              {decide(change, report), report}
          end

        _ ->
          {decide(change, report), report}
      end

    :ets.insert(@table, {change.id, change, report})
    notify(change)
    maybe_check_rules(change, report)
    {change, report}
  end

  # The model reads new and changed rules (Theseus.RuleCheck) in the
  # background; the stage joins the report when it is done.
  defp maybe_check_rules(change, report) do
    if Theseus.RuleCheck.wanted?(change, report) do
      Task.Supervisor.start_child(Theseus.TaskSupervisor, fn ->
        stage = Theseus.RuleCheck.run(change, report)
        GenServer.cast(__MODULE__, {:rules_checked, change.id, stage})
      end)
    end

    :ok
  end

  defp approve_one({:ok, %Change{status: :held, id: id} = change, report}, actor) do
    {:ok, _} =
      Ledger.append({:gate_decision, id, :promote, :human},
        actor: actor,
        unit: change.unit,
        branch: change.branch
      )

    case promote(change, actor) do
      :ok ->
        change = %{change | status: :promoted}
        :ets.insert(@table, {id, change, report})
        notify(change)
        {:ok, change}

      {:error, reason} ->
        mark_rejected(change, report, reason, :system)
        {:error, reason}
    end
  end

  defp approve_one({:ok, change, _}, _actor), do: {:error, {:not_held, change.status}}
  defp approve_one(:error, _actor), do: {:error, :not_found}

  # Every change of the group must be held. They are loaded in an order
  # where each unit's callees come first: new units, then pure, server and
  # endpoint units. If one fails, the ones already loaded are rolled back
  # and the whole group is rejected.
  defp approve_group(group, actor) do
    members = group(group)
    waiting = for {c, _} <- members, c.status != :held, do: {c.id, c.status}

    if waiting != [] do
      {:error, {:group_not_ready, waiting}}
    else
      ordered = Enum.sort_by(members, fn {c, _} -> load_order(c) end)

      result =
        Enum.reduce_while(ordered, {:ok, []}, fn {change, report}, {:ok, done} ->
          {:ok, _} =
            Ledger.append({:gate_decision, change.id, :promote, :human},
              actor: actor,
              unit: change.unit,
              branch: change.branch
            )

          case promote(change, actor) do
            :ok -> {:cont, {:ok, [{change, report} | done]}}
            {:error, reason} -> {:halt, {:error, change, reason, done}}
          end
        end)

      case result do
        {:ok, done} ->
          for {c, r} <- done do
            c = %{c | status: :promoted}
            :ets.insert(@table, {c.id, c, r})
            notify(c)
          end

          {:ok, elem(get(hd(members) |> elem(0) |> Map.get(:id)), 1)}

        {:error, failed, reason, done} ->
          why = "#{failed.id} in the same group failed to load"

          for {c, _r} <- done do
            cond do
              Change.removes?(c) ->
                restore_removed(c, why)

              Change.creates?(c) ->
                undo_create(c, why)

              true ->
                for v <- c.candidates do
                  Loader.rollback(v.unit, :previous,
                    actor: :system,
                    reason: why,
                    branch: c.branch
                  )
                end
            end
          end

          for {c, r} <- members do
            why =
              if c.id == failed.id,
                do: reason,
                else: "#{failed.id} in the same group failed to load"

            mark_rejected(c, r, why, :system)
          end

          {:error, reason}
      end
    end
  end

  # A removal comes last, once its callers have changed.
  defp load_order(%Change{removes: removes}) when removes != nil, do: {2, 0}

  defp load_order(%Change{} = change) do
    kind =
      case Change.unit_candidate(change) do
        %Version{unit: u, ast: ast} -> Unit.infer_kind(u, ast)
        nil -> :spec
      end

    {if(Change.creates?(change), do: 0, else: 1),
     Enum.find_index([:spec, :pure, :server, :store, :endpoint], &(&1 == kind)) || 5}
  end

  defp reject_one(id, reason, actor) do
    {:ok, %Change{status: status} = change, report} = get(id)
    if status == :shadowing, do: Shadow.stop(id)

    {:ok, _} =
      Ledger.append({:gate_decision, id, :reject, :human},
        actor: actor,
        unit: change.unit,
        branch: change.branch
      )

    {:ok, mark_rejected(change, report, reason, actor)}
  end

  defp mark_rejected(change, report, reason, actor) do
    {:ok, _} =
      Ledger.append({:rejected, change.id, reason},
        actor: actor,
        unit: change.unit,
        branch: change.branch
      )

    change = %{change | status: :rejected}
    :ets.insert(@table, {change.id, change, report})
    notify(change)
    change
  end

  # When one change of a group is rejected, the others that are still
  # waiting go with it.
  defp reject_rest_of_group(%Change{group: nil}), do: :ok

  defp reject_rest_of_group(%Change{group: group, id: id, unit: unit}) do
    for {c, r} <- group(group), c.id != id, c.status in [:held, :shadowing, :proposed] do
      if c.status == :shadowing, do: Shadow.stop(c.id)
      mark_rejected(c, r, "#{id} (#{inspect(unit)}) in the same group was rejected", :gate)
    end

    :ok
  end

  @impl true
  def handle_cast({:rules_checked, id, stage}, state) do
    case get(id) do
      {:ok, change, report} ->
        {:ok, _} =
          Ledger.append({:rules_checked, id, stage},
            actor: :system,
            unit: change.unit,
            branch: change.branch
          )

        :ets.insert(@table, {id, change, Report.put_stage(report, stage)})

      :error ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:shadowed, id, stage}, state) do
    case get(id) do
      {:ok, %Change{status: :shadowing} = change, report} -> finish_shadow(change, report, stage)
      _ -> :ok
    end

    {:noreply, state}
  end

  defp finish_shadow(change, report, stage) do
    {:ok, _} =
      Ledger.append({:shadowed, change.id, stage},
        actor: :system,
        unit: change.unit,
        branch: change.branch
      )

    report = Report.put_stage(report, stage)
    change = decide(change, report)
    :ets.insert(@table, {change.id, change, report})
    notify(change)
    if change.status == :rejected, do: reject_rest_of_group(change)
  end

  # Crash repair follows what happens to its changes; consolidation counts
  # promotions.
  defp notify(%Change{} = change) do
    if change.status == :promoted, do: Theseus.Consolidate.promoted(change)
    if change.status == :promoted, do: Theseus.Combine.promoted(change)
    Theseus.Notices.changed(change)

    if change.trigger.kind == :crash and change.status in [:held, :promoted, :rejected],
      do: Theseus.Trigger.decided(change)

    :ok
  end

  # Asks the gate and acts on its decision. Returns the updated change.
  # Groups are only ever promoted together, by a person.
  defp decide(change, report) do
    decision =
      case Gate.decide(change, report) do
        :reject -> :reject
        _hold_or_promote when change.group != nil -> {:hold, :group}
        decision -> decision
      end

    {:ok, _} =
      Ledger.append({:gate_decision, change.id, decision, :auto},
        actor: :gate,
        unit: change.unit,
        branch: change.branch
      )

    case decision do
      {:hold, _} ->
        %{change | status: :held}

      :reject ->
        reason = "failed at #{Report.failure(report).name}"

        {:ok, _} =
          Ledger.append({:rejected, change.id, reason},
            actor: :gate,
            unit: change.unit,
            branch: change.branch
          )

        %{change | status: :rejected}

      :promote ->
        case promote(change, :gate) do
          :ok -> %{change | status: :promoted}
          {:error, _} -> %{change | status: :rejected}
        end
    end
  end

  # Specs go first when creating, so the unit never exists without its spec.
  # When updating, the unit goes first; if its spec then fails to load, the
  # unit is rolled back.
  defp promote(%Change{removes: removes} = change, actor) when removes != nil do
    reason = "removed by #{change.id}"
    spec = Unit.spec_module(change.unit)

    cond do
      Ledger.current(change.unit, change.branch) != removes.unit or
          Ledger.current(spec, change.branch) != removes.spec ->
        {:error, :stale}

      true ->
        if removes.spec,
          do:
            :ok =
              Loader.unregister(spec,
                actor: actor,
                reason: reason,
                branch: change.branch,
                by: Theseus.Team.by()
              )

        Loader.unregister(change.unit,
          actor: actor,
          reason: reason,
          branch: change.branch,
          by: Theseus.Team.by()
        )
    end
  end

  defp promote(change, actor) do
    opts = [actor: actor, change_id: change.id, branch: change.branch, by: Theseus.Team.by()]
    unit_version = Change.unit_candidate(change)
    spec_version = Change.spec_candidate(change)

    if Change.creates?(change) do
      kind = Unit.infer_kind(unit_version.unit, unit_version.ast)

      with {:ok, _} <- Loader.register(spec_version, opts),
           {:ok, _} <-
             Loader.register(unit_version, [kind: kind] ++ opts)
             |> unregister_on_error(spec_version.unit, change) do
        :ok
      end
    else
      with {:ok, promoted_unit} <- maybe(unit_version, &Loader.promote(&1, opts)),
           {:ok, _} <-
             maybe(spec_version, &Loader.promote(&1, opts))
             |> undo_on_error(promoted_unit, change) do
        :ok
      end
    end
  end

  defp maybe(nil, _fun), do: {:ok, nil}
  defp maybe(version, fun), do: fun.(version)

  defp undo_on_error({:error, _} = error, %Version{unit: unit}, change) do
    Loader.rollback(unit, :previous,
      actor: :system,
      reason: "spec of #{change.id} failed to load",
      branch: change.branch
    )

    error
  end

  defp undo_on_error(result, _promoted, _change), do: result

  defp unregister_on_error({:error, _} = error, spec, change) do
    Loader.unregister(spec,
      actor: :system,
      reason: "unit of #{change.id} failed to load",
      branch: change.branch
    )

    error
  end

  defp unregister_on_error(result, _spec, _change), do: result

  # What changed on a group's units since it was approved, as names.
  defp moved_since(%Change{removes: removes} = c) when removes != nil do
    if Ledger.current(c.unit, c.branch) == nil, do: [], else: [inspect(c.unit)]
  end

  defp moved_since(%Change{candidates: candidates, branch: branch}) do
    for v <- candidates, Ledger.current(v.unit, branch) != v.hash, do: inspect(v.unit)
  end

  # Versions an undo would go back to that mention data a schema change
  # has dropped since (Theseus.Store.Migrate).
  defp dropped_data(members) do
    for c <- members,
        c.removes == nil,
        v <- c.candidates,
        v.parent != nil,
        why = Theseus.Store.Migrate.rollback_refusal(v.unit, v.parent, c.branch),
        why != nil,
        do: why
  end

  defp undo_one(%Change{removes: removes} = c, _actor, reason) when removes != nil,
    do: restore_removed(c, reason)

  defp undo_one(%Change{} = c, actor, reason) do
    if Change.creates?(c) do
      undo_create(c, reason)
    else
      for v <- Enum.sort_by(c.candidates, &(not Unit.spec_name?(&1.unit))) do
        opts = [actor: actor, reason: reason, branch: c.branch, by: Theseus.Team.by()]

        # A spec the change added to an existing unit goes; anything else
        # goes back to the version before.
        if v.parent == nil,
          do: :ok = Loader.unregister(v.unit, opts),
          else: {:ok, _} = Loader.rollback(v.unit, v.parent, opts)
      end
    end
  end

  @doc false
  # Brings back a removed unit and its spec, at the versions it removed.
  def restore_removed(%Change{removes: removes, unit: unit, branch: branch}, reason) do
    with {:ok, version} <- Ledger.version(unit, removes.unit) do
      kind = Unit.infer_kind(unit, version.ast)
      opts = [actor: :system, reason: reason, branch: branch]

      if removes.spec do
        {:ok, spec} = Ledger.version(Unit.spec_module(unit), removes.spec)
        {:ok, _} = Loader.register(spec, opts)
      end

      Loader.register(version, [kind: kind] ++ opts)
    end
  end

  # A created unit and its spec, removed again: the unit first, so it never
  # exists without its spec.
  defp undo_create(change, reason) do
    for v <- Enum.sort_by(change.candidates, &Unit.spec_name?(&1.unit)) do
      Loader.unregister(v.unit, actor: :system, reason: reason, branch: change.branch)
    end
  end

  defp proposer_actor(%{kind: :mcp}), do: :agent
  defp proposer_actor(%{kind: :in_process}), do: :system
  defp proposer_actor(%{kind: kind}) when kind in [:iex, :review], do: :human
  defp proposer_actor(_proposer), do: :agent

  defp strip(%Change{candidates: candidates} = change),
    do: %{change | candidates: Enum.map(candidates, &%{&1 | beam: nil})}

  # Changes recorded before branches existed have no branch field.
  defp replay(%Event{body: {:change_proposed, %Change{} = change}}) do
    change = struct(Change, Map.from_struct(change))
    :ets.insert(@table, {change.id, %{change | status: :proposed}, nil})
  end

  defp replay(%Event{body: {:validated, id, report}}) do
    status = if Report.running?(report), do: :shadowing, else: :proposed
    update(id, fn {c, _} -> {%{c | status: status}, report} end)
  end

  defp replay(%Event{body: {:rules_checked, id, stage}}),
    do: update(id, fn {c, r} -> {c, Report.put_stage(r, stage)} end)

  defp replay(%Event{body: {:shadowed, id, stage}}),
    do: update(id, fn {c, r} -> {%{c | status: :proposed}, Report.put_stage(r, stage)} end)

  defp replay(%Event{body: {:gate_decision, id, {:hold, _}, _}}),
    do: update(id, fn {c, r} -> {%{c | status: :held}, r} end)

  # A failed promotion is followed by a `:rejected` event, which wins.
  defp replay(%Event{body: {:gate_decision, id, :promote, _}}),
    do: update(id, fn {c, r} -> {%{c | status: :promoted}, r} end)

  defp replay(%Event{body: {:rejected, id, _}}),
    do: update(id, fn {c, r} -> {%{c | status: :rejected}, r} end)

  defp replay(%Event{body: {:promoted, _module, _from, _to, id}}) when is_binary(id),
    do: update(id, fn {c, r} -> {%{c | status: :promoted}, r} end)

  defp replay(_event), do: :ok

  defp update(id, fun) do
    case :ets.lookup(@table, id) do
      [{^id, change, report}] ->
        {change, report} = fun.({change, report})
        :ets.insert(@table, {id, change, report})

      [] ->
        :ok
    end
  end
end
