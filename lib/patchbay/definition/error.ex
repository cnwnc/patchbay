defmodule Patchbay.Definition.Error do
  @moduledoc """
  A collection of validation or loading failures for an agent definition.

  Each issue carries the path of the offending declaration, using string keys
  and integer indexes, plus a human-readable message.
  """

  defexception errors: []

  @typedoc "A path inside a declaration, such as `[\"results\", 0, \"required-by\"]`."
  @type path :: [String.t() | non_neg_integer()]

  @typedoc "One failed validation or loading check."
  @type issue :: %{required(:path) => path(), required(:message) => String.t()}

  @type t :: %__MODULE__{errors: [issue()]}

  @spec issue(path(), String.t()) :: issue()
  def issue(path, message), do: %{path: path, message: message}

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{errors: []}), do: "invalid agent definition"

  def message(%__MODULE__{errors: errors}) do
    Enum.map_join(errors, "\n", fn %{path: path, message: message} ->
      "#{format_path(path)}: #{message}"
    end)
  end

  defp format_path([]), do: "<definition>"

  defp format_path([first | rest]) do
    Enum.reduce(rest, to_string(first), fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      segment, acc -> "#{acc}.#{segment}"
    end)
  end
end
