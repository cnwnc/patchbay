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

The Console and Configuration routes require HTTP Basic authentication. The password is `PATCHBAY_UI_TOKEN`, the username is ignored. Read the token as root when connecting:

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
| `extensions` | array of strings | no | Only valid for `form = "file"`; defaults to `[]`. Empty strings are allowed, for example to represent a file without an extension. |

All results are returned through the implicit `complete_task` tool under a `results` object. Every result whose `required` is true must be present; unknown result ids are rejected. `number` values must be JSON numbers; `prose`, `url`, and `file` values must be non-empty strings. A `required-by` result is not required by `complete_task`; the dependency is validated for existence and cycles but is not enforced at submission. Duplicate result ids, unknown dependencies, and dependency cycles are validation errors.

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
| `native` | string | no | — | Registered native toolkit id. Built-ins: `filesystem`, `terminal`. Other ids work only when registered at runtime. |
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
