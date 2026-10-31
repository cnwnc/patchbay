# Patchbay

Patchbay runs declarative agents as supervised worker processes behind a Phoenix management UI. It ships as an escript plus a NixOS module.

## Flake input

```nix
{
  inputs.patchbay.url = "github:cnwnc/patchbay";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, patchbay }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          imports = [patchbay.nixosModules.default];
          services.patchbay.enable = true;
        }
      ];
    };
  };
}
```

`services.patchbay.package` defaults to the package exported by the flake. The module also exposes the package directly:

```sh
nix build .#default
nix run .#default -- help
```

The management endpoint listens on loopback only. Set the port with `services.patchbay.manager.webPort` (default `4000`).

The Console, Configuration, and artifact download routes require HTTP Basic authentication. The password is `PATCHBAY_UI_TOKEN`, the username is ignored. Read the token as root when connecting:

```sh
sudo cat /run/patchbay/ui-token.env
curl -u patchbay:"$PATCHBAY_UI_TOKEN" http://127.0.0.1:4000/
```

For remote browsers, use an SSH tunnel such as `ssh -L 4000:127.0.0.1:4000 host` rather than exposing the port.

## Configuration layout

The manager reads definitions from `services.patchbay.configDir` (default `/etc/patchbay`):

```text
<config_dir>/
  agents/<id>/agent.toml          required
  agents/<id>/prompts/*.md        optional; .md and .markdown are loaded
  agents/<id>/scripts/*           optional; any regular file
  shared/prompts/*.md             optional; loaded before agent prompts
  scripts/*                       optional; any regular file
  toolkits/*.toml                 optional toolkit manifests
```

The workspace, result, state, runtime, transcript, and per-agent roots are separate manager and worker-supervisor state, not part of the config tree. `services.patchbay.stateDir` and `services.patchbay.agentStateDir` hold them.

`Patchbay.Definition.load/2` resolves the config root automatically when the agent directory ends in `agents/<id>`; otherwise pass `config_root:`. The `id` in `agent.toml` must match the agent directory name. The registry ignores symlinked agent directories and symlinked `agent.toml` files and rescans only when `reload/1` is called; there is no file watcher.

`Patchbay.Definition.parse/2` validates a TOML document without reading prompts, scripts, or the filesystem. Toolkit manifests are resolved by `parse/2` only when `toolkit_dirs:` is supplied.

### Configuration editor

The `/config` route has SOURCE and STRUCTURED tabs for the selected definition. Both save through the revision-checked `Patchbay.Config.Source.write/4`; a file changed after it was loaded produces a save conflict instead of an overwrite.

The STRUCTURED tab is available when the definition validates and `agent.toml` parses. It edits the agent ID (read-only), model name, provider, and reasoning; lifecycle kind, schedule, overlap, and catch-up; `[[lifecycle.init]]` and `[[lifecycle.finalize]]` hooks; environment packages; context recovery and compaction thresholds; teardown workspace; budgets; toolkits and results. Invalid or blank definitions use the source editor only.

Toolkits are added by picking from the manifests the manager can resolve (the built-in `filesystem`, `personal-memory`, `secret-env`, and `terminal` manifests, plus every `toolkits/*.toml` under the config directory) or by typing any manifest name. Each row shows the tools the resolved manifest exposes, so a declared native toolkit's tool surface is visible. The native config the schema defines is editable per native: the `filesystem` root (which must pass the native toolkit check), the `personal-memory` namespace, and `secret-env` lines of the form `NAME=secret://<name>`. Secret references are declarations, not secret bytes: the structured editor shows and rewrites the lines, even though the source tab hides sources that carry `secret://` references.

Inline `[[toolkits.operations]]` are edited with executable, argv, and model-facing arguments. Argument rows carry the type (string, number, integer, boolean, enum, path, file, directory), an explicit required flag, and for `enum` the accepted values. Lifecycle hooks use the fixed-operation schema with its hook restrictions (absolute executable, no model-facing arguments); the placeholders use `/nix/store/.../bin/tool` to keep paths absolute and NixOS-neutral. Context recovery offers every accepted word grouped by what it does today: keep-side values (keep, carry, handoff, prompt, full, all, continue, resume, checkpoint, queryable) and reset-side values (reset, none, fresh, clear, drop, new). Several words currently map to the same keep or reset behavior and the option labels say so. Results are edited with form, required, `required-by`, and `extensions`; an `""` extensions line declares the empty-string extension that matches files without any extension. Result IDs, `required-by` references, dependency cycles, argument declarations, hook argv, and secret reference syntax are validated before writing.

Structured saves apply edits to the parsed TOML document. Comments, key order, and keys the form does not cover are kept; fields changed through the form are written in normalized TOML. A blank model name is written as `"default"`. Unsaved source and structured changes survive reload broadcasts. Switching definitions asks before discarding, and RELOAD discards them.

