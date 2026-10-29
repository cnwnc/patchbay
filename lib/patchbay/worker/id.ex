defmodule Patchbay.Worker.Id do
  @moduledoc """
  Reversible mapping from agent IDs to worker IDs.

  Agent IDs may contain spaces, Unicode, or other bytes that are not valid in
  worker IDs. The mapping keeps already-safe IDs readable under an `agent.`
  namespace and encodes everything else with unpadded URL-safe base64 under an
  `agent-` namespace. The two prefixes are disjoint and both mappings are
  injective, so distinct agent IDs never share a worker ID.
  """

  @max_bytes 128
  @safe_prefix "agent."
  @encoded_prefix "agent-"
  @safe_body_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @doc "Maps an agent ID to a worker ID."
  @spec for_agent(term()) :: {:ok, String.t()} | {:error, term()}
  def for_agent(agent_id) when is_binary(agent_id) do
    cond do
      safe?(agent_id) and byte_size(@safe_prefix <> agent_id) <= @max_bytes ->
        {:ok, @safe_prefix <> agent_id}

      true ->
        encoded = @encoded_prefix <> Base.url_encode64(agent_id, padding: false)

        if byte_size(encoded) <= @max_bytes do
          {:ok, encoded}
        else
          {:error, {:agent_id_too_long, byte_size(agent_id)}}
        end
    end
  end

  def for_agent(_agent_id), do: {:error, :invalid_agent_id}

  @doc "Recovers the agent ID from a worker ID produced by `for_agent/1`."
  @spec agent(term()) :: {:ok, String.t()} | {:error, term()}
  def agent(@safe_prefix <> agent_id) when agent_id != "" do
    if safe?(agent_id), do: {:ok, agent_id}, else: {:error, :invalid_worker_id}
  end

  def agent(@encoded_prefix <> encoded) when encoded != "" do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, agent_id} when agent_id != "" ->
        if String.valid?(agent_id) and
             Base.url_encode64(agent_id, padding: false) == encoded and
             not safe?(agent_id),
           do: {:ok, agent_id},
           else: {:error, :invalid_worker_id}

      _other ->
        {:error, :invalid_worker_id}
    end
  end

  def agent(_worker_id), do: {:error, :invalid_worker_id}

  defp safe?(agent_id) do
    agent_id not in ["", ".", ".."] and
      String.valid?(agent_id) and
      Regex.match?(@safe_body_regex, agent_id)
  end
end
