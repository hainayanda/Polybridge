# Draft: Run workflow node

Status: future feature proposal; not approved for implementation.

Add a node that delegates an assignment to another saved workflow. Polybridge remains a workflow and harness coordinator; harnesses retain responsibility for their tools and work.

## Execution model

- The parent orchestrator writes a focused assignment for the child workflow.
- The child orchestrator owns that assignment, its workflow context, and its own checklist. Do not automatically pass the parent's original request or global checklist.
- Polybridge starts and persists the child run, waits for it to settle, and returns a structured outcome to the parent orchestrator.
- Treat a child workflow as one execution within its parent's branch. In a parallel region, that branch settles only when the child run settles.
- Start with separate child sessions; cross-workflow session sharing is outside the initial proposal.

## Benefits and costs

Reusable workflows reduce canvas duplication and centralize maintenance. For example, Feature Implementation could delegate to a shared Code Review workflow. Separate orchestrator contexts keep responsibilities focused.

Costs include additional orchestrator calls, deeper execution history, dependency management, and more complex cancellation and recovery. Editing a shared workflow can affect several callers unless revisions are pinned.

## Safety and recovery requirements

- Reference saved workflows by stable identity. Resolve and pin child revisions when the parent starts; persist snapshots for recovery. Missing dependencies prevent starting.
- Reject direct and indirect recursive calls and enforce a nesting limit. Decide how dependency validation handles references within pinned snapshots.
- Forward child input questions through the parent to the original caller, retaining their source. Serialize simultaneous questions from parallel children.
- Parent cancellation or timeout propagates to descendants and waits for settlement or explicit reconciliation.
- Distinguish recovery of an existing child run from starting a new child run. Never silently repeat completed child work, particularly publishing or other external actions.
- Persist child dispatch identity before advancing. Uncertain spawn outcomes require reconciliation rather than duplicate child runs.
- Expose effective child access settings during authoring. Invocation must not silently broaden authorization; reconcile this with saved workflow access being authoritative.
- Define structured child outcomes and result references so the parent can inspect relevant evidence without inheriting every child message.

## UI proposal

- A compact Run workflow node shows the workflow icon and name, with optional assignment guidance in its inspector.
- During execution, show child status and an Open workflow action.
- Nest child workflow runs beneath the parent in the sidebar rather than flattening every descendant task into the parent.
- Preserve independent child checklists and execution history, with navigation back to the parent.

## Decisions to settle before implementation

- Exact input and final-result contracts, including what evidence is attached automatically.
- Child revision pinning and dependency validation policy.
- Access authorization across workflow boundaries.
- Nesting and concurrency limits, and whether parent timeout includes all child execution time.
- Recovery actions and attempt accounting for existing versus newly started child runs.
- How optional parent branches handle failed or blocked child workflows.

This draft records the discussion only. It does not change runtime behavior or saved workflow definitions.
