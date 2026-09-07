# NixOS Passphrase-less Reboot

A NixOS module that enables **passphrase-less reboots using `kexec`**.

Instead of rebooting through the firmware and bootloader and requiring the LUKS passphrase again, the module:

1. Generates a random temporary LUKS key.
2. Adds the key to a configurable LUKS keyslot.
3. Creates a modified initrd containing the temporary key.
4. Loads the NixOS generation currently selected for boot with `kexec`.
5. Boots directly into that generation.
6. Unlocks the LUKS device using the temporary key.
7. Removes the temporary LUKS key from the keyslot during initrd startup.

This makes it possible to use, for example:

```console
sudo nixos-rebuild boot
sudo kexec-reboot
```

to rebuild a remote machine and boot into the new generation without having to manually enter the LUKS passphrase.

> **Note:** Most of the configuration and implementation is based on the excellent [Passphraseless reboots using kexec](https://www.bevuta.com/en/blog/passphraseless-reboots-using-kexec/) article by Bevuta IT.

## Usage

Add the flake as an input to your NixOS flake:

```nix
{
  inputs = {
    nixos-passphrase-less-reboot.url =
      "github:flyingpeakock/nixos-passphrase-less-reboot";
  };

  outputs = inputs@{ self, nixpkgs, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      modules = [
        inputs.nixos-passphrase-less-reboot.nixosModules.default

        ./configuration.nix
      ];
    };
  };
}
```

Then enable the module in your NixOS configuration:

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

`existingKeyFile` must contain a key that can already unlock the LUKS device. It is used by `prepare-kexec` to add the randomly generated temporary key.

Using a path such as `/run/secrets/luks-passphrase` works well with secret-management solutions such as [sops-nix](https://github.com/Mic92/sops-nix) or [agenix](https://github.com/ryantm/agenix).

The `keyFile` of the LUKS device must point to the same path as `passphrase-less-reboot.tempKeyFile`.

### Rebooting

Build the generation that should be used for the next boot:

```console
sudo nixos-rebuild boot --flake .#my-host
```

Then reboot into it using:

```console
sudo kexec-reboot
```

The command runs:

```text
systemctl start prepare-kexec
systemctl kexec
```

`prepare-kexec` resolves `/nix/var/nix/profiles/system`, so the generation selected by `nixos-rebuild boot` is loaded.

The machine then transitions directly into that NixOS generation without going through the normal firmware and bootloader reboot sequence.

## Options

All options are under `passphrase-less-reboot`.

### `passphrase-less-reboot.enable`

**Type:** `boolean`

**Default:** `false`

Enables passphrase-less reboot support.

```nix
passphrase-less-reboot.enable = true;
```

### `passphrase-less-reboot.tempKeyFile`

**Type:** `str`

**Default:** `"/etc/tmp-passphrase"`

Path to the temporary key file.

The randomly generated key is placed at this path inside the modified initrd and is used to unlock the configured LUKS devices.

The LUKS configuration must reference the same path:

```nix
passphrase-less-reboot.tempKeyFile = "/etc/tmp-passphrase";

boot.initrd.luks.devices.cryptroot.keyFile =
  "/etc/tmp-passphrase";
```

The default is normally sufficient.

### `passphrase-less-reboot.keySlot`

**Type:** `integer`

**Default:** `31`

The LUKS keyslot used for the temporary key.

```nix
passphrase-less-reboot.keySlot = 31;
```

The keyslot should be unused on the LUKS device or devices.

The module adds the temporary key to this slot before `kexec` and removes it again during initrd startup.

### `passphrase-less-reboot.existingKeyFile`

**Type:** `str`

**Required**

Path to an existing key file capable of unlocking the LUKS device.

For example, when using sops-nix or agenix:

```nix
passphrase-less-reboot.existingKeyFile =
  "/run/secrets/luks-passphrase";
```

This key is **not** embedded into the generated initrd. It is only read by the `prepare-kexec` service in the running system to authenticate the `luksAddKey` operation.

### `passphrase-less-reboot.installPackage`

**Type:** `boolean`

**Default::** `true`

Installs the kexec-reboot script which reboots the system using kexec.

## Multiple LUKS devices

The module supports multiple LUKS devices.

Any LUKS device whose `keyFile` matches `tempKeyFile` is automatically included.

For example:

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

Both devices will receive the temporary key, and the temporary keyslot will be removed from both devices after their cryptsetup services have completed.

LUKS devices that use a different `keyFile` are ignored.

At least one LUKS device must use `passphrase-less-reboot.tempKeyFile`; otherwise the NixOS configuration fails its module assertion.

## How it works

When `kexec-reboot` is invoked, the `prepare-kexec` systemd service performs the following operations.

### 1. Find the generation selected for boot

The service resolves:

```text
/nix/var/nix/profiles/system
```

This is the system profile updated by commands such as:

```console
sudo nixos-rebuild boot
```

The kernel, initrd, kernel parameters, and `init` from that generation are then used for the kexec boot.

### 2. Generate a temporary key

256 bytes of random data are generated using `/dev/urandom`:

```text
/dev/urandom
    │
    ▼
temporary LUKS key
```

The key is created inside a temporary directory under `/dev/shm`.

### 3. Add the key to LUKS

For every LUKS device configured with the temporary key file, the service runs the equivalent of:

```console
cryptsetup luksAddKey \
  --batch-mode \
  --key-slot <keySlot> \
  <device> \
  <temporary-key> \
  < <existing-key>
```

The existing key authenticates the operation while the newly generated temporary key is added to the configured keyslot.

### 4. Create a modified initrd

The initrd belonging to the selected NixOS generation is copied into the temporary directory.

A compressed `cpio` archive containing the temporary key is then appended to it.

Conceptually:

```text
original initrd
      +
temporary key
      │
      ▼
modified initrd
```

Because the configured LUKS `keyFile` points to the same location, the key becomes available to the initrd during early boot.

### 5. Load the selected generation using kexec

The kernel and modified initrd are loaded with `kexec`, together with the generation's kernel parameters and `init` path.

Conceptually, the service executes:

```console
kexec --load \
  <kernel> \
  --initrd=<modified-initrd> \
  --append="<kernel-params> init=<generation>/init"
```

When `systemctl kexec` is subsequently executed, the machine jumps directly into that kernel.

### 6. Unlock LUKS

The new initrd starts and the normal NixOS cryptsetup units unlock the configured LUKS devices using:

```nix
boot.initrd.luks.devices.<name>.keyFile
```

Since the temporary key was added to the initrd at that location, no interactive passphrase entry is necessary.

### 7. Remove the temporary key

After the relevant `systemd-cryptsetup@.service` units have completed, the initrd runs the equivalent of:

```console
cryptsetup luksKillSlot \
  --batch-mode \
  <device> \
  <keySlot>
```

This removes the temporary key from the LUKS header.

The temporary key is therefore valid only for the transition between the running system and the new kexec-booted system.

## Safety checks

The module requires at least one LUKS device whose `keyFile` matches `passphrase-less-reboot.tempKeyFile`.

For example:

```nix
passphrase-less-reboot.tempKeyFile = "/etc/tmp-passphrase";

boot.initrd.luks.devices.cryptroot.keyFile =
  "/etc/tmp-passphrase";
```

If no matching device exists, NixOS evaluation fails with an assertion rather than producing a configuration in which the feature cannot work.

Before loading the kernel, `prepare-kexec` also verifies that:

* the NixOS system profile exists;
* `existingKeyFile` exists.

If a kexec kernel has already been loaded, `prepare-kexec` exits successfully without replacing it.

## Security considerations

This module intentionally places a temporary LUKS key inside an initrd that is loaded into memory for the duration of the reboot.

The temporary key is:

* randomly generated for each prepared reboot;
* 256 bytes long;
* added to a dedicated LUKS keyslot;
* stored in a temporary directory under `/dev/shm`;
* embedded only in the temporary kexec initrd;
* removed from the LUKS keyslot after the new initrd has unlocked the device.

The permanent key referenced by `existingKeyFile` is never copied into the initrd.

However, **kexec is not equivalent to a cold reboot from a security perspective**. The next kernel is entered directly from the currently running system, without a normal firmware reboot, and the temporary key necessarily exists in memory while preparing and performing the reboot.

This mechanism should therefore be considered in the context of your threat model, particularly where an attacker may have privileged access to the running system or physical access to its memory.

You should also ensure that `keySlot` is suitable for use as a temporary keyslot on every LUKS device managed by this module.

## Requirements

This module assumes:

* NixOS;
* systemd-based initrd;
* LUKS/dm-crypt storage;
* kernel support for `kexec`;
* an existing key file capable of unlocking every relevant LUKS device.

The module uses the following tools internally:

* `kexec`
* `cryptsetup`
* `cpio`
* `gzip`

## Troubleshooting

### `existingKeyFile` cannot be found

Make sure the secret exists in the running system before invoking `kexec-reboot`:

```console
sudo ls -l /run/secrets/luks-passphrase
```

If using sops-nix or agenix, ensure the secret has been provisioned before `prepare-kexec` runs.

The file must contain a valid key or passphrase capable of unlocking the LUKS device.

You can inspect the service logs with:

```console
systemctl status prepare-kexec
journalctl -u prepare-kexec
```

### The configured keyslot is already in use

Choose a different keyslot:

```nix
passphrase-less-reboot.keySlot = 30;
```

You can inspect the current LUKS metadata with:

```console
sudo cryptsetup luksDump /dev/your-device
```

The configured temporary keyslot must be suitable for use on every LUKS device managed by the module.

### Inspecting a prepared kexec boot

You can explicitly prepare the kexec boot without immediately rebooting:

```console
sudo systemctl start prepare-kexec
```

Then check whether a kernel has been loaded:

```console
cat /sys/kernel/kexec_loaded
```

A value of:

```text
1
```

indicates that a kexec kernel has been loaded.

You can then perform the transition with:

```console
sudo systemctl kexec
```

## Complete example

A minimal configuration might look like:

```nix
{
  imports = [
    inputs.nixos-passphrase-less-reboot.nixosModules.default
  ];

  passphrase-less-reboot = {
    enable = true;
    existingKeyFile = "/run/secrets/luks-passphrase";
    keySlot = 31;
  };

  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-uuid/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
    keyFile = "/etc/tmp-passphrase";
  };
}
```

If using sops-nix, for example, the permanent key could be provided separately:

```nix
{
  sops.secrets.luks-passphrase = { };

  passphrase-less-reboot.existingKeyFile =
    config.sops.secrets.luks-passphrase.path;
}
```

Build the system for the next boot:

```console
sudo nixos-rebuild boot --flake .#my-host
```

Then reboot directly into it:

```console
sudo kexec-reboot
```

## Credits

The implementation is largely based on:

**[Passphraseless reboots using kexec](https://www.bevuta.com/en/blog/passphraseless-reboots-using-kexec/)** by Bevuta IT.

This project packages the approach as a reusable NixOS module and integrates it with NixOS's declarative LUKS configuration.

## License

Licensed under the [MIT License](LICENSE).

## AI Disclosure

This README is 100% AI-generated. I have proof-read the entire README and take responsibility for its contents.

All of the Nix code and implementation were written by me; AI was only used to help generate and polish the documentation.

