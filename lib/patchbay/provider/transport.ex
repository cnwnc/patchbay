defmodule Patchbay.Provider.Transport do
  @moduledoc """
  Minimal HTTP transport used by provider clients.

  Implementations return the status, string-keyed response headers, and a
  binary body. They must not retry or log request content; credentials are
  supplied by the caller as headers.

  `stream/6` is optional. A streaming transport receives an initial
  accumulator and a reducer. It reduces each transport event, in order, and
  returns the accumulator so the provider can assemble its final response.

  Transport events are:

    * `{:status, status, headers}` - emitted once before any body data
    * `{:data, chunk}` - emitted for each body fragment as it arrives

  The reducer returns `{:cont, acc}` to keep reading or `{:halt, acc}` to stop.
  Implementations must cancel the underlying request after a halt and must not
  log request headers, bodies, or credentials.
  """

  @type headers :: [{String.t(), String.t()}]

  @type stream_event :: {:status, non_neg_integer(), headers()} | {:data, binary()}

  @type reducer :: (stream_event(), term() -> {:cont, term()} | {:halt, term()})

  @callback post(String.t(), headers(), binary(), keyword()) ::
              {:ok, non_neg_integer(), headers(), binary()} | {:error, term()}

  @callback stream(String.t(), headers(), binary(), term(), reducer(), keyword()) ::
              {:ok, non_neg_integer(), headers(), term()}
              | {:halted, term()}
              | {:error, term(), term()}

  @optional_callbacks stream: 6
end
