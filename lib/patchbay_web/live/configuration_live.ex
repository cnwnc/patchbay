defmodule PatchbayWeb.ConfigurationLive do
  @moduledoc false

  use PatchbayWeb, :live_view

  import PatchbayWeb.Presenter

  alias Patchbay.Config.Source
  alias Patchbay.Definition.Error
  alias Patchbay.DefinitionRegistry

  @pubsub Patchbay.PubSub
  @flash_timeout 6_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, "config")
      :timer.send_interval(1_000, :tick)
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
       pending_select: nil,
       config_dir: nil,
       resolved: "",
       prompts: [],
       scripts: [],
       new_agent_open: false,
       new_agent_id: "",
       new_agent_lifecycle: "one-shot",
       now: DateTime.utc_now()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_id = params["id"]

    socket =
      if discard_draft?(socket, requested_id) do
        socket
        |> assign(source_draft: nil, source_dirty?: false)
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

      socket.assigns.source_dirty? ->
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
        socket = assign(socket, pending_select: nil, source_draft: nil, source_dirty?: false)
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

    {:noreply, load(socket, socket.assigns.selected, reset_source: true)}
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

  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

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

    prompts = if definition, do: definition.prompts, else: []
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
      prompts: prompts,
      scripts: scripts,
      now: DateTime.utc_now()
    )
    |> assign(source_assigns(source_info, socket, selected, opts))
  end

  defp source_assigns(source_info, socket, selected, opts) do
    if preserve_draft?(socket, selected, opts) do
      Map.take(socket.assigns, [
        :source,
        :editable_source,
        :source_hash,
        :source_path,
        :source_absent?,
        :source_editable?,
        :source_note,
        :source_draft,
        :source_baseline,
        :source_dirty?
      ])
    else
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
        source_dirty?: false
      }
    end
  end

  defp preserve_draft?(socket, selected, opts) do
    not Keyword.get(opts, :reset_source, false) and
      selected == socket.assigns.selected and
      not is_nil(socket.assigns.source_draft)
  end

  defp discard_draft?(socket, requested_id) do
    socket.assigns.source_dirty? and is_binary(requested_id) and
      requested_id != socket.assigns.selected
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
    %{display: "", editable: nil, hash: nil, path: nil, absent: false, note: nil}
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
      %{display: raw, editable: raw, hash: hash, path: path, absent: false, note: nil}
    else
      %{
        display: redacted,
        editable: nil,
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

  defp write_source(socket, id, content, expected_hash) do
    config_dir = socket.assigns.config_dir
    expected_hash = normalize_expected_hash(socket, expected_hash)

    with {:ok, path} <- Source.path(config_dir, id),
         :ok <- authoritative_path(socket.assigns.snapshot, path),
         {:ok, _written} <- Source.write(config_dir, id, content, expected_hash) do
      apply_write(socket, id)
    else
      {:error, :stale} ->
        socket
        |> load(id, reset_source: true)
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

  defp apply_write(socket, id) do
    socket =
      case safe(fn -> DefinitionRegistry.reload_agent(id) end) do
        {:ok, _snapshot} ->
          notify(socket, :info, "Source saved. Definition reloaded.")

        {:error, %Error{} = error} ->
          message =
            if socket.assigns.snapshot do
              "Source saved, but the definition is invalid. The last good definition remains active: " <>
                Error.message(error)
            else
              "Source saved, but the definition is invalid: " <> Error.message(error)
            end

          notify(socket, :error, message)

        {:error, :not_found} ->
          notify(
            socket,
            :error,
            "Source saved, but the definition directory was not found during reload."
          )

        {:error, reason} ->
          notify(socket, :error, "Source saved, but reload failed: #{error_detail(reason)}")
      end

    Phoenix.PubSub.broadcast_from(@pubsub, self(), "config", {:config, :reloaded})
    load(socket, id, reset_source: true)
  end

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

  defp short_hash(nil), do: "—"
  defp short_hash(hash), do: String.slice(hash, 0, 12)

  @impl true
  def render(assigns) do
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
          </nav>
          <span class="local">DEFINITIONS <b>{length(@definitions)}</b></span>
          <time class="clock">{Calendar.strftime(@now, "%H:%M:%S")} <small>UTC</small></time>
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

            <section class="config-section">
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

            <section class="config-section">
              <header class="panel-head">
                <h3>RESOLVED <span>{if @snapshot, do: "definition", else: "validation error"}</span></h3>
              </header>
              <pre class="code-block">{@resolved}</pre>
            </section>

            <section :if={@snapshot} class="config-section">
              <header class="panel-head">
                <h3>PROMPTS <span>{length(@prompts)}</span></h3>
              </header>
              <div :if={@prompts == []} class="empty-state inline">
                <p>NO PROMPTS</p>
              </div>
              <article :for={prompt <- @prompts} class="prompt-card">
                <header>
                  <span class="prompt-name">{prompt.name}</span>
                  <span class="prompt-source">{prompt.source}</span>
                  <span class="prompt-path">{prompt.path}</span>
                </header>
                <pre class="code-block">{prompt.content}</pre>
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
