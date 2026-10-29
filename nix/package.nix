{
  lib,
  beamMinimalPackages,
  writeShellScriptBin,
  zstd,
}:
let
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../mix.exs
      ../mix.lock
      ../config
      ../lib
      ../priv
    ];
  };

  mixDeps = beamMinimalPackages.fetchMixDeps {
    pname = "patchbay-deps";
    inherit version src;
    mixEnv = "prod";
    hash = "sha256-sb+aMoK4GJ3Ew7LhZ0lZCqiA9+FhUi2sOp9s10ABz1Y=";
  };

  escript = beamMinimalPackages.mixRelease {
    pname = "patchbay";
    inherit version src;
    mixEnv = "prod";
    escriptBinName = "patchbay";
    mixFodDeps = mixDeps;

    meta = {
      description = "Patchbay manager and worker supervisor";
      mainProgram = "patchbay";
      platforms = lib.platforms.linux;
    };

    passthru = {
      inherit mixDeps escript;
    };
  };
in
writeShellScriptBin "patchbay" ''
  export PATH="${zstd}/bin:$PATH"
  exec ${beamMinimalPackages.erlang}/bin/escript ${escript}/bin/patchbay "$@"
''
// {
  meta = escript.meta;
  passthru = escript.passthru;
}
