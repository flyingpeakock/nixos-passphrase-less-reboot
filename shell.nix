{ inputs, ... }:
{
  imports = [ inputs.git-hooks-nix.flakeModule ];

  perSystem = { config, pkgs, ... }: {
    pre-commit.settings.hooks = {
      nixfmt.enable = true;
      deadnix.enable = true;
      flake-checker.enable = true;
      statix.enable = true;
    };

    devShells.default = pkgs.mkShell {
      shellHook = ''
        ${config.pre-commit.installationScript}
      '';

      packages = builtins.attrValues {
        inherit (pkgs)
          nixfmt-tree
          deadnix
          statix
          ;
      };
    };
  };
}