Kept intentionally source-only:

- Top-level `[[operations]]`: it is accepted by `Definition.parse/2`, but definitions loaded from the config tree drop inline operations whose names are new to the resolved manifest, so fixed operations belong in a manifest. The editor edits `[[toolkits.operations]]` only.
- The `[context]` compaction aliases (`compact-threshold`, `compact-at`, `compact-target`, `compact-to`): editing a compaction field writes `threshold` or `target`, leaving the aliases in place for other tooling.
- `format-version`, and the lifecycle `one_shot` spelling, which is normalized to `one-shot` on edit.
- Manifest files themselves (`<config_dir>/toolkits/*.toml`), scripts, and the agent directory layout.
- Prompt and script files: the tab inventories their names, sources, and paths, and prompt texts are shown read-only. Edit prompt files on disk.
- Provider selection: the `[model] provider` value is stored on the definition, while the manager's configured provider module decides the transport.

## Agent reference

Unknown top-level keys and unknown keys in most tables are ignored. Validation errors list a TOML path such as `["lifecycle", "schedule"]`.

### Top-level keys

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `format-version` | integer | yes | Must be `1`. |
| `id` | string | yes | Agent identifier. Non-empty, not `.` or `..`, no `/` or `\`, and equal to the agent directory name when loading from disk. |
| `model` | table | yes | Provider model selection. |
| `lifecycle` | table | yes | Activation mode and hooks. |
| `environment` | table | no | Declared Nix packages. Currently validated and retained only. |
| `toolkits` | array of tables | no | Toolkit instances and manifest references. |
| `operations` | array of tables | no | Shorthand for one implicit `fixed` toolkit. |
| `context` | table | no | Context recovery and compaction policy. |
| `teardown` | table | no | Declared workspace disposition. Currently validated and retained only. |
| `budgets` | table | no | Declared per-run limits. Currently not enforced. |
| `results` | array of tables | no | Values the agent submits through `complete_task`. |

### `[model]`

| Key | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `name` | string | no | configured model | Provider model sent in requests. Omit it, or write `"default"`, to use the configured `PATCHBAY_LLM_MODEL`, then `OPENAI_MODEL`; any other value is sent literally. |
| `provider` | string | no | `"default"` | Stored on the definition. Provider selection is the manager's configured provider module, currently the OpenAI-compatible provider; this field does not select a module. |
| `reasoning` | string | no | — | Stored on the definition. It is not forwarded to the provider. |

### `[lifecycle]`

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `kind` | enum | yes | `one-shot`, `one_shot`, `scheduled`, or `perpetual`. |
| `schedule` | string | scheduled only | Five-field cron expression, interpreted in UTC. |
| `overlap` | enum | scheduled only | Only `forbid` is accepted. Omission behaves the same: a scheduled activation is skipped while that agent is active. `allow` and `queue` are rejected. |
| `catch-up` | enum | scheduled only | `none` (default when omitted), `once`, or `all`. Applies when more than one cron occurrence was missed. `all` replays occurrences up to a limit of 100. |
| `init` | array of tables | no | Hooks run after the worker is ready and before the first model turn. |
| `finalize` | array of tables | no | Hooks run when a run completes, fails, is stopped, or fails to start. |

`one-shot` and `perpetual` definitions are not scheduled by the scheduler; they are activated manually. `perpetual` restores prior context by default across closed runs; `one-shot` and `scheduled` reset context by default unless `[context]` says otherwise. `schedule`, `overlap`, and `catch-up` on a non-scheduled lifecycle are validation errors.

Supported cron forms are `*`, a number, `a-b`, `*/n`, `a-b/n`, and comma-separated lists of those. Month and weekday names, seconds fields, and `@daily`-style aliases are not accepted. Definition loading only checks that `schedule` is a string; cron syntax is validated by the scheduler when it processes the definition.

#### Lifecycle hooks

`[[lifecycle.init]]` and `[[lifecycle.finalize]]` use the fixed-operation schema with two restrictions: model-facing arguments cannot be declared or referenced, and the executable must be an absolute path.

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | Hook name, `[A-Za-z0-9_-]{1,64}`. |
| `description` | string | no | Recorded description. |
| `executable` | string | no | Absolute executable path. When omitted, `argv[0]` is the executable. |
| `argv` | array of strings | yes | Arguments. May be empty when `executable` is set. When `executable` is omitted, `argv` must be non-empty and `argv[0]` must be absolute. |

Hooks run without a shell, with the agent workspace as the working directory when it exists, or the manager's working directory otherwise. Hook argv supports fixed variables only. A failing init hook fails the start. A failing finalize hook is reported as a `hook_failed` event and does not undo the completed, failed, or stopped run.

### `[environment]`

| Key | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `packages` | array of strings | no | `[]` | Non-empty package names, must be unique. Accepted and retained on the definition; no worker package installation or environment composition currently consumes this list. |

### `[[toolkits]]`

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `toolkit` | string | yes | Manifest name to resolve. Must match `[a-z0-9][a-z0-9._-]{0,63}`. |
| `description` | string | no | Used when the resolved manifest has no description. |
| `config` | table | no | Merged over the manifest `config`; values in the agent declaration win. |
| `operations` | array of tables | no | Inline fixed operations. `Patchbay.Definition.parse/2` accepts any inline operation. Under `Patchbay.Definition.load/2`, an inline operation with the same name replaces the manifest operation, while an inline operation with a new name is dropped during manifest merging. Duplicate inline names are rejected. |

Manifest lookup checks `<config_root>/toolkits/<name>.toml`, then the application's `priv/toolkits/<name>.toml`, then the manifests embedded in the executable. Passing `toolkit_dirs:` replaces the two directory searches; embedded manifests remain as a fallback. A name that resolves nowhere is a validation error.

The resolved manifest supplies `native`, `tools`, `config`, and manifest operations. If the toolkit resolves to a native toolkit, its tools are exposed according to the manifest `tools` list. Fixed operations are always exposed.

### Top-level `[[operations]]`

Top-level `[[operations]]` is parsed as one implicit toolkit named `fixed` with `source: :inline`, appended after declared toolkits. It uses the same operation schema as `[[toolkits.operations]]` and is accepted by `Patchbay.Definition.parse/2` without a manifest.

`Patchbay.Definition.load/2` resolves every non-nil toolkit name through manifest lookup, including the implicit `fixed` toolkit, and then merges manifest operations. A definition loaded from disk that uses top-level `[[operations]]` fails with `unknown toolkit "fixed"` unless `<config_root>/toolkits/fixed.toml` exists. Even with that manifest, only inline names that already exist in the manifest survive the merge; new operations are dropped. Add fixed operations to a manifest when definitions are loaded from the config tree.

### `[context]`

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `between-runs` | string | no | Context decision between closed runs. |
| `prior-runs` | string | no | Fallback context decision when `between-runs` is unset or unrecognized. |
| `restore-interrupted` | string | no | Context decision for an interrupted run. |
| `threshold` | non-negative integer | no | Token estimate that triggers compaction. Alias: `compact-threshold`, `compact-at`. |
| `target` | non-negative integer | no | Retained-suffix token target after compaction. Alias: `compact-target`, `compact-to`. |

Recovery values are matched case-insensitively after trimming:
- keep values: `keep`, `carry`, `handoff`, `prompt`, `full`, `all`, `continue`, `resume`, `checkpoint`, `queryable`
- reset values: `reset`, `none`, `fresh`, `clear`, `drop`, `new`
- any other string is treated as unset, so it falls back to the next rule or the lifecycle kind

When the last stored run is interrupted:
- `restore-interrupted = keep` restores all prior runs when the prior-run policy keeps them, otherwise restores only the current run.
- `restore-interrupted = reset` starts with no messages.
- unset falls back to the prior-run policy; failing that, `scheduled` restores the current run and other kinds reset.

When the last stored run is closed:
- `between-runs = keep` restores all prior runs.
- `between-runs = reset` starts with no messages.
- unset consults `prior-runs`; if that is also unset, `perpetual` restores all prior runs and other kinds reset.

With no stored run, context is always reset.

Compaction is enabled when `threshold` is greater than zero. After a model response, a token estimate above the threshold starts compaction: older messages are summarized through the configured provider, a recent suffix is retained, the full generation is archived under `<state_dir>/context/<agent>/archive`, and the current context is replaced only after summarization and archiving succeed. `target` defaults to half of `threshold` and is clamped below `threshold`; `threshold = 0` disables compaction.

### `[teardown]`

| Key | Type | Required | Values |
| --- | --- | --- | --- |
| `workspace` | enum | no | `retain`, `export`, `destroy` |

The value is parsed, validated, and retained on the definition. No workspace teardown action currently consumes it.

### `[budgets]`

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `run-seconds` | non-negative integer | no | Declared per-run wall-clock limit. Not enforced. |
| `tokens` | non-negative integer | no | Declared per-run token limit. Displayed in the management UI; not enforced. |

### `[[results]]`

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | Result identifier. Must be unique within the definition. |
| `label` | string | yes | Human-readable description; used as the provider property description. |
| `form` | enum | yes | `prose`, `number`, `url`, or `file`. |
| `required` | boolean | no | Defaults to `true`. Mutually exclusive with `required-by`. |
| `required-by` | string | no | Must name another declared result. Sets `required` to `false` and records the dependency. |
| `extensions` | array of strings | no | Only valid for `form = "file"`; defaults to `[]`. Empty strings are allowed and match a file without an extension. When `extensions` is non-empty a submitted file must carry a matching extension. |

All results are returned through the implicit `complete_task` tool under a `results` object. Every result whose `required` is true must be present; unknown result ids are rejected. `number` values must be JSON numbers; `prose`, `url`, and `file` values must be non-empty strings that name a file. When a `required-by` dependency is submitted, the result carrying `required-by` must be submitted too. A `file` result must carry an extension in the declared `extensions` list when one is declared (case and leading dots are ignored). Duplicate result ids, unknown dependencies, and dependency cycles are validation errors.

#### Published artifacts

File results are published before the run's worker exits. The values are paths inside the agent workspace or result directory, relative to it. Because the workspace belongs to the agent user and the manager does not, the manager reads the bytes through a reserved worker operation, `patchbay-read-artifact`: the worker stays confined to its own workspace and result directory and refuses anything else, including symlink escapes. The copy is written to `<state_dir>/artifacts/<agent-id>/` with manager-owned `0700` directories and `0600` files, so it outlives the worker and any later workspace teardown and cannot be read by the agent user.

Published bytes are capped (8 MiB per artifact by default) and read in bounded chunks over the worker session; a file larger than the cap is not published and the run records an `artifact_publish_failed` event instead. Public names keep the source extension and are collision resistant: `<memorable-slug>-<run-tag>-<random>.<ext>`, for example `prepared-report-p9m2-axq4jpzm.md`, built from the result id and file stem, a short tag for the run, and eight random base32 characters. Publication of every file result is recorded as an `artifact_published` event; failures are recorded as `artifact_publish_failed` and do not otherwise fail the run.

Run records in the transcript still contain the submitted result values, not the published bytes. Publication does not touch transcript permissions.

#### Downloading artifacts

Artifacts are served from the management endpoint by the same UI credentials as the Console, under `GET /artifacts/<agent-id>/<filename>`:

```sh
curl -u patchbay:"$PATCHBAY_UI_TOKEN" \
  -O http://127.0.0.1:4000/artifacts/researcher/prepared-report-p9m2-axq4jpzm.md
