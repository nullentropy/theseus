defmodule Theseus.StaticTest do
  use ExUnit.Case, async: true

  alias Theseus.Validator.Static
  alias Theseus.Version

  defp check(body, module \\ Demo.Unit, kind \\ :pure) do
    {:ok, v} = Version.build(module, "defmodule #{inspect(module)} do\n#{body}\nend")
    Static.check(v, kind)
  end

  defp rejects(body, pattern) do
    assert {:error, violations} = check(body)
    assert Enum.any?(violations, &(&1 =~ pattern)), inspect(violations)
  end

  test "plain data code passes" do
    assert :ok =
             check("""
             @limit 10
             def f(items, m) do
               total = items |> Enum.map(& &1.qty) |> Enum.sum()
               %{total: min(total, @limit), name: String.upcase(m.name), root: :math.sqrt(4), me: __MODULE__.g()}
             end
             def g, do: {:ok, [1, 2]}
             def h(x) when x in ?A..?Z, do: raise(ArgumentError, "no")
             """)
  end

  test "side effects are rejected" do
    rejects(~s|def f, do: System.cmd("echo", ["hi"])|, "System is not on the allowlist")
    rejects(~s|def f, do: File.write("/tmp/x", "y")|, "File is not on the allowlist")
    rejects(~s|def f, do: IO.puts("x")|, "IO is not on the allowlist")
    rejects(~s|def f, do: :os.cmd(~c"ls")|, ":os is not on the allowlist")
    rejects("def f, do: spawn(fn -> :ok end)", "spawn is not allowed")
    rejects("def f(pid), do: send(pid, :x)", "send is not allowed")
    rejects("def f, do: receive(do: (x -> x))", "receive is not allowed")
  end

  test "ways around the allowlist are rejected" do
    rejects("def f(m), do: m.cmd(~c\"ls\")", "dynamic call")
    rejects("def f(m), do: apply(m, :cmd, [])", "apply is not allowed")
    rejects("def f(m), do: Kernel.apply(m, :cmd, [])", "Kernel.apply is not allowed")
    rejects("def f(m), do: &m.cmd/1", "dynamic capture")
    rejects("def f do\n  m = :init\n  m.stop\nend", ":init is not on the allowlist")
    rejects("def f(s), do: String.to_existing_atom(s)", "String.to_existing_atom is not allowed")
    rejects(~S|def f(s), do: :"#{s}"|, ":erlang is not on the allowlist")
    rejects("alias Sample.Evil, as: Enum", "alias is not allowed")
    rejects("@on_load :boot", "@on_load is not allowed")
    rejects("@x System.get_env(\"HOME\")", "System is not on the allowlist")
    rejects("def f, do: Demo.Unit.g()", "refer to the unit itself as __MODULE__")
    rejects("use GenServer", "use GenServer is not allowed")

    rejects(
      "def f(r), do: Theseus.call(__MODULE__.Admin, :handle, [r])",
      "write the module's full name, not a name built on __MODULE__ or a variable"
    )

    rejects("def f(x), do: x.Foo", "write the module's full name")
    rejects("@m Sample\ndef f, do: @m.Foo.g()", "dynamic call")
  end

  test "a function may be named like an Erlang module, and the module stays out of reach" do
    assert :ok =
             check("def f(r), do: Theseus.call(__MODULE__, :shell, [r])", Demo.Unit, :endpoint)

    rejects("def f do\n  m = :shell\n  m.start\nend", ":shell is not on the allowlist")
    rejects("def f(g), do: g.(:file)", ":file is not on the allowlist")

    assert :ok =
             check(
               """
               use Theseus.Spec

               spec Demo.Unit do
                 invariant "named like a module", check: fn call, app -> call.(:shell, []) == app.(:file, []) end
               end
               """,
               Demo.Unit.Spec,
               :spec
             )

    {:error, reasons} =
      check(
        """
        use Theseus.Spec

        spec Demo.Unit do
          invariant "not the harness", check: fn call -> f = fn m -> m end; f.(:os) == call.(:g, []) end
        end
        """,
        Demo.Unit.Spec,
        :spec
      )

    assert Enum.any?(reasons, &(&1 =~ ":os is not on the allowlist"))
  end

  test "spec modules may use Theseus.Spec and StreamData and name their unit" do
    assert :ok =
             check(
               """
               use Theseus.Spec

               spec Demo.Unit do
                 example "one", f: [1], expect: 2
                 property "It is positive.", f: [gen()], check: fn r -> r > 0 end
               end

               defp gen, do: StreamData.integer(1..5)
               """,
               Demo.Unit.Spec,
               :spec
             )
  end

  test "units over the size cap are rejected" do
    body = Enum.map_join(1..120, "\n", &"def f#{&1}(x), do: x + #{&1}")
    rejects(body, "split it into two units")
  end

  test "server units may use GenServer, and must define code_change/3" do
    server = """
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def get, do: GenServer.call(__MODULE__, :get)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(:get, _from, state), do: {:reply, state, state}
    """

    assert {:error, [violation]} = check(server, Demo.Unit, :server)
    assert violation =~ "code_change/3"

    with_migration =
      server <> "\n@impl true\ndef code_change(_old, state, _extra), do: {:ok, state}"

    assert :ok = check(with_migration, Demo.Unit, :server)

    assert {:error, [violation]} =
             check(
               with_migration <> "\ndef all, do: GenServer.multi_call(:x)",
               Demo.Unit,
               :server
             )

    assert violation =~ "GenServer.multi_call is not allowed"
    assert {:error, _} = check(with_migration, Demo.Unit, :pure)
  end

  test "units do not read the clock or use randomness" do
    assert {:error, [v]} = check("def f, do: DateTime.utc_now()")
    assert v =~ "DateTime.utc_now is not allowed: units do not read the clock"
    assert {:error, [v]} = check("def f(list), do: Enum.random(list)")
    assert v =~ "Enum.random is not allowed"
    assert :ok = check("def f(at), do: DateTime.add(at, 60, :second)")
  end
end
