# Draft: Run workflow node

Status: implemented and verified in the unreleased workflow feature. Full backend suite: 5,369 passed and 322 opt-in tests skipped. All nine macOS packages built and tested; formatting, lint, private-reference guard, release build and isolated native navigation smoke passed. No new public version or installation is part of this change.

Add a node that delegates a focused assignment to another saved workflow. Polybridge remains a workflow and multi-harness coordinator. Harnesses own their tools and external operations; orchestrators own judgment, natural-language routing, assignments, and checklist state.

## Node configuration

- Add **Run workflow** to the canvas palette.
- Select one saved workflow by stable identity. References do not depend on the display name; a rename operation is outside this implementation.
- Provide optional assignment guidance, attempt limits, timeout, and optional-branch configuration consistent with existing nodes.
- Add **Orchestrator mode** with **Child orchestrator** as the default and **Current orchestrator** as the alternative.
- Child harness, model, access, network, fallback, and worker session settings remain owned by the pinned child definition. Invocation cannot override permissions. The root network policy can disable network throughout the tree; a child setting cannot re-enable it.
- Show the selected workflow and effective access requirements in the inspector. Validate the complete dependency tree against the caller's delegation authority before dispatch; do not silently widen or cap saved access.

## Orchestrator modes and context

### Child orchestrator (default)

The parent orchestrator writes a focused assignment, which becomes the child's original request. The child uses its configured orchestrator, its own Start context, checklist, and technical plan. Do not automatically pass the parent's original request, complete graph, or global checklist.

### Current orchestrator

The parent orchestrator also directs the child's nodes, reusing its orchestrator session. The child's configured orchestrator is unused. Polybridge exposes the active child's graph, responsibilities, Start context, results, and valid continuations through scoped decision context.

Keep the child execution boundary rather than literally flattening graph definitions. Checklist and task identities remain scoped and collision-free; child items appear in a distinct section. Preserve session serialization when multiple parallel children share the orchestrator: do not send simultaneous turns into one harness session.

In both modes, workers receive focused assignments, local guidance, and selected inputs, not the orchestrator's complete context. Automatically attach relevant predecessor results using the existing complete-result handling and immutable references. Child checklist completion never automatically completes parent tasks.

Start child workers with independent sessions. Cross-workflow worker session reuse is outside this initial implementation; ordinary session policies within each child still apply.

## Dependency resolution and circular references

- Resolve and pin the complete dependency tree before starting the parent. Persist immutable snapshots, revisions, and content identities for recovery.
- Editing or deleting a saved definition must not reinterpret an existing run.
- Missing dependencies prevent starting.
- Reject direct and indirect circular references in either orchestrator mode: A → A and A → B → C → A are invalid.
- Validate dependencies on save and revalidate the fully resolved snapshots before dispatch. Errors identify the cycle path.
- Calling the same workflow from separate branches is valid; referencing an ancestor is not.
- Intentional retry arrows inside a workflow remain valid under their existing budgets.
- Enforce a maximum of four workflow levels, including the root.

## Execution and concurrency

- Child invocation is an internal runner operation, not an MCP call made by a worker or orchestrator.
- Persist dispatch reservations and parent/child execution relationships before advancing. Child creation must be idempotent; ambiguous outcomes require reconciliation rather than duplicate runs.
- Treat a child as one execution within its parent branch. A parallel branch containing a child settles only when that child execution settles.
- Support children containing their own nested parallel regions and workflow calls.
- Share a root-level harness concurrency budget across descendants. Waiting parents must not occupy execution slots needed by children.
- Preserve repository/process safety across the workflow tree. Nested orchestration must not create competing checkout owners or bypass existing write coordination.

## Outcomes and inspection

Return a structured child outcome containing status, final summary, child run identity, pinned definition identity, and immutable result/evidence references. Preserve full results; bounded previews identify truncation and permit complete retrieval without copying every child message into parent context.

The parent orchestrator evaluates the outcome and selects the next parent continuation. Distinguish runtime failure, worker failure, blocked/input-required state, cancellation, and uncertain outcomes. A suspended child is not a settled parent-node result.

