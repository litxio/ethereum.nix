{
  options,
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib.lists) optionals findFirst;
  inherit (lib.strings) hasPrefix;
  inherit
    (lib)
    concatStringsSep
    filterAttrs
    flatten
    mapAttrs'
    mapAttrsToList
    mkBefore
    mkIf
    mkMerge
    nameValuePair
    zipAttrsWith
    ;

  modulesLib = import ../lib.nix lib;
  inherit (modulesLib) baseServiceConfig mkArgs scripts;

  eachErigon = config.services.ethereum.erigon;
in {
  # Disable the service definition currently in nixpkgs
  disabledModules = ["services/blockchain/ethereum/erigon.nix"];

  ###### interface
  inherit (import ./options.nix {inherit lib pkgs;}) options;

  ###### implementation

  config = mkIf (eachErigon != {}) {
    # configure the firewall for each service
    networking.firewall = let
      openFirewall = filterAttrs (_: cfg: cfg.openFirewall) eachErigon;
      perService =
        mapAttrsToList
        (
          _: cfg:
            with cfg.args; {
              allowedUDPPorts = [port torrent.port];
              allowedTCPPorts =
                [port authrpc.port torrent.port]
                ++ (optionals http.enable [http.port])
                ++ (optionals ws.enable [])
                ++ (optionals metrics.enable [metrics.port]);
            }
        )
        openFirewall;
    in
      zipAttrsWith (_name: flatten) perService;

    # configure systemd to create the state directory with a subvolume
    systemd.tmpfiles.rules =
      map
      (name: "v /var/lib/private/erigon-${name}")
      (builtins.attrNames (filterAttrs (_: v: v.subVolume) eachErigon));

    # create a service for each instance
    systemd.services =
      mapAttrs'
      (
        erigonName: let
          serviceName = "erigon-${erigonName}";
        in
          cfg: let
            scriptArgs = let
              # replace enable flags like --http.enable with just --http
              pathReducer =
                path:
                  let arg = concatStringsSep "." (lib.lists.remove "enable" path);
                   in "--${arg}";

              # generate flags
              args = let
                opts = import ./args.nix lib;
              in
                mkArgs {
                  inherit pathReducer opts;
                  inherit (cfg) args;
                };

              specialArgs = ["--authrpc.jwtsecret" "--datadir"];
              isNormalArg = name: (findFirst (arg: hasPrefix arg name) null specialArgs) == null;
              filteredArgs = builtins.filter isNormalArg args;

              # If provided, load from systemd credentials dir (see LoadCredential below).
              jwtsecret =
                if cfg.args.authrpc.jwtsecret != null
                  then "--authrpc.jwtsecret %d/jwt-secret"
                  else "";
              # If provided: use the provided path. If not: use the systemd statedir
              datadir =
                if cfg.args.datadir != null
                  then cfg.args.datadir
                  else "%S/${serviceName}";

            in ''
              --datadir ${datadir} \
              ${jwtsecret} \
              ${concatStringsSep " \\\n" filteredArgs} \
              ${lib.escapeShellArgs cfg.extraArgs}
            '';
          in
            nameValuePair serviceName (mkIf cfg.enable {
              description = "Erigon Ethereum node (${erigonName})";
              wantedBy = ["multi-user.target"];
              after = ["network.target"];

              # create service config by merging with the base config
              serviceConfig = mkMerge [
                baseServiceConfig
                {
                  StateDirectory = serviceName;
                  ExecStartPre =
                    mkIf (cfg.subVolume && cfg.args.datadir == null) (mkBefore [
                      "+${scripts.setupSubVolume} /var/lib/private/${serviceName}"
                    ]);
                  ExecStart = "${cfg.package}/bin/erigon ${scriptArgs}";
                  ReadWritePaths =
                    mkIf (cfg.args.datadir != null) cfg.args.datadir;

                  SystemCallFilter = lib.mkDefault ["@system-service" "~@privileged" "mincore"];
                }
                (mkIf (cfg.user == null) {
                  User = serviceName;
                })
                (mkIf (cfg.user != null) {
                  DynamicUser = false;
                  User = cfg.user;
                })
                (mkIf (cfg.group != null) {
                  Group = cfg.group;
                })
                (mkIf (cfg.args.authrpc.jwtsecret != null) {
                  LoadCredential = ["jwt-secret:${cfg.args.authrpc.jwtsecret}"];
                })
                cfg.extraServiceConfig
              ];
            })
      )
      eachErigon;
  };
}
