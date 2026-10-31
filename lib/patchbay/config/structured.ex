defmodule Patchbay.Config.Structured do
  @moduledoc """
  A form-shaped view of an agent definition and the TOML edits it produces.

  The structured editor loads an existing, valid `agent.toml` through
  `TomlElixir.Document`, so unchanged text, comments, key order, and tables the
  form does not cover survive a save. Only the fields represented by the form
  are rewritten. Removed toolkit, operation, and result entries are deleted
  from the document.
  """

  alias Patchbay.Definition
  alias Patchbay.Definition.Error
  alias Patchbay.Toolkit.Manifest
  alias Patchbay.Toolkit.Name
  alias Patchbay.Toolkit.Native.Filesystem
  alias TomlElixir.Document

  @lifecycle_kinds ["one-shot", "scheduled", "perpetual"]
  @result_forms ["prose", "number", "url", "file"]
  @overlaps ["forbid"]
  @catch_ups ["none", "once", "all"]

  @type form :: %{String.t() => term()}

  @spec load(String.t(), Path.t() | nil, String.t()) ::
          {:ok, %{document: Document.t(), form: form()}} | {:error, String.t()}
  def load(source, config_dir, id) when is_binary(source) do
    case Document.parse(source) do
      {:ok, document} ->
        form = document |> Document.to_map() |> form_from_data(config_dir)
        form = Map.put(form, "id", id)
        {:ok, %{document: document, form: form}}

      {:error, exception} ->
        {:error, "Cannot parse agent.toml: #{Exception.message(exception)}"}
    end
  end

  @spec toolkit_names(Path.t() | nil) :: [String.t()]
  def toolkit_names(config_dir) do
    opts = if is_binary(config_dir), do: [config_root: config_dir], else: []
    from_dirs = opts |> Manifest.dirs() |> Enum.flat_map(&manifest_files/1)

    (Manifest.builtin_names() ++ from_dirs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec filesystem_toolkit?(String.t() | nil, Path.t() | nil) :: boolean()
  def filesystem_toolkit?(name, config_dir), do: native_toolkit?(name, config_dir, "filesystem")

  @spec personal_memory_toolkit?(String.t() | nil, Path.t() | nil) :: boolean()
  def personal_memory_toolkit?(name, config_dir),
    do: native_toolkit?(name, config_dir, "personal-memory")

  defp native_toolkit?(name, config_dir, native) when is_binary(name) and name != "" do
    case safe_manifest(name, config_dir) do
      {:ok, %{native: ^native}} -> true
      _other -> false
    end
  end

  defp native_toolkit?(_name, _config_dir, _native), do: false

  @spec form_from_params(form() | nil, form()) :: form()
  def form_from_params(params, current) when is_map(params) do
    current = current || empty_form()

    %{
      "id" => text(params, current, "id"),
      "model" => section(params, current, "model", &model_from_params/2),
      "lifecycle" => section(params, current, "lifecycle", &lifecycle_from_params/2),
      "context" => section(params, current, "context", &context_from_params/2),
      "budgets" => section(params, current, "budgets", &budgets_from_params/2),
      "toolkits" => toolkits_from_params(params["toolkits"], current["toolkits"], current),
      "results" => results_from_params(params["results"], current["results"], current)
    }
  end

  def form_from_params(_params, current), do: current || empty_form()

  @spec add_toolkit(form()) :: form()
  def add_toolkit(form) do
    Map.update!(form, "toolkits", &(&1 ++ [empty_toolkit()]))
  end

  @spec remove_toolkit(form(), non_neg_integer()) :: form()
  def remove_toolkit(form, index) do
    Map.update!(form, "toolkits", &List.delete_at(&1, index))
  end

  @spec add_operation(form(), non_neg_integer()) :: form()
  def add_operation(form, toolkit_index) do
    update_in(form, ["toolkits", Access.at(toolkit_index), "operations"], fn operations ->
      (operations || []) ++ [empty_operation()]
    end)
  end

  @spec remove_operation(form(), non_neg_integer(), non_neg_integer()) :: form()
  def remove_operation(form, toolkit_index, operation_index) do
    update_in(form, ["toolkits", Access.at(toolkit_index), "operations"], fn operations ->
      List.delete_at(operations || [], operation_index)
    end)
  end

  @spec add_result(form()) :: form()
  def add_result(form) do
    Map.update!(form, "results", &(&1 ++ [empty_result()]))
  end

  @spec remove_result(form(), non_neg_integer()) :: form()
  def remove_result(form, index) do
    Map.update!(form, "results", &List.delete_at(&1, index))
  end

  @spec build(Document.t(), form(), String.t(), Path.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def build(document, form, id, config_dir) do
    with :ok <- validate(form, id, config_dir),
         {:ok, document} <- apply_form(document, form, config_dir),
         content = Document.to_string(document),
         {:ok, _definition} <- validate_rendered(content, id, config_dir) do
      {:ok, content}
    end
  end

  @spec lifecycle_submission_error(term()) :: :ok | {:error, String.t()}
  def lifecycle_submission_error(params) when is_map(params) do
    case params["lifecycle"] do
      lifecycle when is_map(lifecycle) ->
        kind = normalize_kind(lifecycle["kind"])

        if kind != "scheduled" and
             Enum.any?(
               ["schedule", "overlap", "catch_up"],
               &(String.trim(string(lifecycle[&1])) != "")
             ) do
          {:error, "Schedule, overlap, and catch-up are only valid for a scheduled lifecycle."}
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  def lifecycle_submission_error(_params), do: :ok

  @spec validate(form(), String.t(), Path.t() | nil) :: :ok | {:error, String.t()}
  def validate(form, id, config_dir) do
    with :ok <- validate_id(form, id),
         :ok <- validate_lifecycle(form["lifecycle"]),
         :ok <-
           validate_numbers(form["context"], "Context", [
             ["threshold", "Threshold"],
             ["target", "Target"]
           ]),
         :ok <-
           validate_numbers(form["budgets"], "Budget", [
             ["run_seconds", "Run seconds"],
             ["tokens", "Tokens"]
           ]),
         :ok <- validate_toolkits(form["toolkits"] || [], config_dir),
         :ok <- validate_results(form["results"] || []) do
      :ok
    end
  end

  @spec render(Document.t(), form(), Path.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def render(document, form, config_dir) do
    with {:ok, document} <- apply_form(document, form, config_dir) do
      {:ok, Document.to_string(document)}
    end
  end

  defp form_from_data(data, config_dir) when is_map(data) do
    model = table(data["model"])
    lifecycle = table(data["lifecycle"])
    context = table(data["context"])
    budgets = table(data["budgets"])

    %{
      "id" => string(data["id"]),
      "model" => %{
        "name" => string(model["name"]),
        "provider" => string(model["provider"]),
        "reasoning" => string(model["reasoning"])
      },
      "lifecycle" => %{
        "kind" => normalize_kind(lifecycle["kind"]),
        "schedule" => string(lifecycle["schedule"]),
        "overlap" => string(lifecycle["overlap"]),
        "catch_up" => string(lifecycle["catch-up"]),
        "schedule_draft" => "",
        "overlap_draft" => "",
        "catch_up_draft" => ""
      },
      "context" => %{
        "between_runs" => string(context["between-runs"]),
        "prior_runs" => string(context["prior-runs"]),
        "restore_interrupted" => string(context["restore-interrupted"]),
        "threshold" => integer_string(context["threshold"]),
        "target" => integer_string(context["target"])
      },
      "budgets" => %{
        "run_seconds" => integer_string(budgets["run-seconds"]),
        "tokens" => integer_string(budgets["tokens"])
      },
      "toolkits" => toolkits_from_data(data["toolkits"], config_dir),
      "results" => results_from_data(data["results"])
    }
  end

  defp form_from_data(_data, _config_dir), do: empty_form()

  defp empty_form do
    %{
      "id" => "",
      "model" => %{"name" => "", "provider" => "", "reasoning" => ""},
      "lifecycle" => %{
        "kind" => "one-shot",
        "schedule" => "",
        "overlap" => "",
        "catch_up" => "",
        "schedule_draft" => "",
        "overlap_draft" => "",
        "catch_up_draft" => ""
      },
      "context" => %{
        "between_runs" => "",
        "prior_runs" => "",
        "restore_interrupted" => "",
        "threshold" => "",
        "target" => ""
      },
      "budgets" => %{"run_seconds" => "", "tokens" => ""},
      "toolkits" => [],
      "results" => []
    }
  end

  defp model_from_params(params, current) do
    %{
      "name" => text_value(params, current, "name"),
      "provider" => text_value(params, current, "provider"),
      "reasoning" => text_value(params, current, "reasoning")
    }
  end

  defp lifecycle_from_params(params, current) do
    params = table(params)
    kind = normalize_kind(text_value(params, current, "kind"))

    schedule = text_value(params, current, "schedule")
    overlap = text_value(params, current, "overlap")
    catch_up = text_value(params, current, "catch_up")

    if kind == "scheduled" do
      %{
        "kind" => kind,
        "schedule" => schedule_or_draft(schedule, current, "schedule", params),
        "overlap" => schedule_or_draft(overlap, current, "overlap", params),
        "catch_up" => schedule_or_draft(catch_up, current, "catch_up", params),
        "schedule_draft" => "",
        "overlap_draft" => "",
        "catch_up_draft" => ""
      }
    else
      %{
        "kind" => kind,
        "schedule" => "",
        "overlap" => "",
        "catch_up" => "",
        "schedule_draft" => retained_draft(schedule, current, "schedule", params),
        "overlap_draft" => retained_draft(overlap, current, "overlap", params),
        "catch_up_draft" => retained_draft(catch_up, current, "catch_up", params)
      }
    end
  end

  defp schedule_or_draft(value, current, key, params) do
    cond do
      Map.has_key?(params, key) -> value
      value != "" -> value
      true -> string(current[key <> "_draft"])
    end
  end

  defp retained_draft(value, current, key, params) do
    cond do
      Map.has_key?(params, key) and value != "" -> value
      Map.has_key?(params, key) -> string(current[key <> "_draft"])
      string(current[key <> "_draft"]) != "" -> string(current[key <> "_draft"])
      true -> value
    end
  end

  defp context_from_params(params, current) do
    %{
      "between_runs" => text_value(params, current, "between_runs"),
      "prior_runs" => text_value(params, current, "prior_runs"),
      "restore_interrupted" => text_value(params, current, "restore_interrupted"),
      "threshold" => text_value(params, current, "threshold"),
      "target" => text_value(params, current, "target")
    }
  end

  defp budgets_from_params(params, current) do
    %{
      "run_seconds" => text_value(params, current, "run_seconds"),
      "tokens" => text_value(params, current, "tokens")
    }
  end

  defp toolkits_from_data(nil, _config_dir), do: []

  defp toolkits_from_data(toolkits, _config_dir) when is_list(toolkits) do
    toolkits
    |> Enum.with_index()
    |> Enum.map(fn {toolkit, index} ->
      toolkit = table(toolkit)
      config = table(toolkit["config"])
      name = string(toolkit["toolkit"])

      %{
        "_key" => Integer.to_string(index),
        "toolkit" => name,
        "description" => string(toolkit["description"]),
        "root" => string(config["root"]),
        "namespace" => string(config["namespace"]),
        "operations" => operations_from_data(toolkit["operations"])
      }
    end)
  end

  defp toolkits_from_data(_toolkits, _config_dir), do: []

  defp operations_from_data(nil), do: []

  defp operations_from_data(operations) when is_list(operations) do
    operations
    |> Enum.with_index()
    |> Enum.map(fn {operation, index} ->
      operation = table(operation)

      %{
        "_key" => Integer.to_string(index),
        "name" => string(operation["name"]),
        "description" => string(operation["description"]),
        "executable" => string(operation["executable"]),
        "argv" => (operation["argv"] || []) |> Enum.map(&string/1) |> Enum.join("\n")
      }
    end)
  end

  defp operations_from_data(_operations), do: []

  defp results_from_data(nil), do: []

  defp results_from_data(results) when is_list(results) do
    results
    |> Enum.with_index()
    |> Enum.map(fn {result, index} ->
      result = table(result)
      required_by = string(result["required-by"])

      %{
        "_key" => Integer.to_string(index),
        "id" => string(result["id"]),
        "label" => string(result["label"]),
        "form" => string(result["form"]),
        "required" =>
          if(Map.get(result, "required", true) == false and required_by == "",
            do: "false",
            else: "true"
          ),
        "required_by" => required_by,
        "extensions" => (result["extensions"] || []) |> Enum.map(&string/1) |> Enum.join("\n")
      }
    end)
  end

  defp results_from_data(_results), do: []

  defp toolkits_from_params(nil, current, _all), do: current || []

  defp toolkits_from_params(params, current, all) when is_map(params),
    do: toolkits_from_params(map_values(params), current, all)

  defp toolkits_from_params(params, current, _all) when is_list(params) do
    current = current || []

    params
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} ->
      raw = table(raw)
      current_toolkit = current_item(raw, current, index, empty_toolkit())

      %{
        "_key" => item_key(raw, current_toolkit),
        "toolkit" => text_value(raw, current_toolkit, "toolkit"),
        "description" => text_value(raw, current_toolkit, "description"),
        "root" => text_value(raw, current_toolkit, "root"),
        "namespace" => text_value(raw, current_toolkit, "namespace"),
        "operations" =>
          operations_from_params(
            raw["operations"],
            current_toolkit["operations"],
            current_toolkit
          )
      }
    end)
  end

  defp toolkits_from_params(_params, current, _all), do: current || []

  defp operations_from_params(nil, current, _all), do: current || []

  defp operations_from_params(params, current, all) when is_map(params),
    do: operations_from_params(map_values(params), current, all)

  defp operations_from_params(params, current, _all) when is_list(params) do
    current = current || []

    params
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} ->
      raw = table(raw)
      current_operation = current_item(raw, current, index, empty_operation())

      %{
        "_key" => item_key(raw, current_operation),
        "name" => text_value(raw, current_operation, "name"),
        "description" => text_value(raw, current_operation, "description"),
        "executable" => text_value(raw, current_operation, "executable"),
        "argv" => text_value(raw, current_operation, "argv")
      }
    end)
  end

  defp operations_from_params(_params, current, _all), do: current || []

  defp results_from_params(nil, current, _all), do: current || []

  defp results_from_params(params, current, all) when is_map(params),
    do: results_from_params(map_values(params), current, all)

  defp results_from_params(params, current, _all) when is_list(params) do
    current = current || []

    params
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} ->
      raw = table(raw)
      current_result = current_item(raw, current, index, empty_result())
      form = text_value(raw, current_result, "form")

      %{
        "_key" => item_key(raw, current_result),
        "id" => text_value(raw, current_result, "id"),
        "label" => text_value(raw, current_result, "label"),
        "form" => form,
        "required" => text_value(raw, current_result, "required"),
        "required_by" => text_value(raw, current_result, "required_by"),
        "extensions" =>
          if(form == "file", do: text_value(raw, current_result, "extensions"), else: "")
      }
    end)
  end

  defp results_from_params(_params, current, _all), do: current || []

  defp empty_toolkit do
    %{
      "_key" => new_key(),
      "toolkit" => "",
      "description" => "",
      "root" => "",
      "namespace" => "",
      "operations" => []
    }
  end

  defp empty_operation do
    %{
      "_key" => new_key(),
      "name" => "",
      "description" => "",
      "executable" => "",
      "argv" => ""
    }
  end

  defp empty_result do
    %{
      "_key" => new_key(),
      "id" => "",
      "label" => "",
      "form" => "prose",
      "required" => "true",
      "required_by" => "",
      "extensions" => ""
    }
  end

  defp new_key, do: "new-" <> Integer.to_string(System.unique_integer([:positive]))

  defp current_item(raw, current, index, fallback) do
    key = string(table(raw)["_key"])

    found =
      if key == "" do
        nil
      else
        Enum.find(current, &(string(&1["_key"]) == key))
      end

    found || Enum.at(current, index) || fallback
  end

  defp item_key(raw, current) do
    cond do
      string(table(raw)["_key"]) != "" -> string(table(raw)["_key"])
      string(current["_key"]) != "" -> string(current["_key"])
      true -> new_key()
    end
  end

  defp existing_item(form_item, existing, index) do
    case Integer.parse(string(form_item["_key"])) do
      {key_index, ""} when key_index >= 0 -> Enum.at(existing, key_index) || %{}
      _other -> if string(form_item["_key"]) == "", do: Enum.at(existing, index) || %{}, else: %{}
    end
  end

  defp key_index(item) do
    case Integer.parse(string(item["_key"])) do
      {index, ""} when index >= 0 -> index
      _other -> nil
    end
  end

  defp retained_indexes(items, count) do
    items
    |> Enum.map(&key_index/1)
    |> Enum.reject(&(is_nil(&1) or &1 >= count))
    |> MapSet.new()
  end

  defp delete_missing(document, _path, 0, _retained), do: {:ok, document}

  defp delete_missing(document, path, count, retained) do
    removed = for index <- (count - 1)..0//-1, not MapSet.member?(retained, index), do: index

    Enum.reduce_while(removed, {:ok, document}, fn index, {:ok, document} ->
      case Document.delete(document, path ++ [index]) do
        {:ok, document} -> {:cont, {:ok, document}}
        error -> {:halt, error}
      end
    end)
  end

  defp section(params, current, key, fun) do
    fun.(table(params[key]), table(current[key]) || %{})
  end

  defp text(params, current, key) do
    text_value(params, current, key)
  end

  defp text_value(params, current, key) do
    params = table(params)

    case Map.fetch(params, key) do
      {:ok, value} -> string(value)
      :error -> string(current[key])
    end
  end

  defp map_values(map) do
    map
    |> Enum.map(fn {key, value} -> {parse_index(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp parse_index(key) when is_integer(key), do: key

  defp parse_index(key) when is_binary(key) do
    case Integer.parse(key) do
      {index, ""} -> index
      _other -> 1_000_000
    end
  end

  defp parse_index(_key), do: 1_000_000

  defp validate_id(form, id) do
    case String.trim(string(form["id"])) do
      "" -> {:error, "Agent ID is required."}
      ^id -> :ok
      other -> {:error, "Agent ID #{inspect(other)} does not match the selected definition."}
    end
  end

  defp validate_lifecycle(lifecycle) do
    kind = normalize_kind(lifecycle["kind"])

    cond do
      kind not in @lifecycle_kinds ->
        {:error, "Lifecycle kind must be one-shot, scheduled, or perpetual."}

      kind == "scheduled" and String.trim(string(lifecycle["schedule"])) == "" ->
        {:error, "A scheduled lifecycle requires a schedule."}

      kind == "scheduled" and invalid_optional?(lifecycle["overlap"], @overlaps) ->
        {:error, "Lifecycle overlap must be forbid when set."}

      kind == "scheduled" and invalid_optional?(lifecycle["catch_up"], @catch_ups) ->
        {:error, "Lifecycle catch-up must be none, once, or all when set."}

      kind != "scheduled" and
          Enum.any?(
            ["schedule", "overlap", "catch_up"],
            &(String.trim(string(lifecycle[&1])) != "")
          ) ->
        {:error, "Schedule, overlap, and catch-up are only valid for a scheduled lifecycle."}

      true ->
        :ok
    end
  end

  defp invalid_optional?(value, allowed) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed != "" and trimmed not in allowed
  end

  defp invalid_optional?(_value, _allowed), do: false

  defp validate_numbers(section, label, fields) do
    Enum.reduce_while(fields, :ok, fn [key, name], :ok ->
      case non_negative_integer(section[key]) do
        {:ok, _value} -> {:cont, :ok}
        :error -> {:halt, {:error, "#{label} #{name} must be a non-negative integer."}}
      end
    end)
  end

  defp validate_toolkits(toolkits, config_dir) do
    toolkits
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {toolkit, index}, :ok ->
      case validate_toolkit(toolkit, index, config_dir) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp validate_toolkit(toolkit, index, config_dir) do
    label = "Toolkit #{index + 1}"
    name = String.trim(string(toolkit["toolkit"]))

    cond do
      name == "" ->
        {:error, "#{label} requires a toolkit name."}

      true ->
        case safe_manifest(name, config_dir) do
          {:ok, %{native: "filesystem"}} ->
            root = String.trim(string(toolkit["root"]))

            cond do
              root == "" ->
                {:error, "#{label} (#{name}) requires a filesystem root."}

              true ->
                case Filesystem.validate_config(%{"root" => root}, config_dir) do
                  :ok -> validate_operations(toolkit["operations"] || [], label)
                  {:error, message} -> {:error, "#{label} (#{name}) root #{message}."}
                end
            end

          {:ok, _manifest} ->
            validate_operations(toolkit["operations"] || [], label)

          :error ->
            {:error, "#{label} names unknown toolkit #{inspect(name)}."}

          {:error, %Error{} = error} ->
            {:error, "#{label} (#{name}) cannot be loaded: #{Error.message(error)}"}

          {:error, reason} ->
            {:error, "#{label} (#{name}) cannot be loaded: #{inspect(reason)}"}
        end
    end
  end

  defp validate_operations(operations, label) do
    operations
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {operation, index}, :ok ->
      case validate_operation(operation, "#{label} operation #{index + 1}") do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> duplicate_operation_names(operations, label)
      error -> error
    end
  end

  defp validate_operation(operation, label) do
    name = String.trim(string(operation["name"]))
    executable = String.trim(string(operation["executable"]))
    argv = argv_lines(operation["argv"])

    cond do
      name == "" ->
        {:error, "#{label} requires a name."}

      not Name.valid?(name) ->
        {:error, "#{label} name must use letters, digits, underscores, or hyphens."}

      executable != "" and Path.type(executable) != :absolute ->
        {:error, "#{label} executable must be an absolute path."}

      executable == "" and argv == [] ->
        {:error, "#{label} requires argv when no executable is set."}

      true ->
        :ok
    end
  end

  defp duplicate_operation_names(operations, label) do
    names = Enum.map(operations, &String.trim(string(&1["name"])))

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [duplicate | _rest] ->
        {:error, "#{label} declares operation #{inspect(duplicate)} more than once."}
    end
  end

  defp validate_results(results) do
    with :ok <- validate_result_fields(results),
         :ok <- validate_result_ids(results),
         :ok <- validate_result_dependencies(results) do
      :ok
    end
  end

  defp validate_result_fields(results) do
    results
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {result, index}, :ok ->
      label = "Result #{index + 1}"
      form = String.trim(string(result["form"]))
      extensions = extension_lines(result["extensions"])

      cond do
        String.trim(string(result["id"])) == "" ->
          {:halt, {:error, "#{label} requires an ID."}}

        String.trim(string(result["label"])) == "" ->
          {:halt, {:error, "#{label} requires a label."}}

        form not in @result_forms ->
          {:halt, {:error, "#{label} form must be prose, number, url, or file."}}

        form != "file" and extensions != [] ->
          {:halt, {:error, "#{label} extensions are only valid for a file result."}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_result_ids(results) do
    ids = Enum.map(results, &String.trim(string(&1["id"])))

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [duplicate | _rest] -> {:error, "Result #{inspect(duplicate)} is declared more than once."}
    end
  end

  defp validate_result_dependencies(results) do
    ids = MapSet.new(Enum.map(results, &String.trim(string(&1["id"]))))

    unknown =
      Enum.find_value(results, fn result ->
        dependency = String.trim(string(result["required_by"]))

        cond do
          dependency == "" -> nil
          dependency == String.trim(string(result["id"])) -> {:self, dependency}
          not MapSet.member?(ids, dependency) -> {:unknown, dependency}
          true -> nil
        end
      end)

    case unknown do
      nil ->
        validate_result_cycles(results)

      {:self, id} ->
        {:error, "Result #{inspect(id)} cannot be required by itself."}

      {:unknown, id} ->
        {:error, "Result required-by references undeclared result #{inspect(id)}."}
    end
  end

  defp validate_result_cycles(results) do
    edges =
      for result <- results,
          id = String.trim(string(result["id"])),
          dependency = String.trim(string(result["required_by"])),
          id != "" and dependency != "",
          into: %{},
          do: {id, dependency}

    case find_cycle(edges) do
      nil -> :ok
      cycle -> {:error, "Result dependency cycle: #{Enum.join(cycle, " -> ")}."}
    end
  end

  defp find_cycle(edges) do
    Enum.find_value(Map.keys(edges), fn node ->
      case walk(node, edges, [], MapSet.new()) do
        {:cycle, cycle} -> cycle
        {:ok, _visited} -> nil
      end
    end)
  end

  defp walk(node, edges, trail, visited) do
    cond do
      node in trail ->
        path = Enum.reverse([node | trail])
        start = Enum.find_index(path, &(&1 == node))
        {:cycle, Enum.drop(path, start)}

      MapSet.member?(visited, node) ->
        {:ok, visited}

      true ->
        visited = MapSet.put(visited, node)

        case Map.get(edges, node) do
          nil ->
            {:ok, visited}

          next ->
            case walk(next, edges, [node | trail], visited) do
              {:cycle, _cycle} = cycle -> cycle
              {:ok, visited} -> {:ok, visited}
            end
        end
    end
  end

  defp apply_form(document, form, config_dir) do
    with {:ok, document} <- apply_model(document, form["model"]),
         {:ok, document} <- apply_lifecycle(document, form["lifecycle"]),
         {:ok, document} <- apply_context(document, form["context"]),
         {:ok, document} <- apply_budgets(document, form["budgets"]),
         {:ok, document} <- apply_toolkits(document, form["toolkits"] || [], config_dir),
         {:ok, document} <- apply_results(document, form["results"] || []) do
      {:ok, document}
    end
  end

  defp apply_model(document, model) do
    name = String.trim(string(model["name"]))

    with {:ok, document} <- apply_model_name(document, name),
         {:ok, document} <- put_string(document, ["model", "provider"], model["provider"]),
         {:ok, document} <- put_string(document, ["model", "reasoning"], model["reasoning"]) do
      {:ok, document}
    end
  end

  defp apply_model_name(document, "") do
    case Document.get(document, ["model", "name"]) do
      nil -> {:ok, document}
      "" -> {:ok, document}
      _existing -> Document.put(document, ["model", "name"], "default")
    end
  end

  defp apply_model_name(document, name) do
    Document.put(document, ["model", "name"], name)
  end

  defp apply_lifecycle(document, lifecycle) do
    kind = normalize_kind(lifecycle["kind"])

    with {:ok, document} <- put_string(document, ["lifecycle", "kind"], kind) do
      if kind == "scheduled" do
        with {:ok, document} <-
               put_string(document, ["lifecycle", "schedule"], lifecycle["schedule"]),
             {:ok, document} <-
               put_string(document, ["lifecycle", "overlap"], lifecycle["overlap"]),
             {:ok, document} <-
               put_string(document, ["lifecycle", "catch-up"], lifecycle["catch_up"]) do
          {:ok, document}
        end
      else
        with {:ok, document} <- delete(document, ["lifecycle", "schedule"]),
             {:ok, document} <- delete(document, ["lifecycle", "overlap"]),
             {:ok, document} <- delete(document, ["lifecycle", "catch-up"]) do
          {:ok, document}
        end
      end
    end
  end

  defp apply_context(document, context) do
    with {:ok, document} <-
           put_string(document, ["context", "between-runs"], context["between_runs"]),
         {:ok, document} <-
           put_string(document, ["context", "prior-runs"], context["prior_runs"]),
         {:ok, document} <-
           put_string(
             document,
             ["context", "restore-interrupted"],
             context["restore_interrupted"]
           ),
         {:ok, document} <- put_integer(document, ["context", "threshold"], context["threshold"]),
         {:ok, document} <- put_integer(document, ["context", "target"], context["target"]) do
      {:ok, document}
    end
  end

  defp apply_budgets(document, budgets) do
    with {:ok, document} <-
           put_integer(document, ["budgets", "run-seconds"], budgets["run_seconds"]),
         {:ok, document} <- put_integer(document, ["budgets", "tokens"], budgets["tokens"]) do
      {:ok, document}
    end
  end

  defp apply_toolkits(document, toolkits, config_dir) do
    existing = map_list(Document.get(document, ["toolkits"], []))
    retained = retained_indexes(toolkits, length(existing))

    with {:ok, document} <- delete_missing(document, ["toolkits"], length(existing), retained),
         {:ok, document} <- delete_missing_operations(document, toolkits, retained) do
      desired =
        toolkits
        |> Enum.with_index()
        |> Enum.map(fn {toolkit, index} ->
          build_toolkit(existing_item(toolkit, existing, index), toolkit, config_dir)
        end)

      put_list(document, ["toolkits"], desired)
    end
  end

  defp delete_missing_operations(document, toolkits, retained) do
    retained
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, document}, fn {original_index, new_index}, {:ok, document} ->
      toolkit = Enum.find(toolkits, &(key_index(&1) == original_index))
      operations = (toolkit && toolkit["operations"]) || []
      path = ["toolkits", new_index, "operations"]
      count = length(map_list(Document.get(document, path, [])))

      case delete_missing(document, path, count, retained_indexes(operations, count)) do
        {:ok, document} -> {:cont, {:ok, document}}
        error -> {:halt, error}
      end
    end)
  end

  defp build_toolkit(existing, toolkit, config_dir) do
    existing = table(existing)
    name = String.trim(string(toolkit["toolkit"]))
    existing = Map.put(existing, "toolkit", name)
    existing = put_key(existing, "description", toolkit["description"])

    config = table(existing["config"])

    config =
      cond do
        filesystem_toolkit?(name, config_dir) ->
          Map.put(config, "root", String.trim(string(toolkit["root"])))

        personal_memory_toolkit?(name, config_dir) ->
          put_key(config, "namespace", toolkit["namespace"])

        true ->
          config
      end

    existing = put_map(existing, "config", config)
    operations = build_operations(existing["operations"], toolkit["operations"] || [])
    put_map(existing, "operations", operations)
  end

  defp build_operations(existing_operations, operations) do
    existing_operations = map_list(existing_operations)

    operations
    |> Enum.with_index()
    |> Enum.map(fn {operation, index} ->
      existing = table(existing_item(operation, existing_operations, index))
      argv = argv_lines(operation["argv"])

      existing
      |> Map.put("name", String.trim(string(operation["name"])))
      |> put_key("description", operation["description"])
      |> put_key("executable", operation["executable"])
      |> Map.put("argv", argv)
    end)
  end

  defp apply_results(document, results) do
    existing = map_list(Document.get(document, ["results"], []))
    retained = retained_indexes(results, length(existing))

    with {:ok, document} <- delete_missing(document, ["results"], length(existing), retained) do
      desired =
        results
        |> Enum.with_index()
        |> Enum.map(fn {result, index} ->
          build_result(existing_item(result, existing, index), result)
        end)

      put_list(document, ["results"], desired)
    end
  end

  defp build_result(existing, result) do
    existing = table(existing)
    required_by = String.trim(string(result["required_by"]))
    form = String.trim(string(result["form"]))

    existing =
      existing
      |> Map.put("id", String.trim(string(result["id"])))
      |> Map.put("label", String.trim(string(result["label"])))
      |> Map.put("form", form)

    existing =
      if required_by == "",
        do: Map.delete(existing, "required-by"),
        else: Map.put(existing, "required-by", required_by)

    existing =
      cond do
        required_by != "" -> Map.delete(existing, "required")
        string(result["required"]) == "false" -> Map.put(existing, "required", false)
        true -> Map.delete(existing, "required")
      end

    extensions = extension_lines(result["extensions"])

    if form == "file" and extensions != [] do
      Map.put(existing, "extensions", extensions)
    else
      Map.delete(existing, "extensions")
    end
  end

  defp put_list(document, path, []), do: delete(document, path)
  defp put_list(document, path, list), do: Document.put(document, path, list)

  defp put_string(document, path, value) do
    case String.trim(string(value)) do
      "" -> delete(document, path)
      value -> Document.put(document, path, value)
    end
  end

  defp put_integer(document, path, value) do
    case non_negative_integer(value) do
      {:ok, nil} -> delete(document, path)
      {:ok, integer} -> Document.put(document, path, integer)
      :error -> {:error, "invalid integer for #{Enum.join(path, ".")}"}
    end
  end

  defp delete(document, path) do
    Document.delete(document, path)
  end

  defp put_key(map, key, value) do
    case String.trim(string(value)) do
      "" -> Map.delete(map, key)
      value -> Map.put(map, key, value)
    end
  end

  defp put_map(map, key, value) when is_map(value) do
    if value == %{}, do: Map.delete(map, key), else: Map.put(map, key, value)
  end

  defp put_map(map, key, value) when is_list(value) do
    if value == [], do: Map.delete(map, key), else: Map.put(map, key, value)
  end

  defp put_map(map, key, value), do: Map.put(map, key, value)

  defp validate_rendered(content, id, config_dir) do
    opts = [
      config_root: config_dir,
      toolkit_dirs: Manifest.dirs(config_root: config_dir)
    ]

    case Definition.parse(content, opts) do
      {:ok, %{id: ^id} = definition} ->
        {:ok, definition}

      {:ok, %{id: other}} ->
        {:error, "Generated definition id #{inspect(other)} does not match #{inspect(id)}."}

      {:error, %Error{} = error} ->
        {:error, Error.message(error)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    exception ->
      {:error, "Generated TOML is invalid: #{Exception.message(exception)}"}
  end

  defp safe_manifest(name, config_dir) do
    Manifest.load(name, config_root: config_dir)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp manifest_files(directory) do
    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(Path.extname(&1) == ".toml"))
        |> Enum.map(&Path.basename(&1, ".toml"))

      {:error, _reason} ->
        []
    end
  end

  defp normalize_kind("one_shot"), do: "one-shot"
  defp normalize_kind(kind) when is_binary(kind), do: String.trim(kind)
  defp normalize_kind(_kind), do: "one-shot"

  defp argv_lines(value) do
    value
    |> string()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&(&1 == ""))
  end

  defp extension_lines(value) do
    value
    |> string()
    |> String.split("\n")
    |> Enum.map(&String.trim(&1))
    |> Enum.reject(&(&1 == ""))
  end

  defp non_negative_integer(nil), do: {:ok, nil}
  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(value) when is_integer(value), do: :error

  defp non_negative_integer(value) do
    case String.trim(string(value)) do
      "" ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {integer, ""} when integer >= 0 -> {:ok, integer}
          _other -> :error
        end
    end
  end

  defp integer_string(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_string(value) when is_binary(value), do: value
  defp integer_string(_value), do: ""

  defp table(value) when is_map(value), do: value
  defp table(_value), do: %{}

  defp map_list(value) when is_list(value), do: value
  defp map_list(_value), do: []

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: value
  defp string(value) when is_integer(value), do: Integer.to_string(value)
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(value), do: to_string(value)
end
