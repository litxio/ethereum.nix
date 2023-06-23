{
  lib,
  pkgs,
  ...
}: let
  args = import ./args.nix lib;

  beaconOpts = with lib; {
    options = {
      enable = mkEnableOption (mdDoc "Ethereum Beacon Chain Node from Prysmatic Labs");

      inherit args;

      extraArgs = mkOption {
        type = types.listOf types.str;
        description = mdDoc "Additional arguments to pass to Prysm Beacon Chain.";
        default = [];
      };

      package = mkOption {
        default = pkgs.prysm;
        defaultText = literalExpression "pkgs.prysm";
        type = types.package;
        description = mdDoc "Package to use for Prysm binary";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = lib.mdDoc "Open ports in the firewall for any enabled networking services";
      };

      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = mdDoc "User to run the systemd service.";
      };

      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = mdDoc "Primary group for the systemd service.";
      };

      extraServiceConfig = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = mdDoc "Extra settings for the systemd [Service] stanza.";
      };

      # mixin backup options
      backup = let
        inherit (import ../backup/lib.nix lib) options;
      in
        options;

      # mixin restore options
      restore = let
        inherit (import ../restore/lib.nix lib) options;
      in
        options;
    };
  };
in {
  options.services.ethereum.prysm-beacon = with lib;
    mkOption {
      type = types.attrsOf (types.submodule beaconOpts);
      default = {};
      description = mdDoc "Specification of one or more prysm beacon chain instances.";
    };
}
