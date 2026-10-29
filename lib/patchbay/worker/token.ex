defmodule Patchbay.Worker.Token do
  @moduledoc false

  @token_bytes 32
  @control_token_variable "PATCHBAY_CONTROL_TOKEN"
  @control_token_file_variable "PATCHBAY_CONTROL_TOKEN_FILE"

  @doc """
  Resolves the control-channel token.

  An explicit `:control_token` option wins. Otherwise the token comes from
  `PATCHBAY_CONTROL_TOKEN`, then from the file named by `:control_token_file` or
  `PATCHBAY_CONTROL_TOKEN_FILE`.
  """
  @spec resolve_control_token(keyword() | map(), map() | nil) :: binary() | nil
  def resolve_control_token(opts \\ [], env \\ nil) do
    env = env || System.get_env()
    file = option(opts, :control_token_file) || Map.get(env, @control_token_file_variable)

    [option(opts, :control_token), Map.get(env, @control_token_variable), read_file(file)]
    |> Enum.find(fn value -> is_binary(value) and value != "" end)
  end

  @doc "Environment variable holding the control-channel token."
  @spec control_token_variable() :: binary()
  def control_token_variable, do: @control_token_variable

  @doc "Environment variable naming a file that holds the control-channel token."
  @spec control_token_file_variable() :: binary()
  def control_token_file_variable, do: @control_token_file_variable

  @doc "Creates an unguessable URL-safe token for a local control channel."
  @spec generate() :: binary()
  def generate do
    {:ok, _apps} = Application.ensure_all_started(:crypto)
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "Compares two tokens without stopping at the first differing byte."
  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right) do
      xor_compare(left, right, 0) == 0
    else
      false
    end
  end

  def equal?(_left, _right), do: false

  defp xor_compare(<<>>, <<>>, acc), do: acc

  defp xor_compare(<<left, rest_left::binary>>, <<right, rest_right::binary>>, acc) do
    xor_compare(rest_left, rest_right, Bitwise.bor(acc, Bitwise.bxor(left, right)))
  end

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp option(_opts, _key), do: nil

  defp read_file(nil), do: nil

  defp read_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> nil
          token -> token
        end

      {:error, _reason} ->
        nil
    end
  end

  defp read_file(_path), do: nil
end
