# Vibe refusal leaves a review workflow waiting for input

Status: unresolved user report, recorded 2026-10-06 (Asia/Jakarta). Documentation only;
no behavior change or reproduction was attempted for this report.

## Reported sequence

- Codex and Claude reviewed the change. Codex reported no findings; Claude raised two findings.
- Vibe stopped before reading code because it attempted a `git -C` command that its permissions
  did not allow.
- The caller chose to proceed without Vibe, but Polybridge continued waiting on the Vibe step.
- `recover_workflow` refused to restart the run because it was waiting for input.
- The caller used the fallback in its `CLAUDE.md` and completed the final review outside the
  workflow, checking both Claude findings against the PR head.

The workflow/run ID, exact refused command, decision ID, PR head SHA, and persisted events were
not provided. The sequence above is the caller's account, not an independently verified trace.
The disposition of Claude's findings was not reported.

## Follow-up investigation

- Capture the run state, worker result and permission denial, published input decision, caller's
  answer, and subsequent supervisor events to reproduce the stalled transition.
- Check whether proceeding without an unavailable reviewer settles or skips that step and lets
  the final review advance without changing its tool permissions or replaying completed reviews.
- Examine the recovery path for a permission-blocked run that is still waiting for input.
  `recover_workflow` currently requires a failed, settled run; determine which existing or new
  transition should handle the caller's decision to proceed.
- Add regression coverage for the denied command, proceed-without-reviewer decision, and final
  review completion once the intended transition is defined.

The refusal itself may reflect Vibe's configured permissions. This report does not establish
whether the command choice, orchestration transition, caller interaction, or recovery routing
caused the stall. See [workflow recovery rules](../workflows.md) for the current contract.
