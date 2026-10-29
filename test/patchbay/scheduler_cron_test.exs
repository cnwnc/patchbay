defmodule Patchbay.Scheduler.CronTest do
  use ExUnit.Case, async: true

  alias Patchbay.Scheduler.Cron

  defp parse!(expression) do
    assert {:ok, cron} = Cron.parse(expression)
    cron
  end

  defp next!(expression, datetime) do
    assert {:ok, next} = Cron.next_after(parse!(expression), datetime)
    next
  end

  test "finds the next daily occurrence" do
    assert next!("0 7 * * *", ~U[2026-01-01 06:59:30Z]) == ~U[2026-01-01 07:00:00Z]
    assert next!("0 7 * * *", ~U[2026-01-01 07:00:00Z]) == ~U[2026-01-02 07:00:00Z]
  end

  test "supports steps" do
    assert next!("*/15 * * * *", ~U[2026-01-01 10:07:00Z]) == ~U[2026-01-01 10:15:00Z]
    assert next!("0 */6 * * *", ~U[2026-01-01 07:00:00Z]) == ~U[2026-01-01 12:00:00Z]
  end

  test "supports ranges, lists, and weekday ranges" do
    assert next!("5,10-12 * * * *", ~U[2026-01-01 10:06:00Z]) == ~U[2026-01-01 10:10:00Z]
    assert next!("0 9-17 * * 1-5", ~U[2026-01-02 18:00:00Z]) == ~U[2026-01-05 09:00:00Z]
  end

  test "treats Sunday as both 0 and 7" do
    assert next!("0 0 * * 0", ~U[2026-01-02 00:00:00Z]) == ~U[2026-01-04 00:00:00Z]
    assert next!("0 0 * * 7", ~U[2026-01-02 00:00:00Z]) == ~U[2026-01-04 00:00:00Z]
  end

  test "day-of-month and day-of-week match either field when both are restricted" do
    assert next!("0 0 13 * 1", ~U[2026-02-03 00:00:00Z]) == ~U[2026-02-09 00:00:00Z]
    assert next!("0 0 13 * 1", ~U[2026-02-10 00:00:00Z]) == ~U[2026-02-13 00:00:00Z]
  end

  test "rejects unsupported or malformed schedules" do
    assert {:error, {:field_count, 4}} = Cron.parse("0 7 * *")
    assert {:error, {:field_count, 6}} = Cron.parse("0 0 7 * * *")
    assert {:error, {:invalid_field, :minute, "60"}} = Cron.parse("60 * * * *")
    assert {:error, {:invalid_field, :day_of_week, "8"}} = Cron.parse("0 0 * * 8")
    assert {:error, {:invalid_field, :minute, "*/0"}} = Cron.parse("*/0 * * * *")
    assert {:error, {:invalid_field, :month, "JAN"}} = Cron.parse("0 0 * JAN *")
  end

  test "returns no occurrence for an impossible date" do
    assert {:error, :no_occurrence} =
             Cron.next_after(parse!("0 0 31 2 *"), ~U[2026-01-01 00:00:00Z])
  end
end
