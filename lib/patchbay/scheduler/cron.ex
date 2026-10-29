defmodule Patchbay.Scheduler.Cron do
  @moduledoc """
  A deliberately small cron parser for five-field schedules.

  Supported field forms are `*`, a number, a range (`a-b`), a step
  (`*/n` or `a-b/n`), and comma-separated lists of those forms. Month and
  weekday names, seconds fields, and the `@daily` shorthands are not
  supported.

  Day-of-month and day-of-week use the usual cron rule: when both fields are
  restricted, either may match. When one field is `*`, the other must match.
  """

  @enforce_keys [:minutes, :hours, :days, :months, :weekdays]
  defstruct [
    :minutes,
    :hours,
    :days,
    :months,
    :weekdays,
    dom_wildcard: false,
    dow_wildcard: false
  ]

  @type t :: %__MODULE__{
          minutes: MapSet.t(0..59),
          hours: MapSet.t(0..23),
          days: MapSet.t(1..31),
          months: MapSet.t(1..12),
          weekdays: MapSet.t(0..6),
          dom_wildcard: boolean(),
          dow_wildcard: boolean()
        }

  @max_years 8

  @doc """
  Parses a five-field cron expression.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, term()}
  def parse(expression) when is_binary(expression) do
    fields =
      expression
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    case fields do
      [minute, hour, day, month, weekday] ->
        with {:ok, minutes} <- parse_field(minute, 0, 59, :minute),
             {:ok, hours} <- parse_field(hour, 0, 23, :hour),
             {:ok, days} <- parse_field(day, 1, 31, :day_of_month),
             {:ok, months} <- parse_field(month, 1, 12, :month),
             {:ok, weekdays} <- parse_field(weekday, 0, 7, :day_of_week) do
          {:ok,
           %__MODULE__{
             minutes: minutes,
             hours: hours,
             days: days,
             months: months,
             weekdays: normalize_weekdays(weekdays),
             dom_wildcard: String.trim(day) == "*",
             dow_wildcard: String.trim(weekday) == "*"
           }}
        end

      other ->
        {:error, {:field_count, length(other)}}
    end
  end

  def parse(_expression), do: {:error, {:invalid_schedule, :not_a_string}}

  @doc """
  Returns the first matching minute strictly after `datetime`.

  The returned `DateTime` is always in UTC. `next_after/2` searches at most
  eight years ahead, so schedules that can never match, such as February 31,
  return an error.
  """
  @spec next_after(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :no_occurrence}
  def next_after(%__MODULE__{} = cron, %DateTime{} = datetime) do
    utc = DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)

    start =
      utc
      |> Map.put(:second, 0)
      |> Map.put(:microsecond, {0, 0})
      |> DateTime.add(60, :second)

    do_next(cron, start, utc.year + @max_years)
  end

  defp do_next(_cron, datetime, limit_year) when datetime.year > limit_year,
    do: {:error, :no_occurrence}

  defp do_next(cron, datetime, limit_year) do
    cond do
      not MapSet.member?(cron.months, datetime.month) ->
        do_next(cron, next_month_start(datetime), limit_year)

      not day_match?(cron, datetime) ->
        do_next(cron, next_day_start(datetime), limit_year)

      not MapSet.member?(cron.hours, datetime.hour) ->
        do_next(cron, next_hour_start(datetime, cron), limit_year)

      not MapSet.member?(cron.minutes, datetime.minute) ->
        do_next(cron, align_minute(datetime, cron), limit_year)

      true ->
        {:ok, datetime}
    end
  end

  defp day_match?(cron, datetime) do
    date = DateTime.to_date(datetime)
    dom = MapSet.member?(cron.days, date.day)
    dow = MapSet.member?(cron.weekdays, cron_weekday(date))

    cond do
      cron.dom_wildcard and cron.dow_wildcard -> true
      cron.dom_wildcard -> dow
      cron.dow_wildcard -> dom
      true -> dom or dow
    end
  end

  defp cron_weekday(date), do: Date.day_of_week(date, :sunday) - 1

  defp next_hour_start(datetime, cron) do
    case Enum.find(sorted(cron.hours), &(&1 > datetime.hour)) do
      nil -> next_day_start(datetime)
      hour -> %{datetime | hour: hour, minute: 0, second: 0, microsecond: {0, 0}}
    end
  end

  defp align_minute(datetime, cron) do
    case Enum.find(sorted(cron.minutes), &(&1 > datetime.minute)) do
      nil ->
        datetime
        |> next_hour_start(cron)
        |> Map.put(:minute, cron.minutes |> sorted() |> hd())
        |> Map.put(:second, 0)
        |> Map.put(:microsecond, {0, 0})

      minute ->
        %{datetime | minute: minute, second: 0, microsecond: {0, 0}}
    end
  end

  defp next_day_start(datetime) do
    date = datetime |> DateTime.to_date() |> Date.add(1)
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end

  defp next_month_start(%DateTime{year: year, month: 12}) do
    DateTime.new!(Date.new!(year + 1, 1, 1), ~T[00:00:00], "Etc/UTC")
  end

  defp next_month_start(%DateTime{year: year, month: month}) do
    DateTime.new!(Date.new!(year, month + 1, 1), ~T[00:00:00], "Etc/UTC")
  end

  defp sorted(set), do: set |> MapSet.to_list() |> Enum.sort()

  defp parse_field(text, min, max, name) do
    text = String.trim(text)

    if text == "" do
      {:error, {:invalid_field, name, text}}
    else
      text
      |> String.split(",", trim: false)
      |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
        case parse_part(part, min, max) do
          {:ok, values} -> {:cont, {:ok, MapSet.union(acc, MapSet.new(values))}}
          :error -> {:halt, {:error, {:invalid_field, name, part}}}
        end
      end)
    end
  end

  defp parse_part("*", min, max), do: {:ok, min..max}

  defp parse_part(part, min, max) do
    with [body | rest] <- String.split(part, "/", parts: 2),
         true <- length(rest) <= 1,
         {:ok, step} <- parse_step(rest),
         {:ok, first, last} <- parse_range(body, min, max) do
      if step == 1 do
        {:ok, first..last}
      else
        {:ok, first..last//step}
      end
    else
      _other -> :error
    end
  end

  defp parse_step([]), do: {:ok, 1}

  defp parse_step([text]) do
    case Integer.parse(text) do
      {step, ""} when step > 0 -> {:ok, step}
      _other -> :error
    end
  end

  defp parse_range("*", min, max), do: {:ok, min, max}

  defp parse_range(body, min, max) do
    case String.split(body, "-", parts: 2) do
      [single] ->
        case parse_value(single, min, max) do
          {:ok, value} -> {:ok, value, value}
          :error -> :error
        end

      [first, last] ->
        with {:ok, first} <- parse_value(first, min, max),
             {:ok, last} <- parse_value(last, min, max),
             true <- first <= last do
          {:ok, first, last}
        else
          _other -> :error
        end
    end
  end

  defp parse_value(text, min, max) do
    case Integer.parse(text) do
      {value, ""} when value >= min and value <= max -> {:ok, value}
      _other -> :error
    end
  end

  defp normalize_weekdays(weekdays) do
    weekdays
    |> MapSet.to_list()
    |> Enum.map(&rem(&1, 7))
    |> MapSet.new()
  end
end
