{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.patchbay;
  inherit (lib) mkEnableOption mkIf mkOption optional types;

  user = cfg.user;
  group = cfg.group;
  agentUser = cfg.agentUser;
  agentGroup = cfg.agentGroup;

  managerArgs =
    [
      "run-manager"
      "--supervisor-host"
      cfg.manager.supervisorHost
      "--supervisor-port"
      (toString cfg.manager.supervisorPort)
      "--transcript-dir"
      cfg.manager.transcriptDir
      "--listen-port"
      (toString cfg.manager.listenPort)
    ]
    ++ cfg.manager.extraArgs;

  supervisorArgs =
    [
      "run-worker-supervisor"
      "--listen-port"
      (toString cfg.workerSupervisor.listenPort)
      "--worker-executable"
      cfg.workerSupervisor.workerExecutable
      "--max-workers"
      (toString cfg.workerSupervisor.maxWorkers)
    ]
    ++ optional (cfg.workerSupervisor.operationsFile != null) "--operations"
    ++ optional (cfg.workerSupervisor.operationsFile != null) cfg.workerSupervisor.operationsFile
    ++ optional (cfg.workerSupervisor.workspace != null) "--workspace"
    ++ optional (cfg.workerSupervisor.workspace != null) cfg.workerSupervisor.workspace
    ++ optional (cfg.workerSupervisor.workspaceRoot != null) "--workspace-root"
    ++ optional (cfg.workerSupervisor.workspaceRoot != null) cfg.workerSupervisor.workspaceRoot
    ++ optional (cfg.workerSupervisor.resultRoot != null) "--result-root"
    ++ optional (cfg.workerSupervisor.resultRoot != null) cfg.workerSupervisor.resultRoot
    ++ optional (cfg.workerSupervisor.stateRoot != null) "--state-root"
    ++ optional (cfg.workerSupervisor.stateRoot != null) cfg.workerSupervisor.stateRoot
    ++ optional (cfg.workerSupervisor.workerCd != null) "--worker-cd"
    ++ optional (cfg.workerSupervisor.workerCd != null) cfg.workerSupervisor.workerCd
    ++ cfg.workerSupervisor.extraArgs;

  commonEnvironment = {
    LANG = "C.UTF-8";
    LC_CTYPE = "C.UTF-8";
  };

  managerEnvironment =
    commonEnvironment
    // {
      PATCHBAY_CONFIG_DIR = cfg.configDir;
      PATCHBAY_STATE_DIR = cfg.stateDir;
      PATCHBAY_RUNTIME_DIR = cfg.runtimeDir;
      PATCHBAY_SECRETS_DIR = cfg.secretsDir;
      PATCHBAY_WEB_PORT = toString cfg.manager.webPort;
      PATCHBAY_CONTROL_TOKEN_FILE = cfg.controlTokenFile;
      PATCHBAY_UI_TOKEN_FILE = cfg.uiTokenFile;
      PATCHBAY_SECRET_KEY_BASE_FILE = cfg.secretKeyBaseFile;
      PATCHBAY_SIGNING_SALTS_FILE = cfg.signingSaltsFile;
    }
    // lib.optionalAttrs (cfg.workerSupervisor.workspaceRoot != null) {
      PATCHBAY_WORKSPACE_DIR = cfg.workerSupervisor.workspaceRoot;
    }
    // lib.optionalAttrs (cfg.workerSupervisor.resultRoot != null) {
      PATCHBAY_RESULT_DIR = cfg.workerSupervisor.resultRoot;
    }
    // cfg.environment
    // cfg.manager.environment;

  supervisorEnvironment =
    commonEnvironment
    // {
      PATCHBAY_CONFIG_DIR = cfg.configDir;
      PATCHBAY_STATE_DIR = cfg.agentStateDir;
      PATCHBAY_RUNTIME_DIR = cfg.agentRuntimeDir;
      PATCHBAY_EXECUTABLE = cfg.workerSupervisor.workerExecutable;
    }
    // lib.optionalAttrs (cfg.workerSupervisor.workspaceRoot != null) {
      PATCHBAY_WORKSPACE_DIR = cfg.workerSupervisor.workspaceRoot;
    }
    // lib.optionalAttrs (cfg.workerSupervisor.resultRoot != null) {
      PATCHBAY_RESULT_DIR = cfg.workerSupervisor.resultRoot;
    }
    // cfg.environment
    // cfg.workerSupervisor.environment;
