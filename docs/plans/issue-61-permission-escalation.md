# Issue #61: Harness permission escalation

Status: Claude implementation completed and validated on 18 October 2026. See
[`issue-61-implementation-validation.md`](issue-61-implementation-validation.md) for results,
review adjudications and support limits.

Issue: https://github.com/hainayanda/Polybridge/issues/61

## Evidence and initial scope

The [certification report](issue-61-certification.md) records actual installed CLI behavior,
request/response examples, negative controls, native limitations and outstanding qualification.
These results establish transport feasibility, not production support in Polybridge.

| Harness/version | Observed result | Proposed scope |
| --- | --- | --- |
| Claude Code 2.1.302 | Opt-in stdio control requests support correlated approve/reject, repeated actions and fresh/persisted resume under existing write/publish rules. | Initial adapter target: non-native, uncapped stream JSON, Bash requests, `acceptEdits` at `write_in_repo` or `publish`. |
| Codex 0.163.0 | Existing exec remains Never; separate app-server accepts command approval decisions. | Exec unsupported; app-server deferred pending explicit architecture and escalation-scope design. |
| OpenCode 1.18.21 | Run auto-rejects; separate HTTP server supports pending requests and once/reject replies. | Run unsupported; server transport deferred pending explicit architecture/security design. |
| Vibe 2.26.0 | Programmatic callback already answered deny; action fails with `tool_denied`. | Unsupported on existing transport. Alternative callback server unqualified. |
| Antigravity 1.4.2 | Authenticated retry reached exact commands and auto-denied them; no pending request. Requested `accept-edits` init still reported `request-review`. | Observed headless transport unsupported; effective accept-edits and alternatives remain unqualified. |

Do not silently switch transports, versions, access modes or native execution to obtain support.
The first release does not override plan mode, explicit denies, sandbox restrictions or managed
policy. It does not promise that every action asks: the harness may already permit or forbid it.
Other tools and configurations stay unsupported until independently qualified. An unexpected
child or unsupported tool request must never acquire caller approval through the initial adapter.

The original transport feasibility gate is complete for the proposed Claude target. Remaining
adapter, ownership, lifecycle and UI certification below is still required before advertising support.

## Implementation sequence

### 1. Lock the supported contract and preserve probe evidence

The primary owns the specification and adjudication. Convert the successful Claude experiments
into isolated, no-paid-call, version-gated CLI regression fixtures. Preserve exact invocation
modes, policy rules, payloads and observed effects. Cover allow/reject in `acceptEdits`, explicit
hard denial, wrong request ID, repeated identical actions, EOF while pending, and persisted resume.
A stream run with `--max-turns 5` worked, but cap exhaustion and the current classic/text one-shot
transports were not qualified: keep capped launches out of initial support.

Native remains excluded. Claude 2.1.302 exposes useful child correlation IDs, but its asynchronous
child behavior is outside the foreground adapter pinned to 2.1.295. Codex 0.163.0 also differs
from its adapter's 0.162.0 pin. No version pin or lifecycle contract changes belong in this work.
Additional harness transports require a separate plan decision. The authenticated Antigravity
retry confirms already-denied headless behavior; it does not expand initial coverage. Retain its
requested/effective-mode discrepancy as a limitation, without changing global settings to bypass it.

### 2. Add a backend-owned opt-in control transport

Extend `backends/base.py` with a qualified capability and request decoder/response encoder contract.
Keep all harness-specific logic under `backends/`; `mcp_approval.py` remains configuration editing.
In the Claude adapter, support the exact qualified JSONL invocation with
`--permission-prompt-tool stdio --permission-prompts host`. Extend `assert_safe` only for that
explicit mode, retaining the current saved freedom, Git deny/allow rules and all other safety
checks. Validate the installed version and requested tool/execution mode before launch.

Add a separate serialized control-response path in `tasks.py`; never use `encode_live_message`
or count a permission response as a user turn. The stdin owner must remain alive while a verified
request is pending: EOF was observed to abandon the action and exit zero. Retain ordinary live
message behavior and prevent competing writers, early stdin close and background-idle settlement.

Approve sends the exact original `updatedInput` and `behavior=allow`; reject sends `behavior=deny`
with an explicit message. Never apply `permission_suggestions`, send `updatedPermissions`, edit
settings, change modes or create session/persistent grants. Match the action snapshot and digest
again immediately before sending. Disclose effective enforcement accurately, including Claude's
lack of a bridge OS sandbox.

Use an explicit saved opt-in for applicable launches and workflow node settings, propagated through
MCP/CLI/Monitor launch contracts. Existing definitions default off; unsupported combinations fail
before spawn. Permission previews disclose the control transport and exact-action scope. A resumed
session inherits saved approval policy but gets new request/process identity; pending requests never
carry across process generations. Backward compatibility for definitions without the new field is
required. Enabling the opt-in does not authorize worker self-approval.

### 3. Persist requests, decisions and observed outcomes separately

