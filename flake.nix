{
  description = "content-filter in haskell playground";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-20.03";
    utils.url = "github:numtide/flake-utils";
    haskell-nix.url = "github:input-output-hk/haskell.nix";
  };

  outputs = { self, nixpkgs, haskell-nix, utils }:
    let 
      projectName = "record-dot-preprocessor";
      # Perhaps we should provide a more convinient way to do this?
      systems = [ "x86_64-linux" ];
      genAttrs = lst: f:
        builtins.listToAttrs (map (name: {
          inherit name;
          value = f name;
        }) lst);
      mkProject' = system: static: import ./project.nix { nixpkgs = haskell-nix.legacyPackages.${system}; inherit static projectName; };
      mkProject = system: static: (mkProject' system static).${projectName};
      mkExes = system: (mkProject system false).components.exes;
      mkStatic = system: { "${projectName}-static" = (mkProject system true).components.exes.${projectName}; };
      mkTests = system: (mkProject system false).components.tests;
    in   
    rec {
      packages = genAttrs systems (s: mkStatic s // mkExes s);
      defaultPackage = builtins.mapAttrs (n: v: v.${projectName}) self.packages;
      checks =  genAttrs systems mkTests;
      devShell = genAttrs systems (s: (mkProject' s false).shellFor {
        tools = { "cabal-install" = "3.2.0.0"; }; 
      });
    };
}
