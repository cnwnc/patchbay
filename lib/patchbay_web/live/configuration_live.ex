defmodule PatchbayWeb.ConfigurationLive do
  @moduledoc false

  use PatchbayWeb, :live_view

  import PatchbayWeb.Presenter

  alias Patchbay.Config.Prompt, as: ConfigPrompt
  alias Patchbay.Config.Source
  alias Patchbay.Config.Structured
  alias Patchbay.Definition.Error
  alias Patchbay.DefinitionRegistry

  @pubsub Patchbay.PubSub
  @flash_timeout 6_000

  @draft_assigns [
    :source,
    :editable_source,
    :source_hash,
    :source_path,
    :source_absent?,
    :source_editable?,
    :source_note,
    :source_draft,
    :source_baseline,
    :source_dirty?,
    :editor_tab,
    :structured,
    :structured_base,
    :structured_document,
    :structured_available?,
    :structured_dirty?,
    :structured_note,
    :structured_toolkit_names
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, "config")
    end

    {:ok,
     assign(socket,
       definitions: [],
       failures: [],
       selected: nil,
       snapshot: nil,
       failure: nil,
       source: "",
       editable_source: nil,
       source_hash: nil,
       source_path: nil,
       source_absent?: false,
       source_editable?: false,
       source_note: nil,
       source_draft: nil,
       source_baseline: nil,
       source_dirty?: false,
       editor_tab: "source",
       structured: nil,
       structured_base: nil,
       structured_document: nil,
       structured_available?: false,
       structured_dirty?: false,
       structured_note: nil,
       structured_toolkit_names: [],
       new_toolkit_name: "",
       pending_select: nil,
       config_dir: nil,
       resolved: "",
       prompts: [],
       prompt_files: [],
       prompt_drafts: %{},
       prompt_conflicts: %{},
       scripts: [],
       new_agent_open: false,
       new_agent_id: "",
       new_agent_lifecycle: "one-shot"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_id = params["id"]

    socket =
      if discard_draft?(socket, requested_id) do
        socket
        |> assign(
          source_draft: nil,
          source_dirty?: false,
          structured: nil,
          structured_dirty?: false,
          prompt_drafts: %{},
          prompt_conflicts: %{}
        )
        |> notify(:info, "Discarded unsaved changes to #{socket.assigns.selected}.")
      else
        socket
      end

    {:noreply, load(socket, requested_id)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    cond do
      id == socket.assigns.selected ->
        {:noreply, assign(socket, pending_select: nil)}

      dirty?(socket) ->
        {:noreply, assign(socket, pending_select: id)}

      true ->
        {:noreply, push_patch(socket, to: ~p"/config/#{id}")}
    end
  end

  def handle_event("confirm_select", _params, socket) do
    case socket.assigns.pending_select do
      nil ->
        {:noreply, socket}

      id ->
        socket =
          assign(socket,
            pending_select: nil,
            source_draft: nil,
            source_dirty?: false,
            structured: nil,
            structured_dirty?: false,
            prompt_drafts: %{},
            prompt_conflicts: %{}
          )

        {:noreply, push_patch(socket, to: ~p"/config/#{id}")}
    end
  end

  def handle_event("cancel_select", _params, socket) do
    {:noreply, assign(socket, pending_select: nil)}
  end

  def handle_event("dismiss_flash", %{"kind" => kind}, socket) do
    kind = flash_kind(kind)
    paused = MapSet.delete(paused_flashes(socket), kind)

    {:noreply,
     socket
     |> assign(:paused_flashes, paused)
     |> clear_flash(kind)}
  end

  def handle_event("pause_flash", %{"kind" => kind}, socket) do
    {:noreply,
     assign(socket, :paused_flashes, MapSet.put(paused_flashes(socket), flash_kind(kind)))}
  end

  def handle_event("resume_flash", %{"kind" => kind}, socket) do
    kind = flash_kind(kind)

    socket =
      assign(socket, :paused_flashes, MapSet.delete(paused_flashes(socket), kind))

    case Map.fetch(socket.assigns.flash, kind) do
      {:ok, message} ->
        Process.send_after(self(), {:expire_flash, kind, message}, @flash_timeout)
        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("edit_source", params, socket) do
    {content, _expected_hash} = save_params(params)

    if is_binary(content) do
      dirty? = content != socket.assigns.source_baseline
      {:noreply, assign(socket, source_draft: content, source_dirty?: dirty?)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["source", "structured"] do
    socket =
      if tab == "structured" and not socket.assigns.structured_available? do
        socket
      else
        assign(socket, :editor_tab, tab)
      end

    {:noreply, socket}
  end

  def handle_event("edit_structured", params, socket) do
    socket =
      if socket.assigns.structured do
        socket
        |> assign(:new_toolkit_name, picked_toolkit(params))
        |> update_structured(
          Structured.form_from_params(structured_params(params), socket.assigns.structured)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("add_toolkit", _params, socket) do
    socket =
      if socket.assigns.structured do
        update_structured(
          socket,
          Structured.add_toolkit(socket.assigns.structured, socket.assigns.new_toolkit_name)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("select_new_toolkit", _params, socket), do: {:noreply, socket}

  def handle_event("add_argument", %{"toolkit" => toolkit, "operation" => operation}, socket) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           {:ok, toolkit} <- parse_index(toolkit),
           {:ok, operation} <- parse_index(operation) do
        update_structured(socket, Structured.add_argument(structured, toolkit, operation))
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event(
        "remove_argument",
        %{"toolkit" => toolkit, "operation" => operation, "index" => index},
        socket
      ) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           {:ok, toolkit} <- parse_index(toolkit),
           {:ok, operation} <- parse_index(operation),
           {:ok, index} <- parse_index(index) do
        update_structured(
          socket,
          Structured.remove_argument(structured, toolkit, operation, index)
        )
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("add_hook", %{"hook" => hook}, socket) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           true <- hook in Structured.hook_kinds() do
        update_structured(socket, Structured.add_hook(structured, hook))
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("remove_hook", %{"hook" => hook, "index" => index}, socket) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           true <- hook in Structured.hook_kinds(),
           {:ok, index} <- parse_index(index) do
        update_structured(socket, Structured.remove_hook(structured, hook, index))
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("remove_toolkit", %{"index" => index}, socket) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           {:ok, index} <- parse_index(index) do
        update_structured(socket, Structured.remove_toolkit(structured, index))
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("add_operation", %{"toolkit" => index}, socket) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           {:ok, index} <- parse_index(index) do
        update_structured(socket, Structured.add_operation(structured, index))
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("remove_operation", %{"toolkit" => toolkit, "index" => index}, socket) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           {:ok, toolkit} <- parse_index(toolkit),
           {:ok, index} <- parse_index(index) do
        update_structured(socket, Structured.remove_operation(structured, toolkit, index))
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("add_result", _params, socket) do
    socket =
      if socket.assigns.structured do
        update_structured(socket, Structured.add_result(socket.assigns.structured))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("remove_result", %{"index" => index}, socket) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           {:ok, index} <- parse_index(index) do
        update_structured(socket, Structured.remove_result(structured, index))
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("edit_prompt", params, socket) do
    source = string_param(params["prompt_source"])
    name = string_param(params["prompt_name"])
    content = params["prompt_content"]

    case Enum.find(
           socket.assigns.prompt_files,
           &(Atom.to_string(&1.source) == source and &1.name == name)
         ) do
      nil ->
        {:noreply, socket}

      file when is_binary(content) ->
        key = prompt_key(file.source, file.name)
        existing = Map.get(socket.assigns.prompt_drafts, key)

        draft = %{
          source: source,
          name: name,
          content: content,
          baseline: prompt_draft_baseline(existing, file),
          hash: prompt_draft_hash(existing, Map.get(socket.assigns.prompt_conflicts, key), file)
        }

        drafts = Map.put(socket.assigns.prompt_drafts, key, draft)

        {:noreply,
         socket
         |> assign(prompt_drafts: drafts)
         |> assign(
           prompts:
             prompt_views(
               socket.assigns.prompt_files,
               drafts,
               socket.assigns.prompt_conflicts
             )
         )}

      _file ->
        {:noreply, socket}
    end
  end

  def handle_event("save_prompt", params, socket) do
    {:noreply, save_prompt(socket, params)}
  end

  def handle_event("delete_prompt", params, socket) do
    {:noreply, delete_prompt(socket, params)}
  end

  def handle_event("create_prompt", params, socket) do
    {:noreply, create_prompt(socket, params)}
  end

  def handle_event("save_structured", params, socket) do
    structured_params = params["structured"]

    if socket.assigns.structured do
      form = Structured.form_from_params(structured_params || %{}, socket.assigns.structured)
      socket = update_structured(socket, form)

      case Structured.lifecycle_submission_error(structured_params || %{}) do
        :ok ->
          {:noreply, save_structured(socket, params)}

        {:error, message} ->
          {:noreply, notify(socket, :error, "Structured save rejected: #{message}")}
      end
    else
      {:noreply,
       notify(socket, :error, "Structured save failed: the definition is not available.")}
    end
  end

  @impl true
  def handle_event("new_agent", _params, socket) do
    {:noreply, assign(socket, new_agent_open: true)}
  end

  def handle_event("cancel_new_agent", _params, socket) do
    {:noreply, assign(socket, new_agent_open: false)}
  end

  def handle_event("create_agent", params, socket) do
    {:noreply, create_agent(socket, params)}
  end

  @impl true
  def handle_event(event, params, socket) when event in ["save", "save_source"] do
    {:noreply, save_source(socket, params)}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    socket =
      case safe(fn -> DefinitionRegistry.reload() end) do
        {:ok, report} ->
          Phoenix.PubSub.broadcast_from(@pubsub, self(), "config", {:config, :reloaded})

          notify(
            socket,
            :info,
            "Reloaded: #{length(report.loaded)} loaded, #{length(report.rejected)} rejected, #{length(report.removed)} removed."
          )

        {:error, reason} ->
          notify(socket, :error, "Reload failed: #{error_detail(reason)}")
      end

    {:noreply, load(socket, socket.assigns.selected, reset_source: true, reset_prompts: true)}
  end

  @impl true
  def handle_info({:config, :reloaded}, socket) do
    {:noreply, load(socket, socket.assigns.selected)}
  end

  def handle_info({:expire_flash, kind, message}, socket) do
    expired? =
      not MapSet.member?(paused_flashes(socket), kind) and
        Map.get(socket.assigns.flash, kind) == message

    socket =
      if expired? do
        clear_flash(socket, kind)
      else
        socket
      end

    {:noreply, socket}
  end

  defp load(socket, requested_id, opts \\ []) do
    definitions =
      case safe(fn -> DefinitionRegistry.list() end) do
        definitions when is_list(definitions) -> definitions
        _other -> []
      end

    failures =
      case safe(fn -> DefinitionRegistry.errors() end) do
        failures when is_list(failures) -> failures
        _other -> []
      end

    selected = select_id(definitions, failures, requested_id)
    snapshot = Enum.find(definitions, &(&1.id == selected))
    failure = Enum.find(failures, &(&1.id == selected))
    definition = snapshot && snapshot.definition

    config_dir =
      case safe(fn -> DefinitionRegistry.config() end) do
        %{config_dir: directory} -> directory
        _other -> nil
      end

    {source_info, resolved} =
      case definition do
        nil ->
          failure_data(config_dir, selected, failure)

        definition ->
          definition_data(definition)
      end

    prompt_drafts =
      if selected == socket.assigns.selected and not Keyword.get(opts, :reset_prompts, false),
        do: socket.assigns.prompt_drafts,
        else: %{}

    prompt_conflicts =
      if selected == socket.assigns.selected and not Keyword.get(opts, :reset_prompts, false),
        do: socket.assigns.prompt_conflicts,
        else: %{}

    prompt_files = prompt_files(config_dir, selected)
    scripts = if definition, do: definition.shared_scripts ++ definition.agent_scripts, else: []

    socket
    |> assign(
      definitions: definitions,
      failures: failures,
      selected: selected,
      snapshot: snapshot,
      failure: failure,
      config_dir: config_dir,
      resolved: resolved,
      prompt_files: prompt_files,
      prompt_drafts: prompt_drafts,
      prompt_conflicts: prompt_conflicts,
      prompts: prompt_views(prompt_files, prompt_drafts, prompt_conflicts),
      scripts: scripts
    )
    |> assign(source_assigns(source_info, socket, selected, snapshot, config_dir, opts))
  end

  defp prompt_files(config_dir, selected) do
    if is_binary(config_dir) and is_binary(selected) do
      case safe(fn -> ConfigPrompt.list(config_dir, selected) end) do
        files when is_list(files) -> files
        _other -> []
      end
    else
      []
    end
  end

  defp prompt_views(files, drafts, conflicts) do
    Enum.map(files, fn file ->
      key = prompt_key(file.source, file.name)
      hash = prompt_expected(file, Map.get(drafts, key), Map.get(conflicts, key))

      case Map.get(drafts, key) do
        %{content: content, baseline: baseline} ->
          Map.merge(file, %{draft: content, dirty?: content != baseline, hash: hash})

        _other ->
          Map.merge(file, %{draft: file.content, dirty?: false, hash: hash})
      end
    end)
  end

  defp prompt_expected(_file, %{hash: hash}, _conflict) when is_binary(hash), do: hash
  defp prompt_expected(_file, _draft, hash) when is_binary(hash), do: hash
  defp prompt_expected(file, _draft, _conflict), do: file.hash

  defp prompt_key(source, name), do: "#{source}/#{name}"

  defp save_prompt(socket, params) do
    id = socket.assigns.selected
    source = string_param(params["prompt_source"])
    name = string_param(params["prompt_name"])
    content = params["prompt_content"]
    file = find_prompt(socket, source, name)
    draft = Map.get(socket.assigns.prompt_drafts, prompt_key(source, name))

    cond do
      is_nil(id) or is_nil(socket.assigns.config_dir) ->
        notify(socket, :error, "Prompt save failed: no agent is selected.")

      is_nil(file) ->
        notify(socket, :error, "Prompt save failed: the prompt is no longer listed.")

      is_nil(content) and is_nil(draft) ->
        notify(socket, :error, "Prompt save failed: no content was submitted.")

      true ->
        content = if is_binary(content), do: content, else: draft.content
        expected = prompt_expected_hash(params, file)

        case safe(fn ->
               ConfigPrompt.write(socket.assigns.config_dir, id, source, name, content, expected)
             end) do
          {:ok, _entry} ->
            socket
            |> assign(
              prompt_drafts: Map.delete(socket.assigns.prompt_drafts, prompt_key(source, name)),
              prompt_conflicts:
                Map.delete(socket.assigns.prompt_conflicts, prompt_key(source, name))
            )
            |> reload_prompt_files()
            |> after_prompt_change("Prompt #{name} saved.")

          {:error, :stale} ->
            socket
            |> put_prompt_conflict(prompt_key(source, name), expected)
            |> notify(
              :error,
              "Prompt save conflict: #{name} changed on disk after it was loaded. Reload to review the external change before saving; the current draft will not overwrite it."
            )

          {:error, reason} ->
            notify(socket, :error, "Prompt save failed: #{prompt_error(reason)}")
        end
    end
  end

  defp delete_prompt(socket, params) do
    id = socket.assigns.selected
    source = string_param(params["prompt_source"])
    name = string_param(params["prompt_name"])
    file = find_prompt(socket, source, name)

    cond do
      is_nil(id) or is_nil(socket.assigns.config_dir) ->
        notify(socket, :error, "Prompt delete failed: no agent is selected.")

      is_nil(file) ->
        notify(socket, :error, "Prompt delete failed: the prompt is no longer listed.")

      true ->
        expected = prompt_expected_hash(params, file)

        case safe(fn ->
               ConfigPrompt.delete(socket.assigns.config_dir, id, source, name, expected)
             end) do
          :ok ->
            socket
            |> assign(
              prompt_drafts: Map.delete(socket.assigns.prompt_drafts, prompt_key(source, name)),
              prompt_conflicts:
                Map.delete(socket.assigns.prompt_conflicts, prompt_key(source, name))
            )
            |> reload_prompt_files()
            |> after_prompt_change("Prompt #{name} deleted.")

          {:error, :stale} ->
            socket
            |> put_prompt_conflict(prompt_key(source, name), expected)
            |> notify(
              :error,
              "Prompt delete conflict: #{name} changed on disk after it was loaded. Reload to review the external change."
            )

          {:error, reason} ->
            notify(socket, :error, "Prompt delete failed: #{prompt_error(reason)}")
        end
    end
  end

  defp create_prompt(socket, params) do
    id = socket.assigns.selected
    new_prompt = params["new_prompt"] || %{}
    source = string_param(new_prompt["source"])
    source = if source == "", do: "agent", else: source
    name = string_param(new_prompt["filename"])
    content = new_prompt["content"]
    content = if is_binary(content) and String.trim(content) != "", do: content, else: nil

    cond do
      is_nil(id) or is_nil(socket.assigns.config_dir) ->
        notify(socket, :error, "Prompt create failed: no agent is selected.")

      not ConfigPrompt.valid_filename?(name) ->
        notify(
          socket,
          :error,
          "Prompt create failed: use a top-level .md or .markdown filename without slashes."
        )

      true ->
        case safe(fn ->
               ConfigPrompt.create(socket.assigns.config_dir, id, source, name, content)
             end) do
          {:ok, _entry} ->
            socket
            |> reload_prompt_files()
            |> after_prompt_change("Prompt #{name} created.")

          {:error, :exists} ->
            notify(socket, :error, "Prompt create failed: #{name} already exists.")

          {:error, :not_found} ->
            notify(
              socket,
              :error,
              "Prompt create failed: the agent directory does not exist."
            )

          {:error, reason} ->
            notify(socket, :error, "Prompt create failed: #{prompt_error(reason)}")
        end
    end
  end

  defp find_prompt(socket, source, name) do
    Enum.find(socket.assigns.prompt_files, fn file ->
      Atom.to_string(file.source) == source and file.name == name
    end)
  end

  defp prompt_expected_hash(params, file) do
    case params["expected_hash"] do
      hash when is_binary(hash) and hash != "" -> hash
      _other -> file.hash
    end
  end

  defp reload_prompt_files(socket) do
    files = prompt_files(socket.assigns.config_dir, socket.assigns.selected)

    assign(socket,
      prompt_files: files,
      prompts: prompt_views(files, socket.assigns.prompt_drafts, socket.assigns.prompt_conflicts)
    )
  end

  defp put_prompt_conflict(socket, key, expected_hash) do
    assign(socket, prompt_conflicts: Map.put(socket.assigns.prompt_conflicts, key, expected_hash))
  end

  defp prompt_draft_baseline(existing, file) do
    if is_map(existing), do: Map.get(existing, :baseline, file.content), else: file.content
  end

  defp prompt_draft_hash(existing, conflict, file) do
    cond do
      is_map(existing) and is_binary(Map.get(existing, :hash)) -> existing.hash
      is_binary(conflict) -> conflict
      true -> file.hash
    end
  end

  defp after_prompt_change(socket, message) do
    detail =
      case safe(fn -> DefinitionRegistry.reload_agent(socket.assigns.selected) end) do
        {:ok, _snapshot} ->
          nil

        {:error, %Error{} = error} ->
          " The agent definition is still invalid, so the last good definition remains active: #{Error.message(error)}"

        {:error, :not_found} ->
          " The agent directory was not found during reload."

        {:error, reason} ->
          " Definition reload failed: #{error_detail(reason)}"
      end

    broadcast_reload()
    notify(socket, :info, message <> (detail || ""))
  end

  defp prompt_error(:invalid_filename),
    do: "the filename must be a top-level .md or .markdown file"

  defp prompt_error(:invalid_source), do: "the prompt source is not recognized"
  defp prompt_error(:invalid_id), do: "the agent identifier is not valid"
  defp prompt_error(:unsafe_path), do: "the path is not safe to edit"
  defp prompt_error(:not_found), do: "the file no longer exists"

  defp prompt_error({:io, reason}) when is_atom(reason),
    do: :file.format_error(reason) |> to_string()

  defp prompt_error(reason), do: error_detail(reason)

  defp source_assigns(source_info, socket, selected, snapshot, config_dir, opts) do
    fresh =
      Map.merge(
        %{
          source: source_info.display,
          editable_source: source_info.editable,
          source_hash: source_info.hash,
          source_path: source_info.path,
          source_absent?: source_info.absent,
          source_editable?: not is_nil(source_info.editable),
          source_note: source_info.note,
          source_draft: source_info.editable,
          source_baseline: source_info.editable,
          source_dirty?: false,
          editor_tab: "source",
          structured_toolkit_names: Structured.toolkit_names(config_dir),
          new_toolkit_name: ""
        },
        structured_assigns(source_info, snapshot, config_dir, selected)
      )

    cond do
      Keyword.get(opts, :reset_source, false) ->
        fresh

      kind = Keyword.get(opts, :preserve_drafts) ->
        keep_drafts(socket, fresh, kind)

      preserve_draft?(socket, selected) ->
        Map.take(socket.assigns, @draft_assigns)

      true ->
        fresh
    end
  end

  defp keep_drafts(socket, fresh, kind) do
    source_draft =
      if kind == :source and not is_nil(socket.assigns.source_draft),
        do: socket.assigns.source_draft,
        else: fresh.editable_source

    structured =
      if kind == :structured and not is_nil(socket.assigns.structured),
        do: socket.assigns.structured,
        else: fresh.structured

    fresh
    |> Map.put(:source_draft, source_draft)
    |> Map.put(:source_dirty?, not is_nil(source_draft) and source_draft != fresh.editable_source)
    |> Map.put(:structured, structured)
    |> Map.put(
      :structured_dirty?,
      not is_nil(structured) and structured != fresh.structured_base
    )
    |> Map.put(:editor_tab, socket.assigns.editor_tab)
  end

  defp structured_assigns(source_info, snapshot, config_dir, selected) do
    cond do
      is_nil(snapshot) ->
        unavailable_structured("Structured editing is available after the definition validates.")

      is_nil(selected) ->
        unavailable_structured("No definition is selected.")

      is_nil(source_info.raw) and is_nil(source_info.editable) ->
        unavailable_structured("The source is not available for editing.")

      true ->
        source = source_info.raw || source_info.editable

        case Structured.load(source, config_dir, selected) do
          {:ok, %{document: document, form: form}} ->
            %{
              structured: form,
              structured_base: form,
              structured_document: document,
              structured_available?: true,
              structured_dirty?: false,
              structured_note: structured_note(source_info)
            }

          {:error, message} ->
            unavailable_structured(message)
        end
    end
  end

  defp structured_note(source_info) do
    base = "Structured saves keep comments and unrecognized keys; edited fields are normalized."

    if is_nil(source_info.editable) do
      base <> " Secret values are preserved and not shown here."
    else
      base
    end
  end

  defp unavailable_structured(note) do
    %{
      structured: nil,
      structured_base: nil,
      structured_document: nil,
      structured_available?: false,
      structured_dirty?: false,
      structured_note: note
    }
  end

  defp preserve_draft?(socket, selected) do
    selected == socket.assigns.selected and dirty?(socket)
  end

  defp discard_draft?(socket, requested_id) do
    dirty?(socket) and is_binary(requested_id) and requested_id != socket.assigns.selected
  end

  defp dirty?(socket) do
    socket.assigns.source_dirty? or socket.assigns.structured_dirty? or prompt_dirty?(socket)
  end

  defp prompt_dirty?(socket) do
    socket.assigns.prompt_drafts
    |> Map.values()
    |> Enum.any?(fn draft -> draft.content != draft.baseline end)
  end

  defp select_id(definitions, failures, nil) do
    first_id(definitions) || first_id(failures)
  end

  defp select_id(definitions, failures, requested_id) when is_binary(requested_id) do
    if Enum.any?(definitions, &(&1.id == requested_id)) or
         Enum.any?(failures, &(&1.id == requested_id)) do
      requested_id
    else
      first_id(definitions) || first_id(failures)
    end
  end

  defp first_id([entry | _rest]), do: entry.id
  defp first_id([]), do: nil

  defp definition_data(definition) do
    {source_info(definition), resolved_data(definition)}
  end

  defp empty_source_info do
    %{display: "", editable: nil, raw: nil, hash: nil, path: nil, absent: false, note: nil}
  end

  defp failure_data(config_dir, id, failure) when is_binary(config_dir) and is_binary(id) do
    {failure_source_info(config_dir, id), failure_resolved(failure)}
  end

  defp failure_data(_config_dir, _id, failure) do
    {empty_source_info(), failure_resolved(failure)}
  end

  defp failure_resolved(nil), do: ""
  defp failure_resolved(%{error: %Error{} = error}), do: failure_text(error)

  defp failure_source_info(config_dir, id) do
    with {:ok, path} <- Source.path(config_dir, id) do
      case Source.read(config_dir, id) do
        {:ok, %{content: raw, hash: hash}} ->
          editable_source(raw, hash, path)

        {:error, :not_found} ->
          %{
            display: "agent.toml does not exist yet.",
            editable: "",
            raw: nil,
            hash: nil,
            path: path,
            absent: true,
            note: nil
          }

        {:error, reason} ->
          unreadable_source(path, reason)
      end
    else
      {:error, reason} ->
        unreadable_source(nil, reason)
    end
  end

  defp source_info(%{path: nil}) do
    %{
      display: "No agent.toml path was recorded.",
      editable: nil,
      raw: nil,
      hash: nil,
      path: nil,
      absent: false,
      note: nil
    }
  end

  defp source_info(%{path: path}) do
    case File.read(path) do
      {:ok, raw} ->
        editable_source(raw, Source.hash(raw), path)

      {:error, reason} ->
        unreadable_source(path, reason)
    end
  end

  defp editable_source(raw, hash, path) do
    redacted = redact_source(raw)

    if redacted == raw do
      %{display: raw, editable: raw, raw: raw, hash: hash, path: path, absent: false, note: nil}
    else
      %{
        display: redacted,
        editable: nil,
        raw: raw,
        hash: hash,
        path: path,
        absent: false,
        note: "Editing is disabled because this source contains secret values."
      }
    end
  end

  defp unreadable_source(path, reason) do
    label = if path, do: "Cannot read #{path}", else: "Cannot read source"

    %{
      display: "#{label}: #{source_error(reason)}",
      editable: nil,
      raw: nil,
      hash: nil,
      path: path,
      absent: false,
      note: nil
    }
  end

  defp source_error(reason) when is_atom(reason) do
    case :file.format_error(reason) do
      message when message in [~c"unknown POSIX error", ~c"unknown error"] -> inspect(reason)
      message -> to_string(message)
    end
  end

  defp source_error(reason), do: error_detail(reason)

  defp resolved_data(definition) do
    definition
    |> definition_map()
    |> redact_definition()
    |> Jason.encode(pretty: true)
    |> case do
      {:ok, json} -> json
      {:error, reason} -> "Cannot render definition: #{inspect(reason)}"
    end
  end

  defp create_agent(socket, params) do
    id = params["agent_id"] || params["id"]
    id = if is_binary(id), do: String.trim(id), else: ""

    lifecycle =
      if params["lifecycle"] in ["one-shot", "perpetual"],
        do: params["lifecycle"],
        else: "one-shot"

    config_dir = socket.assigns.config_dir

    cond do
      is_nil(config_dir) ->
        new_agent_error(socket, id, lifecycle, "the configuration directory is unavailable")

      not Source.valid_new_id?(id) ->
        new_agent_error(
          socket,
          id,
          lifecycle,
          "use a lowercase ID starting with a letter or digit, with dashes or underscores, up to 64 characters"
        )

      true ->
        case Source.create(config_dir, id, Source.template(id, lifecycle)) do
          {:ok, %{id: created_id}} ->
            {level, message} =
              case reload_created(created_id) do
                :ok ->
                  {:info, "Created agent #{created_id}."}

                {:error, detail} ->
                  {:error, "Created agent #{created_id}, but reload failed: #{detail}"}
              end

            broadcast_reload()

            socket
            |> assign(new_agent_open: false, new_agent_id: "", new_agent_lifecycle: "one-shot")
            |> notify(level, message)
            |> push_patch(to: ~p"/config/#{created_id}")

          {:error, :exists} ->
            new_agent_error(
              socket,
              id,
              lifecycle,
              "an agent directory with that ID already exists"
            )

          {:error, :invalid_id} ->
            new_agent_error(socket, id, lifecycle, "the ID is not valid")

          {:error, reason} ->
            new_agent_error(socket, id, lifecycle, error_detail(reason))
        end
    end
  end

  defp new_agent_error(socket, id, lifecycle, detail) do
    socket
    |> assign(new_agent_open: true, new_agent_id: id, new_agent_lifecycle: lifecycle)
    |> notify(:error, "Create failed: #{detail}.")
  end

  defp reload_created(id) do
    case safe(fn -> DefinitionRegistry.reload_agent(id) end) do
      {:ok, _snapshot} -> :ok
      {:error, %Error{} = error} -> {:error, Error.message(error)}
      {:error, :not_found} -> {:error, "the definition directory was not found"}
      {:error, reason} -> {:error, error_detail(reason)}
    end
  end

  defp broadcast_reload do
    Phoenix.PubSub.broadcast_from(@pubsub, self(), "config", {:config, :reloaded})
  rescue
    _exception -> :ok
  end

  defp save_source(socket, params) do
    id = socket.assigns.selected
    {content, expected_hash} = save_params(params)
    socket = load(socket, id)

    cond do
      socket.assigns.structured_dirty? ->
        notify(
          socket,
          :error,
          "Save blocked: the structured editor has unsaved changes. Save or discard them first."
        )

      is_nil(id) ->
        notify(socket, :error, "Save failed: no definition is selected.")

      is_nil(content) ->
        notify(socket, :error, "Save failed: no source was submitted.")

      is_nil(socket.assigns.config_dir) ->
        notify(socket, :error, "Save failed: the configuration directory is unavailable.")

      is_nil(socket.assigns.editable_source) and not is_nil(socket.assigns.source_hash) ->
        notify(
          socket,
          :error,
          "Save refused: this source cannot be edited because it contains secret values."
        )

      is_nil(socket.assigns.editable_source) ->
        notify(socket, :error, "Save failed: the source is not available for editing.")

      is_nil(socket.assigns.source_hash) and not socket.assigns.source_absent? ->
        notify(socket, :error, "Save failed: the source is not available.")

      true ->
        write_source(socket, id, content, expected_hash)
    end
  end

  defp save_structured(socket, params) do
    id = socket.assigns.selected
    structured = socket.assigns.structured
    expected_hash = params["expected_hash"] || socket.assigns.source_hash

    cond do
      socket.assigns.source_dirty? ->
        notify(
          socket,
          :error,
          "Save blocked: the source editor has unsaved changes. Save or discard them first."
        )

      is_nil(id) ->
        notify(socket, :error, "Structured save failed: no definition is selected.")

      is_nil(structured) ->
        notify(socket, :error, "Structured save failed: the definition is not available.")

      is_nil(socket.assigns.structured_document) ->
        notify(socket, :error, "Structured save failed: the source is not available for editing.")

      is_nil(socket.assigns.config_dir) ->
        notify(
          socket,
          :error,
          "Structured save failed: the configuration directory is unavailable."
        )

      true ->
        case Structured.build(
               socket.assigns.structured_document,
               structured,
               id,
               socket.assigns.config_dir
             ) do
          {:ok, content} ->
            write_source(socket, id, content, expected_hash, :structured)

          {:error, message} ->
            notify(socket, :error, "Structured save rejected: #{message}")
        end
    end
  end

  defp update_structured(socket, nil), do: socket

  defp update_structured(socket, form) do
    assign(socket,
      structured: form,
      structured_dirty?: form != socket.assigns.structured_base
    )
  end

  # The manifest picker rides along with the structured form's change events,
  # so picking a manifest and adding it needs no separate submit.
  defp structured_params(params) when is_map(params) do
    case params["structured"] do
      structured when is_map(structured) -> structured
      _other -> %{}
    end
  end

  defp picked_toolkit(params) when is_map(params), do: string_param(params["new_toolkit"])
  defp picked_toolkit(_params), do: ""

  defp string_param(value) when is_binary(value), do: String.trim(value)
  defp string_param(_value), do: ""

  defp parse_index(index) when is_integer(index) and index >= 0, do: {:ok, index}

  defp parse_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> :error
    end
  end

  defp parse_index(_index), do: :error

  defp write_source(socket, id, content, expected_hash, kind \\ :source) do
    config_dir = socket.assigns.config_dir
    expected_hash = normalize_expected_hash(socket, expected_hash)

    with {:ok, path} <- Source.path(config_dir, id),
         :ok <- authoritative_path(socket.assigns.snapshot, path),
         {:ok, _written} <- Source.write(config_dir, id, content, expected_hash) do
      apply_write(socket, id, kind)
    else
      {:error, :stale} ->
        socket
        |> load(id, preserve_drafts: kind)
        |> notify(
          :error,
          "Save conflict: the source changed on disk after it was loaded. Review it and save again."
        )

      {:error, :not_found} ->
        socket
        |> load(id, reset_source: true)
        |> notify(:error, "Save failed: the source file no longer exists.")

      {:error, :not_authoritative} ->
        notify(
          socket,
          :error,
          "Save failed: the selected definition does not own this source file."
        )

      {:error, :invalid_id} ->
        notify(socket, :error, "Save failed: invalid definition identifier.")

      {:error, {:io, reason}} ->
        notify(socket, :error, "Save failed: #{:file.format_error(reason)}")

      {:error, reason} ->
        notify(socket, :error, "Save failed: #{error_detail(reason)}")
    end
  end

  defp normalize_expected_hash(socket, expected_hash) do
    if socket.assigns.source_absent? and expected_hash in [nil, "", "absent"] do
      :absent
    else
      expected_hash
    end
  end

  defp authoritative_path(nil, expected) when is_binary(expected), do: :ok

  defp authoritative_path(%{definition: %{path: path}}, expected) when is_binary(path) do
    if Path.expand(path) == Path.expand(expected) do
      :ok
    else
      {:error, :not_authoritative}
    end
  end

  defp authoritative_path(_snapshot, _expected), do: {:error, :not_authoritative}

  defp apply_write(socket, id, kind) do
    tab = socket.assigns[:editor_tab] || "source"

    socket =
      case safe(fn -> DefinitionRegistry.reload_agent(id) end) do
        {:ok, _snapshot} ->
          notify(socket, :info, saved_message(kind))

        {:error, %Error{} = error} ->
          message =
            if socket.assigns.snapshot do
              "#{saved_label(kind)}, but the definition is invalid. The last good definition remains active: " <>
                Error.message(error)
            else
              "#{saved_label(kind)}, but the definition is invalid: " <> Error.message(error)
            end

          notify(socket, :error, message)

        {:error, :not_found} ->
          notify(
            socket,
            :error,
            "#{saved_label(kind)}, but the definition directory was not found during reload."
          )

        {:error, reason} ->
          notify(
            socket,
            :error,
            "#{saved_label(kind)}, but reload failed: #{error_detail(reason)}"
          )
      end

    Phoenix.PubSub.broadcast_from(@pubsub, self(), "config", {:config, :reloaded})
    socket |> load(id, reset_source: true) |> assign(:editor_tab, tab)
  end

  defp saved_message(:structured), do: "Structured configuration saved. Definition reloaded."
  defp saved_message(_kind), do: "Source saved. Definition reloaded."

  defp saved_label(:structured), do: "Structured configuration saved"
  defp saved_label(_kind), do: "Source saved"

  defp save_params(%{"source" => %{"content" => content} = source} = params)
       when is_binary(content) do
    {content, expected_hash(params) || expected_hash(source)}
  end

  defp save_params(%{"source" => content} = params) when is_binary(content) do
    {content, expected_hash(params)}
  end

  defp save_params(params) do
    content = params["content"] || params["text"]
    {if(is_binary(content), do: content), expected_hash(params)}
  end

  defp expected_hash(params) do
    Enum.find_value(["expected_hash", "expected_hash_sha256", "source_hash", "hash"], fn key ->
      case params[key] do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp failure_for(_failures, nil), do: nil
  defp failure_for(failures, id), do: Enum.find(failures, &(&1.id == id))

  defp notify(socket, kind, message) do
    Process.send_after(self(), {:expire_flash, kind, message}, @flash_timeout)
    put_flash(socket, kind, message)
  end

  defp paused_flashes(socket), do: Map.get(socket.assigns, :paused_flashes, MapSet.new())

  defp flash_kind("info"), do: "info"
  defp flash_kind("error"), do: "error"
  defp flash_kind(_kind), do: nil

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, reason -> {:error, reason}
  end

  defp model_name(nil), do: "—"
  defp model_name(%{name: nil}), do: "—"
  defp model_name(%{name: name}), do: name

  defp toolkit_names(nil), do: "—"

  defp toolkit_names(definition) do
    case definition.toolkits do
      [] ->
        "—"

      toolkits ->
        toolkits
        |> Enum.map(& &1.toolkit)
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")
    end
  end

  defp script_label(path), do: path

  # Structured editor helpers ------------------------------------------------

  @exec_placeholder "git or /nix/store/.../bin/tool"
  @arguments_placeholder "clone\nhttps://github.com/owner/repo"

  defp toolkit_meta(toolkit, config_dir) do
    manifest = Structured.manifest_info(toolkit["toolkit"], config_dir)

    env? =
      (manifest && manifest.native == "secret-env") == true or
        (toolkit["env"] || "") != ""

    %{manifest: manifest, env?: env?}
  end

  defp manifest_tools_label(%{native: nil, operations: []}), do: "NO MANIFEST TOOLS"

  defp manifest_tools_label(%{native: nil, operations: operations}),
    do: "OPERATIONS " <> Enum.join(operations, ", ")

  defp manifest_tools_label(%{native: native, tools: []}) when not is_nil(native),
    do: "NO MODEL-FACING TOOLS"

  defp manifest_tools_label(%{tools: tools}), do: "TOOLS " <> Enum.join(tools, ", ")

  attr(:id, :string, required: true)
  attr(:field, :string, required: true)
  attr(:value, :string, required: true)

  # Every accepted `[context]` recovery word is offered; the synonyms share
  # the keep or reset behavior they currently map to.
  defp context_value_select(assigns) do
    keep = Structured.context_keep_values()
    reset = Structured.context_reset_values()

    assigns =
      assign(assigns,
        keep_values: keep,
        reset_values: reset,
        known_values: ["" | keep ++ reset]
      )

    ~H"""
    <select id={@id} name={@field}>
      <option value="" selected={@value == ""}>LIFECYCLE RULES</option>
      <optgroup label="KEEP — RESTORES PRIOR CONTEXT">
        <option :for={value <- @keep_values} value={value} selected={@value == value}>
          {heex_context_option(value, @keep_values)}
        </option>
      </optgroup>
      <optgroup label="RESET — STARTS WITHOUT PRIOR CONTEXT">
        <option :for={value <- @reset_values} value={value} selected={@value == value}>
          {heex_context_option(value, @reset_values)}
        </option>
      </optgroup>
      <option :if={@value not in @known_values} value={@value} selected>
        {@value}
      </option>
    </select>
    """
  end

  defp heex_context_option("keep", _all), do: "KEEP"
  defp heex_context_option("reset", _all), do: "RESET"

  defp heex_context_option(value, all) do
    primary = if Enum.member?(all, "keep"), do: "KEEP", else: "RESET"

    "#{String.upcase(value)} — SAME AS #{primary}"
  end

  attr(:kind, :string, required: true)
  attr(:hooks, :list, required: true)

  # Matches the fixed-operation schema without model-facing arguments: the
  # executable may be bare or absolute, and argv may start with it when no
  # executable key is set.
  defp hooks_section(assigns) do
    assigns =
      assign(assigns,
        exec_placeholder: @exec_placeholder,
        arguments_placeholder: @arguments_placeholder
      )

    ~H"""
    <div class="struct-subhead">
      <span>{String.upcase(@kind)} HOOKS <b>{length(@hooks)}</b></span>
      <button class="filter" type="button" phx-click="add_hook" phx-value-hook={@kind}>
        ADD {String.upcase(@kind)} HOOK
      </button>
    </div>

    <article :for={{hook, index} <- Enum.with_index(@hooks)} class="struct-item nested">
      <header class="struct-item-head">
        <span>{String.upcase(@kind)} HOOK {index + 1}</span>
        <button
          class="filter"
          type="button"
          phx-click="remove_hook"
          phx-value-hook={@kind}
          phx-value-index={index}
        >
          REMOVE
        </button>
      </header>

      <div class="struct-grid">
        <div class="struct-field">
          <label>NAME</label>
          <input
            name={"structured[lifecycle][#{@kind}][#{index}][name]"}
            type="text"
            value={hook["name"]}
            autocomplete="off"
            spellcheck="false"
            phx-debounce="200"
          />
        </div>
        <div class="struct-field">
          <label>EXECUTABLE</label>
          <input
            name={"structured[lifecycle][#{@kind}][#{index}][executable]"}
            type="text"
            value={hook["executable"]}
            placeholder={@exec_placeholder}
            autocomplete="off"
            spellcheck="false"
            phx-debounce="200"
          />
        </div>
        <div class="struct-field">
          <label>DESCRIPTION</label>
          <input
            name={"structured[lifecycle][#{@kind}][#{index}][description]"}
            type="text"
            value={hook["description"]}
            autocomplete="off"
            spellcheck="false"
            phx-debounce="200"
          />
        </div>
      </div>

      <div class="struct-field">
        <label>ARGUMENTS</label>
        <textarea
          name={"structured[lifecycle][#{@kind}][#{index}][argv]"}
          rows="3"
          placeholder={@arguments_placeholder}
          spellcheck="false"
          phx-debounce="200"
        >{hook["argv"]}</textarea>
      </div>
    </article>
    """
  end

  defp short_hash(nil), do: "—"
  defp short_hash(hash), do: String.slice(hash, 0, 12)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        exec_placeholder: @exec_placeholder,
        arguments_placeholder: @arguments_placeholder
      )

    ~H"""
    <div class="console">
      <header class="masthead">
        <div class="brand">
          <span class="mark" aria-hidden="true"></span>
          <span class="wordmark">PATCHBAY</span>
          <span class="divider" aria-hidden="true"></span>
          <span class="view">CONFIGURATION</span>
        </div>
        <div class="mast-right">
          <nav class="global-nav" aria-label="Global navigation">
           <a class="nav-link" href={~p"/"}>CONSOLE</a>
           <a class="nav-link is-active" href={~p"/config"} aria-current="page">CONFIG</a>
           <a class="nav-link" href={~p"/toolkits"}>TOOLKITS</a>
          </nav>
          <span class="local">DEFINITIONS <b>{length(@definitions)}</b></span>
          <time id="config-clock" class="clock" phx-hook="PatchbayClock">
            <span data-clock-time>{Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")}</span>
            <small>UTC</small>
          </time>
        </div>
      </header>

      <main class="workspace config-workspace">
        <section class="channels" aria-label="Definitions">
          <header class="channels-head">
            <h1>DEFINITIONS <span class="count">{length(@definitions)}</span></h1>
            <button class="filter" type="button" phx-click="new_agent">NEW AGENT</button>
            <button class="filter" type="button" phx-click="reload">RELOAD</button>
            <div class="sort">FAILURES <b>{length(@failures)}</b></div>
          </header>

          <form :if={@new_agent_open} class="new-agent-form" phx-submit="create_agent">
            <label for="new-agent-id">NEW AGENT ID</label>
            <div class="new-agent-fields">
              <input
                id="new-agent-id"
                name="agent_id"
                type="text"
                value={@new_agent_id}
                placeholder="agent-id"
                autocomplete="off"
                spellcheck="false"
              />
              <select name="lifecycle" aria-label="Lifecycle">
                <option value="one-shot" selected={@new_agent_lifecycle == "one-shot"}>
                  ONE-SHOT
                </option>
                <option value="perpetual" selected={@new_agent_lifecycle == "perpetual"}>
                  PERPETUAL
                </option>
              </select>
              <button class="filter" type="submit">CREATE</button>
              <button class="filter" type="button" phx-click="cancel_new_agent">CANCEL</button>
            </div>
          </form>

          <div class="strip-cols config-row" aria-hidden="true">
            <span>#</span>
            <span>AGENT</span>
            <span>LIFECYCLE</span>
            <span>MODEL</span>
            <span>REV</span>
            <span>FAIL</span>
          </div>

          <ol class="strips config-list" role="listbox" aria-label="Definitions">
            <li
              :for={{failure, index} <- Enum.with_index(@failures)}
              :if={is_nil(Enum.find(@definitions, &(&1.id == failure.id)))}
              class={"strip config-row #{if @selected == failure.id, do: "is-selected on-dark"}"}
              role="option"
              aria-selected={@selected == failure.id}
              tabindex="0"
              phx-click="select"
              phx-value-id={failure.id}
            >
              <span class="ch">{String.pad_leading(Integer.to_string(index + 1 + length(@definitions)), 2, "0")}</span>
              <div class="agent">
                <span class="agent-name">{failure.id}</span>
                <span class="agent-sub">invalid definition</span>
              </div>
              <span class="config-cell">—</span>
              <span class="config-cell">—</span>
              <span class="config-cell mono">—</span>
              <span class="config-cell"><span class="lamp fail"></span></span>
            </li>
            <li
              :for={{snapshot, index} <- Enum.with_index(@definitions)}
              class={"strip config-row #{if @selected == snapshot.id, do: "is-selected on-dark"}"}
              role="option"
              aria-selected={@selected == snapshot.id}
              tabindex="0"
              phx-click="select"
              phx-value-id={snapshot.id}
            >
              <span class="ch">{String.pad_leading(Integer.to_string(index + 1), 2, "0")}</span>
              <div class="agent">
                <span class="agent-name">{snapshot.id}</span>
                <span class="agent-sub">{snapshot.definition.path || "agent.toml"}</span>
              </div>
              <span class="config-cell">{lifecycle_label(snapshot.definition.lifecycle && snapshot.definition.lifecycle.kind)}</span>
              <span class="config-cell">{model_name(snapshot.definition.model)}</span>
              <span class="config-cell mono">{snapshot.revision}</span>
              <span class="config-cell">
                <span :if={failure_for(@failures, snapshot.id)} class="lamp fail"></span>
                <span :if={!failure_for(@failures, snapshot.id)} class="lamp"></span>
              </span>
            </li>
          </ol>

          <div :if={@definitions == []} class="empty-state inline">
            <p>NO DEFINITIONS</p>
            <p class="muted">No valid agent.toml files were found under the configured config directory.</p>
          </div>

          <footer class="channels-foot">
            <span class="foot-item">AGENTS DIR <b>config/agents</b></span>
            <span class="foot-item push">FAILURES <b>{length(@failures)}</b></span>
          </footer>
        </section>

        <aside class="inspector config-inspector" aria-label="Definition detail">
          <div :if={is_nil(@selected)} class="empty-state">
            <span class="lamp idle"></span>
            <p>NO DEFINITION SELECTED</p>
            <p class="muted">Add a definition, then reload.</p>
          </div>

          <header :if={@selected} class="insp-head on-dark">
            <div class="kicker">
              <span class="sel">DEF</span>
              <span class="kind">{if @snapshot, do: lifecycle_label(@snapshot.definition.lifecycle && @snapshot.definition.lifecycle.kind), else: "INVALID"}</span>
              <span class="run-meta">REV <b>{if @snapshot, do: @snapshot.revision, else: "—"}</b></span>
            </div>
            <div class="insp-title">
              <h2>{@selected}</h2>
              <span class="state-pill state-model">{model_name(@snapshot && @snapshot.definition.model)}</span>
            </div>
            <div class="config-head-meta">
              <span>TOOLKITS <b>{toolkit_names(@snapshot && @snapshot.definition)}</b></span>
              <span>PROMPTS <b>{length(@prompts)}</b></span>
            </div>
          </header>

          <div :if={@failure} class="failure-block">
            <span class="label">VALIDATION FAILURE</span>
            <pre class="code-block">{failure_text(@failure.error)}</pre>
          </div>

          <div :if={@selected} class="config-detail">
            <div :if={@pending_select} class="source-confirm" role="alertdialog" aria-label="Unsaved changes">
              <p>Discard unsaved changes to {@selected}?</p>
              <div class="source-confirm-actions">
                <button class="filter" type="button" phx-click="confirm_select">
                  DISCARD AND SWITCH
                </button>
                <button class="filter" type="button" phx-click="cancel_select">
                  KEEP EDITING
                </button>
              </div>
            </div>

            <div class="editor-tabs" role="tablist" aria-label="Definition editor">
              <button
                class={"filter #{if @editor_tab == "source", do: "is-active"}"}
                type="button"
                role="tab"
                aria-selected={@editor_tab == "source"}
                phx-click="tab"
                phx-value-tab="source"
              >
                SOURCE
              </button>
              <button
                class={"filter #{if @editor_tab == "structured", do: "is-active"}"}
                type="button"
                role="tab"
                aria-selected={@editor_tab == "structured"}
                disabled={!@structured_available?}
                phx-click="tab"
                phx-value-tab="structured"
              >
                STRUCTURED
              </button>
            </div>

            <section :if={@editor_tab == "source"} class="config-section">
              <header class="panel-head">
                <h3>SOURCE <span>{@source_path || "agent.toml"}</span></h3>
                <span :if={@source_hash} class="panel-meta">SHA {short_hash(@source_hash)}</span>
              </header>

              <form
                :if={@source_editable?}
                id="source-form"
                class="source-form"
                phx-submit="save"
                phx-change="edit_source"
              >
                <input type="hidden" name="expected_hash" value={@source_hash || "absent"} />
                <textarea
                  id="source-editor"
                  class="source-editor"
                  name="source"
                  rows="24"
                  spellcheck="false"
                  aria-label="agent.toml source"
                  phx-debounce="200"
                >{@source_draft}</textarea>
                <div class="source-actions">
                  <span :if={@source_dirty?} class="source-dirty">UNSAVED CHANGES</span>
                  <button class="filter" type="submit">SAVE SOURCE</button>
                </div>
              </form>

              <pre :if={!@source_editable?} class="code-block">{@source}</pre>

              <p :if={@source_note} class="source-note source-note-block">{@source_note}</p>
            </section>

            <section :if={@editor_tab == "structured"} class="config-section">
              <header class="panel-head">
                <h3>STRUCTURED <span>{@source_path || "agent.toml"}</span></h3>
                <span :if={@source_hash} class="panel-meta">SHA {short_hash(@source_hash)}</span>
              </header>

              <div :if={!@structured_available?} class="empty-state inline">
                <p>STRUCTURED EDITING UNAVAILABLE</p>
                <p class="muted">{@structured_note}</p>
              </div>

              <form
                :if={@structured}
                id="structured-form"
                class="structured-form"
                phx-submit="save_structured"
                phx-change="edit_structured"
              >
                <input type="hidden" name="expected_hash" value={@source_hash || "absent"} />

                <fieldset class="struct-group">
                  <legend>IDENTITY</legend>
                  <div class="struct-field">
                    <label for="structured-id">AGENT ID</label>
                    <input id="structured-id" type="text" value={@structured["id"]} readonly />
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>MODEL</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="structured-model-name">MODEL NAME</label>
                      <input
                        id="structured-model-name"
                        name="structured[model][name]"
                        type="text"
                        value={@structured["model"]["name"]}
                        placeholder="default"
                        autocomplete="off"
                        spellcheck="false"
                        phx-debounce="200"
                      />
                    </div>
                    <div class="struct-field">
                      <label for="structured-model-provider">PROVIDER</label>
                      <input
                        id="structured-model-provider"
                        name="structured[model][provider]"
                        type="text"
                        value={@structured["model"]["provider"]}
                        placeholder="default"
                        autocomplete="off"
                        spellcheck="false"
                        phx-debounce="200"
                      />
                    </div>
                    <div class="struct-field">
                      <label for="structured-model-reasoning">REASONING</label>
                      <input
                        id="structured-model-reasoning"
                        name="structured[model][reasoning]"
                        type="text"
                        value={@structured["model"]["reasoning"]}
                        autocomplete="off"
                        spellcheck="false"
                        phx-debounce="200"
                      />
                    </div>
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>LIFECYCLE</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="structured-lifecycle-kind">KIND</label>
                      <select
                        id="structured-lifecycle-kind"
                        name="structured[lifecycle][kind]"
                      >
                        <option
                          value="one-shot"
                          selected={@structured["lifecycle"]["kind"] == "one-shot"}
                        >
                          ONE-SHOT
                        </option>
                        <option
                          value="scheduled"
                          selected={@structured["lifecycle"]["kind"] == "scheduled"}
                        >
                          SCHEDULED
                        </option>
                        <option
                          value="perpetual"
                          selected={@structured["lifecycle"]["kind"] == "perpetual"}
                        >
                          PERPETUAL
                        </option>
                      </select>
                    </div>
                    <div
                      :if={@structured["lifecycle"]["kind"] == "scheduled"}
                      class="struct-field"
                    >
                      <label for="structured-lifecycle-schedule">SCHEDULE (CRON, UTC)</label>
                      <input
                        id="structured-lifecycle-schedule"
                        name="structured[lifecycle][schedule]"
                        type="text"
                        value={@structured["lifecycle"]["schedule"]}
                        placeholder="0 7 * * *"
                        autocomplete="off"
                        spellcheck="false"
                        phx-debounce="200"
                      />
                    </div>
                    <div
                      :if={@structured["lifecycle"]["kind"] == "scheduled"}
                      class="struct-field"
                    >
                      <label for="structured-lifecycle-overlap">OVERLAP</label>
                      <select id="structured-lifecycle-overlap" name="structured[lifecycle][overlap]">
                        <option
                          value="forbid"
                          selected={@structured["lifecycle"]["overlap"] in ["", "forbid"]}
                        >
                          FORBID
                        </option>
                      </select>
                    </div>
                    <div
                      :if={@structured["lifecycle"]["kind"] == "scheduled"}
                      class="struct-field"
                    >
                      <label for="structured-lifecycle-catch-up">CATCH-UP</label>
                      <select
                        id="structured-lifecycle-catch-up"
                        name="structured[lifecycle][catch_up]"
                      >
                        <option
                          value="none"
                          selected={@structured["lifecycle"]["catch_up"] in ["", "none"]}
                        >
                          NONE
                        </option>
                        <option
                          value="once"
                          selected={@structured["lifecycle"]["catch_up"] == "once"}
                        >
                          ONCE
                        </option>
                        <option
                          value="all"
                          selected={@structured["lifecycle"]["catch_up"] == "all"}
                        >
                          ALL
                        </option>
                      </select>
                    </div>
                  </div>

                  <.hooks_section kind="init" hooks={@structured["lifecycle"]["init"]} />
                  <.hooks_section kind="finalize" hooks={@structured["lifecycle"]["finalize"]} />
                </fieldset>
                <fieldset class="struct-group">
                  <legend>CONTEXT</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="structured-context-between-runs">BETWEEN RUNS</label>
                      <.context_value_select
                        id="structured-context-between-runs"
                        field="structured[context][between_runs]"
                        value={@structured["context"]["between_runs"]}
                      />
                    </div>
                    <div class="struct-field">
                      <label for="structured-context-prior-runs">PRIOR RUNS</label>
                      <.context_value_select
                        id="structured-context-prior-runs"
                        field="structured[context][prior_runs]"
                        value={@structured["context"]["prior_runs"]}
                      />
                    </div>
                    <div class="struct-field">
                      <label for="structured-context-restore-interrupted">RESTORE INTERRUPTED</label>
                      <.context_value_select
                        id="structured-context-restore-interrupted"
                        field="structured[context][restore_interrupted]"
                        value={@structured["context"]["restore_interrupted"]}
                      />
                    </div>
                    <div class="struct-field">
                      <label for="structured-context-threshold">COMPACTION THRESHOLD</label>
                      <input
                        id="structured-context-threshold"
                        name="structured[context][threshold]"
                        type="number"
                        min="0"
                        value={@structured["context"]["threshold"]}
                        phx-debounce="200"
                      />
                    </div>
                    <div class="struct-field">
                      <label for="structured-context-target">COMPACTION TARGET</label>
                      <input
                        id="structured-context-target"
                        name="structured[context][target]"
                        type="number"
                        min="0"
                        value={@structured["context"]["target"]}
                        phx-debounce="200"
                      />
                    </div>
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>ENVIRONMENT</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="structured-environment-packages">NIX PACKAGES</label>
                      <textarea
                        id="structured-environment-packages"
                        name="structured[environment][packages]"
                        rows="2"
                        spellcheck="false"
                        phx-debounce="200"
                      >{@structured["environment"]["packages"]}</textarea>
                    </div>
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>WORKSPACE</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="structured-workspace-enabled">ALLOCATE WORKSPACE</label>
                      <select
                        id="structured-workspace-enabled"
                        name="structured[workspace][enabled]"
                      >
                        <option
                          value="enabled"
                          selected={@structured["workspace"]["enabled"] in ["", "enabled", "true", "yes"]}
                        >
                          YES
                        </option>
                        <option
                          value="disabled"
                          selected={@structured["workspace"]["enabled"] in ["disabled", "false", "no"]}
                        >
                          NO
                        </option>
                      </select>
                      <p class="panel-meta">
                        Off allocates no workspace; &#123;%workspace&#125; becomes invalid for this agent.
                      </p>
                    </div>
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>TEARDOWN</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="structured-teardown-workspace">WORKSPACE</label>
                      <select
                        id="structured-teardown-workspace"
                        name="structured[teardown][workspace]"
                      >
                        <option :for={action <- Structured.workspace_actions()} value={action} selected={
                          @structured["teardown"]["workspace"] == action or
                            (action == "retain" and @structured["teardown"]["workspace"] == "")
                        }>
                          {String.upcase(action)}
                        </option>
                        <option
                          :if={
                            @structured["teardown"]["workspace"] not in
                              ["" | Structured.workspace_actions()]
                          }
                          value={@structured["teardown"]["workspace"]}
                          selected
                        >
                          {@structured["teardown"]["workspace"]}
                        </option>
                      </select>
                    </div>
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>BUDGETS</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="structured-budget-run-seconds">RUN SECONDS</label>
                      <input
                        id="structured-budget-run-seconds"
                        name="structured[budgets][run_seconds]"
                        type="number"
                        min="0"
                        value={@structured["budgets"]["run_seconds"]}
                        phx-debounce="200"
                      />
                    </div>
                    <div class="struct-field">
                      <label for="structured-budget-tokens">TOKENS</label>
                      <input
                        id="structured-budget-tokens"
                        name="structured[budgets][tokens]"
                        type="number"
                        min="0"
                        value={@structured["budgets"]["tokens"]}
                        phx-debounce="200"
                      />
                    </div>
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>TOOLKITS</legend>
                  <div class="struct-toolbar">
                    <span>DECLARED <b>{length(@structured["toolkits"])}</b></span>
                    <select
                      name="new_toolkit"
                      aria-label="Available manifests"
                    >
                      <option value="" selected={@new_toolkit_name == ""}>
                        CUSTOM TOOLKIT
                      </option>
                      <option
                        :for={name <- @structured_toolkit_names}
                        value={name}
                        selected={@new_toolkit_name == name}
                      >
                        {name}
                      </option>
                    </select>
                    <button class="filter" type="button" phx-click="add_toolkit">
                      ADD TOOLKIT
                    </button>
                  </div>

                  <datalist id="structured-toolkit-names">
                    <option :for={name <- @structured_toolkit_names} value={name} />
                  </datalist>

                  <article
                    :for={{toolkit, toolkit_index} <- Enum.with_index(@structured["toolkits"])}
                    class="struct-item"
                  >
                    <% meta = toolkit_meta(toolkit, @config_dir) %>
                    <header class="struct-item-head">
                      <span>TOOLKIT {toolkit_index + 1}
                        <span :if={meta.manifest} class="panel-meta">
                          {manifest_tools_label(meta.manifest)}
                        </span>
                      </span>
                      <button
                        class="filter"
                        type="button"
                        phx-click="remove_toolkit"
                        phx-value-index={toolkit_index}
                      >
                        REMOVE
                      </button>
                    </header>

                    <div class="struct-grid">
                      <div class="struct-field">
                        <label for={"structured-toolkit-#{toolkit_index}"}>TOOLKIT NAME</label>
                        <input
                          id={"structured-toolkit-#{toolkit_index}"}
                          name={"structured[toolkits][#{toolkit_index}][toolkit]"}
                          type="text"
                          value={toolkit["toolkit"]}
                          list="structured-toolkit-names"
                          autocomplete="off"
                          spellcheck="false"
                          phx-debounce="200"
                        />
                      </div>
                      <div class="struct-field">
                        <label for={"structured-toolkit-description-#{toolkit_index}"}>
                          DESCRIPTION
                        </label>
                        <input
                          id={"structured-toolkit-description-#{toolkit_index}"}
                          name={"structured[toolkits][#{toolkit_index}][description]"}
                          type="text"
                          value={toolkit["description"]}
                          autocomplete="off"
                          spellcheck="false"
                          phx-debounce="200"
                        />
                      </div>
                      <div
                        :if={Structured.filesystem_toolkit?(toolkit["toolkit"], @config_dir)}
                        class="struct-field"
                      >
                        <label for={"structured-toolkit-root-#{toolkit_index}"}>
                          FILESYSTEM ROOT (SUPPORTS &#123;%WORKSPACE&#125; AND OTHER &#123;%VARIABLES&#125;; RELATIVE ROOTS RESOLVE UNDER THE CONFIG TREE)
                        </label>
                        <input
                          id={"structured-toolkit-root-#{toolkit_index}"}
                          name={"structured[toolkits][#{toolkit_index}][root]"}
                          type="text"
                          value={toolkit["root"]}
                          placeholder="&#123;%workspace&#125; or work"
                          autocomplete="off"
                          spellcheck="false"
                          phx-debounce="200"
                        />
                      </div>
                      <div
                        :if={Structured.personal_memory_toolkit?(toolkit["toolkit"], @config_dir)}
                        class="struct-field"
                      >
                        <label for={"structured-toolkit-namespace-#{toolkit_index}"}>
                          MEMORY NAMESPACE
                        </label>
                        <input
                          id={"structured-toolkit-namespace-#{toolkit_index}"}
                          name={"structured[toolkits][#{toolkit_index}][namespace]"}
                          type="text"
                          value={toolkit["namespace"]}
                          placeholder="default"
                          autocomplete="off"
                          spellcheck="false"
                          phx-debounce="200"
                        />
                      </div>
                      <div
                        :if={meta.env?}
                        class="struct-field"
                      >
                        <label for={"structured-toolkit-env-#{toolkit_index}"}>
                          ENVIRONMENT SECRETS (NAME=secret://ref, ONE PER LINE)
                        </label>
                        <textarea
                          id={"structured-toolkit-env-#{toolkit_index}"}
                          name={"structured[toolkits][#{toolkit_index}][env]"}
                          rows="3"
                          spellcheck="false"
                          phx-debounce="200"
                        >{toolkit["env"]}</textarea>
                      </div>
                    </div>

                    <div class="struct-subhead">
                      <span>OPERATIONS <b>{length(toolkit["operations"])}</b></span>
                      <button
                        class="filter"
                        type="button"
                        phx-click="add_operation"
                        phx-value-toolkit={toolkit_index}
                      >
                        ADD OPERATION
                      </button>
                    </div>

                    <article
                      :for={
                        {operation, operation_index} <- Enum.with_index(toolkit["operations"])
                      }
                      class="struct-item nested"
                    >
                      <header class="struct-item-head">
                        <span>OPERATION {operation_index + 1}</span>
                        <button
                          class="filter"
                          type="button"
                          phx-click="remove_operation"
                          phx-value-toolkit={toolkit_index}
                          phx-value-index={operation_index}
                        >
                          REMOVE
                        </button>
                      </header>

                      <div class="struct-grid">
                        <div class="struct-field">
                          <label>NAME</label>
                          <input
                            name={"structured[toolkits][#{toolkit_index}][operations][#{operation_index}][name]"}
                            type="text"
                            value={operation["name"]}
                            autocomplete="off"
                            spellcheck="false"
                            phx-debounce="200"
                          />
                        </div>
                        <div class="struct-field">
                          <label>EXECUTABLE</label>
                          <input
                            name={"structured[toolkits][#{toolkit_index}][operations][#{operation_index}][executable]"}
                            type="text"
                            value={operation["executable"]}
                            placeholder={@exec_placeholder}
                            autocomplete="off"
                            spellcheck="false"
                            phx-debounce="200"
                          />
                        </div>
                        <div class="struct-field">
                          <label>DESCRIPTION</label>
                          <input
                            name={"structured[toolkits][#{toolkit_index}][operations][#{operation_index}][description]"}
                            type="text"
                            value={operation["description"]}
                            autocomplete="off"
                            spellcheck="false"
                            phx-debounce="200"
                          />
                        </div>
                      </div>

                      <div class="struct-field">
                        <label>ARGUMENTS</label>
                        <textarea
                          name={"structured[toolkits][#{toolkit_index}][operations][#{operation_index}][argv]"}
                          rows="3"
                          placeholder={@arguments_placeholder}
                          spellcheck="false"
                          phx-debounce="200"
                        >{operation["argv"]}</textarea>
                      </div>

                      <div class="struct-subhead">
                        <span>ARGUMENTS <b>{length(operation["arguments"] || [])}</b></span>
                        <button
                          class="filter"
                          type="button"
                          phx-click="add_argument"
                          phx-value-toolkit={toolkit_index}
                          phx-value-operation={operation_index}
                        >
                          ADD ARGUMENT
                        </button>
                      </div>

                      <article
                        :for={
                          {argument, argument_index} <- Enum.with_index(operation["arguments"] || [])
                        }
                        class="struct-item nested"
                      >
                        <header class="struct-item-head">
                          <span>ARGUMENT {argument_index + 1}
                            <span class="panel-meta">{String.upcase(argument["type"] || "")}</span>
                          </span>
                          <button
                            class="filter"
                            type="button"
                            phx-click="remove_argument"
                            phx-value-toolkit={toolkit_index}
                            phx-value-operation={operation_index}
                            phx-value-index={argument_index}
                          >
                            REMOVE
                          </button>
                        </header>

                        <div class="struct-grid">
                          <div class="struct-field">
                            <label>NAME</label>
                            <input
                              name={"structured[toolkits][#{toolkit_index}][operations][#{operation_index}][arguments][#{argument_index}][name]"}
                              type="text"
                              value={argument["name"]}
                              autocomplete="off"
                              spellcheck="false"
                              phx-debounce="200"
                            />
                          </div>
                          <div class="struct-field">
                            <label>TYPE</label>
                            <select
                              name={"structured[toolkits][#{toolkit_index}][operations][#{operation_index}][arguments][#{argument_index}][type]"}
                            >
                              <option
                                :for={type <- Structured.argument_types()}
                                value={type}
                                selected={argument["type"] == type}
                              >
                                {String.upcase(type)}
                              </option>
                              <option
                                :if={argument["type"] not in Structured.argument_types()}
                                value={argument["type"]}
                                selected
                              >
                                {argument["type"]}
                              </option>
                            </select>
                          </div>
                          <div class="struct-field">
                            <label>REQUIRED</label>
                            <select
                              name={"structured[toolkits][#{toolkit_index}][operations][#{operation_index}][arguments][#{argument_index}][required]"}
                            >
                              <option value="true" selected={argument["required"] in ["", "true"]}>
                                YES
                              </option>
                              <option value="false" selected={argument["required"] == "false"}>
                                NO
                              </option>
                            </select>
                          </div>
                        </div>

                        <div :if={argument["type"] == "enum"} class="struct-field">
                          <label>VALUES (ONE PER LINE)</label>
                          <textarea
                            name={"structured[toolkits][#{toolkit_index}][operations][#{operation_index}][arguments][#{argument_index}][values]"}
                            rows="2"
                            spellcheck="false"
                            phx-debounce="200"
                          >{argument["values"]}</textarea>
                        </div>
                      </article>
                    </article>
                  </article>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>RESULTS</legend>
                  <div class="struct-toolbar">
                    <span>DECLARED <b>{length(@structured["results"])}</b></span>
                    <button class="filter" type="button" phx-click="add_result">ADD RESULT</button>
                  </div>

                  <article
                    :for={{result, result_index} <- Enum.with_index(@structured["results"])}
                    class="struct-item"
                  >
                    <header class="struct-item-head">
                      <span>RESULT {result_index + 1}</span>
                      <button
                        class="filter"
                        type="button"
                        phx-click="remove_result"
                        phx-value-index={result_index}
                      >
                        REMOVE
                      </button>
                    </header>

                    <div class="struct-grid">
                      <div class="struct-field">
                        <label>ID</label>
                        <input
                          name={"structured[results][#{result_index}][id]"}
                          type="text"
                          value={result["id"]}
                          autocomplete="off"
                          spellcheck="false"
                          phx-debounce="200"
                        />
                      </div>
                      <div class="struct-field">
                        <label>LABEL</label>
                        <input
                          name={"structured[results][#{result_index}][label]"}
                          type="text"
                          value={result["label"]}
                          autocomplete="off"
                          spellcheck="false"
                          phx-debounce="200"
                        />
                      </div>
                      <div class="struct-field">
                        <label>FORM</label>
                        <select name={"structured[results][#{result_index}][form]"}>
                          <option value="prose" selected={result["form"] == "prose"}>PROSE</option>
                          <option value="number" selected={result["form"] == "number"}>
                            NUMBER
                          </option>
                          <option value="url" selected={result["form"] == "url"}>URL</option>
                          <option value="file" selected={result["form"] == "file"}>FILE</option>
                        </select>
                      </div>
                      <div class="struct-field">
                        <label>REQUIRED</label>
                        <select
                          name={"structured[results][#{result_index}][required]"}
                          disabled={result["required_by"] != ""}
                        >
                          <option value="true" selected={result["required"] != "false"}>
                            YES
                          </option>
                          <option value="false" selected={result["required"] == "false"}>
                            NO
                          </option>
                        </select>
                      </div>
                      <div class="struct-field">
                        <label>REQUIRED-BY</label>
                        <select name={"structured[results][#{result_index}][required_by]"}>
                          <option value="" selected={result["required_by"] == ""}>NONE</option>
                          <option
                            :for={{other, other_index} <- Enum.with_index(@structured["results"])}
                            :if={other_index != result_index and other["id"] != ""}
                            value={other["id"]}
                            selected={result["required_by"] == other["id"]}
                          >
                            {other["id"]}
                          </option>
                        </select>
                      </div>
                    </div>

                    <div :if={result["form"] == "file"} class="struct-field">
                      <label>EXTENSIONS (ONE PER LINE)</label>
                      <textarea
                        name={"structured[results][#{result_index}][extensions]"}
                        rows="2"
                        spellcheck="false"
                        phx-debounce="200"
                      >{result["extensions"]}</textarea>
                    </div>
                  </article>
                </fieldset>

                <div class="source-actions">
                  <span :if={@structured_dirty?} class="source-dirty">UNSAVED CHANGES</span>
                  <button class="filter" type="submit">SAVE STRUCTURED</button>
                </div>

                <p :if={@structured_note} class="source-note source-note-block">
                  {@structured_note}
                </p>
              </form>
            </section>

            <section class="config-section">
              <header class="panel-head">
                <h3>RESOLVED <span>{if @snapshot, do: "definition", else: "validation error"}</span></h3>
              </header>
              <pre class="code-block">{@resolved}</pre>
            </section>

            <section :if={@selected && @config_dir} class="config-section">
              <header class="panel-head">
                <h3>PROMPTS <span>{length(@prompts)}</span></h3>
                <span class="panel-meta">SHARED THEN AGENT · FILENAME ORDER</span>
              </header>

              <form class="prompt-create-form" phx-submit="create_prompt">
                <div class="prompt-create-fields">
                  <select name="new_prompt[source]" aria-label="Prompt source">
                    <option value="agent" selected>AGENT</option>
                    <option value="shared">SHARED</option>
                  </select>
                  <input
                    name="new_prompt[filename]"
                    type="text"
                    placeholder="01-system.md"
                    autocomplete="off"
                    spellcheck="false"
                  />
                  <button class="filter" type="submit">CREATE PROMPT</button>
                </div>
                <textarea
                  name="new_prompt[content]"
                  rows="3"
                  placeholder="Optional initial Markdown content"
                  spellcheck="false"
                  phx-debounce="200"
                ></textarea>
              </form>

              <div :if={@prompts == []} class="empty-state inline">
                <p>NO PROMPTS</p>
                <p class="muted">Create a Markdown file above. Shared prompts run before agent prompts.</p>
              </div>

              <article
                :for={{prompt, index} <- Enum.with_index(@prompts)}
                class="prompt-card"
              >
                <header>
                  <span class="prompt-name">{prompt.name}</span>
                  <span class="prompt-source">{ConfigPrompt.label(prompt.source)}</span>
                  <span class="prompt-path">{prompt.path}</span>
                </header>

                <p :if={prompt.error} class="source-note source-note-block">
                  {prompt.error}
                </p>

                <form
                  :if={!prompt.error}
                  id={"prompt-form-#{index}"}
                  class="prompt-form"
                  phx-submit="save_prompt"
                  phx-change="edit_prompt"
                >
                  <input type="hidden" name="prompt_source" value={prompt.source} />
                  <input type="hidden" name="prompt_name" value={prompt.name} />
                  <input type="hidden" name="expected_hash" value={prompt.hash} />
                  <textarea
                    id={"prompt-editor-#{index}"}
                    class="prompt-editor"
                    name="prompt_content"
                    rows="8"
                    spellcheck="false"
                    aria-label={"prompt #{prompt.name}"}
                    phx-debounce="200"
                  >{prompt.draft}</textarea>
                  <div class="source-actions">
                    <span :if={prompt.dirty?} class="source-dirty">UNSAVED CHANGES</span>
                    <button
                      class="filter"
                      type="button"
                      phx-click="delete_prompt"
                      phx-value-prompt_source={prompt.source}
                      phx-value-prompt_name={prompt.name}
                      phx-value-expected_hash={prompt.hash}
                    >
                      DELETE
                    </button>
                    <button class="filter" type="submit">SAVE PROMPT</button>
                  </div>
                </form>
              </article>
            </section>

            <section :if={@snapshot} class="config-section">
              <header class="panel-head">
                <h3>SCRIPTS <span>{length(@scripts)}</span></h3>
              </header>
              <div :if={@scripts == []} class="empty-state inline">
                <p>NO SCRIPTS</p>
              </div>
              <ul class="script-list">
                <li :for={path <- @scripts}>
                  <span class="mono">{script_label(path)}</span>
                </li>
              </ul>
            </section>
          </div>
        </aside>
      </main>
    </div>
    """
  end
end
