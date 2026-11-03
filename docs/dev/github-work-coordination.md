# GitHub work ownership and session handoffs

GitHub issues, pull requests and milestones are the project-management source of truth. Claude, Codex, local chats and future dashboards use the same records. Repository design notes, evidence and session summaries support those records; they are not a separate live backlog.

## Start or resume

1. Read the relevant issue, its latest ownership/handoff comment, linked PRs and milestone. Search before creating another ticket. A stale local chat or branch name does not establish current ownership.
2. If another owner is active, preserve their checkout and ask for a handoff or agree a disjoint scope before editing. Do not launch another implementation lane, reset a shared branch or repurpose an open PR.
3. Record one current implementation owner in the issue: human identity plus session/run link, branch, base SHA and intended files/scope. Use the existing human assignee when appropriate; a model name is not a GitHub assignee. Re-read the issue and open PRs before the first write. Claims are coordination records, not an atomic lock.
4. Use one issue and one focused PR for a logical change. Track cross-repository work with explicitly linked counterpart issues/PRs and the actual dependency commit/tag. Reuse an existing release milestone or parent tracker; do not create parallel planning systems.

## Publish a checkpoint

Put this compact comment on the issue when starting, handing off, blocking or finishing. Update the PR body with the resulting behavior and final validation so the reviewer need not reconstruct chat history.

```text
State: active | blocked | deferred | ready for review | integrated | accepted
Owner: human / session or run URL (or none when parked)
Scope: concrete result and files/repositories owned
Branch / base / checkpoint: names and full commit SHAs
PR / milestone / dependencies: GitHub links
Completed: source/build/test evidence and artifact links
Pending: exact unrun tests, device checks or unresolved decisions
Next action / next owner: one concrete step
Preserved work: uncommitted files, stash/worktree and safe recovery location, if any
```

A successful compile, simulator check, upload and physical-device acceptance are different results. Record app/core SHA, platform, build number and the tested behavior; leave unrun checks pending. Do not close an acceptance ticket merely because implementation merged. If a PR closes an implementation issue, link a separate open acceptance issue for the remaining agreed checks.

Use **deferred** for intentionally parked work, **blocked** for a concrete missing prerequisite and **ready for review** for source awaiting review. When handing off, say whether the old owner has stopped writing. The incoming owner verifies the checkpoint and acknowledges ownership on the same issue before edits. A stopped or old session is not evidence that its branch is merged.

## Close a local session safely

Before archiving, preserve the issue handoff, link the PR/commit, check whether the intended source is integrated, and account for uncommitted files and worktrees. Move remaining tests or decisions to the issue. Archive only the identified completed/deferred chat; preserve code, saves, evidence and other active owners. Do not remove a worktree merely because its chat is archived.

## Release and automation boundaries

Release milestones and existing acceptance trackers determine priority. Deferred accuracy work does not silently become a release gate. Fresh screenshots use the validated app/build and record their provenance.

A ticket is a durable record, not authorization to dispatch an external agent, purchase service, change access/signing or publish a release. Keep existing approval and authentication boundaries. Any future dashboard must read/write these GitHub issues, PRs and milestones rather than maintaining its own authoritative task database.

## Existing iCube release records

Keep current release work under [App Store tracker #51](https://github.com/Provenance-Emu/iCube/issues/51) and its linked issues/[existing milestone](https://github.com/Provenance-Emu/iCube/milestone/1). Verify live status before resuming; [docs/HANDOFF.md](../HANDOFF.md) and release-evidence documents contain historical implementation/validation snapshots that may predate the latest issue or build.

For library sharing, sync and SkinKit work, link the actual Provenance/iFly/shared-package counterparts. A successful ROM copy does not prove metadata convergence, and a package test does not establish installed-app interoperability. Keep pending acceptance on the relevant GitHub issue.

iFly's fleet labels are not an iCube bot installation. Do not assume a label/comment here dispatches the same machinery, or copy runners, credentials or workflow permissions to make that happen. Use this shared handoff format with the existing iCube issue/PR workflow.