Allow the parent orchestrator to inspect eligible settled executions in its linked child. Do not broaden managed access to unrelated runs. Exact contract fields and scoped inspection transport are implementation details to reconcile with existing APIs.

## Questions, recovery, and control

- Forward child input questions to the original caller, preserving their source and exact decision identity. Serialize simultaneous questions from parallel descendants.
- Route each answer to the correct suspended child checkpoint without rerunning completed nodes.
- Preserve interaction ownership: MCP callers answer their questions; Monitor-started runs expose human input in Monitor.
- Distinguish **resume/recover the existing child**, which preserves completed work and accounting, from **run the child again**, which creates a new invocation and consumes another parent-node attempt.
- A caller answer does not automatically authorize a fresh child run or extra attempts. Preserve explicit grants, attempt budgets, and saved access authority.
- Parent cancellation or timeout propagates to descendants. Wait for settlement or explicit reconciliation before permitting redispatch.
- Parent-node timeout covers the entire child invocation, using existing pause-time semantics consistently.
- Optional child-node bypass follows existing safety rules. Permission-caused failures, cancellation, and unknown outcomes must not be silently bypassed.
- Never silently repeat completed child work, particularly publishing or other external actions.

## Monitor presentation

- Reuse the current canvas, design language, activity, inspector, and recovery components.
- A compact Run workflow node shows the selected workflow, child status, and **Open workflow** action.
- Nest child workflow runs beneath their parent in the sidebar instead of flattening all descendant tasks.
- Preserve each child's canvas, checklist, technical plan, activity, and history, with navigation back to the parent.
- In Current orchestrator mode, scope decision history to the relevant workflow boundary without duplicating the shared orchestrator session in the sidebar.
- Display the parent orchestrator's assignment as the child's request. Hide internal protocol guidance.
- Keep takeover unavailable while the enclosing workflow tree is active, suspended, or settling.

## Initial scope and tradeoffs

One referenced workflow per node. No workflow fallback list, invocation-time access overrides, or cross-workflow worker session sharing in the initial implementation.

Reusable workflows reduce canvas duplication and centralize maintenance. Separate orchestrators keep responsibilities focused; Current orchestrator avoids a separate session and handoff but increases the parent's context and responsibilities. Both modes add dependency, cancellation, recovery, and navigation complexity.

Do not rewrite user saved workflows or mutate existing runs during implementation. Use isolated fixtures and test definitions. Preserve historical snapshots and behavior.

## Verification and documentation

Add meaningful tests for both orchestrator modes and context isolation; stable references, pinning, missing dependencies, recursion and nesting limits; nested parallel workflows, shared concurrency and shared-session serialization; simultaneous questions and exact answer routing; retry accounting, recovery, restart reconciliation and ambiguous launch outcomes; cancellation, timeout and optional safety; complete large-result retrieval and scoped inspection; and prevention of repeated completed work.

Add native coverage for authoring, nested navigation, child checklist presentation, assignment display, and shared-session grouping. Update workflow mechanics, diagrams, MCP/CLI descriptions, and relevant examples.

Run affected tests, backend suites, required macOS package checks, formatting/lint, release build, and isolated native smoke checks. Report only verification actually observed.

## Implemented decisions

- Stable definition identities, atomic dependency resolution, pinned revisions, and content identities preserve historical runs and references. No rename API was added.
- The root controls the shared harness-turn budget and checkout coordination; the depth limit is four levels including the root.
- Shared orchestrator sessions serialize turns while child executions, assignments, checklists, plans, and results retain their own boundary.
- Root controls route exact answers and explicit grants to the originating suspended child. Existing-child recovery preserves completed work; retrying creates a fresh invocation.
- Descendant cancellation and reconciliation verify nested settlement before accepting a terminal child outcome. Unconfirmed work remains a reconciliation requirement.

The final full backend suite, required native package checks, release build, and isolated native smoke are completion gates. This draft records the implemented design; it does not change saved workflows or historical runs.
