# NixOS Passphrase-less Reboot

A NixOS module that enables **passphrase-less reboots using `kexec`**.

Instead of rebooting through the firmware and bootloader and requiring the LUKS passphrase again, the module:

1. Generates a random temporary LUKS key.
2. Adds it to a configurable LUKS keyslot.
3. Creates a modified initrd containing the temporary key.
4. Loads the NixOS generation selected for boot with `kexec`.
5. Unlocks the LUKS device using the temporary key.
6. Removes the temporary key from the LUKS keyslot.

This makes it possible to rebuild a remote machine and reboot into the new generation without manually entering the LUKS passphrase.

> **Note:** The implementation is largely based on [Passphraseless reboots using kexec](https://www.bevuta.com/en/blog/passphraseless-reboots-using-kexec/) by Bevuta IT.

## Usage

Add the flake as an input:

```nix
{
  inputs.nixos-passphrase-less-reboot.url =
    "github:flyingpeakock/nixos-passphrase-less-reboot";

  outputs = inputs@{ nixpkgs, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      modules = [
        inputs.nixos-passphrase-less-reboot.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Enable the module:

```nix
{
  passphrase-less-reboot = {
    enable = true;
    existingKeyFile = "/run/secrets/luks-passphrase";
  };

  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-uuid/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
    keyFile = "/etc/tmp-passphrase";
  };
}
```

`existingKeyFile` must contain a key that can already unlock the LUKS device. It is only used by `prepare-kexec` to add the temporary key; it is **not** included in the initrd.

This works well with secret-management solutions such as sops-nix or agenix.

The LUKS `keyFile` must match `passphrase-less-reboot.tempKeyFile` (which defaults to `/etc/tmp-passphrase`).

### Rebooting

First build the generation that should be used for the next boot:

```console
sudo nixos-rebuild boot --flake .#my-host
```

Then reboot into it:

```console
sudo kexec-reboot
```

`kexec-reboot` prepares the selected generation and performs the kexec transition.

## Options

All options are under `passphrase-less-reboot`.

| Option            | Type   | Default                 | Description                                     |
| ----------------- | ------ | ----------------------- | ----------------------------------------------- |
| `enable`          | `bool` | `false`                 | Enable passphrase-less reboots                  |
| `tempKeyFile`     | `str`  | `"/etc/tmp-passphrase"` | Path of the temporary key inside the initrd     |
| `keySlot`         | `int`  | `31`                    | LUKS keyslot used for the temporary key         |
| `existingKeyFile` | `str`  | **required**            | Existing key used to add the temporary LUKS key |
| `installPackage`  | `bool` | `true`                  | Install the `kexec-reboot` command              |

The configured `keySlot` must be unused on all managed LUKS devices.

## Multiple LUKS devices

Any LUKS device whose `keyFile` matches `tempKeyFile` is automatically included:

```nix
boot.initrd.luks.devices = {
  root = {
    device = "/dev/disk/by-uuid/...";
    keyFile = "/etc/tmp-passphrase";
  };

  data = {
    device = "/dev/disk/by-uuid/...";
    keyFile = "/etc/tmp-passphrase";
  };
};
```

The temporary key is added to and later removed from all matching devices.

At least one LUKS device must use `tempKeyFile`, otherwise NixOS evaluation fails.

## Security

The temporary key is:

* randomly generated for each reboot;
* 256 bytes long;
* stored temporarily under `/dev/shm`;
* embedded only in the temporary kexec initrd;
* removed from the LUKS keyslot after boot.

The permanent `existingKeyFile` is never copied into the initrd.

However, **kexec is not equivalent to a cold reboot from a security perspective**. The next kernel is entered directly from the currently running system, without going through firmware, and the temporary key exists in memory during the transition.

Consider this carefully if your threat model includes a privileged attacker on the running system or physical attacks against system memory.

## Requirements

* LUKS/dm-crypt storage
* Kernel support for `kexec`
* An existing key capable of unlocking the relevant LUKS devices

The module uses:

* `kexec`
* `cryptsetup`
* `cpio`
* `gzip`

## Troubleshooting

Check the preparation service:

```console
systemctl status prepare-kexec
journalctl -u prepare-kexec
```

You can prepare the kexec boot without immediately rebooting:

```console
sudo systemctl start prepare-kexec
```

Check whether a kernel has been loaded:

```console
cat /sys/kernel/kexec_loaded
```

A value of `1` means a kexec kernel is loaded.

You can then perform the transition with:

```console
sudo systemctl kexec
```

If `existingKeyFile` cannot be found, make sure the secret has been provisioned in the running system before running `kexec-reboot`.

If the configured keyslot is already in use, choose another slot and inspect the LUKS metadata with:

```console
sudo cryptsetup luksDump /dev/your-device
```

## Credits

The implementation is largely based on **[Passphraseless reboots using kexec](https://www.bevuta.com/en/blog/passphraseless-reboots-using-kexec/)** by Bevuta IT.

## License

Licensed under the [MIT License](LICENSE).

## AI Disclosure

This README is 100% AI-generated. I have proof-read the entire README and take responsibility for its contents.

All Nix code and implementation were written by me; AI was only used to generate and polish the documentation.

