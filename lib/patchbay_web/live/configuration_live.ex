defmodule PatchbayWeb.ConfigurationLive do
  @moduledoc false

  use PatchbayWeb, :live_view

  import PatchbayWeb.Presenter

  alias Patchbay.Config.Source
  alias Patchbay.Definition.Error
  alias Patchbay.DefinitionRegistry

  @pubsub Patchbay.PubSub

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
       source_editable?: false,
       source_note: nil,
       config_dir: nil,
       resolved: "",
       prompts: [],
       scripts: [],
       now: DateTime.utc_now()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params["id"])}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/config/#{id}")}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    socket =
      case safe(fn -> DefinitionRegistry.reload() end) do
        {:ok, report} ->
          Phoenix.PubSub.broadcast_from(@pubsub, self(), "config", {:config, :reloaded})

          put_flash(
            socket,
            :info,
            "Reloaded: #{length(report.loaded)} loaded, #{length(report.rejected)} rejected, #{length(report.removed)} removed."
          )

        {:error, reason} ->
          put_flash(socket, :error, "Reload failed: #{error_detail(reason)}")
      end

    {:noreply, load(socket, socket.assigns.selected)}
  end

  @impl true
  def handle_event(event, params, socket) when event in ["save", "save_source"] do
    {:noreply, save_source(socket, params)}
  end

  @impl true
  def handle_info({:config, :reloaded}, socket) do
    {:noreply, load(socket, socket.assigns.selected)}
  end

  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

  defp load(socket, requested_id) do
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

    {source_info, resolved} = definition_data(definition)
    prompts = if definition, do: definition.prompts, else: []
    scripts = if definition, do: definition.shared_scripts ++ definition.agent_scripts, else: []

    assign(socket,
      definitions: definitions,
      failures: failures,
      selected: selected,
      snapshot: snapshot,
      failure: failure,
      source: source_info.display,
      editable_source: source_info.editable,
      source_hash: source_info.hash,
      source_editable?: not is_nil(source_info.editable),
      source_note: source_info.note,
      config_dir: config_dir,
      resolved: resolved,
      prompts: prompts,
      scripts: scripts,
      now: DateTime.utc_now()
    )
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

  defp definition_data(nil) do
    {%{display: "", editable: nil, hash: nil, note: nil}, ""}
  end

  defp definition_data(definition) do
    {source_info(definition), resolved_data(definition)}
  end

  defp source_info(%{path: nil}) do
    %{display: "No agent.toml path was recorded.", editable: nil, hash: nil, note: nil}
  end

  defp source_info(%{path: path}) do
    case File.read(path) do
      {:ok, raw} ->
        redacted = redact_source(raw)

        if redacted == raw do
          %{display: raw, editable: raw, hash: Source.hash(raw), note: nil}
        else
          %{
            display: redacted,
            editable: nil,
            hash: Source.hash(raw),
            note: "Editing is disabled because this source contains secret values."
          }
        end

      {:error, reason} ->
        %{
          display: "Cannot read #{path}: #{:file.format_error(reason)}",
          editable: nil,
          hash: nil,
          note: nil
        }
    end
  end

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

  defp save_source(socket, params) do
    id = socket.assigns.selected
    {content, expected_hash} = save_params(params)
    socket = load(socket, id)

    cond do
      is_nil(id) ->
        put_flash(socket, :error, "Save failed: no definition is selected.")

      is_nil(content) ->
        put_flash(socket, :error, "Save failed: no source was submitted.")

      is_nil(socket.assigns.snapshot) ->
        put_flash(socket, :error, "Save failed: the definition is not loaded.")

      is_nil(socket.assigns.source_hash) ->
        put_flash(socket, :error, "Save failed: the source is not available.")

      is_nil(socket.assigns.editable_source) ->
        put_flash(
          socket,
          :error,
          "Save refused: this source cannot be edited because it contains secret values."
        )

      is_nil(socket.assigns.config_dir) ->
        put_flash(socket, :error, "Save failed: the configuration directory is unavailable.")

      true ->
        write_source(socket, id, content, expected_hash)
    end
  end

  defp write_source(socket, id, content, expected_hash) do
    config_dir = socket.assigns.config_dir

    with {:ok, path} <- Source.path(config_dir, id),
         :ok <- authoritative_path(socket.assigns.snapshot, path),
         {:ok, _written} <- Source.write(config_dir, id, content, expected_hash) do
      apply_write(socket, id)
    else
      {:error, :stale} ->
        socket
        |> load(id)
        |> put_flash(
          :error,
          "Save conflict: the source changed on disk after it was loaded. Review it and save again."
        )

      {:error, :not_found} ->
        socket
        |> load(id)
        |> put_flash(:error, "Save failed: the source file no longer exists.")

      {:error, :not_authoritative} ->
        put_flash(
          socket,
          :error,
          "Save failed: the selected definition does not own this source file."
        )

      {:error, :invalid_id} ->
        put_flash(socket, :error, "Save failed: invalid definition identifier.")

      {:error, {:io, reason}} ->
        put_flash(socket, :error, "Save failed: #{:file.format_error(reason)}")

      {:error, reason} ->
        put_flash(socket, :error, "Save failed: #{error_detail(reason)}")
    end
  end

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
          put_flash(socket, :info, "Source saved. Definition reloaded.")

        {:error, %Error{} = error} ->
          put_flash(
            socket,
            :error,
            "Source saved, but the definition is invalid. The last good definition remains active: " <>
              Error.message(error)
          )

        {:error, :not_found} ->
          put_flash(
            socket,
            :error,
            "Source saved, but the definition directory was not found during reload."
          )

        {:error, reason} ->
          put_flash(socket, :error, "Source saved, but reload failed: #{error_detail(reason)}")
      end

    Phoenix.PubSub.broadcast_from(@pubsub, self(), "config", {:config, :reloaded})
    load(socket, id)
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
          <a class="nav-link" href={~p"/"}>CONSOLE</a>
          <span class="local">DEFINITIONS <b>{length(@definitions)}</b></span>
          <time class="clock">{Calendar.strftime(@now, "%H:%M:%S")} <small>UTC</small></time>
        </div>
      </header>

      <main class="workspace config-workspace">
        <section class="channels" aria-label="Definitions">
          <header class="channels-head">
            <h1>DEFINITIONS <span class="count">{length(@definitions)}</span></h1>
            <button class="filter" type="button" phx-click="reload">RELOAD</button>
            <div class="sort">FAILURES <b>{length(@failures)}</b></div>
          </header>

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
              <span class="kind">{lifecycle_label(@snapshot && @snapshot.definition.lifecycle && @snapshot.definition.lifecycle.kind)}</span>
              <span class="run-meta">REV <b>{@snapshot && @snapshot.revision}</b></span>
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

          <div :if={@snapshot} class="config-detail">
            <section class="config-section">
              <header class="panel-head">
                <h3>SOURCE <span>{@snapshot.definition.path || "agent.toml"}</span></h3>
                <span :if={@source_hash} class="panel-meta">SHA {short_hash(@source_hash)}</span>
              </header>

              <form :if={@source_editable?} class="source-form" phx-submit="save">
                <input type="hidden" name="expected_hash" value={@source_hash} />
                <label class="sr-only" for="source-editor">agent.toml source</label>
                <textarea
                  id="source-editor"
                  class="source-editor"
                  name="source"
                  rows="24"
                  spellcheck="false"
                >{@editable_source}</textarea>
                <div class="source-actions">
                  <span class="source-note">ATOMIC REPLACE · STALE WRITES CONFLICT</span>
                  <button class="filter" type="submit">SAVE SOURCE</button>
                </div>
              </form>

              <pre :if={!@source_editable?} class="code-block">{@source}</pre>

              <p :if={@source_note} class="source-note source-note-block">{@source_note}</p>
            </section>

            <section class="config-section">
              <header class="panel-head">
                <h3>RESOLVED <span>definition</span></h3>
              </header>
              <pre class="code-block">{@resolved}</pre>
            </section>

            <section class="config-section">
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

            <section class="config-section">
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