```

The name must be a single published file; malformed names and traversal attempts are refused, and unknown or non-file names return `404` rather than revealing anything about the directory. Content types come from an allowlist of extension to type mappings (text, markdown, CSV, JSON, log, and common image and PDF types are served inline); every other extension, including executables, HTML, and SVG, is served as `application/octet-stream` with an `attachment` disposition. The route never serves workspace or transcript paths, only the manager-owned copies.

The runtime exposes `Patchbay.Runtime.list_artifacts(server, agent_id)` and `Patchbay.Runtime.artifact(server, agent_id, name)` for a future UI; the endpoint is loopback-only, and remote operators should use an SSH tunnel as with the rest of the UI.

### Complete example

`<config_dir>/agents/researcher/agent.toml`:

```toml
format-version = 1
id = "researcher"

[model]
provider = "default"
name = "gpt-4.1-mini"
reasoning = "medium"

[lifecycle]
kind = "scheduled"
schedule = "0 7 * * *"
overlap = "forbid"
catch-up = "once"

[[lifecycle.init]]
name = "prepare"
executable = "/bin/sh"
argv = ["-c", 'mkdir -p "$1"', "sh", "{%workspace}"]

[[lifecycle.finalize]]
name = "record"
argv = ["/bin/sh", "-c", 'printf "%s\n" "$1" > "$2/final-state"', "sh", "{%run_state}", "{%result_dir}"]

