defmodule PatchbayWeb.ToolkitLive do
  @moduledoc false

  use PatchbayWeb, :live_view

  alias Patchbay.Config.Manifest
  alias Patchbay.Definition.Error
  alias Patchbay.DefinitionRegistry

  @pubsub Patchbay.PubSub
  @flash_timeout 6_000
  @exec_placeholder "git or /nix/store/.../bin/tool"
  @arguments_placeholder "clone\nhttps://github.com/owner/repo"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, "config")
      :timer.send_interval(1_000, :tick)
    end

    {:ok,
     assign(socket,
       entries: [],
       selected: nil,
       entry: nil,
       config_dir: nil,
       pending_select: nil,
       source_content: "",
       source_hash: nil,
       source_path: nil,
       source_read_only?: false,
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
       new_manifest_open: false,
       new_manifest_id: "",
       new_manifest_native: "",
       now: DateTime.utc_now()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_id = params["id"]

    socket =
      if discard_draft?(socket, requested_id) do
        socket
        |> assign(source_draft: nil, source_dirty?: false, structured_dirty?: false)
        |> notify(:info, "Discarded unsaved changes to #{socket.assigns.selected}.")
      else
        socket
      end

    {:noreply, load(socket, requested_id)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    cond do
      not Manifest.valid_id?(id) ->
        {:noreply, socket}

      id == socket.assigns.selected ->
        {:noreply, assign(socket, pending_select: nil)}

      socket.assigns.source_dirty? or socket.assigns.structured_dirty? ->
        {:noreply, assign(socket, pending_select: id)}

      true ->
        {:noreply, push_patch(socket, to: ~p"/toolkits/#{id}")}
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
            structured_dirty?: false
          )

        {:noreply, push_patch(socket, to: ~p"/toolkits/#{id}")}
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
    socket = assign(socket, :paused_flashes, MapSet.delete(paused_flashes(socket), kind))

    case Map.fetch(socket.assigns.flash, kind) do
      {:ok, message} ->
        Process.send_after(self(), {:expire_flash, kind, message}, @flash_timeout)
        {:noreply, socket}

      :error ->
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

  def handle_event("edit_source", params, socket) do
    content = manifest_content(params)

    if is_binary(content) and socket.assigns.source_editable? do
      dirty? = content != socket.assigns.source_baseline
      {:noreply, assign(socket, source_draft: content, source_dirty?: dirty?)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_source", params, socket) do
    {:noreply, save_source(socket, params)}
  end

  def handle_event("edit_structured", params, socket) do
    socket =
      if socket.assigns.structured do
        form =
          Manifest.form_from_params(
            structured_params(params),
            socket.assigns.structured
          )

        assign_structured(socket, form)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("add_operation", _params, socket) do
    socket =
      if socket.assigns.structured do
        assign_structured(socket, Manifest.add_operation(socket.assigns.structured))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("remove_operation", %{"index" => index}, socket) do
    socket =
      with structured when not is_nil(structured) <- socket.assigns.structured,
           {:ok, index} <- parse_index(index) do
        assign_structured(socket, Manifest.remove_operation(structured, index))
      else
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("save_structured", params, socket) do
    {:noreply, save_structured(socket, params)}
  end

  def handle_event("new_manifest", _params, socket) do
    {:noreply, assign(socket, new_manifest_open: true)}
  end

  def handle_event("cancel_new_manifest", _params, socket) do
    {:noreply, assign(socket, new_manifest_open: false)}
  end

  def handle_event("create_manifest", params, socket) do
    {:noreply, create_manifest(socket, params)}
  end

  def handle_event("reload", _params, socket) do
    _ = reload_definitions()

    {:noreply,
     socket
     |> load(socket.assigns.selected, reset: true)
     |> notify(:info, "Manifests reloaded from disk.")}
  end

  @impl true
  def handle_info({:config, :reloaded}, socket) do
    if socket.assigns.source_dirty? or socket.assigns.structured_dirty? do
      {:noreply, assign(socket, now: DateTime.utc_now())}
    else
      {:noreply, load(socket, socket.assigns.selected)}
    end
  end

  def handle_info({:expire_flash, kind, message}, socket) do
    expired? =
      not MapSet.member?(paused_flashes(socket), kind) and
        Map.get(socket.assigns.flash, kind) == message

    socket = if expired?, do: clear_flash(socket, kind), else: socket
    {:noreply, socket}
  end

  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

  defp load(socket, requested_id, opts \\ []) do
    config_dir =
      case safe(fn -> DefinitionRegistry.config() end) do
        %{config_dir: directory} -> directory
        _other -> socket.assigns.config_dir
      end

    entries =
      case safe(fn -> Manifest.entries(config_dir) end) do
        entries when is_list(entries) -> entries
        _other -> []
      end

    selected = select_id(entries, requested_id)
    entry = Enum.find(entries, &(&1.id == selected))

    fresh = source_assigns(entry, config_dir, selected)

    assigns =
      if preserve_draft?(socket, selected, opts), do: keep_drafts(socket, fresh), else: fresh

    socket
    |> assign(
      entries: entries,
      selected: selected,
      entry: entry,
      config_dir: config_dir,
      now: DateTime.utc_now()
    )
    |> assign(assigns)
  end

  defp source_assigns(nil, _config_dir, _selected) do
    %{
      source_content: "",
      source_hash: nil,
      source_path: nil,
      source_read_only?: false,
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
      structured_note: "No manifest is selected."
    }
  end

  defp source_assigns(entry, config_dir, selected) do
    info = read_source(entry, config_dir, selected)

    fresh = %{
      source_content: info.content,
      source_hash: info.hash,
      source_path: info.path,
      source_read_only?: info.read_only?,
      source_editable?: info.editable?,
      source_note: info.note,
      source_draft: if(info.editable?, do: info.content, else: nil),
      source_baseline: if(info.editable?, do: info.content, else: nil),
      source_dirty?: false,
      editor_tab: "source"
    }

    Map.merge(fresh, structured_assigns(info, selected, config_dir))
  end

  defp read_source(entry, config_dir, selected) do
    case safe(fn -> Manifest.read(config_dir, selected) end) do
      {:ok, %{content: content, hash: hash, path: path, read_only?: read_only?}} ->
        %{
          content: content,
          hash: hash,
          path: path,
          read_only?: read_only?,
          editable?: not read_only?,
          note:
            if(read_only?,
              do:
                "Embedded manifests are read-only. Create a configuration manifest with the same name to override it."
            )
        }

      {:error, reason} ->
        %{
          content: "Cannot read manifest: #{error_detail(reason)}",
          hash: nil,
          path: entry.path,
          read_only?: entry.source == :builtin,
          editable?: false,
          note: nil
        }

      _other ->
        %{
          content: "",
          hash: nil,
          path: nil,
          read_only?: true,
          editable?: false,
          note: "The manifest is not available."
        }
    end
  end

  defp structured_assigns(info, selected, config_dir) do
    cond do
      info.read_only? ->
        unavailable("Embedded manifests are read-only.")

      not info.editable? ->
        unavailable("The manifest source is not available for editing.")

      true ->
        case safe(fn -> Manifest.load(info.content, info.path) end) do
          {:ok, %{document: document, form: form, errors: errors}} ->
            %{
              structured: form,
              structured_base: form,
              structured_document: document,
              structured_available?: true,
              structured_dirty?: false,
              structured_note: structured_note(errors, selected, config_dir)
            }

          {:error, message} ->
            unavailable(message)

          _other ->
            unavailable("Structured editing is unavailable.")
        end
    end
  end

  defp structured_note([], _selected, _config_dir) do
    "Structured saves keep comments and keys the form does not cover."
  end

  defp structured_note(errors, _selected, _config_dir) do
    "Structured saves are refused until the manifest validates: " <> error_text(errors)
  end

  defp unavailable(note) do
    %{
      structured: nil,
      structured_base: nil,
      structured_document: nil,
      structured_available?: false,
      structured_dirty?: false,
      structured_note: note
    }
  end

  defp keep_drafts(socket, fresh) do
    source_dirty? =
      socket.assigns.source_dirty? and not is_nil(socket.assigns.source_draft)

    structured_dirty? =
      socket.assigns.structured_dirty? and not is_nil(socket.assigns.structured)

    source_draft = if source_dirty?, do: socket.assigns.source_draft, else: fresh.source_draft

    source_baseline =
      if source_dirty?, do: socket.assigns.source_baseline, else: fresh.source_baseline

    source_hash = if source_dirty?, do: socket.assigns.source_hash, else: fresh.source_hash
    structured = if structured_dirty?, do: socket.assigns.structured, else: fresh.structured

    structured_base =
      if structured_dirty?, do: socket.assigns.structured_base, else: fresh.structured_base

    structured_document =
      if structured_dirty?,
        do: socket.assigns.structured_document,
        else: fresh.structured_document

    fresh
    |> Map.put(:source_draft, source_draft)
    |> Map.put(:source_baseline, source_baseline)
    |> Map.put(:source_hash, source_hash)
    |> Map.put(:source_dirty?, not is_nil(source_draft) and source_draft != source_baseline)
    |> Map.put(:structured, structured)
    |> Map.put(:structured_base, structured_base)
    |> Map.put(:structured_document, structured_document)
    |> Map.put(
      :structured_dirty?,
      not is_nil(structured) and structured != structured_base
    )
    |> Map.put(:editor_tab, socket.assigns.editor_tab)
  end

  defp preserve_draft?(socket, selected, opts) do
    not Keyword.get(opts, :reset, false) and socket.assigns.selected == selected and
      (socket.assigns.source_dirty? or socket.assigns.structured_dirty?)
  end

  defp discard_draft?(socket, requested_id) do
    (socket.assigns.source_dirty? or socket.assigns.structured_dirty?) and
      is_binary(requested_id) and requested_id != socket.assigns.selected
  end

  defp select_id(entries, nil), do: first_id(entries)

  defp select_id(entries, requested_id) do
    if Manifest.valid_id?(requested_id) and Enum.any?(entries, &(&1.id == requested_id)) do
      requested_id
    else
      first_id(entries)
    end
  end

  defp first_id(entries), do: Enum.find_value(entries, &(Manifest.valid_id?(&1.id) && &1.id))

  defp create_manifest(socket, params) do
    id = params["manifest_id"] || params["id"]
    id = if is_binary(id), do: String.trim(id), else: ""
    native = if is_binary(params["native"]), do: params["native"], else: ""
    config_dir = socket.assigns.config_dir

    cond do
      is_nil(config_dir) ->
        new_manifest_error(socket, id, native, "the configuration directory is unavailable")

      not Manifest.valid_id?(id) ->
        new_manifest_error(
          socket,
          id,
          native,
          "use a lowercase ID starting with a letter or digit, with dashes, dots, or underscores, up to 64 characters"
        )

      true ->
        case Manifest.create(config_dir, id, native: native) do
          {:ok, entry} ->
            _ = reload_definitions()
            broadcast_reload()

            socket
            |> assign(new_manifest_open: false, new_manifest_id: "", new_manifest_native: "")
            |> notify(:info, "Created manifest #{entry.id}.")
            |> push_patch(to: ~p"/toolkits/#{entry.id}")

          {:error, :exists} ->
            new_manifest_error(socket, id, native, "a manifest with that ID already exists")

          {:error, {:invalid, message}} ->
            new_manifest_error(socket, id, native, message)

          {:error, reason} ->
            new_manifest_error(socket, id, native, error_detail(reason))
        end
    end
  end

  defp new_manifest_error(socket, id, native, detail) do
    socket
    |> assign(new_manifest_open: true, new_manifest_id: id, new_manifest_native: native)
    |> notify(:error, "Create failed: #{detail}.")
  end

  defp save_source(socket, params) do
    id = socket.assigns.selected
    content = manifest_content(params)
    expected_hash = params["expected_hash"] || socket.assigns.source_hash

    cond do
      socket.assigns.structured_dirty? ->
        notify(
          socket,
          :error,
          "Save blocked: the structured editor has unsaved changes. Save or discard them first."
        )

      is_nil(id) ->
        notify(socket, :error, "Save failed: no manifest is selected.")

      socket.assigns.source_read_only? ->
        notify(socket, :error, "Save refused: embedded manifests are read-only.")

      not socket.assigns.source_editable? ->
        notify(socket, :error, "Save failed: the manifest source is not available for editing.")

      is_nil(content) ->
        notify(socket, :error, "Save failed: no source was submitted.")

      true ->
        write_manifest(socket, id, content, expected_hash, :source)
    end
  end

  defp save_structured(socket, params) do
    id = socket.assigns.selected
    form = Manifest.form_from_params(structured_params(params), socket.assigns.structured || %{})
    socket = assign_structured(socket, form)
    expected_hash = params["expected_hash"] || socket.assigns.source_hash

    cond do
      socket.assigns.source_dirty? ->
        notify(
          socket,
          :error,
          "Save blocked: the source editor has unsaved changes. Save or discard them first."
        )

      is_nil(id) ->
        notify(socket, :error, "Structured save failed: no manifest is selected.")

      is_nil(socket.assigns.structured) ->
        notify(socket, :error, "Structured save failed: the manifest is not available.")

      is_nil(socket.assigns.structured_document) ->
        notify(socket, :error, "Structured save failed: the source is not available for editing.")

      true ->
        case Manifest.build(
               socket.assigns.structured_document,
               socket.assigns.structured,
               id,
               socket.assigns.config_dir
             ) do
          {:ok, content} ->
            write_manifest(socket, id, content, expected_hash, :structured)

          {:error, message} ->
            notify(socket, :error, "Structured save rejected: #{message}")
        end
    end
  end

  defp assign_structured(socket, form) do
    assign(socket,
      structured: form,
      structured_dirty?: form != socket.assigns.structured_base
    )
  end

  defp write_manifest(socket, id, content, expected_hash, kind) do
    config_dir = socket.assigns.config_dir

    case safe(fn -> Manifest.write(config_dir, id, content, expected_hash) end) do
      {:ok, _written} ->
        apply_write(socket, id, kind)

      {:error, :stale} ->
        notify(
          socket,
          :error,
          "Save conflict: the manifest changed on disk after it was loaded. Reload to review the external change before saving; the current draft will not overwrite it."
        )

      {:error, :read_only} ->
        notify(socket, :error, "Save refused: embedded manifests are read-only.")

      {:error, {:invalid, message}} ->
        notify(socket, :error, "Save rejected: #{message}")

      {:error, {:io, reason}} ->
        notify(socket, :error, "Save failed: #{:file.format_error(reason)}")

      {:error, reason} ->
        notify(socket, :error, "Save failed: #{error_detail(reason)}")
    end
  end

  defp apply_write(socket, id, kind) do
    tab = socket.assigns[:editor_tab] || "source"

    socket =
      case reload_definitions() do
        {:ok, report} ->
          notify(
            socket,
            :info,
            "#{saved_message(kind)} Definitions reloaded: #{length(report.loaded)} loaded, #{length(report.rejected)} rejected."
          )

        {:error, detail} ->
          notify(
            socket,
            :error,
            "#{saved_message(kind)} Definitions reload failed: #{detail}"
          )
      end

    broadcast_reload()
    socket |> load(id, reset: true) |> assign(:editor_tab, tab)
  end

  defp saved_message(:structured), do: "Structured manifest saved."
  defp saved_message(_kind), do: "Manifest saved."

  defp reload_definitions do
    case safe(fn -> DefinitionRegistry.reload() end) do
      {:ok, report} -> {:ok, report}
      {:error, reason} -> {:error, error_detail(reason)}
    end
  end

  defp broadcast_reload do
    Phoenix.PubSub.broadcast_from(@pubsub, self(), "config", {:config, :reloaded})
  rescue
    _exception -> :ok
  end

  defp manifest_content(%{"source" => %{"content" => content}}) when is_binary(content),
    do: content

  defp manifest_content(%{"source" => content}) when is_binary(content), do: content
  defp manifest_content(%{"content" => content}) when is_binary(content), do: content
  defp manifest_content(%{"text" => content}) when is_binary(content), do: content
  defp manifest_content(_params), do: nil

  defp structured_params(params) when is_map(params) do
    case params["manifest"] do
      structured when is_map(structured) -> structured
      _other -> %{}
    end
  end

  defp structured_params(_params), do: %{}

  defp parse_index(index) when is_integer(index) and index >= 0, do: {:ok, index}

  defp parse_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> :error
    end
  end

  defp parse_index(_index), do: :error

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

  defp error_detail(%Error{} = error), do: Error.message(error)
  defp error_detail({:invalid, message}), do: message

  defp error_detail(reason) when is_atom(reason) do
    case :file.format_error(reason) do
      message when message in [~c"unknown POSIX error", ~c"unknown error"] -> inspect(reason)
      message -> to_string(message)
    end
  end

  defp error_detail(reason), do: inspect(reason)

  defp error_text(errors) when is_list(errors) do
    errors
    |> Enum.map(fn
      %{message: message, path: path} -> "#{Enum.join(path, ".")}: #{message}"
      other -> inspect(other)
    end)
    |> Enum.join("; ")
  end

  defp error_text(other), do: inspect(other)

  defp short_hash(nil), do: "—"
  defp short_hash(hash), do: String.slice(hash, 0, 12)

  defp toolkit_tools(entry) do
    cond do
      entry.tools != [] -> Enum.join(entry.tools, ", ")
      entry.native -> "ALL NATIVE TOOLS"
      true -> "—"
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        exec_placeholder: @exec_placeholder,
        arguments_placeholder: @arguments_placeholder,
        native_options: ["" | Manifest.native_ids()]
      )

    ~H"""
    <div class="console">
      <header class="masthead">
        <div class="brand">
          <span class="mark" aria-hidden="true"></span>
          <span class="wordmark">PATCHBAY</span>
          <span class="divider" aria-hidden="true"></span>
          <span class="view">TOOLKITS</span>
        </div>
        <div class="mast-right">
          <nav class="global-nav" aria-label="Global navigation">
            <a class="nav-link" href={~p"/"}>CONSOLE</a>
            <a class="nav-link" href={~p"/config"}>CONFIG</a>
            <a class="nav-link is-active" href={~p"/toolkits"} aria-current="page">TOOLKITS</a>
          </nav>
          <span class="local">
            MANIFESTS <b>{length(@entries)}</b>
          </span>
          <time class="clock">{Calendar.strftime(@now, "%H:%M:%S")} <small>UTC</small></time>
        </div>
      </header>

      <main class="workspace config-workspace">
        <section class="channels" aria-label="Toolkit manifests">
          <header class="channels-head">
            <h1>TOOLKIT MANIFESTS <span class="count">{length(@entries)}</span></h1>
            <button class="filter" type="button" phx-click="new_manifest">NEW MANIFEST</button>
            <button class="filter" type="button" phx-click="reload">RELOAD</button>
            <div class="sort">
              BUILT-INS <b>{Enum.count(@entries, &(&1.source == :builtin))}</b>
            </div>
          </header>

          <form :if={@new_manifest_open} class="new-agent-form" phx-submit="create_manifest">
            <label for="new-manifest-id">NEW MANIFEST ID</label>
            <div class="new-agent-fields">
              <input
                id="new-manifest-id"
                name="manifest_id"
                type="text"
                value={@new_manifest_id}
                placeholder="manifest-id"
                autocomplete="off"
                spellcheck="false"
              />
              <select name="native" aria-label="Native toolkit">
                <option :for={native <- @native_options} value={native} selected={@new_manifest_native == native}>
                  {if native == "", do: "NO NATIVE", else: String.upcase(native)}
                </option>
              </select>
              <button class="filter" type="submit">CREATE</button>
              <button class="filter" type="button" phx-click="cancel_new_manifest">CANCEL</button>
            </div>
          </form>

          <div class="strip-cols toolkit-row" aria-hidden="true">
            <span>#</span>
            <span>MANIFEST</span>
            <span>SOURCE</span>
            <span>NATIVE</span>
            <span>OPS</span>
            <span>FAIL</span>
          </div>

          <ol class="strips config-list" role="listbox" aria-label="Toolkit manifests">
            <li
              :for={{entry, index} <- Enum.with_index(@entries)}
              class={"strip toolkit-row #{if @selected == entry.id, do: "is-selected on-dark"}"}
              role="option"
              aria-selected={@selected == entry.id}
              aria-disabled={if Manifest.valid_id?(entry.id), do: "false", else: "true"}
              tabindex="0"
              phx-click="select"
              phx-value-id={entry.id}
            >
              <span class="ch">{String.pad_leading(Integer.to_string(index + 1), 2, "0")}</span>
              <div class="agent">
                <span class="agent-name">{entry.id}</span>
                <span class="agent-sub">{entry.description || entry.path || "manifest"}</span>
              </div>
              <span class="config-cell">
                {if entry.source == :builtin, do: "BUILT-IN", else: "CONFIG"}
                <span :if={entry.builtin_override?} class="panel-meta"> · OVERRIDE</span>
              </span>
              <span class="config-cell">{entry.native || "—"}</span>
              <span class="config-cell mono">{length(entry.operations)}</span>
              <span class="config-cell">
                <span :if={entry.error} class="lamp fail"></span>
                <span :if={!entry.error} class="lamp"></span>
              </span>
            </li>
          </ol>

          <div :if={@entries == []} class="empty-state inline">
            <p>NO MANIFESTS</p>
            <p class="muted">Create a manifest or add TOML files under config/toolkits.</p>
          </div>

          <footer class="channels-foot">
            <span class="foot-item">MANIFEST DIR <b>config/toolkits</b></span>
            <span class="foot-item push">READ-ONLY <b>{Enum.count(@entries, &(&1.source == :builtin))}</b></span>
          </footer>
        </section>

        <aside class="inspector config-inspector" aria-label="Manifest detail">
          <div :if={is_nil(@selected)} class="empty-state">
            <span class="lamp idle"></span>
            <p>NO MANIFEST SELECTED</p>
            <p class="muted">Create a manifest, then reload.</p>
          </div>

          <header :if={@selected} class="insp-head on-dark">
            <div class="kicker">
              <span class="sel">MANIFEST</span>
              <span class="kind">{if @entry && @entry.source == :builtin, do: "BUILT-IN", else: "CONFIG"}</span>
              <span :if={@source_hash} class="run-meta">SHA <b>{short_hash(@source_hash)}</b></span>
            </div>
            <div class="insp-title">
              <h2>{@selected}</h2>
              <span class="state-pill state-model">{@entry && (@entry.native || "FIXED OPERATIONS")}</span>
            </div>
            <div class="config-head-meta">
              <span>TOOLS <b>{@entry && toolkit_tools(@entry)}</b></span>
              <span>OPERATIONS <b>{@entry && length(@entry.operations)}</b></span>
            </div>
          </header>

          <div :if={@entry && @entry.error} class="failure-block">
            <span class="label">VALIDATION FAILURE</span>
            <pre class="code-block">{@entry.error}</pre>
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

            <div class="editor-tabs" role="tablist" aria-label="Manifest editor">
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
                <h3>SOURCE <span>{@source_path || "manifest.toml"}</span></h3>
                <span :if={@source_hash} class="panel-meta">SHA {short_hash(@source_hash)}</span>
              </header>

              <form
                :if={@source_editable?}
                id="manifest-source-form"
                class="source-form"
                phx-submit="save_source"
                phx-change="edit_source"
              >
                <input type="hidden" name="expected_hash" value={@source_hash || "absent"} />
                <textarea
                  id="manifest-source-editor"
                  class="source-editor"
                  name="source"
                  rows="24"
                  spellcheck="false"
                  aria-label="manifest TOML source"
                  phx-debounce="200"
                >{@source_draft}</textarea>
                <div class="source-actions">
                  <span :if={@source_dirty?} class="source-dirty">UNSAVED CHANGES</span>
                  <button class="filter" type="submit">SAVE MANIFEST</button>
                </div>
              </form>

              <pre :if={!@source_editable?} class="code-block">{@source_content}</pre>

              <p :if={@source_note} class="source-note source-note-block">{@source_note}</p>
            </section>

            <section :if={@editor_tab == "structured"} class="config-section">
              <header class="panel-head">
                <h3>STRUCTURED <span>{@source_path || "manifest.toml"}</span></h3>
                <span :if={@source_hash} class="panel-meta">SHA {short_hash(@source_hash)}</span>
              </header>

              <div :if={!@structured_available?} class="empty-state inline">
                <p>STRUCTURED EDITING UNAVAILABLE</p>
                <p class="muted">{@structured_note}</p>
              </div>

              <form
                :if={@structured}
                id="manifest-structured-form"
                class="structured-form"
                phx-submit="save_structured"
                phx-change="edit_structured"
              >
                <input type="hidden" name="expected_hash" value={@source_hash || "absent"} />

                <fieldset class="struct-group">
                  <legend>IDENTITY</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="manifest-id">MANIFEST ID</label>
                      <input id="manifest-id" type="text" value={@selected} readonly />
                    </div>
                    <div class="struct-field">
                      <label for="manifest-description">DESCRIPTION</label>
                      <input
                        id="manifest-description"
                        name="manifest[description]"
                        type="text"
                        value={@structured["description"]}
                        autocomplete="off"
                        spellcheck="false"
                        phx-debounce="200"
                      />
                    </div>
                    <div class="struct-field">
                      <label for="manifest-implicit">IMPLICIT</label>
                      <select id="manifest-implicit" name="manifest[implicit]">
                        <option value="false" selected={@structured["implicit"] != "true"}>NO</option>
                        <option value="true" selected={@structured["implicit"] == "true"}>YES</option>
                      </select>
                    </div>
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>NATIVE</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="manifest-native">NATIVE TOOLKIT</label>
                      <select id="manifest-native" name="manifest[native]">
                        <option :for={native <- @native_options} value={native} selected={@structured["native"] == native}>
                          {if native == "", do: "NONE", else: String.upcase(native)}
                        </option>
                        <option
                          :if={@structured["native"] != "" and @structured["native"] not in @native_options}
                          value={@structured["native"]}
                          selected
                        >
                          {@structured["native"]}
                        </option>
                      </select>
                    </div>
                    <div class="struct-field">
                      <label for="manifest-tools">TOOLS (ONE PER LINE; EMPTY MEANS ALL)</label>
                      <textarea
                        id="manifest-tools"
                        name="manifest[tools]"
                        rows="3"
                        spellcheck="false"
                        phx-debounce="200"
                      >{@structured["tools"]}</textarea>
                    </div>
                  </div>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>CONFIG</legend>
                  <div class="struct-grid">
                    <div class="struct-field">
                      <label for="manifest-config-root">FILESYSTEM ROOT</label>
                      <input
                        id="manifest-config-root"
                        name="manifest[config_root]"
                        type="text"
                        value={@structured["config_root"]}
                        placeholder="&#123;%workspace&#125; or work"
                        autocomplete="off"
                        spellcheck="false"
                        phx-debounce="200"
                      />
                    </div>
                    <div class="struct-field">
                      <label for="manifest-config-namespace">MEMORY NAMESPACE</label>
                      <input
                        id="manifest-config-namespace"
                        name="manifest[config_namespace]"
                        type="text"
                        value={@structured["config_namespace"]}
                        placeholder="default"
                        autocomplete="off"
                        spellcheck="false"
                        phx-debounce="200"
                      />
                    </div>
                  </div>
                  <div class="struct-field">
                    <label for="manifest-config-env">
                      ENVIRONMENT SECRETS (NAME=secret://ref, ONE PER LINE)
                    </label>
                    <textarea
                      id="manifest-config-env"
                      name="manifest[config_env]"
                      rows="3"
                      spellcheck="false"
                      phx-debounce="200"
                    >{@structured["config_env"]}</textarea>
                  </div>
                  <p class="panel-meta">
                    Keys outside these native fields are preserved as written.
                  </p>
                </fieldset>

                <fieldset class="struct-group">
                  <legend>OPERATIONS</legend>
                  <div class="struct-toolbar">
                    <span>DECLARED <b>{length(@structured["operations"])}</b></span>
                    <button class="filter" type="button" phx-click="add_operation">
                      ADD OPERATION
                    </button>
                  </div>

                  <article
                    :for={{operation, index} <- Enum.with_index(@structured["operations"])}
                    class="struct-item"
                  >
                    <header class="struct-item-head">
                      <span>OPERATION {index + 1}</span>
                      <button
                        class="filter"
                        type="button"
                        phx-click="remove_operation"
                        phx-value-index={index}
                      >
                        REMOVE
                      </button>
                    </header>

                    <div class="struct-grid">
                      <div class="struct-field">
                        <label>NAME</label>
                        <input
                          name={"manifest[operations][#{index}][name]"}
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
                          name={"manifest[operations][#{index}][executable]"}
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
                          name={"manifest[operations][#{index}][description]"}
                          type="text"
                          value={operation["description"]}
                          autocomplete="off"
                          spellcheck="false"
                          phx-debounce="200"
                        />
                      </div>
                    </div>

                    <div class="struct-field">
                      <label>ARGUMENTS (ONE PER LINE; OMIT THE EXECUTABLE WHEN SET ABOVE)</label>
                      <textarea
                        name={"manifest[operations][#{index}][argv]"}
                        rows="3"
                        placeholder={@arguments_placeholder}
                        spellcheck="false"
                        phx-debounce="200"
                      >{operation["argv"]}</textarea>
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
          </div>
        </aside>
      </main>
    </div>
    """
  end
end
