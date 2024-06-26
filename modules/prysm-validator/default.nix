{
  config,
  lib,
  pkgs,
  ...
}: let
  modulesLib = import ../lib.nix lib;

  inherit (lib.lists) optionals findFirst;
  inherit (lib.strings) hasPrefix;
  inherit (lib.attrsets) zipAttrsWith;
  inherit (lib) flatten nameValuePair filterAttrs mapAttrs' mapAttrsToList;
  inherit (lib) mkIf mkMerge concatStringsSep;
  inherit (modulesLib) mkArgs baseServiceConfig;

  eachValidator = config.services.ethereum.prysm-validator;
in {
  ###### interface
  inherit (import ./options.nix {inherit lib pkgs;}) options;

  ###### implementation

  config = mkIf (eachValidator != {}) {
    # configure the firewall for each service
    networking.firewall = let
      openFirewall = filterAttrs (_: cfg: cfg.openFirewall) eachValidator;
      perService =
        mapAttrsToList
        (
          _: cfg:
            with cfg.args; {
              allowedTCPPorts =
                [grpc-gateway-port]
                ++ (optionals rpc.enable [rpc.port])
                ++ (optionals (!disable-monitoring) [monitoring-port]);
            }
        )
        openFirewall;
    in
      zipAttrsWith (_name: flatten) perService;

    systemd.services =
      mapAttrs'
      (
        validatorName: let
          serviceName = "prysm-validator-${validatorName}";
          beaconServiceName = "prysm-beacon-${validatorName}";
        in
          cfg: let
            scriptArgs = let
              # generate args
              args = let
                opts = import ./args.nix lib;
              in
                mkArgs {
                  inherit opts;
                  inherit (cfg) args;
                };

              # filter out certain args which need to be treated differently
              rpc = if cfg.args.rpc.enable
                    then "--rpc"
                    else "";
              specialArgs = [
                "--datadir"
                "--graffiti"
                "--network"
                "--rpc-enable"
                "--wallet-password-file"
              ];
              isNormalArg = name: (findFirst (arg: hasPrefix arg name) null specialArgs) == null;
              filteredArgs = builtins.filter isNormalArg args;

              network =
                if cfg.args.network != null
                then "--${cfg.args.network}"
                else "";
              datadir =
                if cfg.args.datadir != null
                then "--datadir ${cfg.args.datadir}"
                else "--datadir %S/${serviceName}";
              graffiti =  # Needs quoting
                if cfg.args.graffiti != null
                then "--graffiti \"${cfg.args.graffiti}\""
                else "";
              wallet-password-file =
                if cfg.args.wallet-password-file != null
                then "--wallet-password-file %d/wallet-password"
                else "";

            in ''
              --accept-terms-of-use \
              ${network} \
              ${datadir} \
              ${wallet-password-file} \
              ${concatStringsSep " \\\n" filteredArgs} \
              ${lib.escapeShellArgs cfg.extraArgs}
            '';
          in
            nameValuePair serviceName (mkIf cfg.enable {
              after = ["network.target"];
              wantedBy = ["multi-user.target"];
              description = "Prysm Validator Node (${validatorName})";

              environment = {
                GRPC_GATEWAY_HOST = cfg.args.grpc-gateway-host;
                GRPC_GATEWAY_PORT = builtins.toString cfg.args.grpc-gateway-port;
              };

              # create service config by merging with the base config
              serviceConfig = mkMerge [
                baseServiceConfig
                {
                  StateDirectory = serviceName;
                  ExecStart = "${cfg.package}/bin/validator ${scriptArgs}";
                  MemoryDenyWriteExecute = "false"; # causes a library loading error
                }
                (mkIf (cfg.args.wallet-password-file != null) {
                  LoadCredential = ["wallet-password:${cfg.args.wallet-password-file}"];
                })
                (mkIf (cfg.user != null) {
                  DynamicUser = false;
                  User = cfg.user;
                })
                (mkIf (cfg.group != null) {
                  Group = cfg.group;
                })
                cfg.extraServiceConfig
              ];
            })
      )
      eachValidator;
  };
}