[environment]
packages = ["git", "ripgrep"]

[[toolkits]]
toolkit = "filesystem"

[toolkits.config]
root = "agents/researcher/work"
max_read_bytes = 131072
max_list_entries = 200

[context]
between-runs = "handoff"
prior-runs = "queryable"
restore-interrupted = "checkpoint"
threshold = 60000
target = 20000

[teardown]
workspace = "destroy"

[budgets]
run-seconds = 1800
tokens = 1000000

[[results]]
id = "report"
form = "prose"
label = "Summary of completed work"

[[results]]
id = "patch"
form = "file"
required-by = "report"
extensions = ["patch", "diff", ""]
label = "Patch artifact, when one was produced"
```

## Toolkit manifests

A manifest is loaded from `<config_root>/toolkits/<name>.toml`, the application's `priv/toolkits`, or the embedded manifests. The requested toolkit name selects the file; the manifest's own `name` is informational and is not required to match the filename. If omitted, it is inferred from the filename. When present it must match `[a-z0-9][a-z0-9._-]{0,63}`.

Manifest keys may appear at the top level or inside a `[toolkit]` table. With the table form, operations are `[[toolkit.operations]]` and config is `[toolkit.config]`.

| Key | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `name` | string | no | filename stem | Informational identifier. |
| `description` | string | no | — | Toolkit description. |
| `native` | string | no | — | Registered native toolkit id. Built-ins: `filesystem`, `personal-memory`, `secret-env`, `terminal`. Other ids work only when registered at runtime. |
| `implicit` | boolean | no | `false` | Makes the manifest's tools available to every agent. Only manifests whose `native` is `terminal` are accepted as implicit; other implicit manifests are ignored for global tool lists. |
| `tools` | array of strings | no | `[]` | Selects native tool names. Empty means every tool the native toolkit provides. It does not filter fixed operations. |
| `config` | table | no | `{}` | Toolkit configuration. The agent declaration's `[toolkits.config]` is merged over it. |
| `operations` | array of tables | no | `[]` | Fixed operations supplied by the manifest. |

A manifest may declare a native toolkit, fixed operations, or both. TOML never contains a module name, so manifests cannot load Elixir code. A configuration manifest may override the built-in `terminal` manifest, but cannot introduce a different implicit native toolkit into every agent's tool list.

### `[[operations]]`

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | Tool name exposed to the model, `[A-Za-z0-9_-]{1,64}`. |
| `description` | string | no | Tool description. Defaults to `Runs the fixed operation <name>.` when exposed to the model. |
| `executable` | string | no | Absolute executable path. When omitted, `argv[0]` is the executable and the rest are arguments. |
| `argv` | array of strings | yes | Arguments, or executable plus arguments. Must be non-empty when `executable` is omitted; may be empty when it is set. |
| `arguments` | table, array of tables, or child tables | no | Model-facing argument declarations. |

Each operation uses one argument-declaration form: an `arguments` table, `arguments` as an array of tables, or child tables directly under the operation.

```toml
# arguments table
[[operations]]
name = "one"
argv = ["/bin/echo", "{target}"]

