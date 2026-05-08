# Workflow Assets

This folder contains workflow template files that are copied into individual **CppDigest**
(or other **`MODULE_ORG`**) Boost library documentation mirror repositories.

## create-tag.yml

**Purpose:** Creates a versioned tag in a library mirror repo whenever a Weblate translation
PR is merged into a `local-{lang_code}` branch.

**Trigger:** `pull_request` closed event on branches matching `local-*`.

**Condition:** PR must be merged (`github.event.pull_request.merged == true`) and the head
branch must start with `translation-` (Weblate-created branches).

**Bot identity:** The “Create and push tag” step sets
`user.email` to `Boost-Translation-CI-Bot@cppalliance.local`, matching the
orchestration bot pattern in [`env.sh`](env.sh) for the mirror’s GitHub org.

**How it works:**

1. Extracts `lang_code` from the base branch: `local-zh_Hans` → `zh_Hans`.
2. Extracts `version` from the head branch:
   `translation-zh_Hans-boost-1.90.0` → strips `translation-zh_Hans-` → `boost-1.90.0`.
3. Builds the tag name: `{version}-{repo}-{lang_code}`
   (e.g. `boost-1.90.0-algorithm-zh_Hans`).
4. Checks out the `local-{lang_code}` branch with full tag history.
5. Creates and pushes the tag. Skips silently if the tag already exists.

**Tag format:**

```
{version}-{repo}-{lang_code}
```

| Component   | Source                                           | Example        |
| ----------- | ------------------------------------------------ | -------------- |
| `version`   | Head branch (`translation-zh_Hans-boost-1.90.0`) | `boost-1.90.0` |
| `repo`      | `github.event.repository.name`                   | `algorithm`    |
| `lang_code` | Base branch (`local-zh_Hans`)                    | `zh_Hans`      |

**How it gets installed:**

`add-submodules.yml` and `start-translation.yml` copy this file into each mirror at
`.github/workflows/create-tag.yml` when creating a new mirror or the first `local-{lang_code}`
branch. After changing this template, open a PR in
each mirror repo that replaces `.github/workflows/create-tag.yml` with the current file from
this repository (default branch), merge it, and ensure it is present on **`master`** so PR
events can run the workflow.

No placeholder substitution is needed; the repo name is resolved at runtime from
`github.event.repository.name`.

The workflow must exist on the repo's default branch (`master`) to be triggered by PR events.
