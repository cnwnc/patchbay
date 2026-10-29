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
      PATCHBAY_WEB_PORT = toString cfg.manager.webPort;
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
      description = "Patchbay package providing the run-manager and run-worker-supervisor commands.";
    };

    user = mkOption {
      type = types.str;
      default = "patchbay";
      description = "User that runs the manager and owns transcripts.";
    };

    group = mkOption {
      type = types.str;
      default = "patchbay";
      description = "Primary group of the manager and the group that owns its state, runtime, and config directories.";
    };

    agentUser = mkOption {
      type = types.str;
      default = "patchbay-agent";
      description = "User that runs the worker supervisor and the workers it spawns.";
    };

    agentGroup = mkOption {
      type = types.str;
      default = "patchbay-agent";
      description = "Primary group of the worker supervisor and its workers.";
    };

    configDir = mkOption {
      type = types.str;
      default = "/etc/patchbay";
      description = "Directory exposed as PATCHBAY_CONFIG_DIR.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/patchbay";
      description = "Manager state directory, including transcripts. Kept private to the manager user.";
    };

    runtimeDir = mkOption {
      type = types.str;
      default = "/run/patchbay";
      description = "Manager runtime directory exposed as PATCHBAY_RUNTIME_DIR.";
    };

    agentStateDir = mkOption {
      type = types.str;
      default = "/var/lib/patchbay-agent";
      description = "Worker supervisor state directory, separate from manager transcripts.";
    };

    agentRuntimeDir = mkOption {
      type = types.str;
      default = "/run/patchbay-agent";
      description = "Worker supervisor runtime directory exposed as PATCHBAY_RUNTIME_DIR.";
    };

    controlTokenFile = mkOption {
      type = types.str;
      default = "/run/patchbay/control-token.env";
      description = ''
        systemd EnvironmentFile holding PATCHBAY_CONTROL_TOKEN. It is created
        root-owned with mode 0600 and loaded by both services, so the agent user
        and the workers it starts cannot read the token. The token is never
        passed on a command line.
      '';
    };

    secretKeyBaseFile = mkOption {
      type = types.str;
      default = "${config.services.patchbay.stateDir}/secret-key-base";
      description = ''
        systemd EnvironmentFile containing SECRET_KEY_BASE, generated if absent.
        It is created root-owned with mode 0600, loaded only by the manager, and
        is not placed in the Nix store.
      '';
    };

    signingSaltsFile = mkOption {
      type = types.str;
      default = "${config.services.patchbay.stateDir}/web-signing-salts.env";
      description = ''
        systemd EnvironmentFile containing PATCHBAY_SESSION_SIGNING_SALT and
        PATCHBAY_LIVE_VIEW_SIGNING_SALT, generated if absent. It is created
        root-owned with mode 0600, loaded only by the manager, and is not placed
        in the Nix store.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Additional non-secret environment variables for both services.";
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Additional environment files loaded by both services. The manager-only
        control token, secret key base, and signing salts use dedicated
        root-only files, so do not repeat them here.
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Packages added to PATH for both services and their children.";
    };

    manager = {
      supervisorHost = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Loopback host of the worker supervisor control listener.";
      };

      supervisorPort = mkOption {
        type = types.ints.between 1 65535;
        default = config.services.patchbay.workerSupervisor.listenPort;
        description = "Port of the worker supervisor control listener.";
      };

      listenPort = mkOption {
        type = types.port;
        default = 0;
        description = "Manager worker-facing listen port. Zero asks the kernel for a free port.";
      };

      webPort = mkOption {
        type = types.port;
        default = 4000;
        description = "Loopback port for the manager's Phoenix endpoint.";
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
        description = "Additional non-secret environment variables for the manager service.";
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
        description = "Loopback port the worker supervisor listens on.";
      };

      maxWorkers = mkOption {
        type = types.ints.between 1 1024;
        default = 64;
        description = "Maximum number of concurrent workers.";
      };

      operationsFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Absolute path passed to run-worker-supervisor as --operations.";
      };

      workspace = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Absolute worker workspace passed as --workspace. Prefer workspaceRoot
          for per-agent workspaces. The directory must exist and be writable by
          the agent user. ProtectHome= in the service means workspaces below
          /home are not reachable.
        '';
      };

      workspaceRoot = mkOption {
        type = types.nullOr types.str;
        default = "${config.services.patchbay.agentStateDir}/workspaces";
        description = ''
          Agent-owned root for per-agent workspaces. The worker supervisor
          creates and owns the per-agent subdirectory; the manager only supplies
          the path. It is exposed to the manager as PATCHBAY_WORKSPACE_DIR.
        '';
      };

      resultRoot = mkOption {
        type = types.nullOr types.str;
        default = "${config.services.patchbay.agentStateDir}/results";
        description = ''
          Agent-owned root for per-agent result directories. The worker
          supervisor creates each per-agent directory under this root.
        '';
      };

      stateRoot = mkOption {
        type = types.nullOr types.str;
        default = config.services.patchbay.agentStateDir;
        description = ''
          Agent-owned root for per-agent worker state, including the private
          0600 operations file the supervisor writes for each worker.
        '';
      };

      workerCd = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Absolute working directory passed as --worker-cd.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra arguments appended to the run-worker-supervisor command.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Additional non-secret environment variables for the worker supervisor service.";
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
              cfg.agentStateDir
              cfg.agentRuntimeDir
              cfg.controlTokenFile
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
      description = "Create the Patchbay control token and secret key base";
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
        secret_file=${lib.escapeShellArg cfg.secretKeyBaseFile}
        secret_dir=$(dirname "$secret_file")
        salts_file=${lib.escapeShellArg cfg.signingSaltsFile}
        salts_dir=$(dirname "$salts_file")

        if [ ! -d "$token_dir" ]; then
          install -d -m 0755 -o root -g root "$token_dir"
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
          [cfg.controlTokenFile cfg.secretKeyBaseFile cfg.signingSaltsFile]
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
        "patchbay-token.service"
        "patchbay-manager.service"
      ];

      environment = supervisorEnvironment;
      path = [cfg.package pkgs.coreutils pkgs.procps pkgs.bash] ++ cfg.extraPackages;

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