[operations.arguments.target]
type = "string"

# arguments as an array of tables; each entry needs a name
[[operations]]
name = "two"
argv = ["/bin/echo", "{mode}"]

[[operations.arguments]]
name = "mode"
type = "enum"
values = ["dev", "prod"]

# child tables, excluding the reserved keys
[[operations]]
name = "three"
argv = ["/bin/echo", "{target}"]

[operations.target]
type = "path"
required = false
```

An `arguments` inline table such as `arguments = { target = { type = "string" } }` uses the same table form.

Reserved operation keys are `name`, `executable`, `argv`, `arguments`, and `description`. An argument may not be declared in both `arguments` and a child table.

| Argument key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `type` | enum | yes | `string`, `number`, `integer`, `boolean`, `enum`, `path`, `file`, or `directory`. |
| `values` | array of strings | enum only | Non-empty list of accepted values. Rejected for other types. |
| `required` | boolean | no | Defaults to whether the argument appears as `{name}` in `argv`. An explicit value wins. |

Argument names must match `[A-Za-z_][A-Za-z0-9_-]*`. At call time unknown arguments and missing required arguments are rejected. `integer` arguments must be integers; `number` arguments must be numbers; `boolean` arguments must be booleans; `enum` arguments must match `values`. `path`, `file`, and `directory` arguments are resolved relative to the agent workspace, must stay below that workspace after symlink resolution, and `~` paths are rejected. `file` and `directory` also require an existing file or directory. They are passed to argv as absolute paths.

A manifest that combines a native toolkit with fixed operations, at `<config_dir>/toolkits/release.toml`:

```toml
name = "release"
description = "Release helper operations."
native = "filesystem"
tools = ["read_file", "list_directory"]

[config]
root = "agents/researcher/work"

[[operations]]
name = "checksum"
description = "Print the SHA-256 checksum of one workspace file."
executable = "/usr/bin/sha256sum"
argv = ["{artifact}"]

