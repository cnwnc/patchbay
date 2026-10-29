defmodule Patchbay.ContextCompaction.Split do
  @moduledoc """
  Splits a message list into a dropped prefix and a retained recent suffix.

  Messages are first collected into atomic turns. An assistant message that
  requests tools belongs to the same turn as the tool results answering those
  calls, so a turn is either retained whole or dropped whole. Incomplete or
  orphaned tool turns are omitted rather than half-retained.
  """

  alias Patchbay.ContextCompaction.Tokens
  alias Patchbay.Provider.{Message, ToolCall}

  @type result :: %{retained: [Message.t()], dropped: [Message.t()]}

  @doc """
  Retains the newest complete turns that fit in `target_tokens`.

  The most recent complete turn is always retained, even when it alone exceeds
  the target. The returned `:retained` list is the current conversation suffix;
  `:dropped` is the prefix that a summary must replace.
  """
  @spec split([Message.t()], non_neg_integer()) :: result()
  def split(messages, target_tokens)
      when is_list(messages) and is_integer(target_tokens) and target_tokens >= 0 do
    {kept, dropped, _tokens, _full?} =
      messages
      |> groups()
      |> Enum.reverse()
      |> Enum.reduce({[], [], 0, false}, fn group, {kept, dropped, tokens, full?} ->
        group_tokens = Tokens.estimate(group)

        cond do
          full? ->
            {kept, [group | dropped], tokens, true}

          kept == [] or tokens + group_tokens <= target_tokens ->
            {[group | kept], dropped, tokens + group_tokens, false}

          true ->
            {kept, [group | dropped], tokens, true}
        end
      end)

    %{retained: List.flatten(kept), dropped: List.flatten(dropped)}
  end

  @doc false
  @spec groups([Message.t()]) :: [[Message.t()]]
  def groups(messages) when is_list(messages) do
    messages
    |> do_groups([], nil)
    |> Enum.reverse()
  end

  defp do_groups([], groups, nil), do: groups
  defp do_groups([], groups, open), do: close(groups, open)

  defp do_groups(
         [%Message{role: :tool, tool_call_id: id} = message | rest],
         groups,
         %{pending: pending} = open
       )
       when is_binary(id) do
    if id in pending do
      open = %{open | messages: [message | open.messages], pending: List.delete(pending, id)}
      do_groups(rest, groups, open)
    else
      do_groups(rest, groups, open)
    end
  end

  defp do_groups([%Message{role: :assistant, tool_calls: calls} = message | rest], groups, open)
       when calls != [] do
    groups = close(groups, open)

    case call_ids(calls) do
      {:ok, ids} ->
        do_groups(rest, groups, %{messages: [message], pending: ids})

      :invalid ->
        do_groups(rest, groups, nil)
    end
  end

  defp do_groups([message | rest], groups, open) do
    do_groups(rest, [[message] | close(groups, open)], nil)
  end

  defp close(groups, nil), do: groups

  defp close(groups, %{messages: messages, pending: []}),
    do: [Enum.reverse(messages) | groups]

  defp close(groups, %{pending: _pending}), do: groups

  defp call_ids(calls) do
    ids =
      Enum.map(calls, fn
        %ToolCall{id: id, name: name} when is_binary(id) and id != "" and is_binary(name) -> id
        _call -> nil
      end)

    if Enum.all?(ids, &is_binary/1) and Enum.uniq(ids) == ids do
      {:ok, ids}
    else
      :invalid
    end
  end
end
