defmodule Patchbay.Provider do
  @moduledoc """
  Boundary for model providers.

  A provider receives a `Patchbay.Provider.Request` and returns either a
  `Patchbay.Provider.Response` or a `Patchbay.Provider.Error`. Messages, tool
  calls, usage, and errors are provider-neutral; wire formats stay inside the
  implementation.

  `complete/2` dispatches to `:provider` in the options, defaulting to
  `Patchbay.Provider.OpenAI`. Providers are not started as processes, so this
  boundary has no supervision or application wiring.

  `stream/3` is the streaming counterpart. The callback receives normalized
  `Patchbay.Provider.StreamEvent` values and the call returns the same
  `Patchbay.Provider.Response` that `complete/2` would have returned:

      {:ok, response} =
        Patchbay.Provider.stream(request, fn
          %StreamEvent{type: :text_delta, text: text} -> IO.write(text)
          %StreamEvent{type: :tool_call_delta} -> :ok
          %StreamEvent{type: :finish} -> :ok
        end)

  Return `:ok` from the callback to continue, or `:halt` / `{:halt, reason}`
  to cancel. A cancelled stream returns `{:error, %Error{kind: :cancelled}}`
  with the partial response under `details.partial_response`. Providers that do
  not implement `stream/3` return a `:config` error.
  """

  alias Patchbay.Provider.{Error, OpenAI, Request, Response, StreamEvent}

  @callback complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}

  @callback stream(
              Request.t(),
              (StreamEvent.t() -> :ok | :halt | {:halt, term()}),
              keyword()
            ) :: {:ok, Response.t()} | {:error, Error.t()}

  @optional_callbacks stream: 3

  @doc """
  Runs one completion through a provider.

  Options are passed to the provider. Pass `:config` with a
  `Patchbay.Provider.Config` to avoid environment lookup, or use `:env`
  elsewhere to supply an explicit string-keyed environment.
  """
  @spec complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def complete(%Request{} = request, opts \\ []) when is_list(opts) do
    provider = Keyword.get(opts, :provider, OpenAI)
    provider.complete(request, opts)
  end

  @doc """
  Streams one completion through a provider.

  The callback receives a `Patchbay.Provider.StreamEvent` per delta. Options
  are passed to the provider and have the same meaning as `complete/2`.
  """
  @spec stream(Request.t(), (StreamEvent.t() -> :ok | :halt | {:halt, term()}), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def stream(%Request{} = request, on_event, opts \\ []) when is_list(opts) do
    cond do
      not is_function(on_event, 1) ->
        {:error, Error.new(:request, "stream callback must be a 1-arity function")}

      true ->
        provider = Keyword.get(opts, :provider, OpenAI)

        if Code.ensure_loaded?(provider) and function_exported?(provider, :stream, 3) do
          provider.stream(request, on_event, opts)
        else
          {:error, Error.new(:config, "provider does not support streaming")}
        end
    end
  end
end