[operations.arguments.artifact]
type = "file"
required = true
```

An agent references it with:

```toml
[[toolkits]]
toolkit = "release"
```

### Placeholders and fixed variables

Templates use `{%name}` for fixed variables and `{name}` for model-facing arguments. `{{` and `}}` produce literal braces. Other brace sequences that do not form a token stay literal. Substitution is single pass: substituted values are never rescanned. An argv element is never split into multiple elements.

Fixed variables:

| Variable | Value |
| --- | --- |
| `{%workspace}` | Agent workspace. Operations fail if argv uses it and no workspace is available. |
| `{%result_dir}` | Agent result directory. |
| `{%agent_id}` | Agent id. |
| `{%run_id}` | Current run id, when a run exists. |
| `{%attempt_id}` | Current attempt id, when an attempt exists. |
| `{%agent_state}` | Current agent status string. |
| `{%run_state}` | Current run status string. |
| `{%agent_scripts}` | `<agent_dir>/scripts` path. |
| `{%shared_scripts}` | `<config_root>/scripts` path. |

A fixed variable whose value is unavailable fails rendering. Fixed variables and model argument references are validated at definition load time: unknown fixed variables, undeclared model arguments, and model arguments in lifecycle hooks are errors.

Operations execute without a shell. Fixed operations and their arguments run in the worker process with the workspace as the working directory. Native toolkits run in the manager process. Worker operation children receive an allowlisted process environment; provider credentials and `PATCHBAY_*` control tokens are not inherited. Tool names are deduplicated after combining implicit and declared toolkits, with earlier declarations winning; implicit terminal tools come first.

## Native toolkits

### Terminal

The built-in `terminal` manifest is implicit and supplies `complete_task` and `fail_task` to every agent. Its schemas are generated from the agent's `[[results]]`. Calls are intercepted by the agent runner and never reach `Terminal.execute/3`. Do not remove the implicit terminal manifest; an agent may also declare `toolkit = "terminal"` explicitly without adding duplicate tools.

### Filesystem

Declare the built-in filesystem toolkit to expose `read_file`, `list_directory`, `write_file`, and `edit_file`:

```toml
[[toolkits]]
toolkit = "filesystem"

[toolkits.config]
root = "agents/researcher/work"
max_read_bytes = 131072
max_write_bytes = 131072
max_list_entries = 200
```

| Config key | Type | Default | Hard limit | Meaning |
| --- | --- | --- | --- | --- |
| `root` | string | required | — | Confinement root for all model-supplied paths. |
| `max_read_bytes` | positive integer | 262144 | 4194304 | Maximum bytes read for one file. |
| `max_write_bytes` | positive integer | 262144 | 4194304 | Maximum bytes written or edited in one file. |
| `max_list_entries` | positive integer | 500 | 10000 | Maximum directory entries returned by one listing. |

Values above a hard limit are capped to the hard limit. Invalid or non-positive limits fall back to the default.

Filesystem tools execute in the manager process rather than the isolated worker, so absolute roots are checked against manager-owned paths.

A relative `root` is resolved against the agent's config root and must resolve strictly below it; `.` and `..` roots are rejected. An absolute `root` is trusted operator configuration and may point at an agent workspace or project directory outside the config tree, but it must not overlap `/proc` or the manager's state, runtime, or secret paths. The protected paths are the manager state and runtime directories plus any of `PATCHBAY_CONTROL_TOKEN_FILE`, `PATCHBAY_UI_TOKEN_FILE`, `PATCHBAY_SECRET_KEY_BASE_FILE`, and `PATCHBAY_SIGNING_SALTS_FILE` present in the environment. A relative root without an available absolute config root is a validation error.

Every model-supplied filesystem path is relative to the effective root, is checked component by component, and stays below the root. Existing and missing paths are resolved through existing symlinks, so a link that leaves the root is rejected before any read or write. Paths are limited to 4096 bytes. Reads, writes, edits, and directory listings are bounded, and writes are atomic within the target directory.

### Personal memory

Declare the built-in personal memory toolkit to expose `remember`, `append_memory`, `read_memory`, `list_memories`, `recall`, and `delete_memory`:

```toml
[[toolkits]]
toolkit = "personal-memory"

[toolkits.config]
namespace = "research"
max_read_bytes = 131072
max_recall_results = 5
```

Memories are stored as Markdown below `<state_dir>/personal-memory/<agent-id>/<namespace>`. The agent id comes from the execution context, so agents never share a memory directory even when they use the same topic path. The namespace comes from the toolkit config and defaults to `default`. Directories are created `0700` and memory files `0600`.

`remember` writes or overwrites a file, `append_memory` appends to an existing file or creates it when a `summary` is supplied, and `read_memory` returns the whole file. Both writing tools store a one-line summary as the Markdown first line (`# summary`). Topics are relative names; a missing `.md` extension is added. Absolute topics, `.` and `..` components, embedded separators, and control characters are rejected. Every existing path component is inspected with `lstat/1`, so a symlink cannot redirect a read, write, append, or move out of the namespace.

`list_memories` returns `<path>\t<summary>` lines. `recall` tokenizes its query, ranks summary matches above body matches, and bounds both the number of results and the rendered output. `delete_memory` moves the file into `<agent-id>/.trash/<namespace>/<timestamp>/` and leaves the bytes on disk.

