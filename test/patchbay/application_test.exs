defmodule Patchbay.ApplicationTest do
  use ExUnit.Case, async: false

  alias Patchbay.Application, as: PatchbayApp
  alias Patchbay.Config

  @config %Config{
    config_dir: "/tmp/patchbay-test/config",
    state_dir: "/tmp/patchbay-test/state",
    runtime_dir: "/tmp/patchbay-test/state/runtime"
  }

  setup do
    previous = Elixir.Application.get_env(:patchbay, :start_services)
    Elixir.Application.put_env(:patchbay, :start_services, true)
    on_exit(fn -> Elixir.Application.put_env(:patchbay, :start_services, previous) end)
  end

  test "worker and supervisor roles boot no web or manager services" do
    for role <- [:worker, :worker_supervisor, :cli] do
      assert PatchbayApp.children(role, @config) == []
    end
  end

  test "the manager role boots web, registry, runtime, and scheduler without the CLI manager" do
    modules = modules(PatchbayApp.children(:manager, @config))

    assert PatchbayWeb.Endpoint in modules
    assert Patchbay.DefinitionRegistry in modules
    assert Patchbay.Runtime in modules
    assert Patchbay.Scheduler in modules
    refute Patchbay.CLI.Manager in modules
  end

  test "a normal application start boots web, the CLI manager, and services" do
    children = PatchbayApp.children(:app, @config)
    modules = modules(children)

    assert PatchbayWeb.Endpoint in modules
    assert Patchbay.DefinitionRegistry in modules
    assert Patchbay.CLI.Manager in modules
    assert {Patchbay.CLI.Manager, Patchbay.CLI.Manager} in Enum.map(children, &child_id/1)
    assert Patchbay.Runtime in modules
    assert Patchbay.Scheduler in modules
  end

  test "role children have unique supervisor ids" do
    for role <- [:app, :manager] do
      ids = Enum.map(PatchbayApp.children(role, @config), &child_id/1)
      assert ids == Enum.uniq(ids)
    end
  end

  defp modules(children), do: Enum.map(children, &module/1)

  defp module({module, _args}) when is_atom(module), do: module
  defp module(module) when is_atom(module), do: module

  defp child_id({module, args}) when is_atom(module) and is_list(args) do
    case Keyword.fetch(args, :name) do
      {:ok, name} -> {module, name}
      :error -> module
    end
  end

  defp child_id(module) when is_atom(module), do: module
end
