defmodule Patchbay.Definition.Prompt do
  @moduledoc """
  One enabled prompt file from a shared or agent prompt directory.

  Presence in the directory enables the prompt. `Patchbay.Definition.load/2`
  orders shared prompts before agent prompts, with each group sorted by
  filename.
  """

  defstruct [:name, :path, :content, :source]

  @type source :: :shared | :agent

  @type t :: %__MODULE__{
          name: String.t(),
          path: Path.t(),
          content: String.t(),
          source: source()
        }

  @doc false
  @spec from_file(Path.t(), source()) :: {:ok, t()} | {:error, File.posix()}
  def from_file(path, source) do
    case File.read(path) do
      {:ok, content} ->
        {:ok,
         %__MODULE__{name: Path.basename(path), path: path, content: content, source: source}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
