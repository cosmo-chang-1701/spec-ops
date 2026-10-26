# Bare-repo worktree layout

The **bare-repo worktree layout** keeps the git database in `<repo>/.bare/` and gives every
branch its own sibling working directory, so several branches can be open at once without
switching. `<repo>/.git` is a one-line file (`gitdir: ./.bare`) so git still works from the
container root. spec-ops-pipeline task and stage worktrees live in the same container (`sop/<slug>`,
`sop-stage/<id>`).

```text
<repo>/
├── .bare/            git database (former .git, core.bare = true)
├── .git              file: gitdir: ./.bare
├── main/             worktree on the default branch (dir name = branch name)
├── feat/login/       a branch opened later with wt.sh add
├── sop/<slug>/       Worker worktrees
└── .claude, AGENTS.md, …   symlinks to main/'s agent config (below)
```

**Agent config at the root.** Agent CLIs load project skills and instructions from the
directory they start in. So that `claude`, `agy`, `codex`, … started at `<repo>/` still find
them, every top-level `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.claude/`, `.agents/`,
`.codex/` and `.gemini/` of the default-branch worktree has a relative symlink at the root
(`<repo>/.claude -> main/.claude`). The conversion creates them; `wt.sh link-config`
re-syncs them later. Git ignores them (the root is not a work tree). A session at the root
therefore loads the **default branch's** config, and whatever it writes there (e.g.
`.claude/settings.local.json`) lands in `main/`; a session started in another worktree
loads that worktree's own config.

## When to offer it
Preflight, after `worktree.sh config` and `worktree.sh status`: when the config shows
`"offer_bare_migration": true` (standard layout, not disabled), run the dry run from
anywhere inside the repo:

```bash
bash SKILL_DIR/scripts/migrate_to_bare.sh        # plan JSON, changes nothing
```

Then ask the user, in their language. Never name other projects as examples; describe the
layout itself with **this** repo's paths from the plan JSON.

### The question must contain
1. The layout name — **bare-repo worktree layout** — and the one-line definition above.
2. A before/after tree using this repo's real path and default branch (`after.source_worktree`).
3. What changes: the code moves from `<repo>/` to `<repo>/<branch>/`; git commands at the
   `<repo>/` root no longer show a working tree — run them in `<repo>/<branch>/`. If
   `after.root_links` is not empty: agent config stays reachable from `<repo>/` through
   those symlinks.
4. What stays: commit history, all branches, stash, hooks, remotes, and uncommitted changes
   (staged state included). Every step is verified; any failure rolls back automatically.
5. Every entry of `warnings` from this dry run, rephrased plainly.
6. The choices: convert, or keep the current layout and continue. Mention that
   `"offerBareLayout": false` in `.agents/spec-ops-pipeline.json` stops the question for good.

### Example (repo `~/Projects/my-app`, default branch `main`)

> This project uses the standard git layout (`.git` directory inside the project). Convert
> it to the **bare-repo worktree layout**?
>
> **Bare-repo worktree layout**: the git database lives in `.bare/`, and every branch gets
> its own sibling working directory, so several branches can be open at once without
> switching. The Workers of this skill will create their directories next to them.
>
> ```text
> before                         after
> ~/Projects/my-app/             ~/Projects/my-app/
> ├── .git/                      ├── .bare/          ← the former .git
> ├── .claude/                   ├── .git            ← file: gitdir: ./.bare
> ├── src/                       ├── .claude         ← symlink to main/.claude
> ├── package.json               ├── main/           ← working directory of branch main
> └── .env                       │   ├── .claude/
>                                │   ├── src/
>                                │   ├── package.json
>                                │   └── .env
>                                ├── feat/login/     ← branches you open later
>                                └── sop/<task>/     ← Worker directories
> ```
>
> - **Changes**: the code moves from `~/Projects/my-app/` to `~/Projects/my-app/main/`.
>   Running `git status` in `~/Projects/my-app/` itself no longer works; use `main/`.
>   Agents started in `~/Projects/my-app/` still load `.claude/` (from `main/`).
> - **Stays**: commit history, all branches, stash, hooks, remotes, and uncommitted
>   changes (including what is staged).
> - **Heads-up** (found in this project):
>   - `.venv` contains absolute paths; recreate it afterwards (e.g. `uv sync`).
>   - `docker-compose.yml` has no `name:`; its Compose project name changes from `my-app`
>     to `main`.
>   - Close editors, terminals and dev servers that have this project open.
> - Any failed step rolls everything back automatically.
>
> 1. Convert
> 2. Keep the current layout and continue
>
> To never be asked again, set `"offerBareLayout": false` in `.agents/spec-ops-pipeline.json`.

### When the plan is blocked
`eligible: false` (exit 1): do not ask. Tell the user in one short message that this repo
**cannot** be converted to the bare-repo worktree layout right now, list each `blockers`
entry with its fix (e.g. "checked out on `feat/x` — run `git switch main` first"), and
continue with the standard layout.

## After an explicit "convert"
1. `bash SKILL_DIR/scripts/migrate_to_bare.sh --apply` (exit 0 prints the result JSON).
2. Re-run `worktree.sh config`: `layout` is `bare`, `source_worktree` is `<repo>/<branch>`,
   and `default_base` is now `origin/<branch>`. Run every later Lead git/test command there.
