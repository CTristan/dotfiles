---
name: roadmap
description: >-
  Manage a project rolling roadmap: prioritize next work, add items, archive
  completed work, and view overview. GitHub Issues are the source of truth for
  every item (bugs, enhancements, tech debt); the roadmap is the
  local prioritization view over those issues. Use when user says "roadmap",
  "what should I work on next", "add to roadmap", "archive roadmap item",
  "roadmap overview", "prioritize work", "roadmap next", "start working",
  "continue working", "what am I working on", "finish task", "next task", or
  references .claude/roadmap.md management. May also be invoked proactively
  when Claude identifies a substantial deferrable improvement during an
  unrelated task.
tools: Read, Edit, Write, Bash, Glob, Grep
---

# Roadmap Manager

Manage a rolling project roadmap at `.claude/roadmap.md` with monthly archives in `.claude/roadmap/`.

**GitHub Issues are the source of truth** for every roadmap item — bugs, features, enhancements, new mod ideas, and tech debt all live as GH issues, distinguished by label. The roadmap is the local prioritization view over those issues. Nothing is ephemeral: if it's worth tracking, it's worth an issue.

---

## Item Categories

**Every roadmap item is a GitHub Issue**, linked via `([#NN](url))`. There is no local-only concept — nothing is ephemeral.

Every issue must carry **exactly one core classification label** from this table. The core label determines item category, branch prefix, archive tagging, and tier:

| Label | Meaning | Branch prefix |
|-------|---------|---------------|
| `bug` | User-facing defect | `fix/` |
| `enhancement` | User-facing feature or improvement | `feature/` |
| `tech-debt` | Internal chore: refactor, CI, tooling, test coverage, version mismatches | `chore/` |

**Additional labels are allowed — and encouraged — alongside the core label.** Repos commonly carry project-specific labels (e.g., `new_mod` in a mods project, `ui`, `performance`, `api`, area/component labels). These should be applied in combination with the required core label whenever the issue content matches. Example: a new-mod-idea issue in a mods project would typically carry both `enhancement` (the required core label) and `new_mod` (the project-specific label).

One label has special behavior — the **`umbrella` companion label**:

| Label | Meaning | Core label | Branch prefix |
|-------|---------|------------|---------------|
| `umbrella` | Tracking issue for a scoped batch of children | Required — inherits from its children (same-tier rule) | Inherits from its core label |

An `umbrella` issue is a GH issue whose body contains a task list of child `#NN` references (see **Mode: Add Item** step 6b). It still carries exactly one core label — chosen to match its children's shared core label — and the `umbrella` label is applied alongside, not instead of. Cross-tier children are refused; if an umbrella's scope would span `bug` + `enhancement`, split into two umbrellas. Child issues live in their normal roadmap sections with the inline marker `⛂ part of #<umbrella>` after the GH link; they are not nested under the umbrella in the roadmap. See the **Batch-scope recommendations** note at the bottom of this file for the detection rule shared by Prioritize step 7e, Overview/Sync reconciliation, and Implement step 10c.

Items whose linked issue has none of the three core labels are flagged during overview as **Unlabeled** — user is prompted to assign one. Labels, not markdown markers, are the single source of truth for classification.

Litmus test for `tech-debt` vs user-facing: would a user reading the public issue list care? If yes, it's `bug` or `enhancement`. If it's purely internal (version drift, lint config, test scaffolding), it's `tech-debt`.

Example:
```markdown
- **Reset bad luck protection** — Community suggestion. ([#82](https://github.com/.../issues/82))
- **Version mismatch: csproj vs Info.xml** — csproj says 3.0.1 but Info.xml says v3.0.0. ([#104](https://github.com/.../issues/104))
```

---

## GitHub CLI Integration

Use `gh` for all GitHub interactions. Availability is checked once per session by Gate A (below). If `gh` is unavailable or not authenticated, Gate A refuses to run any mode — there is no local-only fallback, because every roadmap item must be a GH issue.

### Commands used

| Purpose | Command |
|---------|---------|
| Check availability | `gh repo view --json nameWithOwner` |
| Sync (overview) | `gh issue list --state all --json number,title,state,labels,body,updatedAt --limit 100` |
| Create issue (add) | `gh issue create --title "..." --body "..." --label "..."` |
| Edit umbrella body (add child link) | `gh issue edit NN --body "..."` |
| Comment on issue (batch-relationship note) | `gh issue comment NN --body "..."` |
| Close issue (archive) | `gh issue close NN --comment "..."` |
| Check single issue (archive / resume) | `gh issue view NN --json title,state,labels,body` |
| List labels (preflight) | `gh label list --json name --limit 100` |
| Create label (preflight) | `gh label create <name> --color <hex> --description "..."` |

---

## Label Preflight

Every repo must have the four standard labels: three core classification labels plus the `umbrella` companion label. Run the preflight at the start of **bootstrap**, **add**, and **overview** modes.

1. Run `gh label list --json name --limit 100` and collect existing label names (case-insensitive compare).
2. Ensure these four labels exist:

   | Label | Color | Description |
   |-------|-------|-------------|
   | `bug` | `d73a4a` | `Something isn't working` |
   | `enhancement` | `a2eeef` | `New feature or request` |
   | `tech-debt` | `fbca04` | `Internal refactor, tooling, or maintenance` |
   | `umbrella` | `0e8a16` | `Tracking issue for a scoped batch of children` |

3. If any are missing: prompt the user once with the full list of missing labels (single confirmation is fine — this is label scaffolding, not issue creation). On approval, run `gh label create` for each missing label with the color and description from the table above.
4. If the user declines: continue with the requested mode, but note that `add` and `overview` will re-prompt until the labels exist.
5. Accept any common variant (`Bug`, `type:bug`, `kind/bug`) as satisfying the `bug` requirement; don't recreate when a variant is already there. Same for `enhancement` and `tech-debt` (`tech debt`, `techdebt`, `chore` are all valid variants). `umbrella` has no common variants — if a repo uses a different term (`epic`, `tracking`), treat that as the variant and don't recreate.

---

## Argument Parsing

Parse `$ARGUMENTS` to determine mode:

| Input | Mode |
|-------|------|
| `start` | Implement (skip sync) |
| `next` | Prioritize |
| `add <description>` | Add item |
| `add umbrella <description>` | Add item explicitly as umbrella (see Mode: Add Item step 6b) |
| `archive [description]` | Archive completed |
| `pause [note]` | Pause current focus |
| `resume <item>` | Resume a paused item |
| *(empty or `overview`)* | Overview (then auto-transition to Implement if clean) |

---

## Bootstrap

If `.claude/roadmap.md` does not exist:

