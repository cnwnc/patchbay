defmodule Patchbay.Worker.Env do
  @moduledoc """
  Explicit, minimal environments for spawned OS processes.

  Children inherit nothing implicitly. Only a short allowlist of ordinary
  process variables is passed through. `PATCHBAY_*` tokens and provider API
  credentials are excluded unless a caller explicitly supplies a permitted
  `PATCHBAY_*` worker variable.

  Worker environments may additionally carry an explicit secret map supplied
  by the worker supervisor. Those names are the only secret values injected;
  `PATCHBAY_SECRET_ENV` records their names so operation children can receive
  the same values without ever seeing the control token.
  """

  alias Patchbay.Secrets

  @passthrough ~w(PATH HOME USER LOGNAME LANG LANGUAGE LC_ALL LC_CTYPE TMPDIR TZ TERM SHELL)

  @instance_variable "PATCHBAY_WORKER_INSTANCE"
  @home_variable "PATCHBAY_HOME"
  @secret_names_variable "PATCHBAY_SECRET_ENV"

  @worker_variables [
    @instance_variable,
    @secret_names_variable
    | ~w(PATCHBAY_HOME PATCHBAY_WORKER_TOKEN PATCHBAY_OPERATIONS PATCHBAY_WORKSPACE PATCHBAY_RESULT_DIR)
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

  Contains only the passthrough allowlist, the worker instance marker,
  `PATCHBAY_HOME`, and the declared secret names from `secret_names`. When
  `source` is the worker's own environment, those names carry the values the
  supervisor injected. The worker token and `PATCHBAY_SECRET_ENV` are never
  included.
  """
  @spec exec_env(map(), [String.t()] | binary()) :: env()
  def exec_env(source \\ System.get_env(), secret_names \\ []) do
    build(
      source,
      %{},
      [],
      [@instance_variable, @home_variable],
      %{},
      normalize_secret_names(secret_names)
    )
  end

  @doc """
  Environment for a worker process started by the worker supervisor.

  Adds the worker configuration variables, including `PATCHBAY_HOME` when the
  manager has one, plus the explicitly supplied secret map. The control-channel
  token is never allowed through, and only valid secret names are kept.
  """
  @spec worker_env(map(), map(), map()) :: env()
  def worker_env(extra \\ %{}, source \\ System.get_env(), secrets \\ %{})
      when is_map(extra) and is_map(secrets) do
    extra = put_secret_names(extra, secrets)
    build(source, extra, @worker_variables, [], secrets, [])
  end

  @doc "Environment variable carrying the supervisor-assigned worker instance marker."
  @spec instance_variable() :: binary()
  def instance_variable, do: @instance_variable

  @doc "Environment variable listing injected secret names, comma-separated."
  @spec secret_names_variable() :: binary()
  def secret_names_variable, do: @secret_names_variable

  @doc "Reads declared secret names from the current environment."
  @spec secret_names(map()) :: [String.t()]
  def secret_names(source \\ System.get_env()) when is_map(source) do
    source
    |> Map.get(@secret_names_variable)
    |> Secrets.parse_names()
  end

  @doc "Encodes names for `PATCHBAY_SECRET_ENV`."
  @spec encode_secret_names([String.t()]) :: String.t()
  def encode_secret_names(names), do: Secrets.encode_names(names)

  defp build(source, extra, extra_patchbay, inherited_patchbay, secrets, secret_names) do
    base_names = Enum.uniq(@passthrough ++ inherited_patchbay ++ secret_names)

    base =
      for name <- base_names,
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

    secret_pairs =
      for {name, value} <- secrets,
          Secrets.valid_variable?(name),
          is_binary(value),
          valid?(value),
          into: %{},
          do: {name, String.to_charlist(value)}

    kept = base |> Map.merge(extras) |> Map.merge(secret_pairs)

    # The port driver merges `env` with the inherited environment, so every
    # inherited name that is not explicitly kept must be unset. `false` removes
    # a variable from the child's environment.
    removed =
      (Map.keys(source) ++ Map.keys(extra) ++ Map.keys(secrets))
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

  defp normalize_secret_names(names) when is_list(names) do
    names
    |> Enum.filter(&Secrets.valid_variable?/1)
    |> Enum.uniq()
    |> Enum.take(Secrets.max_entries())
  end

  defp normalize_secret_names(names), do: Secrets.parse_names(names)

  defp put_secret_names(extra, secrets) when map_size(secrets) == 0, do: extra

  defp put_secret_names(extra, secrets) do
    case Secrets.encode_names(Map.keys(secrets)) do
      "" -> extra
      names -> Map.put(extra, @secret_names_variable, names)
    end
  end

  defp valid?(value), do: :binary.match(value, <<0>>) == :nomatch
end
