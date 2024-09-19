{
  lib,
  pkgs,
  ...
}: let
  args = import ./args.nix lib;

  erigonOpts = with lib; {
    options = {
      enable = mkEnableOption "Erigon Ethereum Node.";

      subVolume = mkEnableOption "Use a subvolume for the state directory if the underlying filesystem supports it e.g. btrfs";

      inherit args;

      extraArgs = mkOption {
        type = types.listOf types.str;
        description = "Additional arguments to pass to Erigon.";
        default = [];
      };

      package = mkOption {
        type = types.package;
        default = pkgs.erigon;
        defaultText = literalExpression "pkgs.erigon";
        description = "Package to use as Erigon node.";
      };

      service = {
        supplementaryGroups = mkOption {
          default = [];
          type = types.listOf types.str;
          description = "Additional groups for the systemd service e.g. sops-nix group for secret access";
        };
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Open ports in the firewall for any enabled networking services";
      };

      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "User to run the systemd service.";
      };

      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Primary group for the systemd service.";
      };

      extraServiceConfig = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Extra settings for the systemd [Service] stanza.";
      };
    };
  };
in {
  options.services.ethereum.erigon = with lib;
    mkOption {
      type = types.attrsOf (types.submodule erigonOpts);
      default = {};
      description = "Specification of one or more erigon instances.";
    };
}