in {
  options.services.patchbay = {
    enable = mkEnableOption "Patchbay manager and worker supervisor";

    package = mkOption {
      type = types.package;
      description = "Patchbay package providing the patchbay command.";
    };

    user = mkOption {
      type = types.str;
      default = "patchbay";
      description = "User that runs the manager.";
    };

    group = mkOption {
      type = types.str;
      default = "patchbay";
      description = "Group of the manager and owner of its state, runtime, and config directories.";
    };

    agentUser = mkOption {
      type = types.str;
      default = "patchbay-agent";
      description = "User that runs the worker supervisor and its workers.";
    };

    agentGroup = mkOption {
      type = types.str;
      default = "patchbay-agent";
      description = "Group of the worker supervisor and its workers.";
    };

    configDir = mkOption {
      type = types.str;
      default = "/etc/patchbay";
      description = "Directory exposed as PATCHBAY_CONFIG_DIR.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/patchbay";
      description = "Manager state and transcript directory.";
    };

    secretsDir = mkOption {
      type = types.str;
      default = "${config.services.patchbay.stateDir}/secrets";
      description = ''
        Manager-only named secret store. Created 0700 and owned by the manager
        user; secret files are 0600. Must not be inside configDir or
        agentStateDir. Exposed as PATCHBAY_SECRETS_DIR to the manager and to
        `patchbay secrets`.
      '';
    };

    runtimeDir = mkOption {
      type = types.str;
      default = "/run/patchbay";
      description = "Manager runtime directory exposed as PATCHBAY_RUNTIME_DIR.";
    };

    agentStateDir = mkOption {
      type = types.str;
      default = "/var/lib/patchbay-agent";
      description = "Worker supervisor state directory.";
    };

    agentRuntimeDir = mkOption {
      type = types.str;
      default = "/run/patchbay-agent";
      description = "Worker supervisor runtime directory exposed as PATCHBAY_RUNTIME_DIR.";
    };

    controlTokenFile = mkOption {
      type = types.str;
      default = "/run/patchbay/control-token.env";
      description = "Environment file containing PATCHBAY_CONTROL_TOKEN, generated if absent.";
    };

    uiTokenFile = mkOption {
      type = types.str;
      default = "${config.services.patchbay.runtimeDir}/ui-token.env";
      description = "Environment file containing PATCHBAY_UI_TOKEN, generated if absent.";
    };

    secretKeyBaseFile = mkOption {
      type = types.str;
      default = "${config.services.patchbay.stateDir}/secret-key-base";
      description = "Environment file containing SECRET_KEY_BASE, generated if absent.";
    };

    signingSaltsFile = mkOption {
      type = types.str;
      default = "${config.services.patchbay.stateDir}/web-signing-salts.env";
      description = ''
        Environment file containing PATCHBAY_SESSION_SIGNING_SALT and
        PATCHBAY_LIVE_VIEW_SIGNING_SALT, generated if absent.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Additional environment variables for both services.";
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional environment files loaded by both services.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Packages added to PATH for both services.";
    };

    manager = {
      supervisorHost = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Host of the worker supervisor control listener.";
      };

      supervisorPort = mkOption {
        type = types.ints.between 1 65535;
        default = config.services.patchbay.workerSupervisor.listenPort;
        description = "Port of the worker supervisor control listener.";
      };

      listenPort = mkOption {
        type = types.port;
        default = 0;
        description = "Manager worker-facing listen port; 0 picks a free port.";
      };

      webPort = mkOption {
        type = types.port;
        default = 4000;
        description = "Port for the manager's Phoenix endpoint.";
      };

      transcriptDir = mkOption {
        type = types.str;
        default = "${config.services.patchbay.stateDir}/transcripts";
        description = "Directory where the manager writes worker transcripts.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra arguments appended to the run-manager command.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Additional environment variables for the manager service.";
      };

      environmentFiles = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Environment files loaded by the manager service.";
      };
    };

    workerSupervisor = {
      workerExecutable = mkOption {
        type = types.str;
        default = "${config.services.patchbay.package}/bin/patchbay";
        description = "Executable the worker supervisor starts for each worker.";
      };

      listenPort = mkOption {
        type = types.ints.between 1 65535;
        default = 7001;
        description = "Port the worker supervisor listens on.";
      };

      maxWorkers = mkOption {
        type = types.ints.between 1 1024;
        default = 64;
        description = "Maximum number of concurrent workers.";
      };

      operationsFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path passed to run-worker-supervisor as --operations.";
      };

      workspace = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Worker workspace passed as --workspace. Must exist and be writable by
          the agent user.
        '';
      };

      workspaceRoot = mkOption {
        type = types.nullOr types.str;
        default = "${config.services.patchbay.agentStateDir}/workspaces";
        description = "Root directory for per-agent workspaces.";
      };

      resultRoot = mkOption {
        type = types.nullOr types.str;
        default = "${config.services.patchbay.agentStateDir}/results";
        description = "Root directory for per-agent result directories.";
      };

      stateRoot = mkOption {
        type = types.nullOr types.str;
        default = config.services.patchbay.agentStateDir;
        description = "Root directory for per-agent worker state.";
      };

      workerCd = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Working directory passed to run-worker-supervisor as --worker-cd.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra arguments appended to the run-worker-supervisor command.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Additional environment variables for the worker supervisor service.";
      };

      environmentFiles = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Environment files loaded by the worker supervisor service.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != cfg.agentUser;
        message = "services.patchbay.user and services.patchbay.agentUser must differ.";
      }
      {
        assertion =
          cfg.stateDir != cfg.agentStateDir
          && !(lib.hasPrefix "${cfg.stateDir}/" cfg.agentStateDir)
          && !(lib.hasPrefix "${cfg.agentStateDir}/" cfg.stateDir);
        message = "services.patchbay.stateDir and agentStateDir must be separate directory trees.";
      }
      {
        assertion =
          !(lib.hasPrefix "${cfg.stateDir}/" cfg.controlTokenFile)
          && !(lib.hasPrefix "${cfg.agentStateDir}/" cfg.controlTokenFile)
          && cfg.controlTokenFile != cfg.stateDir
          && cfg.controlTokenFile != cfg.agentStateDir;
        message = "services.patchbay.controlTokenFile must not be inside the manager or agent state directory.";
      }
      {
        assertion =
          !(lib.hasPrefix "${cfg.agentStateDir}/" cfg.secretKeyBaseFile)
          && cfg.secretKeyBaseFile != cfg.agentStateDir;
        message = "services.patchbay.secretKeyBaseFile must not be readable from the agent state directory.";
      }
      {
        assertion =
          !(lib.hasPrefix "${cfg.agentStateDir}/" cfg.signingSaltsFile)
          && cfg.signingSaltsFile != cfg.agentStateDir;
        message = "services.patchbay.signingSaltsFile must not be readable from the agent state directory.";
      }
      {
        assertion =
          !(lib.hasPrefix "${cfg.agentStateDir}/" cfg.uiTokenFile)
          && !(lib.hasPrefix "${cfg.configDir}/" cfg.uiTokenFile)
          && cfg.uiTokenFile != cfg.agentStateDir
          && cfg.uiTokenFile != cfg.configDir;
        message = "services.patchbay.uiTokenFile must not be readable from the agent state or configuration directory.";
      }
      {
        assertion =
          !(lib.hasPrefix "${cfg.agentStateDir}/" cfg.secretsDir)
          && !(lib.hasPrefix "${cfg.configDir}/" cfg.secretsDir)
          && cfg.secretsDir != cfg.agentStateDir
          && cfg.secretsDir != cfg.configDir;
        message = "services.patchbay.secretsDir must not be readable from the agent state or configuration directory.";
      }
      {
        assertion = cfg.manager.supervisorHost == "127.0.0.1" || cfg.manager.supervisorHost == "localhost";
        message = "services.patchbay.manager.supervisorHost must be loopback.";
      }
      {
        assertion =
          lib.all
          (path: lib.hasPrefix "/" path)
          ([
              cfg.configDir
              cfg.stateDir
              cfg.runtimeDir
              cfg.secretsDir
              cfg.agentStateDir
              cfg.agentRuntimeDir
              cfg.controlTokenFile
              cfg.uiTokenFile
              cfg.secretKeyBaseFile
              cfg.signingSaltsFile
              cfg.manager.transcriptDir
              cfg.workerSupervisor.workerExecutable
            ]
            ++ optional (cfg.workerSupervisor.operationsFile != null) cfg.workerSupervisor.operationsFile
            ++ optional (cfg.workerSupervisor.workspace != null) cfg.workerSupervisor.workspace
            ++ optional (cfg.workerSupervisor.workspaceRoot != null) cfg.workerSupervisor.workspaceRoot
            ++ optional (cfg.workerSupervisor.resultRoot != null) cfg.workerSupervisor.resultRoot
            ++ optional (cfg.workerSupervisor.stateRoot != null) cfg.workerSupervisor.stateRoot
            ++ optional (cfg.workerSupervisor.workerCd != null) cfg.workerSupervisor.workerCd);
        message = "services.patchbay paths and command-line paths must be absolute.";
      }
    ];

    users.groups.${group} = {};
    users.groups.${agentGroup} = {};

    users.users.${user} = {
      isSystemUser = true;
      group = group;
      home = cfg.stateDir;
      createHome = false;
    };

    users.users.${agentUser} = {
      isSystemUser = true;
      group = agentGroup;
      home = cfg.agentStateDir;
      createHome = false;
      extraGroups = [group];
    };

    environment.systemPackages = [cfg.package];

    systemd.tmpfiles.rules =
      lib.unique (
        [
          "d ${cfg.configDir} 0750 ${user} ${group} -"
          "d ${cfg.stateDir} 0700 ${user} ${group} -"
          "d ${cfg.secretsDir} 0700 ${user} ${group} -"
          "d ${cfg.manager.transcriptDir} 0700 ${user} ${group} -"
          "d ${cfg.runtimeDir} 0750 ${user} ${group} -"
          "d ${cfg.agentStateDir} 0700 ${agentUser} ${agentGroup} -"
          "d ${cfg.agentRuntimeDir} 0750 ${agentUser} ${agentGroup} -"
        ]
        ++ optional (cfg.workerSupervisor.workspaceRoot != null)
        "d ${cfg.workerSupervisor.workspaceRoot} 0700 ${agentUser} ${agentGroup} -"
        ++ optional (cfg.workerSupervisor.resultRoot != null)
        "d ${cfg.workerSupervisor.resultRoot} 0700 ${agentUser} ${agentGroup} -"
        ++ optional (cfg.workerSupervisor.stateRoot != null)
        "d ${cfg.workerSupervisor.stateRoot} 0700 ${agentUser} ${agentGroup} -"
      );

    systemd.services.patchbay-token = {
      description = "Create the Patchbay control, UI, and web secrets";
      wantedBy = ["multi-user.target"];
      before = [
        "patchbay-manager.service"
        "patchbay-worker-supervisor.service"
      ];

      path = [pkgs.coreutils];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        NoNewPrivileges = true;
      };

      script = ''
        token_file=${lib.escapeShellArg cfg.controlTokenFile}
        token_dir=$(dirname "$token_file")
        ui_token_file=${lib.escapeShellArg cfg.uiTokenFile}
        ui_token_dir=$(dirname "$ui_token_file")
        secret_file=${lib.escapeShellArg cfg.secretKeyBaseFile}
        secret_dir=$(dirname "$secret_file")
        salts_file=${lib.escapeShellArg cfg.signingSaltsFile}
        salts_dir=$(dirname "$salts_file")

        if [ ! -d "$token_dir" ]; then
          install -d -m 0755 -o root -g root "$token_dir"
        fi

        if [ ! -d "$ui_token_dir" ]; then
          install -d -m 0755 -o root -g root "$ui_token_dir"
        fi

        if [ ! -d "$secret_dir" ]; then
          install -d -m 0700 -o ${lib.escapeShellArg user} -g ${lib.escapeShellArg group} "$secret_dir"
        fi

        if [ ! -d "$salts_dir" ]; then
          install -d -m 0700 -o ${lib.escapeShellArg user} -g ${lib.escapeShellArg group} "$salts_dir"
        fi

        if [ ! -s "$token_file" ]; then
          tmp=$(mktemp "$token_file.XXXXXX")
          printf 'PATCHBAY_CONTROL_TOKEN=%s\n' "$(head -c 48 /dev/urandom | base64 | tr -d '\n=')" > "$tmp"
          install -m 0600 -o root -g root "$tmp" "$token_file"
          rm -f "$tmp"
        else
          chown root:root "$token_file"
          chmod 0600 "$token_file"
        fi

        if [ ! -s "$ui_token_file" ]; then
          tmp=$(mktemp "$ui_token_file.XXXXXX")
          printf 'PATCHBAY_UI_TOKEN=%s\n' "$(head -c 48 /dev/urandom | base64 | tr -d '\n=')" > "$tmp"
          install -m 0600 -o root -g root "$tmp" "$ui_token_file"
          rm -f "$tmp"
        else
          chown root:root "$ui_token_file"
          chmod 0600 "$ui_token_file"
        fi

        if [ ! -s "$secret_file" ]; then
          tmp=$(mktemp "$secret_file.XXXXXX")
          printf 'SECRET_KEY_BASE=%s\n' "$(head -c 64 /dev/urandom | base64 | tr -d '\n=')" > "$tmp"
          install -m 0600 -o root -g root "$tmp" "$secret_file"
          rm -f "$tmp"
        else
          chown root:root "$secret_file"
          chmod 0600 "$secret_file"
        fi

        if [ ! -s "$salts_file" ]; then
          tmp=$(mktemp "$salts_file.XXXXXX")
          {
            printf 'PATCHBAY_SESSION_SIGNING_SALT=%s\n' "$(head -c 48 /dev/urandom | base64 | tr -d '\n=')"
            printf 'PATCHBAY_LIVE_VIEW_SIGNING_SALT=%s\n' "$(head -c 48 /dev/urandom | base64 | tr -d '\n=')"
          } > "$tmp"
          install -m 0600 -o root -g root "$tmp" "$salts_file"
          rm -f "$tmp"
        else
          chown root:root "$salts_file"
          chmod 0600 "$salts_file"
        fi
      '';
    };

    systemd.services.patchbay-manager = {
      description = "Patchbay manager";
      wantedBy = ["multi-user.target"];
      requires = ["patchbay-token.service"];
      after = [
        "network.target"
        "patchbay-token.service"
      ];

      environment = managerEnvironment;
      path = [cfg.package pkgs.coreutils pkgs.procps pkgs.bash] ++ cfg.extraPackages;

      serviceConfig = {
        Type = "simple";
        User = user;
        Group = group;
        WorkingDirectory = cfg.stateDir;
        Restart = "on-failure";
        RestartSec = 2;
        TimeoutStopSec = 15;
        UMask = "0077";
        EnvironmentFile =
          [cfg.controlTokenFile cfg.uiTokenFile cfg.secretKeyBaseFile cfg.signingSaltsFile]
          ++ cfg.environmentFiles
          ++ cfg.manager.environmentFiles;

        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";

        ReadWritePaths = [
          cfg.configDir
          cfg.stateDir
          cfg.secretsDir
          cfg.manager.transcriptDir
          cfg.runtimeDir
        ];

        ExecStart = lib.escapeShellArgs ([
          "${cfg.package}/bin/patchbay"
        ] ++ managerArgs);
      };
    };

    systemd.services.patchbay-worker-supervisor = {
      description = "Patchbay worker supervisor";
      wantedBy = ["multi-user.target"];
      requires = ["patchbay-token.service"];
      after = [
        "network.target"
        "nix-daemon.service"
        "patchbay-token.service"
        "patchbay-manager.service"
      ];

      environment = supervisorEnvironment;
      path =
        [cfg.package pkgs.coreutils pkgs.procps pkgs.bash pkgs.nix]
        ++ cfg.extraPackages;

      serviceConfig = {
        Type = "simple";
        User = agentUser;
        Group = agentGroup;
        WorkingDirectory = cfg.agentStateDir;
        Restart = "on-failure";
        RestartSec = 2;
        TimeoutStopSec = 15;
        UMask = "0077";
        EnvironmentFile =
          [cfg.controlTokenFile]
          ++ cfg.environmentFiles
          ++ cfg.workerSupervisor.environmentFiles;

        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";

        ReadWritePaths =
          lib.unique (
            [
              cfg.agentStateDir
              cfg.agentRuntimeDir
              "-/nix/var/nix/daemon-socket"
            ]
            ++ optional (cfg.workerSupervisor.workspaceRoot != null) cfg.workerSupervisor.workspaceRoot
            ++ optional (cfg.workerSupervisor.resultRoot != null) cfg.workerSupervisor.resultRoot
            ++ optional (cfg.workerSupervisor.stateRoot != null) cfg.workerSupervisor.stateRoot
            ++ optional (cfg.workerSupervisor.workspace != null) "-${cfg.workerSupervisor.workspace}"
            ++ optional (cfg.workerSupervisor.workerCd != null) "-${cfg.workerSupervisor.workerCd}"
          );

        # Configuration, including shared scripts, stays readable but not
        # writable: the manager owns edits, the agent user only executes.
        ReadOnlyPaths = [cfg.configDir];

        ExecStart = lib.escapeShellArgs ([
          "${cfg.package}/bin/patchbay"
        ] ++ supervisorArgs);
      };
    };
  };
}
