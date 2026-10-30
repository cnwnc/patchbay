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

## Configuration

The manager reads agent definitions from `services.patchbay.configDir` (default `/etc/patchbay`):

- `agents/<id>/agent.toml`, with optional `prompts/` and `scripts/` directories
- `toolkits/*.toml` for fixed operations and native toolkit manifests
- `shared/prompts/` and `scripts/` at the configuration root for assets shared by agents

State, transcripts, runtime paths, and worker workspaces use the separate `services.patchbay.stateDir` and `agentStateDir`.

Native filesystem toolkits execute in the manager process, not the isolated worker. An absolute `[toolkits.config] root` is trusted operator configuration and may point at an agent workspace or project directory, but it must not overlap `/proc` or the manager's state, runtime, or secret paths. Relative roots stay strictly below the config root, and every model-supplied path stays confined below the effective root.

Provider settings resolve from the manager environment:

- `PATCHBAY_LLM_BASE_URL`, `PATCHBAY_LLM_API_KEY`, `PATCHBAY_LLM_MODEL`
- `OPENAI_BASE_URL` / `OPENAI_API_BASE`, `OPENAI_API_KEY`, `OPENAI_MODEL` as fallbacks

Non-secret values such as the base URL and model can use `services.patchbay.manager.environment`. Put `PATCHBAY_LLM_API_KEY` or `OPENAI_API_KEY` in a manager environment file configured with `services.patchbay.manager.environmentFiles`.

The module generates `PATCHBAY_CONTROL_TOKEN` at `services.patchbay.controlTokenFile` (default `/run/patchbay/control-token.env`), `PATCHBAY_UI_TOKEN` at `services.patchbay.uiTokenFile` (default `/run/patchbay/ui-token.env`), `SECRET_KEY_BASE` at `services.patchbay.secretKeyBaseFile` (default `<stateDir>/secret-key-base`), and the Phoenix session and LiveView signing salts at `services.patchbay.signingSaltsFile` (default `<stateDir>/web-signing-salts.env`). The control token is loaded by both services; the UI token, secret key base, and signing salts are loaded only by the manager. Back up or preserve these files if browser sessions must survive a state wipe.

## Development

```sh
nix develop
mix deps.get
mix test
```

For local development, set `PATCHBAY_UI_TOKEN` before starting the server; without it the UI answers `401`. The test environment supplies its own token.