| Config key | Type | Default | Hard limit | Meaning |
| --- | --- | --- | --- | --- |
| `namespace` | string | `default` | — | Single directory name below the agent's memory root. `.trash` is reserved. |
| `max_read_bytes` | positive integer | 262144 | 4194304 | Maximum bytes read by `read_memory`. |
| `max_write_bytes` | positive integer | 262144 | 4194304 | Maximum bytes written by one `remember` or `append_memory` call. |
| `max_entries` | positive integer | 500 | 10000 | Maximum memory entries returned by `list_memories`. |
| `max_scan_entries` | positive integer | 5000 | 50000 | Maximum memory entries examined by `recall`. |
| `max_recall_results` | positive integer | 10 | 50 | Default and maximum result count for `recall`. |
| `max_output_bytes` | positive integer | 8192 | 65536 | Maximum rendered bytes returned by `recall`. |

Values above a hard limit are capped to the hard limit. Invalid or non-positive limits fall back to the default.

### Secret environment

The built-in `secret-env` toolkit exposes no tools. Declaring it with a `[toolkits.config.env]` table injects referenced named secrets into that agent's worker environment. See [Secrets](#secrets) for the store, schema, CLI, and redaction behavior.

## Prompts and scripts

Prompt files are enabled by presence. Only regular files whose names end in `.md` or `.markdown` are loaded from the top level of a prompts directory; nested files and other extensions are ignored. Shared prompts from `<config_root>/shared/prompts` come before agent prompts from `<agent_dir>/prompts`, and each group is ordered lexically by filename. Each prompt becomes a system message carrying its filename. If no prompts are enabled, the agent receives one system message: `You are agent <id>.`

Script files are regular files at the top level of `<config_root>/scripts` and `<agent_dir>/scripts`, ordered lexically. Every regular file is recorded regardless of extension or executable bit. Scripts are not copied into the workspace, added to `PATH`, or run automatically. Use `{%shared_scripts}` and `{%agent_scripts}` in operation or hook argv to refer to their directories. `<config_root>/shared/scripts` is not read.

## Provider environment

The manager resolves provider settings from its own environment; workers do not receive provider credentials. Values resolve from explicit options, then `PATCHBAY_LLM_*`, then `OPENAI_*`:

- base URL: `PATCHBAY_LLM_BASE_URL`, then `OPENAI_BASE_URL`, then `OPENAI_API_BASE`, default `https://api.openai.com/v1`
- API key: `PATCHBAY_LLM_API_KEY`, then `OPENAI_API_KEY`
- model: `PATCHBAY_LLM_MODEL`, then `OPENAI_MODEL`

An explicit agent `[model] name` takes precedence over the environment model. An omitted `name`, or `"default"`, resolves to the configured environment model; a run cannot start when neither is set. The OpenAI-compatible provider requires an API key only when the base URL is the default OpenAI URL; a custom base URL may run without one. No dotenv file is read.

Non-secret values such as the base URL can use `services.patchbay.manager.environment`. Put `PATCHBAY_LLM_API_KEY` or `OPENAI_API_KEY` in a manager environment file configured with `services.patchbay.manager.environmentFiles`.

The module generates `PATCHBAY_CONTROL_TOKEN` at `services.patchbay.controlTokenFile` (default `/run/patchbay/control-token.env`), `PATCHBAY_UI_TOKEN` at `services.patchbay.uiTokenFile` (default `/run/patchbay/ui-token.env`), `SECRET_KEY_BASE` at `services.patchbay.secretKeyBaseFile` (default `<stateDir>/secret-key-base`), and the Phoenix session and LiveView signing salts at `services.patchbay.signingSaltsFile` (default `<stateDir>/web-signing-salts.env`). The control token is loaded by both services; the UI token, secret key base, and signing salts are loaded only by the manager. Back up or preserve these files if browser sessions must survive a state wipe.

## Secrets

Named secrets live in a manager-only store, never in the configuration tree. `services.patchbay.secretsDir` defaults to `<stateDir>/secrets` and is exposed as `PATCHBAY_SECRETS_DIR`. The directory is created `0700`; each secret is one file created `0600`. The store is not readable by the agent user, the worker supervisor, or workers.

```text
<secrets_dir>/
  github-main
  registry-token
```

A secret file contains the raw value. Reads return the bytes unchanged. The CLI removes exactly one trailing `\n` or `\r\n` from **input**, so `printf 'value\n' | patchbay secrets set github-main` stores `value`; use `printf 'value'` when the trailing newline is part of the secret.

Secret names match `[a-z0-9][a-z0-9._-]{0,63}`. Names are single path components; `/`, `\`, NUL, `.`, and `..` are refused before any path is built. Reads and deletes refuse symlinks and non-regular files, so a planted link cannot redirect the manager outside the store.

### Managing secrets

The CLI works directly on the store and does not require the manager service:

```sh
sudo -u patchbay patchbay secrets list
sudo -u patchbay env PATCHBAY_STATE_DIR=/var/lib/patchbay \
  patchbay secrets set github-main
