defmodule Patchbay.ProviderTest do
  use ExUnit.Case, async: true

  alias Patchbay.Provider.{Message, Request, Response}

  defmodule Stub do
    @behaviour Patchbay.Provider

    @impl true
    def complete(request, opts) do
      {:ok, %Response{id: Keyword.get(opts, :marker), model: request.model}}
    end
  end

  test "dispatches to the requested provider module" do
    request = %Request{model: "gpt-test", messages: [Message.user("hi")]}

    assert {:ok, %Response{id: :stub, model: "gpt-test"}} =
             Patchbay.Provider.complete(request, provider: Stub, marker: :stub)
  end
end
