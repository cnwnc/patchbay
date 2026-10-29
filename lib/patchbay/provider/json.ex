defmodule Patchbay.Provider.JSON do
  @moduledoc """
  JSON facade for provider payloads.

  Uses Jason when it is loaded, otherwise the `:json` module built into OTP 27
  and later. No JSON dependency is required at compile time.
  """

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(term) do
    cond do
      jason?() -> jason_encode(term)
      json?() -> json_encode(term)
      true -> {:error, :json_encoder_unavailable}
    end
  end

  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(data) when is_binary(data) do
    cond do
      jason?() -> jason_decode(data)
      json?() -> json_decode(data)
      true -> {:error, :json_encoder_unavailable}
    end
  end

  @doc "Returns the JSON backend in use, or `nil` when none is available."
  @spec backend() :: :jason | :json | nil
  def backend do
    cond do
      jason?() -> :jason
      json?() -> :json
      true -> nil
    end
  end

  defp jason?, do: Code.ensure_loaded?(Jason)

  defp json?, do: Code.ensure_loaded?(:json)

  defp jason_encode(term) do
    case apply(Jason, :encode, [term]) do
      {:ok, encoded} when is_binary(encoded) -> {:ok, encoded}
      {:error, reason} -> {:error, error_message(reason)}
    end
  rescue
    error -> {:error, error_message(error)}
  end

  defp jason_decode(data) do
    case apply(Jason, :decode, [data]) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, error_message(reason)}
    end
  rescue
    error -> {:error, error_message(error)}
  end

  # The OTP :json module uses the Erlang atom `null` rather than Elixir's
  # `nil`, so both directions are normalized here.
  defp json_encode(term) do
    guard(fn ->
      term
      |> to_json_term()
      |> :json.encode()
      |> IO.iodata_to_binary()
    end)
  end

  defp json_decode(data) do
    guard(fn -> data |> :json.decode() |> from_json_term() end)
  end

  defp to_json_term(nil), do: :null

  defp to_json_term(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, to_json_term(value)} end)
  end

  defp to_json_term(list) when is_list(list), do: Enum.map(list, &to_json_term/1)
  defp to_json_term(other), do: other

  defp from_json_term(:null), do: nil

  defp from_json_term(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, from_json_term(value)} end)
  end

  defp from_json_term(list) when is_list(list), do: Enum.map(list, &from_json_term/1)
  defp from_json_term(other), do: other

  defp guard(fun) do
    try do
      {:ok, fun.()}
    rescue
      error -> {:error, error_message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)
end
