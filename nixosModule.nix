{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.passphrase-less-reboot;

  inherit (lib)
    mkIf
    mkForce
    concatStringsSep
    optional
    filter
    attrNames
    all
    attrValues
    ;

  deviceNames = filter (name: config.boot.initrd.luks.devices.${name}.keyFile == cfg.tempKeyFile) (
    attrNames config.boot.initrd.luks.devices
  );
  getDevice = name: config.boot.initrd.luks.devices.${name}.device;
in
{
  options = import ./options.nix lib;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = deviceNames != [ ];
        message = ''
          No LUKS devices found with keyFile set to ${cfg.tempKeyFile}.
          Set `config.boot.initrd.luks.devices.*.keyFile` to ${cfg.tempKeyFile}
          for at least one device to use passphrase-less reboot.
        '';
      }
      {
        assertion =
          config.boot.initrd.systemd.enable
          || (all (deviceName: config.boot.initrd.luks.${deviceName}.fallbackToPassword) deviceNames);
        message = ''
          Without systemd in the stage-1 initrd, all configured LUKS devices must have
          `fallbackToPassword = true`.
        '';
      }
    ];

    systemd.services.prepare-kexec = {
      path = attrValues {
        inherit (pkgs)
          cpio
          cryptsetup
          gzip
          ;
      };

      script = mkForce (
        import ./script.nix {
          inherit
            concatStringsSep
            deviceNames
            getDevice
            cfg
            ;
        }
      );
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

    environment.systemPackages = optional cfg.installPackage (
      pkgs.writeShellScriptBin "kexec-reboot" ''
        systemctl start prepare-kexec && systemctl kexec
      ''
    );
  };
}