1. Run Gate A (below) — confirm `gh` + GitHub remote. If it fails, do not create any files; report the Gate A refusal message and exit.
2. Run the Label Preflight (above) to ensure `bug`, `enhancement`, `tech-debt`, and `umbrella` labels exist before any issues are referenced.
3. Run `gh issue list --state open --json number,title,labels,body --limit 100`.
4. Create starter roadmap with `## Priorities` and `## Completed`. For each core label with at least one open issue, add a content section named for that label's domain (default names: `## Bugs`, `## Features`, `## Tech Debt`). Omit sections that would be empty — sections are populated on demand. If the repo's existing issues cluster naturally around project-specific labels (discovered via `gh label list`), those labels may inspire sub-sections or alternative section names, but every section ultimately groups issues that share a core label.
5. Populate items from open issues with `([#NN](url))` links.
6. Issues whose label set does not include any of `bug` / `enhancement` / `tech-debt` (or accepted variants) go into an "Uncategorized" section for manual triage.
7. Create `.claude/roadmap/` directory.
8. Include a `## Current Focus` section with `None.` as placeholder.
9. Proceed with the requested mode.

---

## Pre-flight Gates

Every mode runs these two gates before its own logic. Gate A applies always; Gate B applies after any `.claude/roadmap.md` exists.

### Gate A — `gh` availability

At the start of every mode (before any file reads or issue creation):

1. Run `gh repo view --json nameWithOwner`.
2. If the command succeeds, proceed.
3. If it fails (gh not installed, not authenticated, not a GitHub remote, or network error), print this exact message and exit:

   > This skill requires `gh` and a GitHub remote. All roadmap items must be tracked as GH issues so nothing becomes ephemeral. Install gh + authenticate (`gh auth login`), or set up the repo's GitHub remote, then retry.

There is no local-only fallback. If `gh` is unavailable, the skill does nothing.

### Gate B — Legacy `[local]` migration

After Gate A passes and `.claude/roadmap.md` exists:

1. `grep -n '\[local\]' .claude/roadmap.md` to find legacy items. If none, skip Gate B.
2. If any hits:

   > Found N `[local]` items. All roadmap items must now be GH issues — `[local]` is no longer supported. Migrate each before proceeding.

3. For each `[local]` item, one at a time (per-issue approval is mandatory — never batch):
   - Propose a label based on the item text: default `tech-debt`; infer `bug` or `enhancement` if the title strongly suggests a user-facing defect or feature.
   - Draft a GH issue (title, body, label) using the drafting steps in **Mode: Add Item** (step 8). Title prefix follows classification: `[Bug]`, `[Enhancement]`, or `[Tech Debt]`.
   - Present the draft to the user and wait for explicit approval of *this specific* issue.
   - On approval: run `gh issue create`, parse the returned `#NN` and URL, and rewrite the roadmap line — replace the trailing ` [local]` with ` ([#NN](url))`.
   - On decline: leave the `[local]` entry as-is.
4. After the loop, if any `[local]` entries remain, refuse to proceed with the originally-requested mode:

   > Migration incomplete: M `[local]` item(s) remain. Either migrate them (re-run this mode), or remove them from `.claude/roadmap.md` manually. Other modes are blocked until the roadmap is clean.

5. Otherwise, fall through to the requested mode.

---

## Mode: Overview (default)

1. Gate A + Gate B + Label Preflight have already run (pre-flight section above). Any `[local]` entries have been migrated before this mode executes.
2. Read `.claude/roadmap.md` in full
3. Parse all H2/H3 headings dynamically to discover sections
4. **Fetch fresh state:**
   - `gh issue list --state all --json number,title,state,labels,body,updatedAt --limit 100`
   - `gh pr list --state merged --json number,title,headRefName,body --limit 50`
   - Cache the issue list in session state so the Prioritize mode can reuse it without a second network call. `body` is included so Prioritize step 5b's dependency regex and this mode's umbrella-child parsing can run without extra round-trips; `updatedAt` feeds the stale-umbrella check in step 5 below.
