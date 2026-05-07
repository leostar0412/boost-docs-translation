# Shared shell library for add-submodules and start-translation workflows.
# Source this file after setting: ORG, MODULE_ORG, BOT_NAME, BOT_EMAIL, BOOST_ORG, MASTER_BRANCH,
# TRANSLATIONS_REPO, TRANS_DIR, GITHUB_WORKSPACE, UPDATES (array).

# ── Helpers ──────────────────────────────────────────────────────────

set_git_bot_config() {
  git -C "$1" config user.email "$BOT_EMAIL"
  git -C "$1" config user.name "$BOT_NAME"
}

# ── GitHub API helpers (via gh CLI) ──────────────────────────────────

repo_exists() { gh repo view "$1/$2" &>/dev/null; }

# ── Git clone helpers ────────────────────────────────────────────────

# Clone repo at branch/tag into $3. Pass "keep" as $4 to preserve .git.
clone_repo() {
  mkdir -p "$3"
  git clone --branch "$2" "$1" "$3"
  [[ "${4:-}" == "keep" ]] || rm -rf "$3/.git"
}

# ── Doc-path helpers ─────────────────────────────────────────────────

# Fetch meta/libraries.json via gh API; emit one doc-path per line.
get_doc_paths() {
  local repo="$1" ref="$2" json
  json=$(gh api "repos/${BOOST_ORG}/${repo}/contents/meta/libraries.json?ref=${ref}" \
    -H "Accept: application/vnd.github.v3.raw" 2>/dev/null) || return 1
  echo "$json" | jq -r --arg repo "$repo" '
    (if type == "array" then . else [.] end)
    | .[]
    | select(type == "object")
    | select((.name // "") != "" and (.key // "") != "")
    | .key as $key
    | if $key == $repo then "doc"
      elif ($key | startswith($repo + "/")) then ($key[($repo | length + 1):] + "/doc")
      else ($key + "/doc")
      end
  '
}

# Prune a cloned repo to only root files + the given doc-path subtrees.
# E.g. ("doc") → keep all root files + entire doc/.
#      ("minmax/doc" "string/doc") → keep root files + those two subtrees.
prune_to_doc_only() {
  local dir="$1"; shift
  local keep_paths=("$@")
  [[ ${#keep_paths[@]} -eq 0 ]] && return

  local first_segs=()
  for p in "${keep_paths[@]}"; do first_segs+=("${p%%/*}"); done

  # Delete root-level dirs not needed by any keep path.
  # Use find instead of glob so dotdirs (e.g. .drone, .github) are included.
  while IFS= read -r item; do
    local name="${item##*/}"
    local needed=0
    for seg in "${first_segs[@]}"; do
      [[ "$name" == "$seg" ]] && { needed=1; break; }
    done
    [[ $needed -eq 0 ]] && rm -rf "$item"
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)

  # For paths deeper than one level (e.g. "minmax/doc"), prune the
  # intermediate directory so only the target subdir survives.
  for p in "${keep_paths[@]}"; do
    local first="${p%%/*}"
    [[ "$first" == "$p" ]] && continue  # depth 1 ("doc"): keep entire dir
    local rest_first="${p#${first}/}"; rest_first="${rest_first%%/*}"
    for f in "$dir/$first"/*; do [[ -f "$f" ]] && rm -f "$f"; done
    while IFS= read -r item; do
      local name="${item##*/}"
      [[ "$name" == "$rest_first" ]] || rm -rf "$item"
    done < <(find "$dir/$first" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  done
}

# ── Organization repo helpers ────────────────────────────────────────

# Copy create-tag.yml asset into repo.
add_create_tag_workflow() {
  local repo_dir="$1" wf_dir="$1/.github/workflows"
  mkdir -p "$wf_dir"
  cp "$GITHUB_WORKSPACE/.github/workflows/assets/create-tag.yml" \
    "$wf_dir/create-tag.yml"
  git -C "$repo_dir" add ".github/workflows/create-tag.yml"
  git -C "$repo_dir" commit -m "Add create-tag workflow"
}

# ── Translations repo helpers ─────────────────────────────────────────

ensure_local_branch_in_translations() {
  local dir="$1" lang_code="$2"
  local branch="local-${lang_code}"
  if git -C "$dir" ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
    echo "  Branch $branch already exists in $TRANSLATIONS_REPO." >&2
  else
    echo "  Creating branch $branch in $TRANSLATIONS_REPO from $MASTER_BRANCH..." >&2
    git -C "$dir" checkout -B "$MASTER_BRANCH" "origin/$MASTER_BRANCH"
    git -C "$dir" checkout -b "$branch"
    rm -rf "$dir/libs" "$dir/.gitmodules"
    git -C "$dir" rm -rf --cached libs .gitmodules 2>/dev/null || true
    if ! git -C "$dir" diff --cached --quiet; then
      git -C "$dir" commit -m "Init $branch"
    fi
    git -C "$dir" push -u origin "$branch"
    echo "  Created branch $branch." >&2
  fi
}

ensure_translations_cloned() {
  [[ -d "$3/.git" ]] && return
  clone_repo "https://github.com/${1}/${2}.git" "$MASTER_BRANCH" "$3" keep
  set_git_bot_config "$3"
}

submodule_in_gitmodules() {
  git -C "$1" config --file .gitmodules --get "submodule.${2}.url" &>/dev/null
}

update_translations_submodule() {
  local dir="$1" org="$2" sub_name="$3" branch="$4"
  local libs_path="$dir/libs/$sub_name"
  local sub_path="libs/$sub_name"
  local sub_url="https://github.com/${org}/${sub_name}.git"

  if submodule_in_gitmodules "$dir" "$sub_path" && [[ -d "$libs_path" ]]; then
    if ! git -C "$dir" submodule update --init "$sub_path"; then
      echo "  submodule update --init failed for $sub_path" >&2
      return 1
    fi
    git -C "$dir" config "submodule.${sub_path}.branch" "$branch"
    if ! git -C "$dir" submodule update --remote "$sub_path"; then
      echo "  submodule update --remote failed for $sub_path" >&2; return 1
    fi
    git -C "$dir" add "$sub_path"
  else
    # Submodule not registered on this branch yet; add it fresh.
    rm -rf "$libs_path" "$dir/.git/modules/$sub_path"
    git -C "$dir" submodule add -b "$branch" "$sub_url" "$sub_path"
    git -C "$dir" add .gitmodules "$sub_path"
  fi
}

commit_and_push_translations_branch() {
  local dir="$1" branch="$2" libs_ref="$3" force="${4:-false}"
  git -C "$dir" status --short
  if git -C "$dir" diff --cached --quiet; then
    echo "  No staged submodule changes on $branch; skipping commit." >&2
  else
    git -C "$dir" commit -m "Update libs submodules to $libs_ref"
  fi
  if [[ "$force" == "true" ]]; then
    git -C "$dir" push --force origin "$branch"
  else
    git -C "$dir" push origin "$branch"
  fi
}

# Update one branch of the translations super-repo (checkout → update pointers → push).
sync_translations_branch() {
  local dir="$1" branch="$2" libs_ref="$3" force="${4:-false}"
  git -C "$dir" checkout -B "$branch" "origin/$branch"
  for sub in "${UPDATES[@]}"; do
    update_translations_submodule "$dir" "$MODULE_ORG" "$sub" "$branch"
  done
  commit_and_push_translations_branch "$dir" "$branch" "$libs_ref" "$force"
}

finalize_translations_repo() {
  local dir="$1" libs_ref="$2"
  [[ ${#UPDATES[@]} -eq 0 ]] && return
  git -C "$dir" fetch origin
  sync_translations_branch "$dir" "$MASTER_BRANCH" "$libs_ref"
  for lang_code in "${lang_codes_arr[@]}"; do
    sync_translations_branch "$dir" "local-${lang_code}" "$libs_ref" true
  done
}

# ── Parsing helpers ───────────────────────────────────────────────────

# Parse "[zh_Hans, en]" or "zh_Hans,en" into one code per line.
parse_list() {
  local s="$1"
  s="${s//[[:space:]]/}"
  s="${s#[}"; s="${s%]}"
  [[ -z "$s" ]] && return
  IFS=',' read -ra parts <<< "$s"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] && echo "$part"
  done
}
