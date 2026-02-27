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
  terraformBackendGit = {
    enable ? true,
    repo, ref, state,
    # When `address` is set, std runs Terraform in standalone HTTP-backend mode
    # (expects terraform-backend-git already running at that base URL) and
    # exports TF_HTTP_{ADDRESS,LOCK_ADDRESS,UNLOCK_ADDRESS}.
    address ? "http://localhost:6061",
  },
}

Runtime overrides:
  STD_TERRA_STATE_SUBDIR="foo" # stores state at "<fragmentRelPath>/foo/state.json"
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

      terranixEval = assert pkgs.lib.assertMsg (
        builtins.isAttrs terranix && terranix ? lib && terranix.lib ? evalTerranixConfiguration
      ) "std terra: inputs.terranix must provide lib.evalTerranixConfiguration";
        terranix.lib.evalTerranixConfiguration;

      terranixResult = terranixEval {
        inherit pkgs;
        modules = [
          {
            _file = fragmentRelPath;
            imports = [target];
          }
        ];
        strip_nulls = true;
      };

      stdMeta = (terranixResult._meta or {}).std or {};

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

      backendGitStandalone = backendGitEnable && backendGitCfg ? address;
      backendGitAddress =
        if backendGitStandalone
        then
          (
            let
              a0 = backendGitCfg.address;
              a =
                if a0 == null
                then ""
                else a0;
            in
              assert pkgs.lib.assertMsg (builtins.isString a && a != "")
              "std terra: _meta.std.terraformBackendGit.address must be a non-empty string (e.g. \"http://localhost:6061\")"; a
          )
        else "";

      stateRepo = backendGitCfg.repo or repo;
      stateRef = backendGitCfg.ref or "main";
      statePath = backendGitCfg.state or (fragmentRelPath + "/state.json");

      terraformConfiguration = builtins.toFile "config.tf.json" (builtins.toJSON terranixResult.config);

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

        rm -f "$dir/config.tf.json"
        jq '.' ${terraformConfiguration} > "$dir/config.tf.json"

        rm -f "$dir/terraform-backend-git.auto.tf.json"
        ${pkgs.lib.optionalString backendGitStandalone ''
          cat > "$dir/terraform-backend-git.auto.tf.json" <<'EOF'
          {
            "terraform": {
              "backend": {
                "http": {}
              }
            }
          }
          EOF
        ''}

        rm -rf "$dir/modules"
        ${pkgs.lib.optionalString (modules != {}) ''
          mkdir -p "$dir/modules"
          ${moduleLinksSnippet}
        ''}
      '';
      wrap = cmd: ''
        ${setup}

        action_cmd=${pkgs.lib.strings.escapeShellArg cmd}

        backend_git_address=${pkgs.lib.strings.escapeShellArg backendGitAddress}

        state_subdir="''${STD_TERRA_STATE_SUBDIR-}"
        state_subdir="''${state_subdir#/}"
        state_subdir="''${state_subdir%/}"
        if [[ -n "$state_subdir" ]]; then
          state_path="${fragmentRelPath}/$state_subdir/state.json"
        else
          state_path=${pkgs.lib.strings.escapeShellArg statePath}
        fi

        run_tf() {
          if ${pkgs.lib.boolToString backendGitEnable}; then
            if [[ -n "$backend_git_address" ]]; then
              backend_address="$backend_git_address"
              backend_address="''${backend_address%/}"

              repo_enc=$(jq -rn --arg v ${pkgs.lib.strings.escapeShellArg stateRepo} '$v|@uri')
              ref_enc=$(jq -rn --arg v ${pkgs.lib.strings.escapeShellArg stateRef} '$v|@uri')
              state_enc=$(jq -rn --arg v "$state_path" '$v|@uri')
              backend_url="$backend_address/?type=git&repository=$repo_enc&ref=$ref_enc&state=$state_enc"

              export TF_HTTP_ADDRESS="$backend_url"
              export TF_HTTP_LOCK_ADDRESS="$backend_url"
              export TF_HTTP_UNLOCK_ADDRESS="$backend_url"

              ${tfExe} -chdir="$dir" "$@"
            else
              terraform-backend-git git \
                --dir "$dir" \
                --repository ${stateRepo} \
                --ref ${stateRef} \
                --state "$state_path" \
                terraform --tf ${tfExe} "$@"
            fi
          else
            ${tfExe} -chdir="$dir" "$@"
          fi
        }

        ensure_backend_initialized() {
          if [[ ! -e "$TF_DATA_DIR/terraform.tfstate" ]]; then
            run_tf init -reconfigure
          fi
        }

        run_cmd() {
          if [[ -n "$action_cmd" ]]; then
            run_tf "$action_cmd" "$@"
          else
            run_tf "$@"
          fi
        }

        run_plan() {
          plan_file="$TF_DATA_DIR/std.plan"
          rm -f "$plan_file"
          run_tf plan "$@" -lock=false -no-color -out="$plan_file"
          run_tf show -no-color "$plan_file" > "$PRJ_CACHE_HOME/tf.console.txt"
        }

        post_plan_to_github() {
          console_file="$PRJ_CACHE_HOME/tf.console.txt"
          summary_plan=$(tac "$console_file" | grep -m 1 -E '^(Error:|Plan:|Apply complete!|No changes\.|Success)' | tac || echo "View output.")

          diff_summary="$(
            while IFS= read -r line; do
              msg="''${line#*# }"
              case "$msg" in
                *" be created"*)
                  printf '+ %s\n' "$msg"
                  ;;
                *" be destroyed"*)
                  printf '%s\n' "- $msg"
                  ;;
                *" be updated"*|*" be replaced"*)
                  printf '! %s\n' "$msg"
                  ;;
                *" be read"*)
                  printf '~ %s\n' "$msg"
                  ;;
                *)
                  printf '# %s\n' "$msg"
                  ;;
              esac
            done < <(grep '^  # ' "$console_file" || true)
          )"

          if [[ -z "$diff_summary" ]]; then
            diff_summary="# $summary_plan"
          fi

          max_bytes=42000
          console_truncated=$(head -c "$max_bytes" "$console_file" || true)
          console_size=$(wc -c < "$console_file" 2>/dev/null || echo 0)
          if [[ "$console_size" -gt "$max_bytes" ]]; then
            console_truncated="$console_truncated"$'\n...'
          fi

          output="$diff_summary"$'\n\n'"# --- terraform show (truncated) ---"$'\n'"$console_truncated"
          summary="<code>std ${fragmentRelPath}:${cmd}</code>: $summary_plan"
          ${postDiffToGitHubSnippet "${fragmentRelPath}:${cmd}" "$output" "$summary"}
        }

        if [[ -n "$action_cmd" ]] && [[ "$action_cmd" != "init" ]]; then
          ensure_backend_initialized
        fi

        if [[ "$action_cmd" == "plan" ]]; then
          run_plan "$@"
          post_plan_to_github
        else
          run_cmd "$@"
        fi
      '';

      deps = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.jq
        tfPkg
        pkgs.terraform-backend-git
      ];
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
