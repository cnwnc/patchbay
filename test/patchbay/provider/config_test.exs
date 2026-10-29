defmodule Patchbay.Provider.ConfigTest do
  use ExUnit.Case, async: true

  alias Patchbay.Provider.Config

  test "defaults to the public OpenAI endpoint without credentials" do
    assert %Config{
             base_url: "https://api.openai.com/v1",
             api_key: nil,
             model: nil,
             timeout: 60_000
           } = Config.load(env: %{})
  end

  test "PATCHBAY_LLM values win over OPENAI values" do
    env = %{
      "PATCHBAY_LLM_BASE_URL" => "http://patchbay.example/v1",
      "OPENAI_BASE_URL" => "http://openai.example/v1",
      "OPENAI_API_BASE" => "http://api-base.example/v1",
      "PATCHBAY_LLM_API_KEY" => "patchbay-key",
      "OPENAI_API_KEY" => "openai-key",
      "PATCHBAY_LLM_MODEL" => "patchbay-model",
      "OPENAI_MODEL" => "openai-model"
    }

    assert %Config{
             base_url: "http://patchbay.example/v1",
             api_key: "patchbay-key",
             model: "patchbay-model"
           } = Config.load(env: env)
  end

  test "OPENAI equivalents fill gaps and empty values are ignored" do
    env = %{
      "PATCHBAY_LLM_BASE_URL" => "",
      "OPENAI_BASE_URL" => "http://openai.example/v1/",
      "PATCHBAY_LLM_API_KEY" => "",
      "OPENAI_API_KEY" => "openai-key",
      "OPENAI_MODEL" => "openai-model"
    }

    assert %Config{
             base_url: "http://openai.example/v1/",
             api_key: "openai-key",
             model: "openai-model"
           } = Config.load(env: env)
  end

  test "explicit options win over every environment variable" do
    env = %{
      "PATCHBAY_LLM_BASE_URL" => "http://patchbay.example/v1",
      "PATCHBAY_LLM_API_KEY" => "patchbay-key",
      "PATCHBAY_LLM_MODEL" => "patchbay-model"
    }

    assert %Config{
             base_url: "http://explicit.example/v1",
             api_key: "explicit-key",
             model: "explicit-model",
             timeout: 1_000
           } =
             Config.load(
               env: env,
               base_url: "http://explicit.example/v1",
               api_key: "explicit-key",
               model: "explicit-model",
               timeout: 1_000
             )
  end

  test "chat completion URLs append the path once" do
    assert Config.chat_completions_url(%Config{base_url: "http://host/v1"}) ==
             "http://host/v1/chat/completions"

    assert Config.chat_completions_url(%Config{base_url: "http://host/v1/"}) ==
             "http://host/v1/chat/completions"

    assert Config.chat_completions_url(%Config{
             base_url: "http://host/v1/chat/completions"
           }) == "http://host/v1/chat/completions"
  end

  test "inspect redacts the API key" do
    config = Config.load(env: %{"OPENAI_API_KEY" => "sk-very-secret"})
    inspected = inspect(config)

    refute inspected =~ "sk-very-secret"
    assert inspected =~ "[REDACTED]"
  end
end
