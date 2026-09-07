{
  flake.nixosModules.default =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.passphrase-less-reboot;

      inherit (lib)
        mkOption
        mkEnableOption
        mkIf
        mkForce
        concatStringsSep
        ;
      inherit (lib.types) str int bool;

      deviceNames = lib.filter (
        name: config.boot.initrd.luks.devices.${name}.keyFile == cfg.tempKeyFile
      ) (lib.attrNames config.boot.initrd.luks.devices);
      getDevice = name: config.boot.initrd.luks.devices.${name}.device;
    in
    {
      options.passphrase-less-reboot = {
        enable = mkEnableOption "passphrase-less reboot";

        tempKeyFile = mkOption {
          description = ''
            Path to the temporary key file created by the systemd service.
            This file will be used to store the randomly generated passKey for the encrypted root partition during reboot.
            `config.boot.initrd.devices.*.keyFile`should point to this file.
          '';
          type = str;
          default = "/etc/tmp-passphrase";
        };

        keySlot = mkOption {
          description = "The key slot number to use for the temporary passKey.";
          type = int;
          default = 31;
        };

        existingKeyFile = mkOption {
          description = ''
            Path to an existing key file.
            This is used to add a new key to the encrypted device.
          '';
          type = str;
        };

        installPackage = mkOption {
          description = ''
            Whether to install the `kexec-reboot`package.
            This package provides a script that reboots the system using kexec and the temporary passKey.
          '';
          type = bool;
          default = true;
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = deviceNames != [ ];
            message = ''
              No LUKS devices found with keyFile set to ${cfg.tempKeyFile}.
              Set `config.boot.initrd.luks.devices.*.keyFile to ${cfg.tempKeyFile}
              for at least one device to use passphrase-less reboot.
            '';
          }
        ];

        systemd.services.prepare-kexec = {
          path = lib.attrValues {
            inherit (pkgs)
              cpio
              cryptsetup
              gzip
              ;
          };

          script = mkForce ''
            # Don't load the current system profile if we already have a kernel loaded
            if [[ 1 = "$(</sys/kernel/kexec_loaded)" ]]; then
              echo "kexec kernel has already been loaded, prepare-kexec skipped"
              exit 0
            fi

            p=$(readlink -f /nix/var/nix/profiles/system)
            if ! [[ -d $p ]]; then
              echo "Could not find system profile for prepare-kexec"
              exit 1
            fi

            if ! [[ -f "${cfg.existingKeyFile}" ]]; then
              echo "Could not find LUKS passphrase file: ${cfg.existingKeyFile}"
              exit 1
            fi

            # add 256 random bytes temp key to the LUKS keyslot ${toString cfg.keySlot}
            KEY_DIR=$(dirname "${cfg.tempKeyFile}")
            TEMP_DIR="$(mktemp -d --tmpdir=/dev/shm)"
            mkdir -p "$TEMP_DIR$KEY_DIR"
            head -c 256 /dev/urandom > "$TEMP_DIR${cfg.tempKeyFile}"
            ${concatStringsSep "\n" (
              map (name: ''
                cryptsetup luksAddKey \
                  --batch-mode \
                  --key-slot ${toString cfg.keySlot} \
                  ${getDevice name} \
                  "$TEMP_DIR${cfg.tempKeyFile}" \
                  < "${cfg.existingKeyFile}"
              '') deviceNames
            )}

            # create a new cpio archive and append it to the original initrd
            cd "$TEMP_DIR"
            cp "$p/initrd" "$TEMP_DIR/initrd.img"
            find "$KEY_DIR" | cpio -H newc -o | gzip >> "$TEMP_DIR/initrd.img"

            # load the kernel with the new initrd
            echo "Loading NixOS system via kexec."
            exec kexec --load "$p/kernel" --initrd="$TEMP_DIR/initrd.img" --append="$(cat "$p/kernel-params") init=$p/init"
          '';
        };

        boot.initrd.systemd.services.clear-luks-keyslot = {
          description = "Clear the temporary LUKS keyslot after kexec";
          wantedBy = [ "initrd.target" ];
          after = map (name: "systemd-cryptsetup@${name}.service") deviceNames;
          serviceConfig.Type = "oneshot";
          path = [ pkgs.cryptsetup ];
          script = concatStringsSep "\n" (
            map (name: ''
              cryptsetup luksKillSlot --batch-mode ${getDevice name} ${toString cfg.keySlot} || true
            '') deviceNames
          );
        };

        environment.systemPackages = [
          (pkgs.writeShellScriptBin "kexec-reboot" ''
            systemctl start prepare-kexec && systemctl kexec
          '')
        ];
      };
    };
}
