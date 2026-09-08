{
  description = "Reboot your encrypted NixOS system without entering your passphrase";

  outputs = _: {
    nixosModules.default = import ./nixosModule.nix;
  };
}
