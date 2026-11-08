defmodule Theseus.Loader do
  @moduledoc """
  Compiles versions and swaps them into the live module slot. All loads go
  through this process, one at a time.

  Changes to a branch that is not live are compiled and recorded in the
  ledger, never loaded. `switch/2` loads another branch's versions into the
  live slots.

  Server units keep their running processes across a load: each process is
  suspended, its state is migrated with the unit's `code_change/3`, and it
  is resumed. Upgrading calls the new version's `code_change(old_hash,
  state, nil)` after loading it. Rolling back calls the current version's
  `code_change({:down, target_hash}, state, nil)` before loading the older
  version, as OTP does. If a migration fails, the old code and state stay.

  Compilation writes a `.beam` without loading it, so nothing reaches a live
  slot until `load_version/2` puts it there. The compiled source is the
  version's source with `@vsn "<hash>"` appended to the module body, so a
  loaded module reports which version it is, and every earlier line number
  matches `Version.source`. Source only touches disk as a temporary file
  during compilation.
  """

  use GenServer
  require Logger

  alias Theseus.{Branches, Ledger, Registry, Unit, Version}

  @call_timeout 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new unit or spec module at `version` and loads it.

  Options: `:kind` (default `:pure`, or `:spec` for spec modules), `:actor`
  (default `:system`), `:change_id`.
  """
  @spec register(Version.t(), keyword()) :: {:ok, Version.t()} | {:error, term()}
  def register(%Version{} = version, opts \\ []) do
    write({:register, version, opts})
  end

  @doc """
  Promotes `version` of an already registered module. Its parent must be the
  module's current version. Options: `:actor` (default `:human`), `:change_id`.
  """
  @spec promote(Version.t(), keyword()) :: {:ok, Version.t()} | {:error, term()}
  def promote(%Version{} = version, opts \\ []) do
    write({:promote, version, opts})
  end

  @doc """
  Loads an earlier version from its stored beam. No compiler, no LLM.

  `to` is `:previous` (the current version's parent) or a hash or hash prefix.
  """
  @spec rollback(module(), :previous | String.t(), keyword()) ::
          {:ok, Version.t()} | {:error, term()}
  def rollback(module, to \\ :previous, opts \\ []) do
    write({:rollback, module, to, opts})
  end

  @doc """
  Removes a registered unit or spec from a branch: records
  `{:unit_unregistered, module, reason}` and, on the live branch, stops its
  server, unloads it and drops it from the registry. Used to undo a create
  whose change did not complete. Options: `:actor` (default `:system`),
  `:branch`, `:reason`.
  """
  @spec unregister(module(), keyword()) :: :ok | {:error, term()}
  def unregister(module, opts \\ []),
    do: write({:unregister, module, opts})

  @doc """
  Makes `branch` the live branch: loads every unit and spec version it has
  into the live slots, unloads modules it does not have, and records the
  switch. If a load fails, the previous branch is loaded back.
  """
  @spec switch(String.t(), keyword()) :: :ok | {:error, term()}
  def switch(branch, opts \\ []) do
    if Theseus.Branches.closed?(branch),
      do: {:error, "branch #{branch} is closed; reopen it first"},
      else: write({:switch, branch, opts})
  end

  # On a follower, changes are made on the leader, and this node loads
  # them from the ledger before answering.
  defp write(message) do
    if Theseus.Leader.follower?() do
      reply = GenServer.call(Theseus.Leader.name(__MODULE__), message, @call_timeout)
      Ledger.catch_up()
      reply
    else
      GenServer.call(__MODULE__, message, @call_timeout)
    end
  end

  @doc """
  On a follower: loads the live branch as the ledger now has it, after the
  leader changed it. Every unit whose version differs is loaded, units the
  branch no longer has are unloaded.
  """
  @spec follow() :: :ok
  def follow, do: GenServer.call(__MODULE__, :follow, @call_timeout)

  @doc """
  Reconstructs every unit and spec from the ledger: recompiles the current
  version's AST, checks its hash, loads it.
  Returns `%{module => {:ok, hash} | {:error, reason}}`.
  """
  @spec rebuild() :: %{module() => {:ok, String.t()} | {:error, term()}}
  def rebuild, do: GenServer.call(__MODULE__, :rebuild, @call_timeout)

  @doc """
  Compiles a version under the module name in `version.unit` and returns the
  beam. Nothing is loaded. Warnings go to `compile_checked/1`.
  """
  @spec compile(Version.t()) :: {:ok, binary()} | {:error, term()}
  def compile(%Version{} = version) do
    with {:ok, beam, _warnings} <- compile_checked(version), do: {:ok, beam}
  end

  @doc """
  Compiles a version and returns the beam with the compiler's warnings, each
  as text with its line. Validation refuses a change with warnings.
  """
  @spec compile_checked(Version.t()) :: {:ok, binary(), [String.t()]} | {:error, term()}
  def compile_checked(%Version{unit: module, hash: hash} = version) do
    with {:ok, source} <- compile_source(version) do
      dir = Path.join(System.tmp_dir!(), "theseus_build_#{System.unique_integer([:positive])}")
      out = Path.join(dir, "out")
      file = Path.join(dir, "#{inspect(module)}@#{Version.short(hash)}.ex")
      File.mkdir_p!(out)
      File.write!(file, source)
      previous = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)

      try do
        case Kernel.ParallelCompiler.compile_to_path([file], out, return_diagnostics: true) do
          {:ok, [^module], diagnostics} ->
            {:ok, File.read!(Path.join(out, Atom.to_string(module) <> ".beam")),
             warnings(diagnostics)}

          {:ok, modules, _} ->
            {:error, {:unexpected_modules, modules}}

          {:error, errors, _} ->
            {:error, {:compile, Enum.map(errors, &Map.take(&1, [:message, :position]))}}
        end
      after
        Code.put_compiler_option(:ignore_module_conflict, previous)
        File.rm_rf(dir)
      end
    end
  end

  # The compiler's warnings, each as text with its line in the unit's source.
  defp warnings(%{compile_warnings: compile, runtime_warnings: runtime}) do
    for %{message: message, position: position} <- compile ++ runtime,
        do: "#{message} (line #{line(position)})"
  end

  defp warnings(_diagnostics), do: []

  defp line({line, _column}), do: line
  defp line(line) when is_integer(line), do: line
  defp line(_position), do: "?"

  @doc "The unit an event about `module` belongs to: a spec belongs to its unit."
  @spec owner(module()) :: module()
  def owner(module),
    do: if(Unit.spec_name?(module), do: Unit.specified_unit(module), else: module)

  ## Server

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:register, %Version{unit: module} = version, opts}, _from, state) do
    actor = Keyword.get(opts, :actor, :system)
    kind = Keyword.get(opts, :kind, if(Unit.spec_name?(module), do: :spec, else: :pure))
    {branch, live?} = branch(opts)

    reply =
      with :ok <- check_allowed(module),
           :ok <- check_kind(module, kind),
           nil <- Ledger.current(module, branch),
           :ok <- Theseus.Store.DB.prepare(version, live?),
           {:ok, version} <- compile_and_store(%{version | parent: nil}, actor, branch) do
        record = %Unit{
          module: module,
          kind: kind,
          spec: if(kind == :spec, do: nil, else: Unit.spec_module(module)),
          current_version: version.hash
        }

        with :ok <- if(live?, do: load_version(record, version), else: :ok) do
          {:ok, _} =
            Ledger.append({:unit_registered, record},
              by: Keyword.get(opts, :by),
              actor: actor,
              unit: owner(module),
              branch: branch
            )

          if live?, do: :ok = Registry.put(record)
          if live? and kind == :server, do: Theseus.Servers.start(module)
          {:ok, version}
        end
      else
        hash when is_binary(hash) -> {:error, :already_registered}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:promote, %Version{unit: module} = version, opts}, _from, state) do
    actor = Keyword.get(opts, :actor, :human)
    {branch, live?} = branch(opts)

    reply =
      with {:ok, record} <- fetch_unit(module, branch, live?),
           :ok <- check_base(version, record),
           {:ok, version} <- known_or_compile(version, actor, branch),
           :ok <- Theseus.Store.DB.prepare(version, live?),
           :ok <- if(live?, do: swap(record, version, :up), else: :ok) do
        body = {:promoted, module, record.current_version, version.hash, opts[:change_id]}

        {:ok, _} =
          Ledger.append(body,
            actor: actor,
            unit: owner(module),
            branch: branch,
            by: Keyword.get(opts, :by)
          )

        if live?, do: :ok = Registry.set_current(module, version.hash)

        Logger.info(
          "promoted #{inspect(module)} #{short(record.current_version)} -> " <>
            "#{short(version.hash)} on #{branch}"
        )

        {:ok, version}
      end

    {:reply, reply, state}
  end

  def handle_call({:rollback, module, to, opts}, _from, state) do
    {branch, live?} = branch(opts)

    reply =
      with {:ok, record} <- fetch_unit(module, branch, live?),
           {:ok, target} <- rollback_target(record, to),
           :ok <- rollback_allowed(module, target, branch),
           {:ok, version} <- Ledger.version(module, target) |> with_beam(),
           :ok <- if(live?, do: swap(record, version, :down), else: :ok) do
        reason = Keyword.get(opts, :reason, "manual")
        body = {:rolled_back, module, record.current_version, target, reason}

        {:ok, _} =
          Ledger.append(body,
            by: Keyword.get(opts, :by),
            actor: Keyword.get(opts, :actor, :human),
            unit: owner(module),
            branch: branch
          )

        if live?, do: :ok = Registry.set_current(module, target)
        if live?, do: Theseus.Store.DB.changed()

        Logger.info(
          "rolled back #{inspect(module)} #{short(record.current_version)} -> #{short(target)}"
        )

        {:ok, version}
      end

    {:reply, reply, state}
  end

  def handle_call({:unregister, module, opts}, _from, state) do
    {branch, live?} = branch(opts)

    reply =
      with {:ok, record} <- fetch_unit(module, branch, live?) do
        if live? do
          if record.kind == :server, do: Theseus.Servers.stop(module)
          unload(module)
          :ok = Registry.delete(module)
        end

        {:ok, _} =
          Ledger.append({:unit_unregistered, module, Keyword.get(opts, :reason, "manual")},
            by: Keyword.get(opts, :by),
            actor: Keyword.get(opts, :actor, :system),
            unit: owner(module),
            branch: branch
          )

        if live?, do: Theseus.Store.DB.changed()
        Logger.info("unregistered #{inspect(module)} on #{branch}")
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:switch, to, opts}, _from, state) do
    from = Branches.live()

    reply =
      cond do
        to == from -> {:error, :already_live}
        not Branches.exists?(to) -> {:error, :no_such_branch}
        true -> do_switch(from, to, opts)
      end

    {:reply, reply, state}
  end

  def handle_call(:rebuild, _from, state) do
    results = Map.new(Ledger.units(), fn record -> {record.module, rebuild_unit(record)} end)
    {:reply, results, state}
  end

  def handle_call(:follow, _from, state) do
    follow_live()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:follow, state) do
    follow_live()
    {:noreply, state}
  end

  ## Internals

  defp follow_live do
    live = Branches.refresh_live()
    before = Map.new(Registry.all(), &{&1.module, &1})
    target = Map.new(Branches.units(live), &{&1.module, &1})

    if before != target do
      case load_all(target) do
        :ok ->
          for m <- Map.keys(before) -- Map.keys(target) do
            unload(m)
            :ok = Registry.delete(m)
          end

          Theseus.Store.DB.changed()

        {:error, why} ->
          Logger.error("could not load the live branch as the leader changed it: #{inspect(why)}")
      end
    end
  end

  defp branch(opts) do
    live = Branches.live()
    branch = Keyword.get(opts, :branch) || live
    {branch, branch == live}
  end

  defp do_switch(from, to, opts) do
    before = Map.new(Registry.all(), &{&1.module, &1})
    target = Map.new(Branches.units(to), &{&1.module, &1})
    gone = Map.keys(before) -- Map.keys(target)

    case load_all(target) do
      :ok ->
        for m <- gone do
          if before[m].kind == :server, do: Theseus.Servers.stop(m)
          unload(m)
          :ok = Registry.delete(m)
        end

        for %Unit{kind: :server, module: m} <- Map.values(target),
            do: Theseus.Servers.start(m)

        {:ok, _} =
          Ledger.append({:branch_switched, to, from},
            actor: Keyword.get(opts, :actor, :human),
            branch: to
          )

        Branches.set_live(to)
        Theseus.Store.DB.changed()
        Logger.info("live branch is now #{to} (was #{from})")
        :ok

      {:error, _} = error ->
        # Put back whatever was loaded before.
        _ = load_all(before)
        error
    end
  end

  # Loads each unit's version where the live slot differs, and updates the
  # registry.
  defp load_all(units) do
    Enum.reduce_while(units, :ok, fn {module, %Unit{current_version: hash} = unit}, :ok ->
      case Registry.fetch(module) do
        {:ok, %Unit{current_version: ^hash}} ->
          {:cont, :ok}

        found ->
          with {:ok, version} <- Ledger.version(module, hash) |> with_beam(),
               :ok <- load_into(found, unit, version) do
            :ok = Registry.put(unit)
            {:cont, :ok}
          else
            error -> {:halt, error}
          end
      end
    end)
  end

  defp load_into({:ok, record}, _unit, version), do: swap(record, version, :up)
  defp load_into(:error, unit, version), do: load_version(unit, version)

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp rebuild_unit(%Unit{module: module, current_version: hash} = record) do
    with {:ok, version} <- Ledger.version(module, hash) |> found(),
         :ok <- check_hash(version),
         {:ok, beam} <- compile(version),
         :ok <- load_version(record, %{version | beam: beam}) do
      :ok = Registry.put(record)
      {:ok, hash}
    end
  end

  # A version that mentions data a schema change dropped stays behind.
  defp rollback_allowed(module, target, branch) do
    case Theseus.Store.Migrate.rollback_refusal(module, target, branch) do
      nil -> :ok
      why -> {:error, why}
    end
  end

  defp check_hash(%Version{ast: ast, hash: hash}) do
    case Version.hash(ast) do
      ^hash -> :ok
      other -> {:error, {:hash_mismatch, expected: hash, got: other}}
    end
  end

  defp check_base(%Version{hash: hash}, %Unit{current_version: hash}), do: {:error, :no_change}
  defp check_base(%Version{parent: parent}, %Unit{current_version: parent}), do: :ok
  defp check_base(_version, %Unit{current_version: current}), do: {:error, {:stale, current}}

  defp known_or_compile(%Version{unit: module, hash: hash} = version, actor, branch) do
    case Ledger.version(module, hash) do
      {:ok, %Version{beam: beam} = known} when is_binary(beam) -> {:ok, known}
      _ -> compile_and_store(version, actor, branch)
    end
  end

  defp compile_and_store(%Version{} = version, actor, branch) do
    with {:ok, beam} <- compile(version) do
      version = %{version | beam: beam}

      {:ok, _} =
        Ledger.put_version(version, actor: actor, unit: owner(version.unit), branch: branch)

      {:ok, version}
    end
  end

  defp swap(%Unit{kind: :server} = record, version, direction),
    do: swap_server(record, version, direction)

  defp swap(record, version, _direction), do: load_version(record, version)

  # Suspends the unit's processes, migrates their state and resumes them.
  # Processes that are not running get nothing; boot and import load server
  # units before the application starts them.
  defp swap_server(%Unit{module: mod, current_version: from} = record, version, direction) do
    pids = server_pids(mod)

    with :ok <- drain(mod, :server) do
      Enum.each(pids, &:sys.suspend/1)

      try do
        case direction do
          :up ->
            with :ok <- load_version(record, version, false) do
              case change_code(pids, mod, from) do
                :ok ->
                  :ok

                {:error, _} = error ->
                  # The old version sits in the old-code slot; clear it to
                  # load it again as current.
                  {:ok, old} = Ledger.version(mod, from)
                  :code.soft_purge(mod) or :code.purge(mod)
                  :ok = load_version(record, old, false)
                  error
              end
            end

          :down ->
            with :ok <- change_code(pids, mod, {:down, version.hash}) do
              load_version(record, version, false)
            end
        end
      after
        Enum.each(pids, &:sys.resume/1)
      end
    end
  end

  defp change_code(pids, mod, old_vsn) do
    Enum.reduce_while(pids, :ok, fn pid, :ok ->
      case :sys.change_code(pid, mod, old_vsn, nil) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:code_change_failed, reason}}}
      end
    end)
  end

  defp server_pids(mod) do
    for pid <- Process.list(),
        {:dictionary, dict} <- [Process.info(pid, :dictionary)],
        dict[:"$initial_call"] == {mod, :init, 1},
        do: pid
  end

  # Swaps a version into the live slot. Processes still running the old-old
  # code get `drain_ms` to finish. After that, pure units are purged (those
  # processes are killed) and server units refuse the load.
  defp load_version(record, version, drain? \\ true)

  defp load_version(%Unit{module: mod, kind: kind}, %Version{hash: hash, beam: beam}, drain?) do
    with :ok <- if(drain?, do: drain(mod, kind), else: :ok) do
      case :code.load_binary(mod, ~c"theseus/#{inspect(mod)}@#{short(hash)}.beam", beam) do
        {:module, ^mod} -> :ok
        {:error, reason} -> {:error, {:load_failed, reason}}
      end
    end
  end

  defp drain(mod, kind) do
    deadline = System.monotonic_time(:millisecond) + Application.fetch_env!(:theseus, :drain_ms)
    drain(mod, kind, deadline)
  end

  defp drain(mod, kind, deadline) do
    cond do
      :code.soft_purge(mod) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(25)
        drain(mod, kind, deadline)

      kind == :server ->
        {:error, :drain_failed}

      true ->
        lingering = Enum.filter(Process.list(), &:erlang.check_process_code(&1, mod))

        Logger.warning(
          "purging old #{inspect(mod)}, killing #{length(lingering)} lingering processes"
        )

        :code.purge(mod)
        :ok
    end
  end

  defp rollback_target(%Unit{module: module, current_version: current}, :previous) do
    case Ledger.version(module, current) do
      {:ok, %Version{parent: nil}} -> {:error, :no_previous_version}
      {:ok, %Version{parent: parent}} -> {:ok, parent}
      :error -> {:error, {:unknown_version, current}}
    end
  end

  defp rollback_target(%Unit{module: module, current_version: current}, prefix)
       when is_binary(prefix) do
    case Enum.filter(Ledger.versions_for(module), &String.starts_with?(&1.hash, prefix)) do
      [%Version{hash: ^current}] -> {:error, :already_current}
      [%Version{hash: hash}] -> {:ok, hash}
      [] -> {:error, {:unknown_version, prefix}}
      _ -> {:error, {:ambiguous_prefix, prefix}}
    end
  end

  defp compile_source(%Version{ast: {:defmodule, meta, [name, [do: body]]}, hash: hash}) do
    exprs =
      case body do
        {:__block__, _, exprs} -> exprs
        nil -> []
        expr -> [expr]
      end

    if Enum.any?(exprs, &match?({:@, _, [{:vsn, _, _}]}, &1)) do
      {:error, :module_sets_vsn}
    else
      vsn = quote(do: @vsn(unquote(hash)))
      {:ok, Version.render({:defmodule, meta, [name, [do: {:__block__, [], exprs ++ [vsn]}]]})}
    end
  end

  # Hard rule 1: Theseus never changes itself.
  defp check_allowed(module) do
    name = Atom.to_string(module)

    if name == "Elixir.Theseus" or String.starts_with?(name, "Elixir.Theseus.") do
      {:error, :theseus_modules_are_not_units}
    else
      :ok
    end
  end

  defp check_kind(module, kind) do
    case {Unit.spec_name?(module), kind} do
      {true, :spec} -> :ok
      {false, kind} when kind in [:pure, :server, :endpoint, :store] -> :ok
      _ -> {:error, {:bad_kind, module, kind}}
    end
  end

  defp fetch_unit(module, _branch, true) do
    case Registry.fetch(module) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_registered}
    end
  end

  defp fetch_unit(module, branch, false) do
    case Branches.unit(branch, module) do
      %Unit{} = record -> {:ok, record}
      nil -> {:error, :not_registered}
    end
  end

  defp found(:error), do: {:error, :version_not_in_ledger}
  defp found(ok), do: ok

  # A version with its beam. Compaction keeps beams only for current
  # versions and the ones before them; others are compiled again from their
  # syntax tree, and the beam stored again. A version whose code compaction
  # removed too is only in the archive (see Theseus.Compact).
  defp with_beam({:ok, %Version{beam: beam} = version}) when is_binary(beam),
    do: {:ok, version}

  defp with_beam({:ok, %Version{ast: nil, unit: module, hash: hash}}),
    do:
      {:error,
       "#{inspect(module)} version #{short(hash)} was removed when the ledger was compacted. " <>
         "The ledger's archive still has it."}

  defp with_beam({:ok, version}) do
    with :ok <- check_hash(version),
         do: compile_and_store(version, :system, Branches.live())
  end

  defp with_beam(:error), do: {:error, :version_not_in_ledger}

  defp short(hash), do: Version.short(hash)
end