sudo -u patchbay env PATCHBAY_STATE_DIR=/var/lib/patchbay \
  patchbay secrets get github-main
sudo -u patchbay env PATCHBAY_STATE_DIR=/var/lib/patchbay \
  patchbay secrets delete github-main
```

`set` reads the value from standard input; a value is never accepted as an argument, so it does not appear in the process list or shell history. `list` prints names only, `get` writes the raw value to stdout, and `delete` removes one file. `--secrets-dir` and `--state-dir` override path resolution.

### Injecting secrets into an agent worker

Declare the built-in `secret-env` toolkit and map environment variable names to `secret://<name>` references:

```toml
[[toolkits]]
toolkit = "secret-env"

[toolkits.config.env]
GH_TOKEN = "secret://github-main"
```

The schema is one table, `env`, whose keys are environment variable names and whose values are `secret://<name>` references. Bare names, literal values, paths, and indirection through other environment variables are rejected, so an agent manifest never contains secret bytes. Validation errors name the variable but do not echo the reference.

Environment variable names match `[A-Z_][A-Z0-9_]{0,127}`. `PATCHBAY_*` and ordinary process variables such as `PATH`, `HOME`, `SHELL`, `TERM`, `TMPDIR`, and the `LANG`/`LC_*` family are reserved. Multiple `secret-env` toolkits may be declared, but one variable may be declared only once.

The runtime resolves references from the store only while starting that agent's worker. A missing or unreadable secret fails the start with `{:missing_secret, name}` instead of launching a partially configured worker. The selected values are passed to the worker supervisor, which validates the names again and injects only those variables into that worker's environment. Values are never placed in worker argv, provider tool schemas, general process environment, or logs.

Operation children started by the worker receive the same declared variables. `PATCHBAY_WORKER_TOKEN`, `PATCHBAY_CONTROL_TOKEN`, `PATCHBAY_*` files and tokens, and manager provider credentials remain scrubbed; the worker keeps only the secret names in `PATCHBAY_SECRET_ENV`, never values. Lifecycle hooks and native manager-side toolkits do not receive secret environment variables.

The agent's operations are explicitly given these values. Treat the declaration as granting the agent permission to read and transmit that secret.

### Redaction

The runtime keeps the values injected for one running agent and replaces literal occurrences before writing tool-history records, durable events, persisted context messages, and model-facing tool results. A tool that returns `token=<secret>` is stored and shown as `token=[redacted]`. Values shorter than four bytes are not replaced, and streamed model deltas are not rewritten. Redaction is best-effort: an operation can split, encode, or otherwise transform a secret before returning text, so it is not an exfiltration barrier.

## Unsupported or inert declarations

Accepted declarations with no runtime effect beyond validation, storage, or management-UI display:

| Declaration | Behavior |
| --- | --- |
| `[environment] packages` | Validated and retained. No package installation or worker environment composition. |
| `[model] provider` | Validated and retained. Provider selection uses the manager's configured provider module. |
| `[model] reasoning` | Validated and retained. Not forwarded to the provider. |
| `[teardown] workspace` | Validated and retained. No retain, export, or destroy action runs after a result. |
| `[budgets] run-seconds` | Validated and retained. Not enforced. |
| `[budgets] tokens` | Validated, retained, and displayed in the UI. Not enforced. |
| `[context]` strings outside the keep/reset vocabularies | Treated as unset instead of producing an error. |

Rejected or ignored:

- Lifecycle kinds other than `one-shot`, `one_shot`, `scheduled`, and `perpetual`.
- `overlap = "allow"` and `overlap = "queue"`; `schedule`, `overlap`, or `catch-up` on a non-scheduled lifecycle.
- Model arguments declared or referenced in lifecycle hooks.
- Result forms other than `prose`, `number`, `url`, and `file`; `extensions` outside file results.
- New inline operations declared through `[[toolkits.operations]]` or top-level `[[operations]]` when the resolved manifest has no operation with that name; `Patchbay.Definition.load/2` drops them. Top-level `[[operations]]` also fails to load without a manifest named `fixed`.
- Manifests that name an unregistered native toolkit; module names in TOML.
- Implicit manifests whose native toolkit is not `terminal`; such manifests are ignored for global tool lists.
- Nested prompt or script directories; prompt extensions other than `.md` and `.markdown`.
- `<config_root>/shared/scripts`; scripts are not added to `PATH` or run automatically.

## Development

```sh
nix develop
mix deps.get
mix test
```

For local development, set `PATCHBAY_UI_TOKEN` before starting the server; without it the UI answers `401`. The test environment supplies its own token.
