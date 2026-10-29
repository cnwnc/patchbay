defmodule Patchbay.BootTest do
  use ExUnit.Case, async: true

  alias Patchbay.Boot

  test "classifies service entry points" do
    assert Boot.role(["run-manager"]) == :manager
    assert Boot.role(["run-worker-supervisor", "--listen-port", "0"]) == :worker_supervisor
    assert Boot.role(["run-worker", "--worker-id", "one"]) == :worker
    assert Boot.role(["help"]) == :cli
    assert Boot.role(["--help"]) == :cli
    assert Boot.role([]) == :app
    assert Boot.role(["unknown-command"]) == :app
  end

  test "escript invocations without a known command are CLI invocations" do
    assert Boot.role([], escript: true) == :cli
    assert Boot.role(["unknown-command"], escript: true) == :cli
    assert Boot.role(["run-manager"], escript: true) == :manager
    assert Boot.role(["help"], escript: true) == :cli
  end

  test "only the application and manager roles own the web endpoint" do
    assert Boot.web?(:app)
    assert Boot.web?(:manager)
    refute Boot.web?(:worker)
    refute Boot.web?(:worker_supervisor)
    refute Boot.web?(:cli)
    refute Boot.web?(["run-worker-supervisor"])
  end
end
