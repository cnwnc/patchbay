defmodule Patchbay.Config.Structured do
  @moduledoc """
  A form-shaped view of an agent definition and the TOML edits it produces.

  The structured editor loads an existing, valid `agent.toml` through
  `TomlElixir.Document`, so unchanged text, comments, key order, and tables the
  form does not cover survive a save. Only the fields represented by the form
  are rewritten. Removed toolkit, operation, hook, argument, and result
  entries are deleted from the document.

  The form covers the practical agent vocabulary: model name, provider, and
  reasoning; lifecycle kind, schedule, overlap, catch-up, and init/finalize
  hooks; environment packages; toolkits with native config (filesystem root,
  memory namespace, secret-environment references) and inline fixed
  operations whose model-facing arguments carry types, enum values, and
  required flags; context recovery vocabulary and compaction thresholds;
  teardown, budgets, and results with dependencies and extensions.
  """

  alias Patchbay.ContextStore
  alias Patchbay.Definition
  alias Patchbay.Definition.Error
  alias Patchbay.Secrets.Env
  alias Patchbay.Toolkit.Manifest
  alias Patchbay.Toolkit.Name
  alias Patchbay.Toolkit.Native.Filesystem
  alias Patchbay.Toolkit.Registry
  alias TomlElixir.Document

  @lifecycle_kinds ["one-shot", "scheduled", "perpetual"]
  @result_forms ["prose", "number", "url", "file"]
  @overlaps ["forbid"]
  @catch_ups ["none", "once", "all"]
  @workspace_actions ["retain", "export", "destroy"]
  @hook_kinds ["init", "finalize"]
  @operation_reserved_keys ["name", "executable", "argv", "arguments", "description"]
  @argument_types ["string", "number", "integer", "boolean", "enum", "path", "file", "directory"]
  @argument_name_regex ~r/\A[A-Za-z_][A-Za-z0-9_-]*\z/
  @env_line_regex ~r/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/
  @filesystem_toolkit "filesystem"
  @memory_toolkit "personal-memory"
  @secret_toolkit "secret-env"

  @type form :: %{String.t() => term()}
  @type hook :: %{String.t() => term()}

  @doc """
  Context strings that restore prior context.

  Every accepted `[context]` word is exposed even though several currently
  share the `keep` behavior; `Patchbay.ContextStore` matches them.
  """
  @spec context_keep_values() :: [String.t()]
  def context_keep_values, do: ContextStore.keep_values()

  @doc "Context strings that start a run without prior context."
  @spec context_reset_values() :: [String.t()]
  def context_reset_values, do: ContextStore.reset_values()

  @doc "Hook lists the lifecycle section edits: `init` and `finalize`."
  @spec hook_kinds() :: [String.t()]
  def hook_kinds, do: @hook_kinds

  @doc "Accepted operation argument types."
  @spec argument_types() :: [String.t()]
  def argument_types, do: @argument_types

  @doc "Accepted `[teardown] workspace` actions."
  @spec workspace_actions() :: [String.t()]
  def workspace_actions, do: @workspace_actions

  @doc """
  `[workspace] enabled` states the workspace section edits.

  Blank means the key is absent, which stays enabled for compatibility with
  existing definitions.
  """
  @spec workspace_states() :: [String.t()]
  def workspace_states, do: ["", "enabled", "disabled"]

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

  @doc """
  The manifest a toolkit name resolves to, including the tool names its
  native part would expose.

  A manifest without `native` exposes no model-facing tools, so `tools` is
  empty for it. An empty manifest `tools` list on a native manifest means
  every tool the native toolkit registers; that expansion comes from the
  registry. Returns `nil` when the name resolves to no manifest.
  """
  @spec manifest_info(String.t() | nil, Path.t() | nil) ::
          %{
            native: String.t() | nil,
            tools: [String.t()],
            operations: [String.t()],
            description: String.t() | nil
          }
          | nil
  def manifest_info(name, config_dir) when is_binary(name) and name != "" do
    case safe_manifest(name, config_dir) do
      {:ok, manifest} ->
        tools =
          cond do
            is_nil(manifest.native) ->
              []

            manifest.tools == [] ->
              manifest.native |> Registry.tools(%{}) |> Enum.map(&tool_name/1)

            true ->
              manifest.tools
          end
          |> Enum.uniq()
          |> Enum.sort()

        %{
          native: manifest.native,
          tools: tools,
          operations: Enum.map(manifest.operations, & &1.name),
          description: manifest.description
        }

      _other ->
        nil
    end
  end

  def manifest_info(_name, _config_dir), do: nil

  defp tool_name(%{name: name}), do: name

  @spec filesystem_toolkit?(String.t() | nil, Path.t() | nil) :: boolean()
  def filesystem_toolkit?(name, config_dir),
    do: native_toolkit?(name, config_dir, @filesystem_toolkit)

  @spec personal_memory_toolkit?(String.t() | nil, Path.t() | nil) :: boolean()
  def personal_memory_toolkit?(name, config_dir),
    do: native_toolkit?(name, config_dir, @memory_toolkit)

  @spec secret_env_toolkit?(String.t() | nil, Path.t() | nil) :: boolean()
  def secret_env_toolkit?(name, config_dir),
    do: native_toolkit?(name, config_dir, @secret_toolkit)

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
      "environment" => section(params, current, "environment", &environment_from_params/2),
      "workspace" => section(params, current, "workspace", &workspace_from_params/2),
      "teardown" => section(params, current, "teardown", &teardown_from_params/2),
      "budgets" => section(params, current, "budgets", &budgets_from_params/2),
      "toolkits" => toolkits_from_params(params["toolkits"], current["toolkits"], current),
      "results" => results_from_params(params["results"], current["results"], current)
    }
  end

  def form_from_params(_params, current), do: current || empty_form()

  @doc """
  Appends a toolkit entry, optionally prefilled with a manifest name.

  A blank name appends a blank row, so custom manifests can still be typed
  by hand.
  """
  @spec add_toolkit(form(), String.t() | nil) :: form()
  def add_toolkit(form, name \\ "") do
    toolkit =
      empty_toolkit()
      |> Map.put("toolkit", if(is_binary(name), do: String.trim(name), else: ""))

    Map.update!(form, "toolkits", &(&1 ++ [toolkit]))
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

  @spec add_argument(form(), non_neg_integer(), non_neg_integer()) :: form()
  def add_argument(form, toolkit_index, operation_index) do
    update_in(
      form,
      [
        "toolkits",
        Access.at(toolkit_index),
        "operations",
        Access.at(operation_index),
        "arguments"
      ],
      fn arguments -> (arguments || []) ++ [empty_argument()] end
    )
  end

  @spec remove_argument(form(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: form()
  def remove_argument(form, toolkit_index, operation_index, argument_index) do
    update_in(
      form,
      [
        "toolkits",
        Access.at(toolkit_index),
        "operations",
        Access.at(operation_index),
        "arguments"
      ],
      fn arguments -> List.delete_at(arguments || [], argument_index) end
    )
  end

  @doc "Appends a lifecycle hook; `kind` must be `\"init\"` or `\"finalize\"`."
  @spec add_hook(form(), String.t()) :: form()
  def add_hook(form, kind) when kind in @hook_kinds do
    update_in(form, ["lifecycle", kind], fn hooks -> (hooks || []) ++ [empty_hook()] end)
  end

  @spec remove_hook(form(), String.t(), non_neg_integer()) :: form()
  def remove_hook(form, kind, index) when kind in @hook_kinds do
    update_in(form, ["lifecycle", kind], &List.delete_at(&1 || [], index))
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
         :ok <- validate_environment(form["environment"]),
         :ok <- validate_workspace(form["workspace"]),
         :ok <- validate_teardown(form["teardown"]),
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
    environment = table(data["environment"])
    teardown = table(data["teardown"])

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
        "catch_up_draft" => "",
        "init" => hooks_from_data(lifecycle["init"]),
        "finalize" => hooks_from_data(lifecycle["finalize"])
      },
      "context" => %{
        "between_runs" => string(context["between-runs"]),
        "prior_runs" => string(context["prior-runs"]),
        "restore_interrupted" => string(context["restore-interrupted"]),
        "threshold" => integer_string(context["threshold"]),
        "target" => integer_string(context["target"])
      },
      "environment" => %{"packages" => list_text(environment["packages"])},
      "workspace" => %{"enabled" => enabled_text(table(data["workspace"])["enabled"])},
      "teardown" => %{"workspace" => string(teardown["workspace"])},
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
        "catch_up_draft" => "",
        "init" => [],
        "finalize" => []
      },
      "context" => %{
        "between_runs" => "",
        "prior_runs" => "",
        "restore_interrupted" => "",
        "threshold" => "",
        "target" => ""
      },
      "environment" => %{"packages" => ""},
      "workspace" => %{"enabled" => ""},
      "teardown" => %{"workspace" => ""},
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

    {schedule, overlap, catch_up, schedule_draft, overlap_draft, catch_up_draft} =
      if kind == "scheduled" do
        {
          schedule_or_draft(schedule, current, "schedule", params),
          schedule_or_draft(overlap, current, "overlap", params),
          schedule_or_draft(catch_up, current, "catch_up", params),
          "",
          "",
          ""
        }
      else
        {
          "",
          "",
          "",
          retained_draft(schedule, current, "schedule", params),
          retained_draft(overlap, current, "overlap", params),
          retained_draft(catch_up, current, "catch_up", params)
        }
      end

    %{
      "kind" => kind,
      "schedule" => schedule,
      "overlap" => overlap,
      "catch_up" => catch_up,
      "schedule_draft" => schedule_draft,
      "overlap_draft" => overlap_draft,
      "catch_up_draft" => catch_up_draft,
      "init" => hooks_from_params(params["init"], current["init"]),
      "finalize" => hooks_from_params(params["finalize"], current["finalize"])
    }
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

  defp environment_from_params(params, current) do
    %{"packages" => text_value(params, current, "packages")}
  end

  defp workspace_from_params(params, current) do
    %{"enabled" => text_value(params, current, "enabled")}
  end

  defp teardown_from_params(params, current) do
    %{"workspace" => text_value(params, current, "workspace")}
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

      %{
        "_key" => Integer.to_string(index),
        "toolkit" => string(toolkit["toolkit"]),
        "description" => string(toolkit["description"]),
        "root" => string(config["root"]),
        "namespace" => string(config["namespace"]),
        "env" => env_text(config["env"]),
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
        "argv" => list_text(operation["argv"]),
        "arguments" => arguments_from_data(operation)
      }
    end)
  end

  defp operations_from_data(_operations), do: []

  defp hooks_from_data(nil), do: []

  defp hooks_from_data(hooks) when is_list(hooks) do
    hooks
    |> Enum.with_index()
    |> Enum.map(fn {hook, index} ->
      hook = table(hook)

      %{
        "_key" => Integer.to_string(index),
        "name" => string(hook["name"]),
        "description" => string(hook["description"]),
        "executable" => string(hook["executable"]),
        "argv" => list_text(hook["argv"])
      }
    end)
  end

  defp hooks_from_data(_hooks), do: []

  # Argument declarations can reach the form through an `arguments` table, an
  # `arguments` array of tables, or child tables under the operation itself.
  defp arguments_from_data(operation) when is_map(operation) do
    declared =
      case Map.get(operation, "arguments") do
        declaration when is_map(declaration) or is_list(declaration) ->
          argument_entries(declaration)

        _other ->
          []
      end

    slots =
      for {name, attr} <- operation,
          is_binary(name) and is_map(attr) and name not in @operation_reserved_keys,
          do: {name, attr}

    (declared ++ slots)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.with_index()
    |> Enum.map(fn {{name, declaration}, index} ->
      %{
        "_key" => Integer.to_string(index),
        "name" => string(name),
        "type" => string(declaration["type"]),
        "values" => list_text(declaration["values"]),
        "required" => required_string(declaration["required"])
      }
    end)
  end

  defp arguments_from_data(_operation), do: []

  @doc false
  def argument_entries(declaration) when is_map(declaration) do
    Enum.map(declaration, fn {name, value} -> {string(name), table(value)} end)
  end

  def argument_entries(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      entry = table(entry)
      {string(entry["name"]), entry}
    end)
  end

  defp required_string(value) do
    case value do
      true -> "true"
      false -> "false"
      "true" -> "true"
      "false" -> "false"
      _other -> ""
    end
  end

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
        "extensions" => extension_text(result["extensions"])
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
        "env" => text_value(raw, current_toolkit, "env"),
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
        "argv" => text_value(raw, current_operation, "argv"),
        "arguments" =>
          arguments_from_params(
            raw["arguments"],
            current_operation["arguments"],
            current_operation
          )
      }
    end)
  end

  defp operations_from_params(_params, current, _all), do: current || []

  defp arguments_from_params(nil, current, _all), do: current || []

  defp arguments_from_params(params, current, all) when is_map(params),
    do: arguments_from_params(map_values(params), current, all)

  defp arguments_from_params(params, current, _all) when is_list(params) do
    current = current || []

    params
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} ->
      raw = table(raw)
      current_argument = current_item(raw, current, index, empty_argument())

      %{
        "name" => text_value(raw, current_argument, "name"),
        "type" => text_value(raw, current_argument, "type"),
        "values" => text_value(raw, current_argument, "values"),
        "required" => text_value(raw, current_argument, "required")
      }
    end)
  end

  defp arguments_from_params(_params, current, _all), do: current || []

  defp hooks_from_params(nil, current), do: current || []

  defp hooks_from_params(params, current) when is_map(params),
    do: hooks_from_params(map_values(params), current)

  defp hooks_from_params(params, current) when is_list(params) do
    current = current || []

    params
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} ->
      raw = table(raw)
      current_hook = current_item(raw, current, index, empty_hook())

      %{
        "_key" => item_key(raw, current_hook),
        "name" => text_value(raw, current_hook, "name"),
        "description" => text_value(raw, current_hook, "description"),
        "executable" => text_value(raw, current_hook, "executable"),
        "argv" => text_value(raw, current_hook, "argv")
      }
    end)
  end

  defp hooks_from_params(_params, current), do: current || []

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
      "env" => "",
      "operations" => []
    }
  end

  defp empty_operation do
    %{
      "_key" => new_key(),
      "name" => "",
      "description" => "",
      "executable" => "",
      "argv" => "",
      "arguments" => []
    }
  end

  defp empty_argument do
    %{
      "name" => "",
      "type" => "string",
      "values" => "",
      "required" => ""
    }
  end

  defp empty_hook do
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
    fun.(table(params[key]), table(current[key]))
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
        with :ok <- validate_hooks(lifecycle["init"] || [], "lifecycle init hook"),
             :ok <- validate_hooks(lifecycle["finalize"] || [], "lifecycle finalize hook") do
          :ok
        end
    end
  end

  defp invalid_optional?(value, allowed) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed != "" and trimmed not in allowed
  end

  defp invalid_optional?(_value, _allowed), do: false

  defp validate_hooks(hooks, label) do
    hooks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {hook, index}, :ok ->
      case validate_hook(hook, "#{label} #{index + 1}") do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp validate_hook(hook, label) do
    name = String.trim(string(hook["name"]))
    executable = String.trim(string(hook["executable"]))
    argv = argv_lines(hook["argv"])

    cond do
      name == "" ->
        {:error, "#{label} requires a name."}

      not Name.valid?(name) ->
        {:error, "#{label} name must use letters, digits, underscores, or hyphens."}

      executable != "" and Path.type(executable) != :absolute ->
        {:error, "#{label} executable must be an absolute path."}

      executable == "" and argv == [] ->
        {:error, "#{label} requires argv when no executable is set."}

      executable == "" and Path.type(List.first(argv)) != :absolute ->
        {:error, "#{label} argv must start with an absolute path to the executable."}

      true ->
        :ok
    end
  end

  defp validate_environment(environment) do
    packages = value_lines(environment["packages"])

    case packages -- Enum.uniq(packages) do
      [] ->
        :ok

      [duplicate | _rest] ->
        {:error, "Environment package #{inspect(duplicate)} is declared more than once."}
    end
  end

  defp validate_teardown(teardown) do
    value = String.trim(string(teardown["workspace"]))

    if value == "" or value in @workspace_actions do
      :ok
    else
      {:error, "Teardown workspace must be retain, export, or destroy when set."}
    end
  end

  defp validate_workspace(workspace) do
    value = String.trim(string(workspace["enabled"]))

    if value in ["", "enabled", "disabled"] do
      :ok
    else
      {:error, "Workspace enabled must be empty, enabled, or disabled."}
    end
  end

  defp enabled_text(nil), do: ""
  defp enabled_text(true), do: "enabled"
  defp enabled_text(false), do: "disabled"
  defp enabled_text(value) when is_binary(value), do: string(value)
  defp enabled_text(_value), do: ""

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
    toolkit
    |> validate_manifest(index, config_dir)
    |> validate_toolkit_env(toolkit, index, config_dir)
  end

  defp validate_manifest(toolkit, index, config_dir) do
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

  defp validate_toolkit_env(:ok, toolkit, index, _config_dir) do
    case value_lines(toolkit["env"]) do
      [] -> :ok
      entries -> validate_env_entries(entries, "Toolkit #{index + 1}")
    end
  end

  defp validate_toolkit_env({:error, _message} = error, _toolkit, _index, _config_dir), do: error

  defp validate_env_entries(entries, label) do
    declarations = Enum.map(entries, &parse_env_line/1)

    with :ok <- check_env_line_errors(declarations, label),
         :ok <- check_env_duplicates(declarations, label),
         {:ok, _checks} <- env_checks(declarations) do
      :ok
    else
      {:error, reason} -> {:error, "#{label} #{reason}"}
    end
  end

  defp parse_env_line(entry) do
    case Regex.run(@env_line_regex, String.trim(entry)) do
      [_, variable, reference] -> {String.trim(variable), String.trim(reference)}
      nil -> :invalid
    end
  end

  defp check_env_line_errors(declarations, _label) do
    if :invalid in declarations do
      {:error, "secret references must use NAME=secret://<name> lines."}
    else
      :ok
    end
  end

  defp check_env_duplicates(declarations, _label) do
    variables = Enum.map(declarations, &elem(&1, 0))

    case variables -- Enum.uniq(variables) do
      [] -> :ok
      [duplicate | _rest] -> {:error, "declares env #{inspect(duplicate)} more than once."}
    end
  end

  # `Patchbay.Secrets.Env` validates variable names and secret reference
  # shape without ever echoing the declared reference.
  defp env_checks(declarations) do
    case Env.validate_config(%{"env" => Map.new(declarations)}) do
      :ok -> {:ok, declarations}
      {:error, path, message} -> {:error, env_path_message(path, message)}
    end
  catch
    kind, reason -> {:error, "secret references are invalid: #{inspect({kind, reason})}"}
  end

  defp env_path_message(path, message) do
    case path |> List.last() |> string() do
      "" -> "env #{message}"
      variable -> "env #{inspect(variable)} #{message}"
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
        validate_arguments(operation["arguments"] || [], label)
    end
  end

  defp validate_arguments(arguments, label) do
    arguments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {argument, index}, :ok ->
      case validate_argument(argument, "#{label} argument #{index + 1}") do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> duplicate_argument_names(arguments, label)
      error -> error
    end
  end

  defp validate_argument(argument, label) do
    name = String.trim(string(argument["name"]))
    type = String.trim(string(argument["type"]))
    values = value_lines(argument["values"])
    required = String.trim(string(argument["required"]))

    cond do
      name == "" ->
        {:error, "#{label} requires a name."}

      not Regex.match?(@argument_name_regex, name) ->
        {:error, "#{label} name must start with a letter or underscore."}

      type not in @argument_types ->
        {:error, "#{label} type must be one of #{Enum.join(Enum.sort(@argument_types), ", ")}."}

      type == "enum" and values == [] ->
        {:error, "#{label} requires at least one enum value."}

      type != "enum" and values != [] ->
        {:error, "#{label} values are only valid for an enum argument."}

      required not in ["", "true", "false"] ->
        {:error, "#{label} required must be true or false when set."}

      true ->
        :ok
    end
  end

  defp duplicate_argument_names(arguments, label) do
    names = Enum.map(arguments, &String.trim(string(&1["name"])))

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [duplicate | _rest] ->
        {:error, "#{label} declares argument #{inspect(duplicate)} more than once."}
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
         {:ok, document} <- apply_hooks(document, form["lifecycle"]),
         {:ok, document} <- apply_context(document, form["context"]),
         {:ok, document} <- apply_environment(document, form["environment"]),
         {:ok, document} <- apply_workspace(document, form["workspace"]),
         {:ok, document} <- apply_teardown(document, form["teardown"]),
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

  # Hooks live in `[[lifecycle.init]]` and `[[lifecycle.finalize]]. Each list
  # is edited with the same stable-index deletion the toolkit lists use.
  defp apply_hooks(document, lifecycle) do
    Enum.reduce_while(@hook_kinds, {:ok, document}, fn kind, {:ok, document} ->
      case apply_hook_list(document, lifecycle, kind) do
        {:ok, document} -> {:cont, {:ok, document}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_hook_list(document, lifecycle, kind) do
    hooks = lifecycle[kind] || []
    existing = map_list(Document.get(document, ["lifecycle", kind], []))
    retained = retained_indexes(hooks, length(existing))

    with {:ok, document} <-
           delete_missing(document, ["lifecycle", kind], length(existing), retained) do
      desired =
        hooks
        |> Enum.with_index()
        |> Enum.map(fn {hook, index} ->
          build_hook(existing_item(hook, existing, index), hook)
        end)

      put_list(document, ["lifecycle", kind], desired)
    end
  end

  defp build_hook(existing, hook) do
    existing
    |> table()
    |> Map.put("name", String.trim(string(hook["name"])))
    |> put_key("description", hook["description"])
    |> put_key("executable", hook["executable"])
    |> Map.put("argv", argv_lines(hook["argv"]))
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

  defp apply_environment(document, environment) do
    put_list(document, ["environment", "packages"], value_lines(environment["packages"]))
  end

  # A blank state keeps the key absent, so older definitions stay enabled
  # without being rewritten on every save.
  defp apply_workspace(document, workspace) do
    case String.trim(string(workspace["enabled"])) do
      "" -> delete(document, ["workspace", "enabled"])
      "disabled" -> Document.put(document, ["workspace", "enabled"], false)
      "enabled" -> Document.put(document, ["workspace", "enabled"], true)
      _other -> {:error, "Workspace enabled must be empty, enabled, or disabled."}
    end
  end

  defp apply_teardown(document, teardown) do
    put_string(document, ["teardown", "workspace"], teardown["workspace"])
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

    config =
      existing
      |> table_in("config")
      |> toolkit_config(toolkit, name, config_dir)

    existing = put_map(existing, "config", config)
    operations = build_operations(existing["operations"], toolkit["operations"] || [])
    put_map(existing, "operations", operations)
  end

  defp toolkit_config(config, toolkit, name, config_dir) do
    config =
      cond do
        filesystem_toolkit?(name, config_dir) ->
          Map.put(config, "root", String.trim(string(toolkit["root"])))

        personal_memory_toolkit?(name, config_dir) ->
          put_key(config, "namespace", toolkit["namespace"])

        true ->
          config
      end

    if secret_env_toolkit?(name, config_dir) or is_map(config["env"]) do
      put_map(config, "env", env_map(toolkit["env"]))
    else
      config
    end
  end

  defp env_map(value) do
    value
    |> value_lines()
    |> Enum.map(fn line ->
      case Regex.run(@env_line_regex, String.trim(line)) do
        [_, variable, reference] -> {String.trim(variable), String.trim(reference)}
        nil -> {String.trim(line), ""}
      end
    end)
    |> Map.new()
  end

  defp build_operations(existing_operations, operations) do
    existing_operations = map_list(existing_operations)

    operations
    |> Enum.with_index()
    |> Enum.map(fn {operation, index} ->
      existing = table(existing_item(operation, existing_operations, index))

      existing
      |> Map.put("name", String.trim(string(operation["name"])))
      |> put_key("description", operation["description"])
      |> put_key("executable", operation["executable"])
      |> Map.put("argv", argv_lines(operation["argv"]))
      |> put_arguments(operation["arguments"] || [])
    end)
  end

  # Model-facing arguments are rewritten under one `arguments` table. Any
  # child-table declarations from the source are folded into it, because a
  # document must not carry both forms at once.
  defp put_arguments(existing, desired) do
    by_name = existing |> existing_arguments() |> Map.new()
    existing = strip_argument_tables(existing)
    declared = declared_arguments(desired, by_name)

    if declared == %{},
      do: Map.delete(existing, "arguments"),
      else: Map.merge(existing, declared)
  end

  defp declared_arguments(operations, by_name) do
    arguments =
      operations
      |> Enum.map(fn argument ->
        name = String.trim(string(argument["name"]))
        {name, build_argument(Map.get(by_name, name, %{}), argument)}
      end)
      |> Map.new()

    if arguments == %{}, do: %{}, else: %{"arguments" => arguments}
  end

  defp build_argument(declaration, form_argument) do
    type = String.trim(string(form_argument["type"]))

    declaration
    |> Map.put("type", type)
    |> Map.drop(["values"])
    |> for_enum_values(type, form_argument)
    |> hold_required(form_argument)
  end

  defp for_enum_values(declaration, "enum", form_argument) do
    Map.put(declaration, "values", value_lines(form_argument["values"]))
  end

  defp for_enum_values(declaration, _type, _form_argument), do: declaration

  defp hold_required(declaration, form_argument) do
    case form_argument["required"] do
      "true" -> Map.put(declaration, "required", true)
      "false" -> Map.put(declaration, "required", false)
      _other -> Map.delete(declaration, "required")
    end
  end

  defp existing_arguments(existing) do
    from_arguments =
      case Map.get(existing, "arguments") do
        declaration when is_map(declaration) or is_list(declaration) ->
          argument_entries(declaration)

        _other ->
          []
      end

    slots =
      for {name, attr} <- existing,
          is_binary(name) and is_map(attr) and name not in @operation_reserved_keys,
          do: {name, attr}

    from_arguments ++ slots
  end

  defp strip_argument_tables(existing) do
    existing
    |> Enum.reject(fn
      {name, value}
      when is_binary(name) and is_map(value) and name not in @operation_reserved_keys ->
        true

      {_name, _value} ->
        false
    end)
    |> Map.new()
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

  # A `""` line declares the empty-string extension, which matches files
  # without any extension. Blank lines are ignored.
  defp extension_lines(value) do
    value
    |> string()
    |> String.split("\n")
    |> Enum.map(&String.trim(&1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn
      "\"\"" -> ""
      extension -> extension
    end)
  end

  defp extension_text(nil), do: ""

  defp extension_text(extensions) when is_list(extensions) do
    extensions
    |> Enum.map(fn
      "" -> "\"\""
      extension -> string(extension)
    end)
    |> Enum.join("\n")
  end

  defp extension_text(_extensions), do: ""

  defp value_lines(value) do
    value
    |> string()
    |> String.split("\n")
    |> Enum.map(&String.trim(&1))
    |> Enum.reject(&(&1 == ""))
  end

  defp list_text(nil), do: ""

  defp list_text(list) when is_list(list) do
    list |> Enum.map(&string/1) |> Enum.join("\n")
  end

  defp list_text(_list), do: ""

  defp env_text(nil), do: ""

  defp env_text(env) when is_map(env) do
    env
    |> Enum.map(fn {variable, reference} -> "#{string(variable)}=#{string(reference)}" end)
    |> Enum.sort()
    |> Enum.join("\n")
  end

  defp env_text(_env), do: ""

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

  defp table_in(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end
end
