_: marker: diff_output: summary: ''
  if [[ -v CI ]] && [[ -v BRANCH ]] && [[ -v OWNER_AND_REPO ]] && command -v gh > /dev/null ; then

    # Evaluate the provided values once.
    # Call sites may pass command substitutions like "$(diff || true)".
    DIFF_OUTPUT=${diff_output}
    SUMMARY=${summary}

    OWNER_REPO_NAME=$(gh repo view "$OWNER_AND_REPO" --json nameWithOwner --jq '.nameWithOwner')

    if ! gh pr view "$BRANCH" --repo "$OWNER_REPO_NAME" >/dev/null 2>&1; then
      exit 0
    fi

    # Proceed only if there is output
    if [[ -z "$DIFF_OUTPUT" ]]; then
      exit 0
    fi

    CENTRAL_COMMENT_HEADER="<!-- Unified Diff Comment -->"
    ENTRY_START_MARKER="<!-- Start Diff for ${marker} -->"
    ENTRY_END_MARKER="<!-- End Diff for ${marker} -->"

  # Use the provided summary
  DIFF_ENTRY=$(printf '%s\n' \
    "$ENTRY_START_MARKER" \
    "<details>" \
    "<summary>$SUMMARY</summary>" \
    "" \
    "\`\`\`diff" \
    "$DIFF_OUTPUT" \
    "\`\`\`" \
    "" \
    "</details>" \
    "$ENTRY_END_MARKER")

    PR_NUMBER=$(gh pr view "$BRANCH" --repo "$OWNER_REPO_NAME" --json number --jq '.number')

    # Serialize updates per PR using flock.
    if command -v flock > /dev/null && command -v mkdir > /dev/null; then
      runtime_dir="''${PRJ_RUNTIME_DIR:-''${XDG_RUNTIME_DIR:-''${PRJ_CACHE_HOME:-/tmp}/std-runtime}}"
      mkdir -p "$runtime_dir"
      LOCK_FILE="$runtime_dir/gh-comment-''${OWNER_REPO_NAME//\//_}-$PR_NUMBER.lock"
      exec 9>"$LOCK_FILE"
      flock -w 120 9 || exit 0
      trap 'flock -u 9' EXIT
    fi

    EXISTING_COMMENT_ID=$(gh api "repos/$OWNER_REPO_NAME/issues/$PR_NUMBER/comments?per_page=100" --jq "[.[] | select(.body | contains(\"$CENTRAL_COMMENT_HEADER\")) | .id][0] // empty")

    if [[ -n "$EXISTING_COMMENT_ID" ]]; then
      EXISTING_BODY=$(gh api "repos/$OWNER_REPO_NAME/issues/comments/$EXISTING_COMMENT_ID" --jq '.body')

      UPDATED_BODY="$EXISTING_BODY"
      while [[ "$UPDATED_BODY" == *"$ENTRY_START_MARKER"* ]]; do
        BEFORE_ENTRY="''${UPDATED_BODY%%"$ENTRY_START_MARKER"*}"
        AFTER_START="''${UPDATED_BODY#*"$ENTRY_START_MARKER"}"
        if [[ "$AFTER_START" == *"$ENTRY_END_MARKER"* ]]; then
          AFTER_ENTRY="''${AFTER_START#*"$ENTRY_END_MARKER"}"
        else
          AFTER_ENTRY=""
        fi
        UPDATED_BODY="$BEFORE_ENTRY$AFTER_ENTRY"
      done

    UPDATED_BODY="$UPDATED_BODY"$'\n\n'"$DIFF_ENTRY"

      echo "Updating existing comment..."
      gh api --method PATCH "repos/$OWNER_REPO_NAME/issues/comments/$EXISTING_COMMENT_ID" -f body="$UPDATED_BODY" --jq '.html_url'

    else
      NEW_COMMENT=$(printf '%s\n' \
        "$CENTRAL_COMMENT_HEADER" \
        "## DiffPost" \
        "" \
        "This PR includes the following diffs:" \
        "$DIFF_ENTRY")
      echo "Creating new comment..."
      gh pr comment "$PR_NUMBER" --repo "$OWNER_REPO_NAME" --body "$NEW_COMMENT"
    fi

    exit 0

  fi
''
