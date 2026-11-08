defmodule Theseus.LedgerLockTest do
  @moduledoc "Two instances cannot open the same ledger."

  use ExUnit.Case, async: false

  alias Theseus.LedgerLock

  setup do
    dir = Path.expand("../../tmp/lock_test_#{System.unique_integer([:positive])}", __DIR__)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{ledger: Path.join(dir, "app.theseus")}
  end

  defp holder_pid(ledger),
    do: ledger |> LedgerLock.path() |> File.read!() |> String.split("\n") |> hd()

  test "the running app holds its ledger's lock" do
    assert holder_pid(Theseus.Ledger.path()) == System.pid()
  end

  test "a free ledger is locked, and released", %{ledger: ledger} do
    assert :ok = LedgerLock.acquire(ledger)
    assert holder_pid(ledger) == System.pid()
    # This same VM may take it again, as when the ledger process restarts.
    assert :ok = LedgerLock.acquire(ledger)
    :ok = LedgerLock.release(ledger)
    refute File.exists?(LedgerLock.path(ledger))
  end

  test "a lock left by a VM that is gone is taken over", %{ledger: ledger} do
    File.write!(LedgerLock.path(ledger), "999999\nold@host\n2026-10-01T00:00:00Z\n")
    assert :ok = LedgerLock.acquire(ledger)
    assert holder_pid(ledger) == System.pid()
  end

  test "a ledger another running VM holds is refused, with who holds it", %{ledger: ledger} do
    erl = System.find_executable("erl")

    port =
      Port.open({:spawn_executable, erl}, [
        :binary,
        :stderr_to_stdout,
        # Stops by itself within 20 seconds whatever happens.
        args: ["-noshell", "-eval", "timer:sleep(20000), halt()."]
      ])

    {:os_pid, other} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", Integer.to_string(other)]) end)

    # erl is a script that execs the VM; wait until it has.
    assert Enum.find(1..100, fn _ ->
             Process.sleep(30)
             {out, _} = System.cmd("ps", ["-o", "comm=", "-p", Integer.to_string(other)])
             out =~ "beam"
           end)

    File.write!(LedgerLock.path(ledger), "#{other}\nother@host\n2026-10-14T09:00:00Z\n")
    assert {:error, message} = LedgerLock.acquire(ledger)
    assert message =~ "is already open in another Theseus (OS process #{other}, node other@host"
    assert message =~ "delete #{LedgerLock.path(ledger)}"

    # Release leaves someone else's lock alone.
    :ok = LedgerLock.release(ledger)
    assert holder_pid(ledger) == Integer.to_string(other)
  end
end
