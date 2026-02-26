{
  root,
  super,
}:
/*
Use the Terra Blocktype for terraform configurations managed by terranix.

Important! You need to specify the state repo on the blocktype, e.g.:

[
  (terra "infra" "git@github.com:myorg/myrepo.git")
]

Available actions:
  - init
  - plan
  - apply
  - state
  - refresh
  - destroy

Optional terranix `_meta` passthru (requires terranix PR #151):
  _meta.std = {
    package, providers, modules,
    terraformBackendGit = { enable, repo, ref, state; },
  }
*/
let
  inherit (root) mkCommand;
  inherit (super) addSelectorFunctor postDiffToGitHubSnippet;
in
  name: repo: {
    inherit name;
    __functor = addSelectorFunctor;
    type = "terra";
    actions = {
      currentSystem,
      fragment,
      fragmentRelPath,
      target,
      inputs,
    }: let
      inherit (inputs) terranix;
      pkgs = inputs.nixpkgs.${currentSystem};

      git = {
        repo = backendGitCfg.repo or repo;
        ref = backendGitCfg.ref or "main";
        state = backendGitCfg.state or (fragmentRelPath + "/state.json");
      };

      terraEval = import (terranix + /core/default.nix);
      terraResult = terraEval {
        inherit pkgs; # only effectively required for `pkgs.lib`
        terranix_config = {
          _file = fragmentRelPath;
          imports = [target];
        };
        strip_nulls = true;
      };

      stdMeta = (terraResult._meta or {}).std or {};

      tfBase = stdMeta.package or pkgs.terraform;
      providers = stdMeta.providers or [];
      tfPkg =
        if tfBase ? withPlugins && providers != []
        then tfBase.withPlugins (_: providers)
        else tfBase;
      tfExe = pkgs.lib.getExe tfPkg;

      modules = stdMeta.modules or {};
      moduleLinksSnippet = pkgs.lib.concatStringsSep "\n" (
        pkgs.lib.mapAttrsToList (n: src: "ln -sf \"${src}\" \"$dir/modules/${n}\"") modules
      );

      backendGitCfg = stdMeta.terraformBackendGit or {};
      backendGitEnable = backendGitCfg.enable or true;

      terraformConfiguration = builtins.toFile "config.tf.json" (builtins.toJSON terraResult.config);

      setup = ''
        export TF_VAR_fragment=${pkgs.lib.strings.escapeShellArg fragment}
        export TF_VAR_fragmentRelPath=${fragmentRelPath}
        export TF_IN_AUTOMATION=1
        export TF_DATA_DIR="$PRJ_DATA_HOME/${fragmentRelPath}"
        export TF_PLUGIN_CACHE_DIR="$PRJ_CACHE_HOME/tf-plugin-cache"
        mkdir -p "$TF_DATA_DIR"
        mkdir -p "$TF_PLUGIN_CACHE_DIR"
        dir="$PRJ_ROOT/.tf/${fragmentRelPath}/.tf"
        mkdir -p "$dir"
        cat << MESSAGE > "$dir/readme.md"
        This is a tf staging area.
        It is motivated by the terraform CLI requiring to be executed in a staging area.
        MESSAGE

        if [[ -e "$dir/config.tf.json" ]]; then rm -f "$dir/config.tf.json"; fi
        jq '.' ${terraformConfiguration} > "$dir/config.tf.json"

        rm -rf "$dir/modules"
        ${pkgs.lib.optionalString (modules != {}) ''
          mkdir -p "$dir/modules"
          ${moduleLinksSnippet}
        ''}
      '';
      wrap = cmd: ''
        ${setup}

        # Run the command and capture output
        if ${pkgs.lib.boolToString backendGitEnable}; then
          terraform-backend-git git \
             --dir "$dir" \
             --repository ${git.repo} \
             --ref ${git.ref} \
             --state ${git.state} \
             terraform --tf ${tfExe} ${cmd} "$@" \
             ${pkgs.lib.optionalString (cmd == "plan") ''
          -lock=false -no-color | tee "$PRJ_CACHE_HOME/tf.console.txt"
        ''}
        else
          ${tfExe} -chdir="$dir" ${cmd} "$@" \
            ${pkgs.lib.optionalString (cmd == "plan") ''
          -lock=false -no-color | tee "$PRJ_CACHE_HOME/tf.console.txt"
        ''}
        fi

        # Pass output to the snippet
        ${pkgs.lib.optionalString (cmd == "plan") ''
          output=$(cat "$PRJ_CACHE_HOME/tf.console.txt")
          summary_plan=$(tac "$PRJ_CACHE_HOME/tf.console.txt" | grep -m 1 -E '^(Error:|Plan:|Apply complete!|No changes.|Success)' | tac || echo "View output.")
          summary="<code>std ${fragmentRelPath}:${cmd}</code>: $summary_plan"
          ${postDiffToGitHubSnippet "${fragmentRelPath}:${cmd}" "$output" "$summary"}
        ''}
      '';

      deps = [pkgs.jq] ++ [tfPkg] ++ [pkgs.terraform-backend-git];
    in [
      (mkCommand currentSystem "init" "tf init" deps (wrap "init") {})
      (mkCommand currentSystem "plan" "tf plan" deps (wrap "plan") {})
      (mkCommand currentSystem "apply" "tf apply" deps (wrap "apply") {})
      (mkCommand currentSystem "state" "tf state" deps (wrap "state") {})
      (mkCommand currentSystem "refresh" "tf refresh" deps (wrap "refresh") {})
      (mkCommand currentSystem "destroy" "tf destroy" deps (wrap "destroy") {})
      (mkCommand currentSystem "terraform" "pass any command to terraform" deps (wrap "") {})
    ];
  }