3. Re-read the agent docs (`AGENTS.md`, `CLAUDE.md`, …) from `source_worktree`; they moved.
4. Tell the user what the warnings asked them to redo (venvs, Compose name, skill symlinks
   — give the `ln -sfn` commands; do not run them), that agent sessions started at `<repo>/`
   load the `<branch>` config through the `root_links` symlinks (sessions in another
   worktree load that worktree's), and that `bash SKILL_DIR/scripts/wt.sh` manages their own
   worktrees (`add`, `remove`, `status`, `link-config`).
5. Continue the preflight (baseline, `default_base` check). Unpushed commits on the default
   branch now show up as `HEAD` ≠ `default_base` there — agree on the base with the user.

## What the conversion does
All renames stay inside `<repo>`; nothing is copied or written outside it.
1. Moves every top-level entry except `.git` into `<repo>/.sop-migrate-tmp/`.
2. Renames `.git` to `.bare`, sets `core.bare = true`, writes the `.git` gitfile.
3. Registers `<repo>/<branch>` with `git worktree add --no-checkout`, then moves the temp
   dir there and hands the old checkout's `index`, `ORIG_HEAD`, `config.worktree` and HEAD
   reflog to the new worktree.
4. Reconnects linked worktrees (`git worktree repair`), including ones that were nested in
   the checkout and moved with it.
5. Verifies: status + staged diff + worktree diff hash unchanged, HEAD on the same branch,
   `.git` resolves to `.bare`, every linked worktree connected.
6. Creates the agent-config symlinks at the root (`after.root_links`) and checks each
   resolves. Any failure (or Ctrl-C) in any step rolls back in reverse order and re-checks
   the original state.

### Blockers (nothing is changed)
| Blocker | Fix |
| :--- | :--- |
| Already a bare layout | none needed |
| `.git` is not a directory in the checkout, or `core.worktree` set | convert by hand |
| Detached HEAD, or not on the default branch (`origin/HEAD`) | `git switch <default>` |
| No commits yet | commit first |
| Merge / rebase / cherry-pick / revert / bisect in progress | finish or abort it |
| `index.lock` present | wait for the other git process, or remove a stale lock |
| Submodules (`.gitmodules` or `.git/modules`) | not supported |
| Sparse checkout | not supported |
| Leftover `sop/*` / `sop-stage/*` worktrees | finish the earlier run or `worktree.sh remove` them |
| `<repo>` not writable, a top-level dir you cannot write, a mount point, or `.sop-migrate-tmp` exists | fix permissions / unmount / remove the leftover |

### Warnings (listed in the plan, never block)
Open editors and processes · agent config files that move (`CLAUDE.md`, `AGENTS.md`,
`.claude/`, …) and get root symlinks · symlinks in the personal skills directories (`~/.claude/skills`,
`~/.agents/skills`, `~/.codex/skills`, `~/.gemini/skills`, `~/.gemini/config/skills`) that
point into the repo, with the `ln -sfn` command that re-points each · the repo itself being a
skill directory in one of them (`SKILL.md` moves to `<branch>/`) · virtualenvs with absolute paths · top-level Compose files without `name:` ·
git config values containing the old absolute path (not rewritten) · `core.fsmonitor`
(its daemon is stopped) · missing `origin/HEAD` (current branch is used as default) ·
stale worktree entries.

## Exit codes and recovery
`0` converted · `1` blocked · `2` failed and rolled back (repo is as before) ·
`3` rollback incomplete: the script prints the partial state and the exact manual steps;
relay them to the user verbatim and do not improvise further moves.

### Undoing a successful conversion by hand
Remove every other worktree first (`wt.sh remove`, `worktree.sh remove`), then from `<repo>`:
```bash
for f in CLAUDE.md AGENTS.md GEMINI.md .claude .agents .codex .gemini; do
  [[ -L $f ]] && rm "$f"                         # agent-config symlinks at the root
done
admin=$(sed -n 's/^gitdir: //p' main/.git)       # .bare/worktrees/main
rm main/.git && mv "$admin/index" .bare/index && rm -rf "$admin"
git --git-dir=.bare config core.bare false && rm .git && mv .bare main/.git
mv main .sop-undo && (shopt -s dotglob && mv .sop-undo/* .) && rmdir .sop-undo
git status
```

## wt.sh (for people)
`bash SKILL_DIR/scripts/wt.sh add|remove|list|status` manages everyday branch worktrees in
this layout: `add <branch> [<base>]` creates `<repo>/<branch>` (existing branch as is,
origin-only branch tracked, else a new branch from `origin/<default>`) and provisions it
like spec-ops-pipeline worktrees; `remove` refuses dirty worktrees without `--force` and keeps the branch;
`status [-v|-s|--check]` shows every worktree's changes and upstream state; `link-config`
re-syncs the agent-config symlinks at the root with the default-branch worktree (adds
missing, re-points dangling, drops those whose target is gone; leaves real files and links
pointing elsewhere alone). It refuses
`sop/*` and `sop-stage/*` branches — those belong to `worktree.sh`. The Lead does not use it.
