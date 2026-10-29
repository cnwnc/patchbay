defmodule Patchbay.Worker.Env do
  @moduledoc """
  Explicit, minimal environments for spawned OS processes.

  Children inherit nothing implicitly. Only a short allowlist of ordinary
  process variables is passed through. `PATCHBAY_*` tokens and provider API
  credentials are excluded unless a caller explicitly supplies a permitted
  `PATCHBAY_*` worker variable.
  """

  @passthrough ~w(PATH HOME USER LOGNAME LANG LANGUAGE LC_ALL LC_CTYPE TMPDIR TZ TERM SHELL)

  @instance_variable "PATCHBAY_WORKER_INSTANCE"
  @home_variable "PATCHBAY_HOME"

  @worker_variables [
    @instance_variable
    | ~w(PATCHBAY_HOME PATCHBAY_WORKER_TOKEN PATCHBAY_OPERATIONS PATCHBAY_WORKSPACE)
  ]

  @provider_names ~w(
    ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY GEMINI_API_KEY
    MISTRAL_API_KEY COHERE_API_KEY TOGETHER_API_KEY GROQ_API_KEY
    XAI_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY HF_TOKEN
    HUGGING_FACE_HUB_TOKEN AZURE_OPENAI_API_KEY AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  )

  @type env :: [{charlist(), charlist() | false}]

  @doc """
  Environment for an operation child started by a worker.

  Contains only the passthrough allowlist plus the worker instance marker and
  `PATCHBAY_HOME`, so neither the worker token nor any provider credential
  reaches the operation.
  """
  @spec exec_env(map()) :: env()
  def exec_env(source \\ System.get_env()) do
    build(source, %{}, [], [@instance_variable, @home_variable])
  end

  @doc """
  Environment for a worker process started by the worker supervisor.

  Adds the worker configuration variables, including `PATCHBAY_HOME` when the
  manager has one. The control-channel token is never allowed through.
  """
  @spec worker_env(map(), map()) :: env()
  def worker_env(extra \\ %{}, source \\ System.get_env()) when is_map(extra) do
    build(source, extra, @worker_variables, [])
  end

  @doc "Environment variable carrying the supervisor-assigned worker instance marker."
  @spec instance_variable() :: binary()
  def instance_variable, do: @instance_variable

  defp build(source, extra, extra_patchbay, inherited_patchbay) do
    base =
      for name <- @passthrough ++ inherited_patchbay,
          value = Map.get(source, name),
          is_binary(value),
          valid?(value),
          into: %{},
          do: {name, String.to_charlist(value)}

    extras =
      for {name, value} <- extra,
          is_binary(name),
          is_binary(value),
          valid?(value),
          permitted_extra?(name, extra_patchbay),
          into: %{},
          do: {name, String.to_charlist(value)}

    kept = Map.merge(base, extras)

    # The port driver merges `env` with the inherited environment, so every
    # inherited name that is not explicitly kept must be unset. `false` removes
    # a variable from the child's environment.
    removed =
      (Map.keys(source) ++ Map.keys(extra))
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(kept, &1))
      |> Enum.map(&{String.to_charlist(&1), false})

    (kept |> Enum.map(fn {name, value} -> {String.to_charlist(name), value} end) |> Enum.sort()) ++
      Enum.sort(removed)
  end

  defp permitted_extra?(name, extra_patchbay) do
    cond do
      name in @provider_names -> false
      String.starts_with?(name, "PATCHBAY_") -> name in extra_patchbay
      true -> String.starts_with?(name, "LC_") or name in @passthrough
    end
  end

  defp valid?(value), do: :binary.match(value, <<0>>) == :nomatch
end
