defmodule Patchbay.Definition do
  @moduledoc """
  Loads and validates declarative agent definitions.

  An agent directory contains `agent.toml`, an optional `prompts/` directory,
  and an optional `scripts/` directory. A configuration root may also provide
  `shared/prompts/` and a shared `scripts/` directory. Prompt files are enabled
  by presence; shared prompts are assembled before agent prompts, and each
  group is ordered lexically by filename.

  `load/2` reads the filesystem. `parse/2` validates a TOML document without
  reading prompts or scripts.
  """

  alias Patchbay.Definition.Agent
  alias Patchbay.Definition.Error
  alias Patchbay.Definition.Loader

  @type t :: Agent.t()

  @type option ::
          {:config_root, Path.t()}
          | {:path, Path.t()}
          | {:agent_dir, Path.t()}
          | {:toolkit_dirs, [Path.t()]}

  @doc """
  Loads and validates the agent definition rooted at `agent_dir`.

  The config root is inferred when `agent_dir` ends in `agents/<id>`;
  otherwise pass `:config_root` explicitly to resolve shared prompts and
  scripts.

  Toolkit declarations are resolved against `<config_root>/toolkits` and the
  application's `priv/toolkits`. Pass `:toolkit_dirs` to override the search
  path.
  """
  @spec load(Path.t(), [option()]) :: {:ok, t()} | {:error, Error.t()}
  def load(agent_dir, opts \\ []), do: Loader.load(agent_dir, opts)

  @doc """
  Same as `load/2`, but raises `Patchbay.Definition.Error` on failure.
  """
  @spec load!(Path.t(), [option()]) :: t()
  def load!(agent_dir, opts \\ []), do: Loader.load!(agent_dir, opts)

  @doc """
  Parses and validates a TOML agent declaration.

  Prompt and script paths are not discovered. `:path`, `:agent_dir`,
  `:config_root`, and `:toolkit_dirs` are recorded on the returned definition
  when supplied. Manifests are resolved only when `:toolkit_dirs` is given.
  """
  @spec parse(String.t(), [option()]) :: {:ok, t()} | {:error, Error.t()}
  def parse(body, opts \\ []), do: Loader.parse(body, opts)
end
