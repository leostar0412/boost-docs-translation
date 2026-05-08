# boost-docs-translation

Super-repository for Boost library documentation translations: it holds `libs/*`
submodules that point at per-library mirrors, keeps **`master`** and
**`local-{lang_code}`** branches aligned with upstream **`boostorg`** sources, and
notifies a Weblate instance when components change. A daily workflow advances
submodule pointers on every **`local-*`** branch to match each library repo’s
corresponding **`local-*`** tip.

The GitHub org used for those library mirrors defaults to **this repository’s
org**; set repository variable **`SUBMODULES_ORG`** to use a
different org.

For system context, branch model, and data flows, see **[ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## Integration contracts

HTTP surfaces are described in **[`docs/endpoint-contract.md`](docs/endpoint-contract.md)**.

---

## Workflows

### `add-submodules.yml` — Create library mirrors and register submodules

**Trigger:** `repository_dispatch` with `event_type: add-submodules`

```json
{
  "event_type": "add-submodules",
  "client_payload": { "version": "boost-1.90.0" }
}
```

For each Boost library name in the resolved list:

1. Skips if **`{MODULE_ORG}/{submodule}`** already exists (`MODULE_ORG` is
   **`SUBMODULES_ORG`** if set, otherwise the translations repo’s org).
2. Fetches **`meta/libraries.json`** from **`boostorg/{submodule}`** to determine doc
   paths, clones that repo at the given ref, and prunes to doc folders only.
3. Creates **`{MODULE_ORG}/{submodule}`**, pushes doc content to **`master`**, creates
   **`local-{lang_code}`** branches for each configured language, and copies
   **`create-tag.yml`** from **`.github/workflows/assets/`** into the new repo.
4. Updates submodule links in this repo under **`libs/`** on **`master`** and each
   **`local-{lang_code}`** branch.

| `client_payload` field | Required | Description                                                                                                                                                            |
| ---------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `version`              | no       | Boost ref (e.g. `boost-1.90.0`). Defaults to `develop`.                                                                                                                |
| `submodules`           | no       | List-like string (e.g. `[algorithm, system]`). If omitted, submodule names are taken from **`.gitmodules` on `boostorg/boost`** at **`version`** (only `libs/` paths). |
| `lang_codes`           | no       | Comma-separated language codes (e.g. `zh_Hans,ja`). Defaults to **`vars.LANG_CODES`**; the workflow fails if neither this field nor **`LANG_CODES`** is set.           |

---

### `start-translation.yml` — Sync existing mirrors and notify Weblate

**Trigger:** `repository_dispatch` with `event_type: start-translation`

```json
{
  "event_type": "start-translation",
  "client_payload": { "version": "boost-1.90.0" }
}
```

Reads the submodule list from **this repo’s `.gitmodules`** on **`master`** (only
**`libs/`** entries). For each language and each submodule:

1. Ensures this repo has a **`local-{lang_code}`** branch.
2. Syncs **`{MODULE_ORG}/{lib}` `master`** from the upstream **`boostorg`** repo
   (same prune rules as **`add-submodules`**).
3. In the library repo: creates **`local-{lang_code}`** if missing, or merges
   **`master`** into it when there is **no** open PR into **`local-{lang_code}`**
   whose head branch starts with **`translation-{lang_code}-`**; otherwise skips
   that lib for that language so in-flight Weblate work is not overwritten.
4. Updates submodule pointers here on **`master`** and each **`local-{lang_code}`**
   branch ( **`local-*`** updates are force-pushed when finalizing).
5. **POST**s JSON to **`{WEBLATE_URL}/boost-endpoint/add-or-update/`** with
   **`organization`**, **`version`**, optional **`extensions`**, and
   **`add_or_update`**: `{lang_code: [submodule names, ...]}` for libs that were
   actually updated for that language. Omits the call if the map would be empty.
   A typical server response is **HTTP 202** (async); **200** is also accepted.

| `client_payload` field | Required | Description                                                                                                                                                  |
| ---------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `version`              | no       | Boost ref (e.g. `boost-1.90.0`). Defaults to `develop`.                                                                                                      |
| `lang_codes`           | no       | Comma-separated language codes (e.g. `zh_Hans,ja`). Defaults to **`vars.LANG_CODES`**; the workflow fails if neither this field nor **`LANG_CODES`** is set. |
| `extensions`           | no       | File extensions for Weblate (e.g. `[.adoc, .md]`). Default: empty (no filter in the payload).                                                                |

---

### `sync-translation.yml` — Advance submodule pointers on `local-*` branches

**Trigger:** `repository_dispatch` with `event_type: sync-translation`, or daily schedule (`0 0 * * *`)

```json
{ "event_type": "sync-translation" }
```

Discovers all remote **`local-*`** branches in this repo, then for each one: checks
it out with submodules, sets each submodule’s tracking branch to that name,
runs **`git submodule update --remote`**, commits if pointers changed, and
**force-pushes** the branch.

No `client_payload` fields.

---

## Assets

Shared workflow snippets live under **`.github/workflows/assets/`**.

### `create-tag.yml`

Copied into each library mirror repo when **`local-{lang_code}`** is created.
When a Weblate PR (**`translation-{lang_code}-{version}`** → **`local-{lang_code}`**)
is merged, it creates tag **`{version}-{repo}-{lang_code}`** if it does not already
exist.

See [`.github/workflows/assets/README.md`](.github/workflows/assets/README.md) for
branch and tag naming details.

### `env.sh` and `lib.sh`

Sourced by **`add-submodules`** and **`start-translation`**: org/repo names, clone
and prune helpers, translations-repo branch setup, submodule pointer updates, and
list parsing.

---

## Scripts (local `repository_dispatch`)

From a clone of this repo:

- **`scripts/trigger-add-submodules.sh`** — fires **`add-submodules`**.
- **`scripts/trigger-start-translation.sh`** — fires **`start-translation`** (optional
  **`--version`**, **`--lang-codes`**, **`--extensions`**).

Copy **`.env.example`** to **`.env`** and set **`GH_TOKEN`** (or **`GITHUB_TOKEN`**)
with permission to call **`POST /repos/{owner}/{repo}/dispatches`** on the target
repo. The workflows still use GitHub **secrets** and **variables** on the server as
documented below.

---

## Required secrets

| Secret          | Used by             | Description                                                                                                                 |
| --------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `SYNC_TOKEN`    | all workflows       | PAT with **`repo`** scope; **`add-submodules`** also needs permission to create org repositories when creating new mirrors. |
| `WEBLATE_URL`   | `start-translation` | Base URL of the Weblate instance (the workflow appends **`boost-endpoint/add-or-update/`**).                                |
| `WEBLATE_TOKEN` | `start-translation` | API token for that endpoint.                                                                                                |

## Repository variables

| Variable         | Used by                               | Description                                                                                                                                                                                                                       |
| ---------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LANG_CODES`     | `add-submodules`, `start-translation` | Default language codes when **`client_payload.lang_codes`** is omitted (comma- or bracket-list, e.g. `zh_Hans,ja`). Must be set here or passed in the dispatch payload.                                                           |
| `SUBMODULES_ORG` | `add-submodules`, `start-translation` | Optional. GitHub org for **`boostorg`** mirror repos (e.g. `CppDigest`). If unset, the org is the same as this repository’s owner. **`sync-translation`** relies on **`.gitmodules`** URLs already pointing at the correct hosts. |

## License

This repository is distributed under the
[Boost Software License, Version 1.0](https://www.boost.org/LICENSE_1_0.txt)
(SPDX: `BSL-1.0`).

---
