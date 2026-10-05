# Draft: Selectable parallel branches

Status: implemented and verified in the unreleased workflow feature. Existing saved definitions and historical runs are preserved.

## Use case

A multi-platform feature workflow has a Parallel start whose branches invoke iOS, Android, and Web implementation workflows. Some requests apply only to iOS and Android. The orchestrator should select those two branches without starting Web.

This selects applicable work before dispatch. It is separate from an optional node, which tolerates eligible failure after a selected branch runs.

## Behavior

Add **Branch selection** to Parallel start:

- **All branches**: default, preserving current behavior.
- **Orchestrator selects**: choose one or more applicable branch entries and write a distinct assignment for each executable entry.

The orchestrator supplies its selection and reason, including why branches were excluded. Polybridge validates and persists the selected branch set before dispatch. Natural-language guidance remains the basis for judgment; do not replace it with coded applicability conditions.

The matching Parallel end waits for exactly the selected branches. Excluded branches appear as **Not selected**, not Pending, Failed, or successfully executed. Selected branches retain their normal required/optional failure and recovery rules.

## Invariants

- Select at least one branch. Skipping the whole group uses a conditional route around it.
- Freeze selection for each group invocation. Recovery cannot silently add or remove dispatched branches.
- A loop that re-enters Parallel start creates a new group invocation and may make a new selection.
- Persist selection across restarts. Parallel end must not infer membership from whichever tasks happen to exist.
- Select branch entries, not individual downstream nodes. A branch may contain serial nodes, nested parallel groups, or a Run workflow node.
- Preserve nested-group identity and convergence boundaries.
- Dispatch nothing for an invalid selection or invalid assignments; use the existing decision correction mechanism.
- Applicability selection is not failure bypass. Selecting optional work requires an actually selected required sibling; an optional-only selected set is rejected before dispatch. Selected branches retain the existing failure-bypass safety contract.

## UI

- Two-option Branch selection control in the Parallel start inspector.
- Optional guidance, for example: “Run only platforms affected by this feature.”
- Highlight selected branches during execution and dim excluded branches.
- Show the recorded selection and reason in execution history.
- Scope excluded presentation to the group invocation; a later loop invocation can select a previously excluded branch.

## Relationship to other routing

An ordinary fork chooses one path. A selectable parallel group chooses one or more paths and waits for the selected set. All branches remains the default.

## Implemented contract

- Parallel start stores `branch_selection: "all"|"orchestrator"` (default `all`) and optional `selection_guidance`.
- The issued continuation lists branch entries. All mode assigns every entry; Orchestrator selects assigns a nonempty subset and supplies `selection_reason` explaining selection and exclusions. Nested structural entries carry validated nested assignment bundles.
- Each durable group invocation records selected and excluded connection IDs, selected assignments, decision identity, reason, and enclosing group identity. Released history retains this record. Recovery keeps the selection frozen; loop re-entry creates another group invocation.
- Parallel end counts exactly the selected set. Excluded regions appear as Not selected for that invocation. Historical records without selection fields preserve existing behavior.
- Guided delegation is required for selectable groups; unsupported historical execution contracts stop for attention rather than dispatching an inferred subset.

Stage verification covers subset convergence, invalid selections and assignments, nested groups and child workflow entries, loop re-entry, restart consistency, and required/optional failure safety. Fresh independent backend and native reviews found no remaining material issues. The full backend suite passed with 5,399 tests and 322 skips before the final arrival-membership hardening; the final post-hardening affected suite passed all 66 tests. Native tests passed all 685 tests, with formatting, lint, release build, and private-reference guard checks passing.

The final app smoke verified the branch selector and guidance, a completed singleton barrier showing 1 of 1, iOS Selected and Web Not selected, the recorded selection reason, and visibly dimmed excluded work. These checks used isolated fixtures; no live run or user workflow was changed.
