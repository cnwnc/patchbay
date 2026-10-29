defmodule Patchbay.Worker.IdTest do
  use ExUnit.Case, async: true

  alias Patchbay.Worker.Id

  test "safe agent ids use a readable reversible namespace" do
    assert {:ok, "agent.alpha"} = Id.for_agent("alpha")
    assert {:ok, "alpha"} = Id.agent("agent.alpha")
  end

  test "unsafe agent ids round-trip through a disjoint encoded namespace" do
    for agent_id <- ["with space", "ümlaut", "a/b", "trailing\n"] do
      assert {:ok, worker_id} = Id.for_agent(agent_id)
      assert String.starts_with?(worker_id, "agent-")
      refute String.starts_with?(worker_id, "agent.")
      assert {:ok, ^agent_id} = Id.agent(worker_id)
    end
  end

  test "distinct agent ids never share a worker id" do
    ids = ["alpha", "agent.alpha", "agent-alpha", "alpha ", "alpha\n", "Alpha"]

    worker_ids =
      Enum.map(ids, fn id ->
        {:ok, worker_id} = Id.for_agent(id)
        worker_id
      end)

    assert length(Enum.uniq(worker_ids)) == length(ids)

    Enum.zip(ids, worker_ids)
    |> Enum.each(fn {agent_id, worker_id} ->
      assert {:ok, ^agent_id} = Id.agent(worker_id)
    end)
  end

  test "worker ids fit the worker id contract" do
    assert {:ok, worker_id} = Id.for_agent(String.duplicate("a", 120))
    assert byte_size(worker_id) <= 128
    assert Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/, worker_id)

    assert {:error, {:agent_id_too_long, _size}} = Id.for_agent(String.duplicate("a", 256))
  end

  test "rejects ids from neither namespace" do
    assert {:error, :invalid_worker_id} = Id.agent("alpha")
    assert {:error, :invalid_worker_id} = Id.agent("agent-node")
  end
end
