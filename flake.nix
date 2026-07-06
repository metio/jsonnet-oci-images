# SPDX-FileCopyrightText: The jsonnet-oci-images Authors
# SPDX-License-Identifier: 0BSD

# The single source of the development toolchain: CI (verify.yml) and local
# shells run every gate through this flake's devShell, so both use the exact
# tool versions pinned in flake.lock. Renovate keeps the lock fresh.
#
# The flake owns only the host-runnable dev/lint tools. Building the library
# OCI images is a container operation (libraries.yml: docker buildx + cosign),
# not a devShell one, so that pipeline stays as it is.
{
  description = "jsonnet-oci-images development environment";

  inputs = {
    # Follow the metio/nix-devshell nixpkgs pin so this repo's actionlint/shellcheck track
    # the same versions as the rest of the org. This repo's two gates (hadolint +
    # actionlint) are not the shared lint set, so it keeps its own minimal shell
    # rather than pulling devshell.lib.mkDevShell (which would add the reuse/typos/
    # yamllint/markdownlint closures it never runs).
    devshell.url = "github:metio/nix-devshell";
    nixpkgs.follows = "devshell/nixpkgs";
    flake-compat.follows = "devshell/flake-compat";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # The PR lint gates (verify.yml).
            hadolint # lints the generic builder Containerfile
            actionlint # lints the workflows
            shellcheck # actionlint shells out to it for run: blocks

            # The discovery / readme hack scripts (hack/*.sh).
            jq
            curl
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
