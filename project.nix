# SPDX-FileCopyrightText: 2020 Serokell <https://serokell.io> 
#
# SPDX-License-Identifier: MPL-2.0

{ nixpkgs
, static ? false
, projectName
}:
let
  pkgs = if static then
    nixpkgs.pkgsCross.musl64
  else
    nixpkgs;
  project = pkgs.haskell-nix.cabalProject {
    compiler-nix-name = "ghc884";
    index-state = "2020-08-19T00:00:00Z";
    src = pkgs.haskell-nix.haskellLib.cleanGit { src = ./.; name="sources"; };
    modules = [{
      packages.${projectName} = {
       # package.ghcOptions = "-Werror";
      };
    }];
  };
in project
