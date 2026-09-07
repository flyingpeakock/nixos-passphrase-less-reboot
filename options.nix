lib:
let
  inherit (lib) mkOption mkEnableOption;
  inherit (lib.types) str int bool;
in
{
  passphrase-less-reboot = {
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
}
