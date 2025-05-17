{ pkgs, config, lib, ... }:

with lib;

let

  cfg = filterAttrs (n: f: f.enable) config.home.file;

  homeDirectory = config.home.homeDirectory;

  fileType = (import lib/file-type.nix {
    inherit homeDirectory lib pkgs;
  }).fileType;

  sourceStorePath = file:
    let
      sourcePath = toString file.source;
      sourceName = config.lib.strings.storeFileName (baseNameOf sourcePath);
    in
      if builtins.hasContext sourcePath
      then file.source
      else builtins.path { path = file.source; name = sourceName; };

in

{
  options = {
    home.file = mkOption {
      description = "Attribute set of files to link into the user home.";
      default = {};
      type = fileType "home.file" "{env}`HOME`" homeDirectory;
    };

    home-files = mkOption {
      type = types.package;
      internal = true;
      description = "Package to contain all home files";
    };
  };

  config = {
    assertions = [(
      let
        dups =
          attrNames
            (filterAttrs (n: v: v > 1)
            (foldAttrs (acc: v: acc + v) 0
            (mapAttrsToList (n: v: { ${v.target} = 1; }) cfg)));
        dupsStr = concatStringsSep ", " dups;
      in {
        assertion = dups == [];
        message = ''
          Conflicting managed target files: ${dupsStr}

          This may happen, for example, if you have a configuration similar to

              home.file = {
                conflict1 = { source = ./foo.nix; target = "baz"; };
                conflict2 = { source = ./bar.nix; target = "baz"; };
              }'';
      })
    ];

    lib.file.mkOutOfStoreSymlink = path:
      let
        pathStr = toString path;
        name = hm.strings.storeFileName (baseNameOf pathStr);
      in
        pkgs.runCommandLocal name {} ''ln -s ${escapeShellArg pathStr} $out'';

    # This verifies that the links we are about to create will not
    # overwrite an existing file.
    home.activation.checkLinkTargets = hm.dag.entryBefore ["writeBoundary"] (
      let
        # Paths that should be forcibly overwritten by Home Manager.
        # Caveat emptor!
        forcedPaths =
          concatMapStringsSep " " (p: ''"$HOME"/${escapeShellArg p}'')
            (mapAttrsToList (n: v: v.target)
            (filterAttrs (n: v: v.force) cfg));

        storeDir = escapeShellArg builtins.storeDir;

        check = pkgs.substituteAll {
          src = ./files/check-link-targets.sh;

          inherit (config.lib.bash) initHomeManagerLib;
          inherit forcedPaths storeDir;
        };
      in
      ''
        function checkNewGenCollision() {
          local newGenFiles
          newGenFiles="$(readlink -e "$newGenPath/home-files")"
          find "$newGenFiles" \( -type f -or -type l \) \
              -exec bash ${check} "$newGenFiles" {} +
        }

        checkNewGenCollision || exit 1
      ''
    );

    # This activation script will
    #
    # 1. Remove files from the old generation that are not in the new
    #    generation.
    #
    # 2. Switch over the Home Manager gcroot and current profile
    #    links.
    #
    # 3. Symlink files from the new generation into $HOME.
    #
    # This order is needed to ensure that we always know which links
    # belong to which generation. Specifically, if we're moving from
    # generation A to generation B having sets of home file links FA
    # and FB, respectively then cleaning before linking produces state
    # transitions similar to
    #
    #      FA   →   FA ∩ FB   →   (FA ∩ FB) ∪ FB = FB
    #
    # and a failure during the intermediate state FA ∩ FB will not
    # result in lost links because this set of links are in both the
    # source and target generation.
    home.activation.linkGeneration = hm.dag.entryAfter ["writeBoundary"] (
      let
        link = pkgs.replaceVars ./files/link.sh {
          inherit (config.lib.bash) initHomeManagerLib;
        };

        storeDir = escapeShellArg builtins.storeDir;

        cleanup = pkgs.replaceVars ./files/cleanup.sh {
          inherit (config.lib.bash) initHomeManagerLib;
          inherit storeDir;
        };
      in
        ''
          function linkNewGen() {
            _i "Creating home file links in %s" "$HOME"

            local newGenFiles
            newGenFiles="$(readlink -e "$newGenPath/home-files")"
            find "$newGenFiles" \( -type f -or -type l \) \
              -exec bash ${link} "$newGenFiles" {} +
          }

          function cleanOldGen() {
            if [[ ! -v oldGenPath || ! -e "$oldGenPath/home-files" ]] ; then
              return
            fi

            _i "Cleaning up orphan links from %s" "$HOME"

            local newGenFiles oldGenFiles
            newGenFiles="$(readlink -e "$newGenPath/home-files")"
            oldGenFiles="$(readlink -e "$oldGenPath/home-files")"

            # Apply the cleanup script on each leaf in the old
            # generation. The find command below will print the
            # relative path of the entry.
            find "$oldGenFiles" '(' -type f -or -type l ')' -printf '%P\0' \
              | xargs -0 bash ${cleanup} "$newGenFiles"
          }

          cleanOldGen

          if [[ ! -v oldGenPath || "$oldGenPath" != "$newGenPath" ]] ; then
            _i "Creating profile generation %s" $newGenNum
            if [[ -e "$genProfilePath"/manifest.json ]] ; then
              # Remove all packages from "$genProfilePath"
              # `nix profile remove '.*' --profile "$genProfilePath"` was not working, so here is a workaround:
              nix profile list --profile "$genProfilePath" \
                | cut -d ' ' -f 4 \
                | xargs -rt $DRY_RUN_CMD nix profile remove $VERBOSE_ARG --profile "$genProfilePath"
              run nix profile install $VERBOSE_ARG --profile "$genProfilePath" "$newGenPath"
            else
              run nix-env $VERBOSE_ARG --profile "$genProfilePath" --set "$newGenPath"
            fi

            run --quiet nix-store --realise "$newGenPath" --add-root "$newGenGcPath" --indirect
            if [[ -e "$legacyGenGcPath" ]]; then
              run rm $VERBOSE_ARG "$legacyGenGcPath"
            fi
          else
            _i "No change so reusing latest profile generation %s" "$oldGenNum"
          fi

          linkNewGen
        ''
    );

    home.activation.checkFilesChanged = hm.dag.entryBefore ["linkGeneration"] (
      let
        homeDirArg = escapeShellArg homeDirectory;
      in ''
        function _cmp() {
          if [[ -d $1 && -d $2 ]]; then
            diff -rq "$1" "$2" &> /dev/null
          else
            cmp --quiet "$1" "$2"
          fi
        }
        declare -A changedFiles
      '' + concatMapStrings (v:
        let
          sourceArg = escapeShellArg (sourceStorePath v);
          targetArg = escapeShellArg v.target;
        in ''
          _cmp ${sourceArg} ${homeDirArg}/${targetArg} \
            && changedFiles[${targetArg}]=0 \
            || changedFiles[${targetArg}]=1
        '') (filter (v: v.onChange != "") (attrValues cfg))
      + ''
        unset -f _cmp
      ''
    );

    home.activation.onFilesChange = hm.dag.entryAfter ["linkGeneration"] (
      concatMapStrings (v: ''
        if (( ''${changedFiles[${escapeShellArg v.target}]} == 1 )); then
          if [[ -v DRY_RUN || -v VERBOSE ]]; then
            echo "Running onChange hook for" ${escapeShellArg v.target}
          fi
          if [[ ! -v DRY_RUN ]]; then
            ${v.onChange}
          fi
        fi
      '') (filter (v: v.onChange != "") (attrValues cfg))
    );

    # Symlink directories and files that have the right execute bit.
    # Copy files that need their execute bit changed.
    home-files = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
      name = "home-manager-files";
      enableParallelBuilding = true;
      preferLocalBuild = true;
      allowSubstitutes = false;
      nativeBuildInputs = [ pkgs.xorg.lndir ];
      PATH = makeBinPath finalAttrs.nativeBuildInputs;
      passAsFile = ["buildCommand" "insertFiles"];
      buildCommand = ./files/home-manager-files.sh;
      insertFiles = concatStrings (
        mapAttrsToList (n: v: ''
          insertFile ${
            escapeShellArgs [
              (sourceStorePath v)
              v.target
              (if v.executable == null
               then "inherit"
               else toString v.executable)
              (toString v.recursive)
            ]}
        '') cfg
      );
      checkPhase = ''
        ${pkgs.stdenvNoCC.shellDryRun} "$target"
      '';
    });
  };
}