Add a bounded durable ledger keyed by a bridge request ID and native request ID. Bind every entry
to root workflow, node, attempt, task, session, owner process generation, original canonical action
payload/digest, tool-use ID, cwd, requested access/scope and deadline. Reject missing, ambiguous,
foreign, unsupported and oversized requests without guessing. Derive cwd from verified execution
context when absent from the request; do not invent per-command working-directory guarantees.

Separate request disposition, decision delivery and execution outcome. A stored approve decision,
a successful pipe write and an observed tool result are different facts. Persist a reservation
under a shared cross-process lock/CAS before sending. One MCP/Monitor contender wins; stale,
duplicate, settled and mismatched answers are rejected. Crashes after a possible send become
`delivery_unknown`, never a reason to replay the decision blindly. Record rejected, expired,
cancelled, unsupported and delivery-failed requests explicitly.

Set concrete request count/byte/retention budgets during contract design. Overflow must produce
bounded attention/error behavior, preserve uncertainty and never silently permit an action. Protect
complete local payload records and redact shared summaries, notifications and diagnostic logs.
Do not place decision authority in worker environments or worker-readable event payloads.

### 4. Integrate workflow ownership and lifecycle

Retain task process ownership and expose `waiting_for_approval` as an interaction substate, not a
terminal task status. Keep approval requests distinct from orchestrator `needs_input`: answering
one must not restart orchestration, replace a live worker or consume an ordinary input decision.
Pause dependent scheduling while preserving completed work, independent active branches and nested
workflow state. Surface pending requests to the root interaction owner with their source path.

Proposed caller deadline: 30 minutes, distinct from MCP wait timeouts. This duration is a policy
proposal, not a measured CLI guarantee; qualify long-held requests before adopting it. Pause the
bridge inactivity timer for a verified pending request while retaining explicit hard execution
deadlines and cancellation. On expiry, send reject only to the verified same live request; if
that cannot be established, invalidate it and retain delivery/execution uncertainty. Never infer
process settlement from ledger expiry, rejection or EOF alone.

Caller disconnect leaves the owned process/request intact until deadline or execution settlement.
Process exit and cancellation invalidate pending answers. Initial restart behavior does not support
reattachment to a lost pipe owner: invalidate stale requests, reconcile process state, and prohibit
retry while prior execution is active or uncertain. Recovery after an already denied/exited run is
a separate explicit caller action requiring durable exit/drain/settlement; configuration repair
belongs to #15 and never occurs implicitly here.

### 5. Expose authorized MCP/CLI interaction

Add bounded list/get and respond operations using request ID, expected action digest and owner
revision, plus approve/reject. Route through existing root interaction-owner checks. Workers,
orchestrators and children cannot answer their own approvals. Generic workflow resume, ordinary
messages and queued follow-ups cannot stand in for a permission response.

Status and wait APIs return attention and request handles promptly. Optional MCP elicitation can
be added only as a client affordance; the explicit decision tool remains usable when a host does
not support it. CLI commands call the same authorization/ledger service. No automatic retry of
refused work, access expansion or workflow success claim follows an answer.

### 6. Add Monitor presentation and controls

Extend PbCore models/services and MainWindowFeature with individual approval cards, oldest first,
plus counts and source workflow/node/attempt. Show the complete exact action, cwd, access, scope,
deadline and observed delivery/outcome state. Offer Approve once and Reject, never approve-all.
Require complete authorized payload inspection before allowing an answer; truncation, missing
payload and stale state cannot be approved. Disable submitted controls and retain errors/details.

Preserve the current caller/Monitor ownership split. Caller-owned requests are read-only in Monitor
and answered through the authorized MCP/CLI caller. Only Monitor-owned roots expose Approve/Reject
there; child cards route to that root. No ownership transfer is introduced. Other configurations
show unsupported/unmeasured or settled-denial recovery guidance, without an active Approve button.
Antigravity's terminal SUCCESS with `denied_actions` must remain settled-denial evidence, even
when its tool step reads DONE; it cannot become a pending approval card.

### 7. Integrate, validate and review

Vibe owns implementation in dependency order: qualified backend/transport, ledger, task/workflow
lifecycle, launch and permission-preview contracts, MCP/CLI, then Monitor and documentation.
The primary owns integration, evidence assessment and decisions. Delegate unit tests to
`test_writer` with separate file ownership and coordinated handoffs. All agents preserve others'
edits. Native fallback follows repository instructions if Vibe is unavailable or fails.

Required validation includes:

- Real installed Claude fixtures: allow/reject, exact input preservation, repeated action prompts,
  hard deny/plan-mode non-escalation, wrong IDs, EOF pending and fresh/persisted resume.
- Normalization: agent prose, ordinary errors, sandbox failures and already denied Vibe/OpenCode
  records never become pending requests. Unknown tool/child contexts fail closed.
- Durable state: cross-process concurrent answers, duplicate/late answers, stale attempts/session
  owners, PID reuse, cancellation/exit/respond races, every reservation/send/ack crash boundary,
  request bounds, sensitive payload handling and no blind resend.