5. **Cross-reference roadmap items with GitHub Issues and merged PRs** and build six lists:
   - **Closed on GH**: roadmap items referencing issues that are now closed — flag for archiving (do NOT auto-edit)
   - **Missing from roadmap**: open GH issues with no corresponding roadmap entry — present as "untriaged"
   - **Unlabeled**: roadmap items whose linked GH issue has none of the three core labels `bug`, `enhancement`, or `tech-debt` (accepting common variants per Label Preflight) — flag for label assignment. Additional non-core labels on the issue don't satisfy this — exactly one core label must be present. Without a core label, the item cannot be tiered, scored correctly, or routed to the right branch prefix.
   - **Completed via merged PR**: roadmap items whose title/keywords match a merged PR's title or body (look for `Closes #NN`, `Fixes #NN`, `Resolves #NN` in the PR body) but whose GH issue is still open. Flag for archiving with the PR link. Never auto-edit — surface only.
   - **Stale umbrellas**: open issues carrying the `umbrella` label whose `updatedAt` timestamp is more than 60 days old AND whose parsed children (from the body's task list) have seen no state change in the same window. These umbrellas have gone dormant — scope may have drifted, or the batch may no longer make sense. Never auto-edit — surface for review.
   - **Umbrella candidates**: groups of open issues that (a) are not already carrying the `⛂ part of #NN` marker in `.claude/roadmap.md` and are not themselves umbrellas, (b) share their core label, (c) share at least one non-core label, and (d) live in the same H3 subsection of `.claude/roadmap.md`. A group must contain 2–5 items to qualify; groups over 5 are either split (prefer the most recently updated members) or suppressed. Uses the exact same detection rule as Prioritize step 7e and Implement step 10c.
6. Count actionable items (bullet points) per section
7. Show any "Priorities" heading content as the active priority list
8. Glob `.claude/roadmap/*.md` to find the latest archive file and its date
9. Present an enhanced summary table:
   ```
   | Section | Items | Bugs | Enhancements | Tech Debt | Unlabeled |
   |---------|-------|------|--------------|-----------|-----------|
   ```
10. Flag stale items: Grep each item's keywords against `git log --oneline -40`. Items with no matching git activity across 2+ monthly archives are flagged stale.
11. **Show reconciliation warnings** at the end. Warnings are split into two groups:

    **Blocking warnings** (require action before the implementation auto-transition):
    - List any closed-on-GH items with a suggestion to archive
    - List any untriaged GH issues with a suggestion to add them
    - List any unlabeled items with a suggestion to apply one of the three core labels `bug` / `enhancement` / `tech-debt` (suggest via `gh issue edit NN --add-label <label>`). If the issue content also matches an existing repo-specific label, suggest adding that alongside the core label.
    - List any completed-via-merged-PR items with the PR link and a suggestion to archive

    **Non-blocking advisories** (surface, but don't block auto-transition — these are opportunities, not defects):
    - List any stale umbrellas with their children and last-update date, e.g. `🪂 #82 [Umbrella] UI consistency pass — no activity 74 days; review scope or split`
    - List any umbrella candidates, e.g. `🧺 Issues #82, #91, #104 share 'enhancement' + 'ui' and live in '## Features › UI consistency'. Wrap as umbrella?` Each entry suggests the concrete action `/roadmap add umbrella "<proposed title>"`. Never auto-create — acceptance runs through Mode: Add Item step 6b's per-issue-approval flow.

12. **Implementation transition gate:**
    - If there are NO **blocking** warnings (closed-on-GH / untriaged / unlabeled / merged-PR):
      - Print "No sync issues found. Transitioning to implementation..." (non-blocking advisories may still be shown — they don't prevent the transition)
      - Fall through to the Implement phase (Mode: Implement below)
    - If there ARE blocking warnings:
      - Print both blocking warnings and non-blocking advisories above
      - Print "Resolve sync issues above, or use `/roadmap start` to skip to implementation."
      - Stop. Do NOT auto-transition.

---

## Mode: Prioritize (`next`)

Works off the local snapshot plus label lookup. **One allowed network call:** a single `gh issue list` for labels if no cached state from a same-session Overview fetch is available. Labels are required because slot assignment (step 6c) depends on them.

1. Read `.claude/roadmap.md` in full
2. Run `git log --oneline -20` for recent momentum context
3. Parse H2/H3 headings dynamically. Classify each section:
   - **Actionable**: contains bullet-point items (features, tasks, debt)
   - **Informational/archive**: headings like "Completed", "Inactive", or sections with only prose/links — skip these
4. Extract all actionable items from actionable sections
5. **Exclude** items referencing closed GH issues from scoring (note they should be archived)

**Step 5b — Dependency graph + cycle detection:**

- For each item, scan the body for case-insensitive `depends on #(\d+)`, `dep: #(\d+)`, `blocked by #(\d+)`. Collect all edges `blocker → blocked` into a dependency graph over roadmap items.
- For each referenced `#NN`: check archive files under `.claude/roadmap/` for the number; if an Overview GH fetch was done earlier in this session and is still fresh, also check `state == "CLOSED"`. If no cached state is available, reuse the label-lookup call from step 6a (no extra network call). Items with at least one open dep are marked `blocked`; all others are `unblocked`.
- **Cycle detection:** DFS with a recursion stack across the graph. Cyclic items are excluded from slot ordering and surfaced in a separate "⚠ Cyclic dependencies" callout at the end of step 7.
- Parser is forgiving: unrecognized syntax is ignored, never errored. Dep references to issues not on the roadmap are respected for blocked/unblocked status but cannot participate in blocker injection (step 7b).

**Step 6a — Label lookup and home tier:**

- Resolve the label set for each item's linked issue:
  1. If the Overview mode ran earlier in this session and cached `gh issue list` output, use that.
  2. Otherwise, run `gh issue list --state open --json number,title,labels --limit 100` **once** and cache it for the rest of this mode.
  3. If `gh` fails at this step (network, rate limit), stop with an error — no degraded fallback. Without labels, slot assignment cannot be computed.
- Assign each item a **home tier** from its core label:
  - `bug` → Tier 1
  - `tech-debt` → Tier 2
  - `enhancement` or no core label (unlabeled) → Tier 3 (unlabeled items surface a note: "classify this item's label before starting.")

**Step 6b — Critical-path-target (CPT):**

For each non-cyclic item, walk the dependency graph *forward* (from the item, following edges to everything that transitively depends on it) and record the highest-priority home tier reached by any descendant:

- Reachable descendant in Tier 1 → CPT = `blocks-bug`
- Else reachable in Tier 2 → CPT = `blocks-tech-debt`
- Else reachable in Tier 3 → CPT = `blocks-enhancement`
- Else → CPT = `blocks-nothing`

CPT is transitive: an enhancement that blocks tech-debt that blocks a bug has CPT = `blocks-bug`. An item's own home tier doesn't count — CPT only reflects what depends on it.

**Step 6c — Slot assignment (unblocked items only):**

Blocked items do not receive a slot here; they are injected in step 7b. Every *unblocked* item maps to exactly one of six slots:

| Slot | Home tier | CPT | Description |
|------|-----------|-----|-------------|
| 1 | Tier 1 | any | Unblocked bugs |
| 2 | Tier 2 | `blocks-bug` | Tech-debt gating a bug |
| 3 | Tier 2 | `blocks-tech-debt` / `blocks-enhancement` / `blocks-nothing` | Other unblocked tech-debt |
| 4 | Tier 3 | `blocks-bug` | Enhancements gating a bug |
| 5 | Tier 3 | `blocks-tech-debt` | Enhancements gating tech-debt |
| 6 | Tier 3 | `blocks-enhancement` / `blocks-nothing` | Non-bug/non-tech-debt-blocking enhancements (incl. unlabeled) |

6. Score each unblocked item 1–100 **within its own slot** on four equally-weighted criteria (25 pts each) using these anchors:

   | Criterion | 25 pts | 12 pts | 0 pts |
   |-----------|--------|--------|-------|
   | **Unblocking value** | Blocks 3+ other items | Blocks 1 item | Standalone |
   | **Momentum** | Adjacent to commits in last 7 days | Same module in last 30 days | No recent activity |
   | **Risk reduction** | Fixes known crash, data loss, or reliability issue | Prevents a likely future incident | Neutral |
   | **Effort efficiency** | <1 day for high-value outcome | Multi-day, proportional | Vague or underspecified |

   Interpolate for intermediate scores; cite the anchor you're closest to in each item's rationale. Score is a **tiebreaker within a slot** — slot membership always dominates.

   **Within slot 3 and slot 6 (mixed-CPT slots):** items with a stronger CPT (`blocks-tech-debt` or `blocks-enhancement` in slot 3; `blocks-enhancement` in slot 6) rank above `blocks-nothing` peers regardless of score. Score tiebreaks within each CPT sub-group.

   **Cold-session fallback:** if no item scores >0 on Momentum (e.g., `git log --oneline -20` shows no activity relevant to any item), redistribute Momentum's 25 pts proportionally across Unblocking value, Risk reduction, and Effort efficiency. Note "(cold session — Momentum disabled)" in the output. This fallback applies per-slot.

7. **Build the final ordering and display:**

   **7a. Base ordering (unblocked items):** lay out unblocked items in slot order (1 → 2 → 3 → 4 → 5 → 6). Within each slot, sort by the within-slot rule from step 6 (CPT sub-groups for slots 3/6; score within each group; same-tier blocker above same-tier blocked where both are unblocked).

   **7b. Inject blocked items:** process blocked items in topological order (every blocker placed before its blocked dependents). For each blocked item X:
   - Find the position of X's latest-appearing open blocker in the current ordering.
   - Insert X immediately after that blocker.
   - If X has multiple blockers, use the one that sits furthest down in the ordering (the last one to land).
   - If any of X's blockers is outside the roadmap (i.e., references an issue that isn't a roadmap item), X cannot be injected via that blocker — fall through to the next blocker. If *all* of X's blockers are off-roadmap, append X to the end of the list with a `⛓ blocked by #NN (off-roadmap)` marker.

   **7c. Show the top 3–5 items** in this table:
   ```
   | Rank | Slot | Tier | Item | Section | GH | Unblock | Momentum | Risk | Efficiency | Total |
   |------|------|------|------|---------|----|---------|----------|------|------------|-------|
   ```
   - `Slot` is `1`–`6` for unblocked items, or `↳N` for a blocked item injected after a slot-`N` blocker.
   - `Tier` shows the home label (`bug`/`tech-debt`/`enhancement`/`unlabeled`).
   - **Inline markers in the Item cell:**
     - `⛓ blocked by #NN` — item has open deps; `NN` is the latest-landing blocker driving its injection point.
     - `⬆ unblocks #NN` — item directly blocks a higher-tier dependent; show one representative target.
     - `⬆ on path to #NN` — item reaches a higher-tier dependent only via transitive blocking.

   **7d. Cyclic dependencies callout** at the end: list any cycles from step 5b as `⚠ #A → #B → #A`. Cyclic items are not ranked until the cycle is broken.

   **7e. Batching suggestions (advisory).** After 7c and 7d, scan the top 5 ranked items for batch candidates. Group items that satisfy **all three** of:
   - Share the same core label (`bug` / `enhancement` / `tech-debt`);
   - Share at least one non-core label (e.g., `ui`, `performance`, `api`, `new_mod`, any area/component label);
   - Live in the same H3 subsection of `.claude/roadmap.md`.

   Skip any item already carrying the `⛂ part of #NN` marker (already inside an open umbrella). Only emit a group if it contains 2–5 items; groups larger than 5 are split (prefer higher-ranked members) or suppressed. If no group qualifies, skip this step silently.

   For each qualifying group, emit a one-line suggestion under a **Batch candidates** header:

   > 🧺 **#82, #91, #104** share `ui` label and live in `## Features › UI consistency`. Consider batching under an umbrella if combined scope is tight (<~2 days).

   This is **advisory only**. Prioritize never creates umbrellas — the user can act on the suggestion via `/roadmap add umbrella ...` (Mode: Add Item step 6b) or via the at-start-of-work prompt in Implement step 10c. The "one allowed network call" discipline for this mode is preserved: detection uses the already-fetched label set, no extra `gh` calls.

8. Flag dependency chains: "X should precede Y because..."
9. End with a brief recommendation: the rank-1 item of the final ordering, with its slot, CPT, and a one-line rationale. Rank 1 is always actionable — blocked items can only appear after their blockers, so the top of the list is always something you can start on today.

---

## Mode: Implement (`start` or auto-transition from Overview)

This mode connects roadmap priorities to active coding sessions. It serves as a **session resumption tool**: run `/roadmap` or `/roadmap start`, get an immediate briefing on where things stand, and either pick up where you left off or start the next priority.

### Status Values

The Current Focus table includes a `Status` column with one of:

| Status | Meaning |
|--------|---------|
| `In Progress` | Actively developing, no PR yet |
| `In Review` | PR submitted, waiting for review/merge |
| `Blocked` | Waiting on an external dependency (e.g., another repo must merge first) |

During the resume flow, update the Status column based on gathered state (e.g., if a PR is discovered, change from `In Progress` to `In Review`).

### Check Current Focus

1. Read `.claude/roadmap.md`
2. Look for a `## Current Focus` section
   - If the section is missing entirely, create it with `None.` before proceeding. The section must always exist.
3. If it has an active item (a table row) → **Resume flow** (step 4)
4. If it shows `None.` → **Start new work** (step 10)

### Resume flow (Current Focus exists)

4. **Gather state** — run these in parallel where possible:
   - `git rev-parse --abbrev-ref HEAD` (current branch)
   - `git rev-list --count origin/main..<branch>` (commits ahead)
   - `git rev-list --count <branch>..origin/main` (commits behind)
   - `gh pr list --head <branch-name> --json number,state,mergedAt,reviewDecision,statusCheckRollup,reviews,comments,url`
   - `gh issue view NN --json state,labels,body` (every Current Focus row has an issue link)

**Step 4b — Umbrella-focus augmentation:**

- If the Current Focus issue's labels include `umbrella` (or an accepted variant), parse the child `#NN` references out of its body's `- [ ] #NN` / `- [x] #NN` task list.
- For each child, fetch `gh issue view <child-NN> --json state,title` (parallelize across children).
- Compute `children_closed` and `children_total`. Any child still `OPEN` keeps the umbrella active; umbrella completion requires all children closed.
- Store `umbrella_children` for the briefing in step 5 and the completion check in step 6. If the focused issue is not an umbrella, skip this step.

5. **Present status briefing:**
   ```
   Current Focus: <item description> (<GH link>)
   Branch: <branch-name>
     <N> commits ahead of main, <M> behind
   PR: #<number> — <state> | not yet created
     Review: <approved | changes requested | pending | N unresolved comments>
     CI: <passing | failing | pending>

   Action needed: <contextual recommendation>
   ```

   If the focus is an umbrella (step 4b ran), prepend a children line right after the `Current Focus:` line:
   ```
   Children: <children_closed>/<children_total> closed — open: #A, #B, #C
   ```
   Truncate the open-children list to the first 5 if there are more.

   Action needed examples:
   - "Implementation in progress, no PR yet. Switching to branch..."
   - "Address review feedback on PR #105"
   - "CI is failing on PR #105 — check test results"
   - "PR #105 is approved and CI passing — ready to merge"
   - "Branch is N commits behind main — consider rebasing"
   - (umbrella) "Umbrella is 3/5 — 2 children still open; keep going."
   - (umbrella) "Umbrella children all closed and PR #105 is open — ready to merge the umbrella PR."

6. **PR merged** (+ linked issue closed) → item is complete:
   - For a non-umbrella focus: archive it (same logic as Mode: Archive — monthly archive file, remove from section, close GH issue if still open).
   - For an umbrella focus: the merged PR should include `Closes #<umbrella>` plus `Closes #<child>` for every open child (see the **PR ↔ issue linking** note). Verify all children are closed on GH before archiving. If any child is still open (e.g., the PR didn't cover it), refuse to archive the umbrella yet and surface which children are still open. Otherwise archive the umbrella using the Mode: Archive umbrella rules (list all children under its archive entry).
   - Replace the Current Focus table with `None.` (the section must always exist, never be removed).
   - Show next priority from the Priorities table: "Completed X! Next priority is Y. Continue on this branch, or stop?"
   - If user wants to continue → populate Current Focus with the next item (reuse the existing branch), exit skill
   - If user wants to stop → leave Current Focus showing `None.`, stop

7. **PR exists, not merged:**
   - Update Status column to `In Review` (or `Blocked` if there are unresolved external dependencies)
   - Present the status briefing (step 5)
   - Check if on the correct branch, switch if needed (use dirty-tree guard from step 9)
   - Exit skill so user can continue working

8. **No PR yet** → still implementing:
   - Ensure Status column shows `In Progress`
   - Present the status briefing (step 5)
   - Check if on the correct branch, switch if needed (use dirty-tree guard from step 9)
   - Exit skill so user can continue implementing

9. **Dirty-tree guard** (used by steps 7–8):
   - Run `git status --porcelain`
   - If clean → proceed with branch switch
   - If already on the correct branch → proceed (user was mid-work)
   - If dirty AND on a different branch → STOP: "You have uncommitted changes on `<current-branch>`. Commit or stash them before switching to `<target-branch>`."
   - Never auto-stash or auto-commit

### Start new work (no Current Focus)

10. Read the Priorities table, select the rank 1 item
    - If no priorities exist → "No prioritized items. Run `/roadmap next` to score and rank items first." → stop

**Step 10b — Verify issue state:**

- Run `gh issue view NN --json state,title` for the selected item (or use cached state from Overview).
- If `state == "CLOSED"`: flag for archive, do not branch. Suggest `/roadmap archive` and offer the rank 2 item instead.
- If `state == "OPEN"`: proceed.
- Every item has a linked issue after Gate B, so this check always runs. Gate A has already ensured `gh` is available.

**Step 10c — Batch-scope prompt (new-work flow only):**

After rank-1 is confirmed OPEN in step 10b, scan for batch candidates using the exact detection rule from Prioritize step 7e (shared core label + shared non-core label + same H3 subsection; skip items already carrying `⛂ part of #NN`). Include only candidates that are also OPEN on GH.

- If no candidates qualify, skip this step silently and continue to step 11.
- If one or more candidates qualify (2–5 total items counting rank-1), call `AskUserQuestion` with exactly this shape:

  - **Header:** `Batch scope`
  - **Question:** `Rank-1 #<NN> shares scope with #<AA>, #<BB>. Start as a batch under an umbrella?` (list up to 4 candidate IDs in the question; truncate beyond with a "+N more" suffix)
  - **Options (exactly three):**
    1. **Focus single** — `Branch off for #<NN> only; leave candidates for later. Existing behavior.`
    2. **Batch with umbrella (Recommended when scope is tight)** — `Create a new umbrella issue grouping #<NN> + selected candidates; branch becomes <prefix>umbrella-<slug>; Current Focus tracks the umbrella. One PR closes all children.`
    3. **Focus single + note relationship** — `Start #<NN>; append a comment on its GH issue noting that #<AA>, #<BB> share scope for future batching. No umbrella created.`

- On **Focus single**: proceed to step 11 with rank-1 unchanged.
- On **Focus single + note relationship**: run `gh issue comment <NN> --body "Shares scope with #<AA>, #<BB>. Consider batching if revisiting."` then proceed to step 11 with rank-1 unchanged.
- On **Batch with umbrella**:
  1. Verify all candidates share rank-1's core label. If any differ, refuse: "Cross-tier candidates: #<AA> is <tier>. Split into two umbrellas — run this flow again per tier." Fall back to the "Focus single" path automatically and continue with step 11.
  2. Enter the umbrella-creation procedure from **Mode: Add Item step 6b** with the candidate set pre-populated. Apply the procedure with this adaptation: subpoints 1, 2, 4, 5, 7, 8, 9 run normally; subpoint 3 is skipped (children already exist as the selected issues — no new issue drafting needed); subpoint 6 runs with a modified per-child loop — instead of `gh issue create` for each child, the skill presents each child's existing title for approval, then runs `gh issue edit <umbrella-NN> --body "..."` to add `- [ ] #<child-NN> - <title>` to the umbrella body's task list, one child at a time. Per-issue approval still applies at every child link.
  3. After the umbrella is created and the task list is populated, set the selected item to the umbrella (not rank-1) for steps 11–15. The branch name in step 11 uses the umbrella's `#NN` and inherits its core label's prefix. The slug can use the umbrella's slugified title prefixed with `umbrella-` to make the batch obvious (e.g., `feature/<umbrella-NN>-umbrella-ui-consistency`).
  4. Roadmap markers: each child gets the inline `⛂ part of #<umbrella-NN>` marker added after its GH link in `.claude/roadmap.md`. The umbrella itself appears in the section matching its core label with the `🪂 umbrella (0/N done)` marker.

11. **Determine branch name:**
    - Fetch GH issue labels via `gh issue view NN --json labels` (or reuse cached state).
    - Map the core label to branch prefix (first match wins, ignore non-core labels):
      - `bug` → `fix/`
      - `enhancement` → `feature/`
      - `tech-debt` → `chore/`
      - No core label present → stop and ask the user to apply one of the three core labels before starting. Don't guess a prefix. Additional non-core labels on the issue are fine but don't determine the prefix.
    - Generate slug: `<prefix><issue-number>-<slugified-title>` (lowercase, replace non-alphanumeric with hyphens, collapse multiple hyphens, truncate to ~50 chars, trim trailing hyphens)
    - Present the proposed branch name to the user for confirmation before creating

**Step 11b — Dependency scan (for the worktree prompt in step 12b):**

- Apply the same regex + resolution logic specified in **Mode: Prioritize step 5b** (above) to the selected rank-1 item's body. Do not duplicate the spec — reuse it.
- Resolve each referenced `#NN` via, in order: cached GH state from an earlier Overview fetch this session → archive files under `.claude/roadmap/` → fresh `gh issue view NN --json state` only if state is still unknown.
- Produce `open_deps` = list of `#NN` that resolved to `OPEN` (or are still unknown after all three checks). This list feeds step 12b. Empty list = no warning.

12. **Guard dirty working tree:**
    - Run `git status --porcelain`
    - If dirty → STOP: "You have uncommitted changes. Commit or stash them before starting roadmap work."
    - If clean → proceed

**Step 12b — Worktree vs. branch prompt:**

Skip this prompt and fall straight through to step 13 in either of these cases:

- The branch `<branch-name>` already exists (`git rev-parse --verify <branch-name>` succeeds). Step 13 already handles reuse / `-v2` / abort.
- A worktree for `<branch-name>` already appears in `git worktree list` for this repo. In that case, call `EnterWorktree(path="<existing-worktree-path>")` directly and jump to step 14.

Otherwise, call `AskUserQuestion` with exactly this shape:

- **Header:** `Work isolation`
- **Question:** `Start issue #<NN> in a git worktree or on a new branch in the current checkout?`
  - If `open_deps` (from step 11b) is non-empty, prepend: `⚠ Depends on open issue(s): #A, #B. Starting now means the change may not be mergeable until those land. ` (then the rest of the question).
- **Options (exactly two):**
  1. **Worktree (Recommended)** — `Creates .claude/worktrees/<branch-name>, branches from origin/main, switches this session into the worktree. Leaves the main checkout untouched so you can keep working on other branches there.`
  2. **New branch** — `Runs git checkout -b <branch-name> origin/main in the current checkout (existing behavior).`

Store the user's answer as `isolation ∈ {"worktree", "branch"}`. This selects the path in step 13.

13. **Create the branch or worktree (path depends on `isolation`):**

    **Path A — Branch** (when `isolation == "branch"`):
    - Run `git fetch origin main`
    - Run `git rev-parse --verify <branch-name>` (silently, discard stderr) to check whether the branch already exists.
    - If the branch exists: present options — (a) switch to the existing branch if the working tree is clean, (b) derive a new slug by appending `-v2` (then `-v3`, etc.) and recheck, (c) abort. Never force-delete.
    - If the branch does not exist: run `git checkout -b <branch-name> origin/main`

    **Path B — Worktree** (when `isolation == "worktree"`):
    - Run `git fetch origin main`
    - Run `git worktree add .claude/worktrees/<branch-name> -b <branch-name> origin/main` via Bash.
      - We use `git worktree add` directly instead of `EnterWorktree`'s built-in creation mode because that mode branches from `HEAD`, and the skill's convention is to branch from `origin/main`.
    - Call `EnterWorktree(path=".claude/worktrees/<branch-name>")` to switch the session into the new worktree. From this point on, all subsequent steps run inside the worktree's checkout.

14. **Record in roadmap:**
    - If `## Current Focus` section doesn't exist, insert it after the Priorities guidance lines (`**Then:** ...`) and before the first content section `## Header`
    - Populate the table:
      ```markdown
      ## Current Focus

      | Item | GH | Branch | PR | Status | Started |
      |------|----|--------|----|--------|---------|
      | **<item title>** | [#NN](url) | `<branch-name>` | — | In Progress | YYYY-MM-DD |
      ```
    - The `GH` column always holds an issue link. There is no `[local]` fallback.
    - If step 13 took the worktree path, this update lives in the worktree's checkout of `.claude/roadmap.md` — same as any other file change on the new branch. It will land on `main` when the feature PR merges.

15. **Print start message and exit:**
    - "Starting work on: <item description>"
    - "Branch: `<branch-name>`"
    - If step 13 took the worktree path, also print:
      - "Worktree: `.claude/worktrees/<branch-name>`"
      - "Main checkout is untouched; use `ExitWorktree` when you're done with this issue."
    - If the item has a GH issue link: "Issue: <url>"
    - Exit the skill. The user now implements freely.

---

## Mode: Add Item (`add <description>`)

1. Label Preflight has already run (pre-flight). `bug`, `enhancement`, `tech-debt`, and `umbrella` labels are guaranteed to exist.
2. Read `.claude/roadmap.md`
3. Parse all H2/H3 headings and their content to understand section themes
4. Analyze the description against existing items and section themes
5. Recommend section placement by matching the description's domain to the closest section. If no section fits, propose creating a new one or ask for clarification.
6. **Classify the item** with exactly one core label — user-facing vs internal:
   - User-facing defect → `bug` (title prefix `[Bug]`, branch prefix `fix/`)
   - User-facing feature or improvement → `enhancement` (title prefix `[Enhancement]`, branch prefix `feature/`)
   - Internal chore, refactor, CI, tooling, test coverage, version mismatches → `tech-debt` (title prefix `[Tech Debt]`, branch prefix `chore/`)
   - Present classification for user override.

6b. **Umbrella detection.** An umbrella is a tracking issue that groups 2–5 children sharing a core label and a scope. Take this path if either:
   - The user invoked `add umbrella <description>` explicitly (Argument Parsing table), OR
   - The description implies multi-part scope — it uses words like "all", "every", "across", "pass", "audit", "consistency", or enumerates 3+ distinct sub-tasks. In this case, **propose** the umbrella path to the user; if they decline, fall through to the normal single-issue flow at step 7.

   Umbrella creation procedure:
   1. Draft the umbrella issue — title prefix `[Umbrella]`, core label inherited from the children's shared tier (if unknown yet, ask the user which tier this batch lives in), `umbrella` companion label applied alongside.
   2. Body structure:
      ```
      Scope: <one-paragraph summary>

      Children:
      - [ ] #TBD - <draft title 1>
      - [ ] #TBD - <draft title 2>

      Acceptance: all children closed.
      ```
   3. Draft each child issue side-by-side with the umbrella, following step 8's drafting rules (title prefix by tier, issue-template check, label suggestions).
   4. **Cross-tier check**: if any proposed child's classification differs from the umbrella's core label, refuse and suggest splitting into two umbrellas (one per tier). Never relax the same-tier rule.
   5. **Per-issue approval**: present the umbrella draft first and wait for explicit approval of *that specific* issue. On approval, run `gh issue create` for the umbrella and capture its `#NN`.
   6. Then, for each child in sequence, present the child's draft and wait for explicit approval. On approval, run `gh issue create` for the child, then edit the umbrella's body in place via `gh issue edit <umbrella-NN> --body "..."` to rewrite the task-list line from `- [ ] #TBD - <title>` to `- [ ] #<child-NN> - <title>`. Do not batch — one child at a time.
   7. If any child creation fails, leave the umbrella open with the successful children linked; rewrite the umbrella body to reflect only the children that were actually created. Do not leave `#TBD` placeholders. Surface the failure and let the user retry the missing child(ren) manually.
   8. Roadmap: insert the umbrella into the section matching its inherited core label, with marker `🪂 umbrella (0/N done)`. Insert each child into the same section (or the section matching its own sub-theme, if distinct) with the inline marker `⛂ part of #<umbrella-NN>` after the child's GH link.
   9. Cross-referencing for detection: after umbrella creation, Prioritize step 7e, Overview/Sync reconciliation, and Implement step 10c will all skip any issue carrying `⛂ part of #NN`.

7. **Duplicate detection**: fuzzy-match the description against existing open GH issues via `gh issue list`. Warn if a close match is found and offer to link to the existing issue instead of creating a new one.
8. **Draft and create the issue** (one unified path — every item becomes a GH issue):
   - Draft the roadmap entry matching the style of adjacent items (bold title, em-dash description, sub-bullets if needed).
   - Draft a GitHub Issue body side-by-side:
     - Title uses the prefix from step 6.
     - Check for issue templates at `.github/ISSUE_TEMPLATE/*.md` and `.github/ISSUE_TEMPLATE/*.yml` (YAML forms). Fall back to `.github/issue_template.md` (case-insensitive). If multiple templates exist, select by classification (bug template for bug items, feature template for features, etc.). Otherwise use: description, details, and acceptance criteria.
     - Apply the core classification label directly (`bug`, `enhancement`, or `tech-debt`). Label Preflight has already ensured these exist, so no extra label-creation dance is needed.
     - If the repo uses a variant (e.g., `type:bug`), prefer the variant already accepted by Label Preflight.
     - **Suggest additional labels alongside the core label.** Fetch the repo's existing label set via `gh label list --json name --limit 100` (or reuse cached state from the preflight/overview run). Scan the item's title and description for matches with labels beyond the three core ones (e.g., `new_mod`, `ui`, `performance`, `api`, area/component labels). Include any matching labels in the draft. Do not create new labels in this step — only apply labels that already exist. The user can add/remove suggestions during review.
   - Present both drafts for user review **one issue at a time**. Never bundle multiple proposed issues into a single confirmation prompt.
   - On explicit approval of **this specific** issue:
     1. Create the GH issue via `gh issue create --title "..." --body "..." --label "..."`
     2. Parse the returned issue number and URL
     3. Insert the roadmap entry with the `([#NN](url))` link
   - **If `gh issue create` fails: do NOT edit the roadmap. Report the error and suggest retry.**
   - If multiple issues are being proposed in sequence (e.g., from an audit or the legacy-migration loop in Gate B), complete the full draft-approve-create cycle for each one before moving to the next. Never pre-stage multiple `gh issue create` calls.

---

## Mode: Archive (`archive [description]`)

1. Read `.claude/roadmap.md`
2. Determine current month's archive file: `.claude/roadmap/YYYY-MM.md`
   - If file doesn't exist, create it with header:
     ```markdown
     # Roadmap — <Month> <Year>

     ## Features Completed
     ```
3. **Find items to archive:**
   - If description provided: find the matching item in the roadmap
   - If no description: run `git log --oneline -20`, cross-reference with roadmap items, and present candidates that appear done based on recent commits
   - Present candidates and ask user to confirm which to archive
4. For each confirmed item (every item has a linked GH issue — there is no local-only branch):
   - Parse the `([#NN](url))` link from the item.
   - Look up the issue's labels (reuse any cached `gh issue list` from an earlier mode this session, or `gh issue view NN --json labels`).
   - **Umbrella check**: if the labels include `umbrella` (or an accepted variant):
     - Parse the child `#NN` references out of the umbrella issue's body task list (`gh issue view NN --json body` if not already cached).
     - For each child, fetch `gh issue view <child-NN> --json state,title`. If any child is still `OPEN`, refuse to archive: "Umbrella #NN has N open children: #A, #B, .... Close their PRs first, then retry archive." Skip to the next confirmed item.
     - If all children are closed: write the archive entry as `### [Umbrella] <Title> (YYYY-MM-DD)` followed by a bulleted list of the children's titles and `#NN` (each prefixed with `- ` and a one-line summary if available). If the umbrella's inherited core label is `tech-debt`, append `[tech-debt]` to the archive title.
     - Remove the umbrella item AND the `⛂ part of #<umbrella>` markers from any children that are still listed in `.claude/roadmap.md`. Do NOT re-archive children that already archived separately — the umbrella archive entry lists them for discoverability only, it does not duplicate their per-item archive entries if those exist.
   - Otherwise (non-umbrella item): append to archive as `### <Title> (YYYY-MM-DD)` with one-line summary. If the labels include `tech-debt` (or accepted variant), append `[tech-debt]` to the archive title. Label is the source of truth here, not section name.
   - Remove the item from `.claude/roadmap.md`.
5. **GitHub Issue close:**
   - Check if the linked issue is still open via `gh issue view NN --json state` (or cached state).
   - If open: ask "Issue #NN is still open. Close it?"
   - If confirmed: `gh issue close NN --comment "Completed and archived in roadmap."`
   - If already closed: note it and proceed normally
6. If archive file was newly created, ensure the Completed section in `.claude/roadmap.md` links to it

---

## Mode: Pause (`pause [note]`)

1. Read `.claude/roadmap.md`.
2. If Current Focus is `None.`: error "Nothing to pause." and exit.
3. Ensure a `## Paused` section exists (create if missing) with header:
   ```markdown
   ## Paused

   | Item | GH | Branch | PR | Status | Started | Paused | Note |
   |------|----|--------|----|--------|---------|--------|------|
   ```
4. Move the Current Focus row into Paused: copy all existing columns, append today's date in `Paused`, append the provided note (or `—` if none).
5. Replace Current Focus with `None.`.
6. Print: "Paused: <item>. Run `/roadmap resume <item>` or `/roadmap start` to pick up new work."
7. Do NOT switch branches, commit, push, or touch GH state.

---

## Mode: Resume (`resume <item>`)

1. Read `.claude/roadmap.md`; find the matching row in `## Paused` (fuzzy-match item name).
2. If Current Focus is NOT `None.`: error "Pause the current focus first."
3. Move the Paused row back into Current Focus (drop the `Paused` and `Note` columns).
4. If `## Paused` is now empty, remove the section header and table.
5. Fall through to **step 4 of Mode: Implement (Resume flow)** using the restored row. Branch switching uses the existing dirty-tree guard at step 9; the branch-exists check is scoped to `git checkout -b` in step 13 and does not fire on resume.

---

## Notes

- **Dynamic discovery**: Never hardcode section names. Parse what's actually in the roadmap file.
- **Style matching**: When adding items, match the formatting conventions (bold titles, sub-bullets, em-dashes) of the target section.
- **No tooling leakage in persisted content**: Content written into GitHub issues (titles, bodies, labels, comments), roadmap entries, archive entries, pause notes, and PR descriptions must never reference Claude, Claude Code, `CLAUDE.md`, `.claude/`, skills, agents, or any other AI-tooling artifact. These artifacts are public and durable — they describe the work in the project's own domain terms. If an item originated from a Claude-session observation, describe the observation itself (the bug, the missing invariant, the refactor opportunity), not the observer. This applies to every mode that writes to a file or calls `gh issue create` / `gh issue close --comment` / `gh issue edit`. The skill's own SKILL.md and internal prompts may reference Claude freely; the rule is about *output that gets persisted into the project*.
- **Reference by name, never by line number**: Roadmap items and GitHub-issue bodies are read weeks or months after they're written, long after the referenced code has shifted. Identify code by stable anchors — class name, method name, module path (`runner.py`, not `runner.py:1697`), dataclass field — never by line number, and never by specific commit SHA unless the item explicitly describes a past event. Line numbers and SHAs rot on the next PR and produce confident-but-wrong guidance. This applies to every item body, acceptance criterion, and reproduction step, whether drafted for the roadmap or for the GH issue. When summarizing an item the user dictates verbally, rewrite any "runner.py:123" they mention as "the `<method_name>` method in `runner.py`" before drafting.
- **Graceful handling**: If `.claude/roadmap.md` doesn't exist, always offer to bootstrap before erroring.
- **Archive links**: The Completed section should maintain reverse-chronological links to monthly archive files.
- **Six-slot critical-path ordering**: `Mode: Prioritize` partitions unblocked items into six slots by home tier × critical-path-target (the highest tier transitively blocked). The slot order is: (1) unblocked bugs, (2) tech-debt blocking bugs, (3) other unblocked tech-debt, (4) enhancements blocking bugs, (5) enhancements blocking tech-debt, (6) non-bug/non-tech-debt-blocking enhancements (incl. unlabeled). Blocked items are injected right after their latest-landing blocker in the final ordering — a bug blocked by an enhancement sits adjacent to that enhancement, even though its home tier is bug. Within slots 3 and 6, items with a stronger critical-path-target rank above pure non-blockers. Score (1–100, per slot) is a tiebreaker and never overrides slot membership or CPT sub-grouping. Cyclic dependencies are surfaced in a separate callout and excluded from ranking until broken.
- **Labels are the source of truth for classification**: Every issue must carry exactly one of the three core labels (`bug`, `enhancement`, or `tech-debt`). The core label — not markdown markers, not section names — determines item category, branch prefix, archive tagging, and tier. The Label Preflight guarantees these three labels exist in every repo, plus the `umbrella` companion label. Additional project-specific labels (e.g., `new_mod`, `ui`, `performance`) are allowed and encouraged alongside the core label, but they never replace it and never drive branch prefix or tier. The `umbrella` label is a companion label, applied alongside (not instead of) the core label; it does not satisfy the core-label requirement on its own.
- **No local-only items**: Every roadmap item is a GH issue. There is no `[local]` fallback — items that would once have been local are now `tech-debt`-labeled issues. Gate A refuses to run without `gh`; Gate B migrates legacy `[local]` entries before any other mode proceeds.
- **Never auto-edit on sync**: The overview mode flags discrepancies but never automatically modifies the roadmap. All changes require user confirmation.
- **Per-issue approval (mandatory)**: Every GitHub issue must be individually drafted and individually approved before `gh issue create` runs. This applies to **every mode** — bootstrap, add, audit-driven batches, overview reconciliation, **the Gate B legacy-migration loop**, anywhere an issue would be opened. Never batch-create issues from a single blanket confirmation, a plan approval, or "create issues for all ≥ N" criteria. For each proposed issue:
  1. Present the full draft (title, labels, body) to the user
  2. Wait for explicit approval of **that specific issue**
  3. Only then run `gh issue create` for it
  4. Move to the next draft and repeat
  Plan-mode approval of a plan that says "create issues for X, Y, Z" does **not** substitute for per-issue approval at execution time.
- **Umbrella issues**: An umbrella is a tracking GH issue that groups 2–5 children sharing a single core label and a common scope. Representation uses GitHub's task-list convention — `- [ ] #NN - <title>` lines in the umbrella's body; GitHub auto-renders progress and auto-checks items when the referenced issue closes. The umbrella carries the `umbrella` companion label plus the inherited core label; children live in their normal roadmap sections with an inline `⛂ part of #<umbrella-NN>` marker. Same-tier rule is strict: cross-tier scopes must split into two umbrellas. When a batch is active, the umbrella sits in `## Current Focus` (one active batch at a time) and a single PR carries `Closes #NN` for every child plus the umbrella itself. The umbrella closes automatically when its last child closes (via the merged PR's closing keywords). See Mode: Add Item step 6b for creation, Mode: Implement step 10c for the at-start-of-work prompt, and Mode: Archive for completion handling.
- **Batch-scope recommendations**: Three surfaces use a shared detection rule — shared core label + shared non-core label + same H3 subsection, 2–5 items, skipping anything already carrying `⛂ part of #NN`:
  1. **Prioritize step 7e** — advisory `🧺 Batch candidates` block after the ranked table; no action, no extra network calls (preserves the mode's "one allowed network call" discipline).
  2. **Overview/Sync reconciliation** — non-blocking advisory warning that suggests `/roadmap add umbrella "<title>"`; does NOT block the step-12 implementation auto-transition.
  3. **Implement step 10c** — at-start-of-work `AskUserQuestion` prompt with three options (focus single / batch with umbrella / focus single + note). Acceptance dispatches to Mode: Add Item step 6b's per-issue-approval flow.

  The skill never auto-bundles. Batch creation always runs through per-issue approval (umbrella drafted first, each child link approved individually). Batching is always optional; users can decline every surface and work items singly.
- **Current Focus**: The `## Current Focus` section in the roadmap tracks the single active work item. At most one item is in focus at a time — a batch counts as one, represented by its umbrella. This section must always exist — when no work is active, it shows `None.` rather than being removed. Work is not complete until the PR is merged; a submitted PR means the item is still in focus (in review). For an umbrella focus, "complete" requires all children closed (which a single PR can achieve with multiple `Closes #NN` keywords).
- **Status briefing**: On resume, always present a full status briefing (branch state, PR status, review comments, CI) so the user can immediately orient. This is the core value for cross-repo context switching — Claude tracks the state so the user doesn't have to.
- **Branch safety**: Never auto-stash or auto-commit. If the working tree is dirty and a branch switch is needed, stop and ask the user to resolve it.
- **Session continuity**: When completing a task and continuing to the next, reuse the current branch. A new branch is only created when starting from a clean state with no Current Focus.
- **PR discovery**: Use `gh pr list --head <branch>` to auto-discover PRs rather than requiring manual entry. Update the PR column in Current Focus when a PR is discovered.
- **PR ↔ issue linking (mandatory)**: Every PR opened for a Current Focus (or Paused) item must include a GitHub closing keyword — `Closes #NN`, `Fixes #NN`, or `Resolves #NN` — referencing the linked issue in the PR body. GitHub then auto-links the issue to the PR and auto-closes the issue when the PR merges, which is what drives the "Completed via merged PR" reconciliation in Mode: Overview. Match the verb to the core label: `Fixes #NN` for `bug`, `Closes #NN` for `enhancement` or `tech-debt`. This applies whether the PR is opened via `gh pr create` directly or through any other flow — before calling `gh pr create`, cross-check the drafted body contains the keyword for the Current Focus item's issue number, and add it if missing. If the PR spans multiple issues, include one keyword per issue. For an **umbrella-focused PR**, include one `Closes #<child-NN>` for every child currently open on the umbrella's task list, plus one closing keyword for the umbrella itself (`Closes #<umbrella-NN>`). The umbrella's own closing keyword uses `Closes` regardless of the inherited core label (the umbrella is not itself a bug, even when its children are). If there is no linked issue (shouldn't happen after Gate B, but defensively), surface the mismatch instead of silently opening a PR with no linkage.
