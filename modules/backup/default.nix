{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    concatMapStrings
    filterAttrs
    mapAttrs
    mkAfter
    mkBefore
    mkIf
    mkMerge
    nameValuePair
    ;
  inherit (builtins) concatStringsSep attrNames map;

  modulesLib = import ../lib.nix lib;
  inherit (modulesLib) findEnabled;

  cfg = with lib;
    filterAttrs (_n: v: v.enable)
    (
      mapAttrs (_: attrByPath ["backup"] {enable = false;})
      (findEnabled config.services.ethereum)
    );

  # util script for converting the output of eth_getBlockByNumber to metadata.json format
  executionClientJq = pkgs.writeTextFile {
    name = "convert.jq";
    text = ''
      def to_i(base):
        explode
        | reverse
        | map(if . > 96  then . - 87 else . - 48 end)  # "a" ~ 97 => 10 ~ 87
        | reduce .[] as $c
            # state: [power, ans]
            ([1,0]; (.[0] * base) as $b | [$b, .[1] + (.[0] * $c)])
        | .[1];

      .result | {hash,stateRoot,number}  + {"height": (.number[2:] | to_i(16)) }
    '';
  };

  # util script for capturing metadata about a running ETH process
  # TODO this is growing in complexity and would be better as a dedicated program
  metadataScript = pkgs.writeShellScript "metadata" ''
    set -euo pipefail

    # enable extended pattern matching
    shopt -s extglob

    SERVICE_NAME=$1

    # check if the service is running
    PID=$(systemctl show --property MainPID $SERVICE_NAME | cut -d'=' -f2)
    if [ $PID -eq 0 ]; then
        echo "$SERVICE_NAME is not running, exiting"
        exit 0
    fi

    # source the same environment as the service
    . <(xargs -0 bash -c 'printf "export %q\n" "$@"' -- < /proc/$PID/environ)

    # we don't want to exit if the following commands fail as the process might be down as part of an update
    # and this unit was inflight at the time
    set +e

    METADATA_JSON=$BACKUP_METADATA_DIR/metadata.json

    case $SERVICE_NAME in

        @(geth|nethermind)-* )
            ${pkgs.curl}/bin/curl -s -X POST \
                -H 'Content-Type: application/json' \
                -d '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",false]}' \
                http://$WEB3_HTTP_HOST:$WEB3_HTTP_PORT \
                | ${pkgs.jq}/bin/jq -f ${executionClientJq} > $METADATA_JSON
            ;;

        prysm-beacon-*)
            ${pkgs.curl}/bin/curl -s http://$GRPC_GATEWAY_HOST:$GRPC_GATEWAY_PORT/eth/v1/node/syncing \
                | ${pkgs.jq}/bin/jq '.data + { "height": (.data.head_slot | tonumber) }' > $METADATA_JSON
            ;;

        *)
            echo "Unknown client type: $SERVICE_NAME"
            exit 1
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo "$METADATA_JSON successfully updated";
        exit 0
    fi

    if [ $? -eq 7 ]; then
        # curl provides this exit code if it couldn't connect to host
        echo "Could not connect to host"
        exit 0  # we exit nicely assuming that this is a transient error due to rollout of updates
    else
        >&2 echo "Failed to fetch metadata"
        exit $?
    fi
  '';

  # util script for extracting the chain height from metadata.json
  chainHeightScript = pkgs.writeShellScript "chain-height" ''
    set -euo pipefail

    # metadata path
    METADATA_JSON=$1

    # check if the metadata file exists
    if [ ! -f $METADATA_JSON ]; then
        >&2 echo "Could not locate $METADATA_JSON"
        # client must have been in a bad state or it had not been able to initialise yet to a point
        # where it's RPC was active and returning so we indicate an error code
        exit 1
    fi

    # ensure the metadata file is recent
    NOW_SECONDS=$(date +%s)
    METADATA_SECONDS=$(date +%s -r $METADATA_JSON)
    METADATA_AGE=$((NOW_SECONDS - METADATA_SECONDS))

    if [ $METADATA_AGE -gt 30 ]; then
        >&2 echo "$METADATA_JSON is older than 30 seconds"
        # suspected failure in the metadata service, we can't be sure about the latest state of the client
        exit 1
    fi

    # determine the chain height from the metadata
    HEIGHT=$(cat $METADATA_JSON | jq .height)

    if [ -z $\{HEIGHT+x} ]; then
        >&2 echo "Could not determine height from $METADATA_JSON";
        # metadata is malformed
        exit 1
    fi

    echo $HEIGHT
  '';

  # It's necessary to record the exit status so that we can safeguard against backing up unclean state directories
  # in the case of performing an in-situ backup. For btrfs snapshot based backups, the snapshot script already
  # performs an exit status check before snapshotting.

  preStartScript = pkgs.writeShellScript "pre-start" ''
    # ensure metadata dir exists
    mkdir -p $BACKUP_METADATA_DIR

    # clear any previous exit status
    rm -f $BACKUP_METADATA_DIR/exit-status
  '';

  postStopScript = pkgs.writeShellScript "record-exit-status" ''
    echo $EXIT_STATUS > $BACKUP_METADATA_DIR/exit-status

    # hash the state directory, excluding backup metadata
    find $STATE_DIRECTORY -path $BACKUP_METADATA_DIR -prune -type f -exec md5sum {} + | LC_ALL=C sort | md5sum > $BACKUP_METADATA_DIR/content-hash
  '';

  setupSubVolumeScript = pkgs.writeShellScript "setup-sub-volume" ''
    set -euo pipefail

    VOLUME_DIR=$1

    if ! ${pkgs.btrfs-progs}/bin/btrfs sub show $VOLUME_DIR > /dev/null; then
        >&2 echo "$VOLUME_DIR is not a btrfs subvolume, exiting"
        exit 0
    fi

    echo "Disabling copy on write"
    ${pkgs.e2fsprogs}/bin/chattr -R +C $VOLUME_DIR
  '';

  snapshotVolumeScript = cfg:
    pkgs.writeShellScript "snapshot-volume" ''
      set -euo pipefail

      # check it was a clean shutdown before snapshotting
      if [ $EXIT_STATUS -ne 0 ]; then
          echo "Unclean shutdown detected: $EXIT_CODE, skipping snapshot"
          exit 1
      fi

      # determine the private path to the volume mount
      SERVICE_NAME=$(basename $STATE_DIRECTORY)

      # check if the volume is in fact a btrfs subvolume
      if ! btrfs sub show $STATE_DIRECTORY > /dev/null; then
          echo "$STATE_DIRECTORY is not a btrfs subvolume, skipping snapshot"
          exit 0  # clean exit as this hook will be registered against every service
      fi

      # determine chain height from metadata
      METADATA_JSON="$BACKUP_METADATA_DIR/metadata.json"
      HEIGHT=$(${chainHeightScript} $METADATA_JSON)

      if [ -z $\{HEIGHT+x} ]; then
          >&2 echo "Could not determine height from $METADATA_JSON, skipping snapshot";
          # metadata is malformed
          exit 1
      fi

      # ensure the base snapshot directory exists
      mkdir -p ${cfg.btrfs.snapshotDirectory}

      # check if the snapshot we are about to create already exists
      SNAPSHOT_DIRECTORY=${cfg.btrfs.snapshotDirectory}/$HEIGHT

      if [ -d $SNAPSHOT_DIRECTORY ]; then
        echo "Snapshot already exists: $SNAPSHOT_DIRECTORY, skipping snapshot"
        exit 0
      fi

      # create a readonly snapshot
      btrfs subvolume snapshot -r $STATE_DIRECTORY $SNAPSHOT_DIRECTORY
    '';

  mkMetadataService = name:
    lib.nameValuePair "${name}-metadata" {
      description = "Captures metadata about ${name}";
      path = with pkgs; [
        curl
        jq
        bash
        binutils
      ];
      # ensures this service is stopped if the main service is stopped
      bindsTo = ["${name}.service"];
      serviceConfig = {
        User = "root";
        CPUSchedulingPolicy = "idle";
        IOSchedulingClass = "idle";
        ExecStart = "${metadataScript} ${name}";
      };
    };

  mkMetadataTimer = name: cfg:
    lib.nameValuePair "${name}-metadata" {
      description = "Metadata timer for ${name}-metadata";
      wantedBy = [
        "timers.target"
        # ensure the timer is started when the main service is started
        "${name}.service"
      ];
      # ensures this service is stopped if the main service is stopped
      bindsTo = ["${name}.service"];
      timerConfig = {
        Persistent = true;
        OnCalendar = "*:*:0/${toString cfg.metadata.interval}"; # triggers every 10 seconds
      };
    };

  mkClientServiceCfg = name: cfg: {
    path = with pkgs; [
      btrfs-progs
      jq
      findutils
      coreutils
    ];

    environment = {
      BACKUP_METADATA_DIR = "/var/lib/${name}/.backup";
    };

    serviceConfig = {
      ExecStartPre = with lib;
        mkMerge [
          (mkIf cfg.btrfs.enable (mkBefore [
            "+${setupSubVolumeScript} /var/lib/private/${name}"
          ]))
          (mkAfter [preStartScript])
        ];
      ExecStopPost = mkAfter ([
          postStopScript
        ]
        ++ (lib.lists.optionals cfg.btrfs.enable [
          "+${snapshotVolumeScript cfg}"
        ]));
    };
  };

  backupScript = with lib;
    name: cfg: let
      inherit (cfg) restic;
      excludeFlags =
        if (restic.exclude != [])
        then ["--exclude-file=${pkgs.writeText "exclude-patterns" (concatStringsSep "\n" restic.exclude)}"]
        else [];
    in
      pkgs.writeShellScript "backup" ''
        set -euo pipefail

        SERVICE_NAME="${name}"
        SERVICE_STATE_DIRECTORY="/var/lib/$SERVICE_NAME"
        SERVICE_METADATA_DIR="$SERVICE_STATE_DIRECTORY/.backup"

        echo "Running backup for: $SERVICE_NAME"

        # first we ensure the repo exists
        if ! $RESTIC_CMD snapshots > /dev/null; then
            $RESTIC_CMD init
        fi

        build_tag_args() {
            METADATA_JSON=$1

            # check if the metadata file exists
            if [ ! -f $METADATA_JSON ]; then
                >&2 echo "Could not locate $METADATA_JSON"
                exit 1
            fi

            TAGS="--tag name:$SERVICE_NAME"
            for tag in $(cat $METADATA_JSON | sed -e 's/[" ,]//g' | grep "^\w.*" | tr '\n' ' ');
            do
                TAGS="--tag $tag $TAGS"
            done

            echo $TAGS
        }

        perform_backup() {
            TARGET_DIR=$1
            METADATA_DIR="$1/.backup"

            cd $TARGET_DIR
            echo "Backing up $TARGET_DIR"

            $RESTIC_CMD backup \
                --cache-dir=$CACHE_DIRECTORY \
                $(build_tag_args $METADATA_DIR/metadata.json) \
                ${concatStringsSep " " excludeFlags} \
                ./
        }

        backup_with_snapshot() {
            echo "Backing up with a snapshot, restarting $SERVICE_NAME"

            # restart the service to create the snapshot
            echo "Restarting $SERVICE_NAME"
            systemctl restart "$SERVICE_NAME.service"

            echo "Backing up snapshots for $SERVICE_NAME"

            # reverse order ensures the greatest chain height first and reduces the bandwidth needed
            # to transfer earlier archives
            SNAPSHOTS=$(ls -r "$SNAPSHOT_DIRECTORY")

            for SNAPSHOT in $SNAPSHOTS; do
                TARGET_DIR=$SNAPSHOT_DIRECTORY/$SNAPSHOT

                METADATA_DIR="$TARGET_DIR/.backup"

                if [ ! -d $METADATA_DIR ]; then
                    echo "Backup metadata directory not found, skipping backup: $METADATA_DIR"
                    continue
                fi

                # check that the process stopped cleanly
                EXIT_STATUS=$(cat $METADATA_DIR/exit-status)

                if [ $EXIT_STATUS -ne 0 ]; then
                    >&2 echo "Unclean shutdown detected, exit status: $EXIT_STATUS. Skipping backup of $TARGET_DIR"
                    continue
                fi

                NOW_SECONDS=$(date +%s)

                SNAPSHOT_CREATION_DATE=$(btrfs sub show $TARGET_DIR | grep 'Creation time' | cut -d$'\t' -f4)
                SNAPSHOT_CREATION_TIME=$(date +%s -d "$SNAPSHOT_CREATION_DATE")

                SNAPSHOT_AGE_SECONDS=$((NOW_SECONDS - SNAPSHOT_CREATION_TIME))

                if [ $SNAPSHOT_AGE_SECONDS -gt $SNAPSHOT_RETENTION_SECONDS ]; then
                    echo "Snapshot is older than configured retention, deleting"
                    btrfs sub delete $TARGET_DIR
                    continue
                fi

                if [ $($RESTIC_CMD snapshots -c | grep "height:$SNAPSHOT" | wc -l) -ge 1 ]; then
                    echo "Snapshot for height:$SNAPSHOT already exists, skipping"
                    continue
                fi

                perform_backup $TARGET_DIR
            done
        }

        backup_in_situ() {

            if [ ! -d $SERVICE_METADATA_DIR ]; then
                echo "Backup metadata directory not found, cannot perform backup: $SERVICE_METADATA_DIR"
                exit 1
            fi

            # stop the service
            echo "Backing up in-situ, stopping $SERVICE_NAME"
            systemctl stop "$SERVICE_NAME.service"

            # check that the process stopped cleanly
            EXIT_STATUS=$(cat $SERVICE_METADATA_DIR/exit-status)

            if [ $EXIT_STATUS -ne 0 ]; then
                >&2 echo "Unclean shutdown detected, exit status: $EXIT_STATUS. Skipping backup"
            else
                # determine chain height from metadata
                METADATA_JSON="$SERVICE_METADATA_DIR/metadata.json"
                HEIGHT=$(${chainHeightScript} $METADATA_JSON)

                if [ -z $\{HEIGHT+x} ]; then
                    >&2 echo "Could not determine height from $METADATA_JSON, skipping backup";
                else

                    if [ $($RESTIC_CMD snapshots -c | grep "height:$HEIGHT" | wc -l) -ge 1 ]; then
                        echo "Snapshot for height:$HEIGHT already exists, skipping"
                        continue
                    fi

                    perform_backup $SERVICE_STATE_DIRECTORY
                fi
            fi

            # start the service again
            echo "Restarting $SERVICE_NAME"
            systemctl start "$SERVICE_NAME.service"
        }

        if ! btrfs sub show $SERVICE_STATE_DIRECTORY > /dev/null; then
            backup_in_situ
        elif [ $SNAPSHOT_ENABLE -eq 0 ]; then
            backup_in_situ
        else
            backup_with_snapshot
        fi

        echo "Backup complete"
      '';

  mkBackupService = name: cfg:
    with lib; let
      inherit (cfg) restic;
      extraOptions = concatMapStrings (arg: " -o ${arg}") restic.extraOptions;
      resticCmd = "${pkgs.restic}/bin/restic${extraOptions} -vv";
      # Helper functions for rclone remotes
      rcloneRemoteName = builtins.elemAt (splitString ":" restic.repository) 1;
      rcloneAttrToOpt = v: "RCLONE_" + toUpper (builtins.replaceStrings ["-"] ["_"] v);
      rcloneAttrToConf = v: "RCLONE_CONFIG_" + toUpper (rcloneRemoteName + "_" + v);
      toRcloneVal = v:
        if lib.isBool v
        then lib.boolToString v
        else v;
    in
      lib.nameValuePair "${name}-backup" {
        description = "Backup service for ${name}";
        path = [
          pkgs.restic
          pkgs.btrfs-progs
          pkgs.jq
          pkgs.openssh
          pkgs.systemd
        ];

        restartIfChanged = false;

        environment =
          {
            RESTIC_PASSWORD_FILE = restic.passwordFile;
            RESTIC_REPOSITORY = restic.repository;
            RESTIC_REPOSITORY_FILE = restic.repositoryFile;
            RESTIC_CMD = resticCmd;

            SNAPSHOT_ENABLE =
              if cfg.btrfs.enable
              then "1"
              else "0";
            SNAPSHOT_DIRECTORY = cfg.btrfs.snapshotDirectory;
            # 86400 seconds in a day
            SNAPSHOT_RETENTION_SECONDS = builtins.toString (cfg.btrfs.snapshotRetention * 86400);
          }
          // optionalAttrs (restic.rcloneOptions != null) (mapAttrs'
            (
              name: value:
                nameValuePair (rcloneAttrToOpt name) (toRcloneVal value)
            )
            restic.rcloneOptions)
          // optionalAttrs (restic.rcloneConfigFile != null) {
            RCLONE_CONFIG = restic.rcloneConfigFile;
          }
          // optionalAttrs (restic.rcloneConfig != null) (mapAttrs'
            (
              name: value:
                nameValuePair (rcloneAttrToConf name) (toRcloneVal value)
            )
            restic.rcloneConfig);

        serviceConfig = {
          User = "root";
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";
          ProtectSystem = "strict";
          PrivateTmp = true;
          EnvironmentFile = cfg.restic.environmentFile;
          StateDirectory = "${name}-backup";
          CacheDirectory = "${name}-backup";
          CacheDirectoryMode = "0700";
          ReadWritePaths = mkIf cfg.btrfs.enable [cfg.btrfs.snapshotDirectory];
          ExecStart = "${backupScript name cfg} ${name}";
        };
      };

  mkBackupTimer = name: cfg:
    lib.nameValuePair "${name}-backup" {
      description = "Timer for ${name}-backup";
      wantedBy = [
        "timers.target"
        # ensure the timer is started when the main service is started
        "${name}.service"
      ];
      # ensures this service is stopped if the main service is stopped
      bindsTo = [
        "${name}.service"
      ];
      timerConfig = {
        Persistent = true;
        OnCalendar = cfg.schedule;
      };
      # wait for network
      after = ["network-online.target"];
    };

  backupTimers = with lib; mapAttrs' mkBackupTimer cfg;
  backupServices = with lib; mapAttrs' mkBackupService cfg;

  metadataTimers = with lib; mapAttrs' mkMetadataTimer cfg;
  metadataServices = with lib; mapAttrs' (name: _: mkMetadataService name) cfg;

  clientServiceCfgs = with lib; mapAttrs mkClientServiceCfg cfg;
in {
  config.systemd = {
    managerEnvironment = {
      # forces v/q/Q in tmpfiles rules to create a subvolume if the backing filesystem supports it, even if `/` is not a subvolume itself.
      "SYSTEMD_TMPFILES_FORCE_SUBVOL" = lib.mkDefault "1";
    };

    # enables a btrfs subvolume for the state directory provided the underlying filesystem supports
    # if the root filesystem is not btrfs then a normal directory is created
    tmpfiles.rules = with lib;
      map
      (name: "v /var/lib/private/${name}")
      (builtins.attrNames (filterAttrs (_: v: v.btrfs.enable) cfg));

    services =
      backupServices
      // metadataServices
      // clientServiceCfgs;

    timers =
      backupTimers
      // metadataTimers;
  };
}