- Workflow/API: caller isolation, prohibited worker/orchestrator decisions, parallel and nested
  state retention, attention/wait behavior, deadline/disconnect/restart handling and explicit settled
  recovery. Native requests remain unsupported even if their raw transport has IDs.
- Launch compatibility: default-off definitions, unsupported/version mismatch rejection, unchanged
  effective access rules, permission previews, inherited resume policy and capped-mode refusal.
- Actual window-backed Monitor and MCP/CLI tests: approve/reject, racing/stale answers, multiple
  requests, ownership restrictions, light/dark appearance and accessibility.

Run the relevant Python suite, guarded Swift suites, formatting/lint, Monitor build and private
reference guard. Update README, workflow/recovery and harness-permission guides, MCP docstrings
and affected CLI/help contracts with the qualified matrix and distinction between live response
and settled recovery. Fresh code review follows the repository workflow after implementation.

## Decisions and review status

Recommended initial scope is now evidence-based: Claude 2.1.302 only, non-native uncapped Bash
requests under saved `acceptEdits` write/publish access, exact action once, individual request UI,
no other transport substitutions. The 30-minute deadline remains a proposed default requiring
long-held-request qualification. Concrete storage budgets and launch opt-in schema must be fixed
in the implementation contract before production changes begin.

The earlier plan received Astra approval with the ownership clarification. Opus hit its provider
session usage limit without returning findings; the repository exception applies. Astra also approved the updated plan
and certification report with no actionable findings. The primary accepted that review. No findings
were rejected. Storage budgets, the opt-in schema and long-held-request qualification remain
explicit gates before production implementation.

## Implementation contract locked on 18 October 2026

- Launch schema: strictly typed `caller_approvals: bool = false` on standalone tasks and each
  workflow agent candidate, including individually configured fallbacks. Resume/continuation
  inherit it without a public override. Include it in workflow candidate/session compatibility
  signatures. For opted-in candidates only, omit the implicit Claude 100-turn default; explicit
  caps remain invalid. Existing definitions and launches retain their current defaults.
- The opt-in is qualified only for Claude Code 2.1.302, uncapped non-native stream input,
  write/publish access and Bash `can_use_tool` requests. Capability/eligibility is backend-owned.
  Reject incompatible launch settings before spawn. Do not silently replace a selected execution
  contract. Permission previews disclose the policy and any unavailable native preference.
- Standalone interaction ownership defaults to caller. Monitor launches explicitly claim Monitor
  ownership through the verified-human path; workflow tasks inherit their authoritative root owner.
  New standalone owner settings exist solely to route approvals and never elevate task freedom.
- API: `list_approval_requests(task_id?, workflow_run_id?, cursor?, limit=16)` accepts exactly one
  target, limit 1–32, returning bounded metadata and a cursor; `get_approval_request(task_id,
  request_id)` returns the full authorized action; `respond_approval_request(task_id, request_id,
  action_digest, owner_revision, decision, interaction_owner="caller")` accepts approve/reject
  only. CLI exposes equivalent approval-list/get/respond commands and `--monitor` for the verified
  Monitor path. Request IDs/digests/revisions are comparison fields, not bearer authorization.
- Limits per task: 64 KiB canonical request/action payload, 16 outstanding requests, 128 lifetime
  request records, and a 2 MiB serialized ledger. Reserve 256 KiB for decisions and final outcomes
  by admitting new payloads only below 1.75 MiB. List pages contain metadata only. Retain bounded
  full records until normal task retention/deletion; no silent eviction of pending or audit state.
  Full/invalid ledgers fail closed: reject a verifiably correlated new request or cancel the owned
  execution if a safe response cannot be recorded/delivered, and surface attention/uncertainty.
- Use a dedicated cross-process ledger lock; never hold it across awaits or call catalog-locked
  persistence under it. Only the live owning bridge serializes control bytes with ordinary stdin
  writes. Reserve before write; a possibly delivered decision is never retried after owner loss.
- Deadline: 1800 seconds from verified request receipt, shortened by any existing explicit hard
  run deadline. Expose the actual deadline. Qualify a full 1800-second pending/reject probe before
  shipping. While pending, pause bridge inactivity expiry only; hard run limits still apply.
- Process/caller detection uses existing fail-closed mutation authority and ancestry checks, plus
  authoritative workflow receipts/root ownership. Refuse workers/orchestrators regardless of
  supplied flags. Files remain protected by the same OS-user boundary as existing task metadata;
  these controls are not an isolation guarantee against malicious same-user filesystem/process
  tampering. No secret approval credential is passed into worker environments or events.
- Ownership/order: Vibe first owns Python backend/ledger/task/workflow/API/CLI integration and
  documentation. A separate Vibe assignment may own Monitor production sources after the API is
  fixed, without touching Python. `test_writer` owns new Python/Swift tests after coordinated
  interface handoff. The primary owns plan/code adjudication, integration and validation. Agents
  share the checkout, must preserve each other's edits, and must not commit or publish this work.
