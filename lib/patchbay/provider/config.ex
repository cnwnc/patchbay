defmodule Patchbay.Provider.Config do
  @moduledoc """
  Connection settings for an OpenAI-compatible provider.

  Values resolve from explicit options, then `PATCHBAY_LLM_*`, then the common
  `OPENAI_*` equivalents:

    * `PATCHBAY_LLM_BASE_URL`, `OPENAI_BASE_URL`, `OPENAI_API_BASE`
    * `PATCHBAY_LLM_API_KEY`, `OPENAI_API_KEY`
    * `PATCHBAY_LLM_MODEL`, `OPENAI_MODEL`

  No dotenv file is read. Pass `:env` with a string-keyed map to resolve from a
  specific environment instead of `System.get_env/0`.

  Inspecting a config redacts the API key so accidental logging cannot expose
  it.
  """

  @default_base_url "https://api.openai.com/v1"
  @default_timeout 60_000

  @base_url_variables ["PATCHBAY_LLM_BASE_URL", "OPENAI_BASE_URL", "OPENAI_API_BASE"]
  @api_key_variables ["PATCHBAY_LLM_API_KEY", "OPENAI_API_KEY"]
  @model_variables ["PATCHBAY_LLM_MODEL", "OPENAI_MODEL"]

  defstruct base_url: @default_base_url,
            api_key: nil,
            model: nil,
            timeout: @default_timeout

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t() | nil,
          model: String.t() | nil,
          timeout: pos_integer()
        }

  @doc """
  Resolves provider settings.

  Options override the environment. Unknown options are ignored so the same
  keyword list can carry transport or provider selection.
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) when is_list(opts) do
    env = Keyword.get(opts, :env, System.get_env())

    %__MODULE__{
      base_url:
        opts
        |> Keyword.get(:base_url)
        |> value_or_env(env, @base_url_variables)
        |> normalize_base_url(),
      api_key: opts |> Keyword.get(:api_key) |> value_or_env(env, @api_key_variables),
      model: opts |> Keyword.get(:model) |> value_or_env(env, @model_variables),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @doc """
  Returns the chat completions URL for a config.

  A base URL already ending in `/chat/completions` is left alone; otherwise the
  path is appended once.
  """
  @spec chat_completions_url(t()) :: String.t()
  def chat_completions_url(%__MODULE__{base_url: base_url}) when is_binary(base_url) do
    base_url = String.trim_trailing(base_url, "/")

    if String.ends_with?(base_url, "/chat/completions") do
      base_url
    else
      base_url <> "/chat/completions"
    end
  end

  defp value_or_env(nil, env, variables), do: env_value(env, variables)
  defp value_or_env(value, _env, _variables), do: value

  defp env_value(env, variables) when is_map(env) do
    Enum.find_value(variables, fn variable ->
      case Map.fetch(env, variable) do
        {:ok, value} when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp normalize_base_url(nil), do: @default_base_url
  defp normalize_base_url(""), do: @default_base_url
  defp normalize_base_url(base_url) when is_binary(base_url), do: base_url
end

defimpl Inspect, for: Patchbay.Provider.Config do
  import Inspect.Algebra

  def inspect(config, opts) do
    api_key =
      case config.api_key do
        nil -> nil
        _value -> "[REDACTED]"
      end

    displayed = config |> Map.from_struct() |> Map.put(:api_key, api_key)
    concat(["#Patchbay.Provider.Config<", to_doc(displayed, opts), ">"])
  end
end
