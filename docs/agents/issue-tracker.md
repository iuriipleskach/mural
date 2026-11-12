# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues in `iuriipleskach/mural`. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --repo iuriipleskach/mural --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --repo iuriipleskach/mural --json number,title,body,labels,comments`.
- **List issues**: `gh issue list --repo iuriipleskach/mural --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Make an issue a sub-issue of a parent**: `gh api --method POST repos/iuriipleskach/mural/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>` (where `<child-db-id>` is `gh api repos/iuriipleskach/mural/issues/<n> --jq .id`). Also include `Part of #<parent>` at the top of the child body.
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with `gh api --method POST repos/iuriipleskach/mural/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/iuriipleskach/mural/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Count open blockers**: `gh api repos/iuriipleskach/mural/issues/<n> --jq .issue_dependencies_summary.blocked_by` (open blockers only; 0 means startable).
- **Comment on an issue**: `gh issue comment <number> --repo iuriipleskach/mural --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --repo iuriipleskach/mural --add-label "..."` / `--remove-label "..."`
- **Close**: post the explanation with `gh issue comment <number> --repo iuriipleskach/mural --body "..."`, then `gh issue close <number> --repo iuriipleskach/mural`.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create --repo iuriipleskach/mural --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: see **Blocking** under Conventions.
- **Frontier query**: list the map's open children (`gh issue list --repo iuriipleskach/mural --state open`), drop any with an open blocker or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --repo iuriipleskach/mural --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> --repo iuriipleskach/mural --body "<answer>"`, then `gh issue close <n> --repo iuriipleskach/mural`, then append a context pointer (gist + link) to the map's Decisions-so-far.
