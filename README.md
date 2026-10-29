# Patchbay

Patchbay runs declarative agents as supervised worker processes behind a Phoenix management UI. It ships as an escript plus a NixOS module.

## Flake input

```nix
{
  inputs.patchbay.url = "github:OWNER/patchbay";
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

The management endpoint listens on loopback only. Set the port with `services.patchbay.manager.webPort` (default `4000`); it is passed to the manager as `PATCHBAY_WEB_PORT`. Put a reverse proxy in front of it if remote access is needed.

## Configuration

The manager reads agent definitions from `services.patchbay.configDir` (default `/etc/patchbay`):

- `agents/<id>/agent.toml`, with optional `prompts/` and `scripts/` directories
- `toolkits/*.toml` for fixed operations and native toolkit manifests
- `shared/prompts/` and `shared/scripts/` for assets shared by agents

State, transcripts, runtime paths, and worker workspaces use the separate `services.patchbay.stateDir` and `agentStateDir`. The manager and worker supervisor run as different users.

Provider settings resolve from the manager environment:

- `PATCHBAY_LLM_BASE_URL`, `PATCHBAY_LLM_API_KEY`, `PATCHBAY_LLM_MODEL`
- `OPENAI_BASE_URL` / `OPENAI_API_BASE`, `OPENAI_API_KEY`, `OPENAI_MODEL` as fallbacks

Non-secret values such as the base URL and model can use `services.patchbay.manager.environment`. Put `PATCHBAY_LLM_API_KEY` or `OPENAI_API_KEY` in a manager environment file configured with `services.patchbay.manager.environmentFiles`, not in the Nix store. Provider credentials stay in the manager; worker and tool process environments strip them.

The module generates `PATCHBAY_CONTROL_TOKEN`, `SECRET_KEY_BASE`, and the Phoenix session and LiveView signing salts in root-owned files under the state directory. The control token is loaded by both services; the secret key base and signing salts are loaded only by the manager. Back up or preserve these files if browser sessions must survive a state wipe.

## Development

```sh
nix develop
mix deps.get
mix test
```
