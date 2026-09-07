{
  concatStringsSep,
  deviceNames,
  getDevice,
  cfg,
}:
''
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
  find ".$KEY_DIR" | cpio -H newc -o | gzip >> "$TEMP_DIR/initrd.img"

  # load the kernel with the new initrd
  echo "Loading NixOS system via kexec."
  exec kexec --load "$p/kernel" --initrd="$TEMP_DIR/initrd.img" --append="$(cat "$p/kernel-params") init=$p/init"
''
