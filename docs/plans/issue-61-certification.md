# Issue #61: Installed harness permission transport probes

Measured on macOS on 18 October 2026. The initial sections record transport feasibility probes
performed before production changes. The implementation qualification follow-up below records
the subsequent Claude checks; neither set establishes support beyond its stated scope.

## Method and limits

The initial probes ran the installed executables in temporary projects with isolated
HOME/configuration, synthetic credentials where required, and local fake model APIs. Actions
only targeted temporary marker files. Those initial probes used no paid model calls or real
credentials. Localhost listeners required sandbox escalation; the authorized probe processes
and servers were stopped afterward. The separately documented authenticated Antigravity retry
below used two real model turns after the user logged in and requested a retry.

Approve/reject conclusions require structured request identity, an absent marker before the
response, and an observed tool outcome or filesystem effect afterward. Help text, source inspection,
exit code zero, and an agent's final message are not approval evidence. OpenCode and Vibe both
exited zero after refusing the action, confirming why exit status alone is insufficient.

All results below apply to the listed version, invocation, tool and configuration only. An
alternative server transport is not automatically supported by the shipped Polybridge backend.
Native workflow ownership, production concurrency, restart reconciliation, managed enterprise
policy, all tool types and the proposed 30-minute deadline are not certified by these probes.

## Support matrix

| Harness | Installed version | Existing headless transport | Separately probed transport | Initial implementation disposition |
| --- | --- | --- | --- | --- |
| Claude Code | 2.1.302 | Normal headless invocation denies an ask-only action without a caller response channel. | Stream JSON plus `--permission-prompt-tool stdio --permission-prompts host` emitted `can_use_tool`; correlated allow executed Bash, deny prevented it. | First target: opt-in, non-native Bash requests under `acceptEdits`, retaining saved access rules. |
| Codex | 0.163.0 | Actual `exec` rejected escalation with policy `Never`; changing its config argument to `on-request` still produced `Never`. | `app-server --stdio` emitted `item/commandExecution/requestApproval`; accept ran the marker, decline prevented it. | Existing exec unsupported. App-server is a separate architecture and scope decision. |
| OpenCode | 1.18.21 | `run --format json --agent build` explicitly auto-rejected an ask request; marker absent. | `serve` HTTP retained a correlated pending request; `once` ran the marker, `reject` prevented it. | Existing run unsupported. Server transport deferred. |
| Vibe | 2.26.0 | Programmatic streaming reported an already answered callback with decision deny, then `tool_denied`; marker absent. | Installed source contains another app-server callback interface, but its runtime was not certified. | Existing programmatic transport unsupported; do not surface answered callback as pending. |
| Antigravity (`agy`) | 1.4.2 | Authenticated stream-json retry reached the command, then auto-denied it; structured `denied_actions`, no marker or pending request. | No alternative transport qualified. Requested `accept-edits` still reported `request-review`. | Current observed headless transport unsupported; effective accept-edits behavior and alternative transports remain unqualified. |

## Claude evidence and implications

The affirmative baseline uses JSONL stdin/stdout and these permission control options:

```text
claude --permission-prompt-tool stdio -p --verbose \
  --input-format stream-json --output-format stream-json \
  --permission-mode acceptEdits --permission-prompts host
```

The effective matrix retained Polybridge's direct Git deny patterns for `write_in_repo` and its
Git allow entries for `publish`. Isolation came from temporary HOME/config/project directories;
the matrix did not require `--bare` or suppressing normal setting sources. A deterministic local
API returned Bash calls using `claude-sonnet-4-6`; this does not certify remote model availability.

Representative request, with synthetic identifiers and the observed action shape:

```json
{
  "type": "control_request",
  "request_id": "request-1",
  "request": {
    "subtype": "can_use_tool",
    "tool_name": "Bash",
    "tool_use_id": "tool-1",
    "input": {
      "command": "python3 -c \"open('action-marker.txt','a').write('APPROVED')\"",
      "description": "Write isolated approval marker"
    }
  }
}
```

Allow preserves the complete input payload:

```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "request-1",
    "response": {
      "behavior": "allow",
      "updatedInput": {
        "command": "python3 -c \"open('action-marker.txt','a').write('APPROVED')\"",
        "description": "Write isolated approval marker"
      }
    }
  }
}
```

Reject uses the same envelope with `{"behavior":"deny","message":"PROBE_REJECTED"}`.
Requests also contained suggested local-settings/session changes. The probe applied none of them:
no `updatedPermissions`, permission-rule edits, directory grants or mode changes.

Observed cases:

- Basic approve and reject completed in the same respective CLI process. Reject produced a tool
  error and no marker; allow produced the marker.
- Before a delayed response the process was alive and the marker absent. A response with an
  unknown request ID did not execute the action or kill the process; the correct ID then allowed
  execution. Polybridge must still enforce its own stale and duplicate response rules.
- With the shipped-equivalent `acceptEdits` rules, two identical Bash actions generated two
  distinct request IDs and tool-use IDs. Approving both appended the marker twice. No reusable
  permission grant was established by the first response.
- The `publish` rule variant also prompted twice for the same non-Git action. This does not
  establish that every Git command or access configuration behaves identically.
- Plan mode denied the mutating Python action without a pending request. Explicit Bash deny
  rules and `--permission-prompts none` also prevented a pending request/action. Caller approval
  is not a way to override those restrictions.
- A shell redirection was automatically allowed by `acceptEdits`, while the Python action
  prompted. Do not infer pending permission from command mutability or syntax.
- Closing stdin while the Python action was pending exited zero without running it. Input-pump
  ownership and shutdown are therefore material parts of the implementation.
- Fresh and persisted-session resume each emitted a new request and executed only after a new
  correlated response; the earlier exact-action approval was not remembered. One exploratory
  resume fixture reused a tool-use ID and looped until its 25-second bound; that fixture defect
  was corrected and the fresh/resume sequence rerun successfully. The failed attempt is retained
  separately and excluded from support conclusions.
- `--max-turns 5` with streaming and two approved actions worked. Cap exhaustion and interaction
  with Polybridge's capped one-shot transport are not certified; initial support remains uncapped.

Initial support is limited to Bash because that is the tool whose request/effect pair was probed.
File, MCP, other tool types and additional policy combinations require probes before expanding
the advertised support matrix. The later long-held-request qualification is recorded below.

### Native children

Claude child transport probes emitted `agent_id` on the permission request, plus child tool-use
identity. Parent/child activity carried `parent_tool_use_id`, and the parent Agent result exposed
`agentId`. Approve executed the child's marker; reject prevented it.

This is useful routing evidence, not native adapter certification. In the tested invocation the
installed CLI launched the Agent asynchronously despite no background request. Polybridge's
foreground Claude adapter is pinned to 2.1.295; the installed 2.1.302 is outside that contract.
Parallel children, parent settlement, individual cancellation, nested ownership and restart remain
unqualified. Do not enable native approvals or change that adapter's version pin from this evidence.

## Codex evidence and implications

The current backend-built read-only invocation passed `assert_safe`, contacted only the fake
Responses API, and was asked to execute a temporary marker action with
`sandbox_permissions="require_escalated"`. The tool result rejected it because policy was Never;
no approval event appeared in the exec stream and no marker was written.

A second direct CLI probe changed only the approval configuration argument to `on-request`.
The actual tool result still reported Never. Polybridge's existing validator correctly rejected
that modified invocation. Changing that config argument is not a viable live-approval design.

A separate app-server process used an isolated thread with `approvalPolicy="on-request"` and
`sandbox="read-only"`. Its request included JSON-RPC request ID, thread ID, turn ID, item ID,
command and cwd. The marker was absent and process alive before the response. Returning
`{"decision":"accept"}` executed it; `{"decision":"decline"}` produced an observed
`rejected by user` error and no marker. Both turns completed.

The action explicitly requested escalation, so this is not certification that approval preserves
an unchanged sandbox boundary. The request advertised accept, an execpolicy amendment, and cancel;
decline was accepted in the probe despite not appearing in that advertised list. A future adapter
must reconcile per-request advertised decisions rather than hard-code all schema enum values.
No session approval or policy amendment was selected. Server transport, access disclosure and
scope require separate design; no app-server replacement is proposed for the initial release.

The installed Codex native version also fails the existing adapter's 0.162.0 eligibility pin.
No Codex native approval ownership is certified here.

## OpenCode, Vibe and Antigravity evidence

OpenCode server probes used isolated `serve --hostname 127.0.0.1 --port <ephemeral>`, created a
session, and sent its prompt asynchronously. `GET /permission` returned a request ID, session ID,
command metadata and tool message/call IDs. The same request remained pending after 0.5 seconds
with no marker. `POST /permission/{id}/reply` with `{"reply":"once"}` ran the action;
`{"reply":"reject"}` did not. The pending request disappeared afterward. Server authentication,
remote exposure, competing clients, cancellation, restart, repeated-action scope and native-child
ownership remain uncertified. The server's broader `always` suggestion was not selected.

Vibe's final probe used the installed Bash schema with only a command argument, the `accept-edits`
agent, streaming output and a three-turn cap. The callback record already had
`state.status="answered"` and an approval decision of deny; the following failed effect had code
`tool_denied`. Installed programmatic consumer source immediately calls `deny_callback` for
`CallbackRequested`. An already completed callback must never be exposed as an actionable request.

The first Antigravity probe used an empty HOME and no credentials. It exited one with
`authentication failed or timed out`, `num_turns: 0`, and zero usage. That initial result did
not establish runtime permission behavior.

### Authenticated Antigravity retry

After the user logged in and requested a retry on 18 October, two bounded real model turns used
the normal CLI login in place. Credentials were not inspected, copied or printed. Each CLI had
a fresh temporary working directory, one exact marker command, stream-json input/output and
`--disable-slash-commands`. No permission configuration was changed, no bypass flag was used,
and no remote-control daemon was started. Normal CLI-owned session cache writes were permitted.

Both default-mode and explicitly requested `--mode accept-edits` invocations reached
`run_command` with the exact temporary marker command. Both terminal results contained:

```json
{
  "status": "SUCCESS",
  "response": "",
  "num_turns": 1,
  "denied_actions": [{"action": "command", "display_name": "RunCommand"}]
}
```

Both stderr streams explicitly stated that headless mode could not prompt for the command
permission and auto-denied it. Neither marker existed. Stdin remained open through the terminal
result and two additional seconds; both processes were alive at that observation. They exited
zero after EOF. The denial therefore preceded EOF and was not an artifact of premature shutdown.
There was no pending request ID or correlated decision exchange to answer.

The default run's tool step reported DONE despite the denial, while the second reported ERROR.
`result.denied_actions` and the absent effect, not step state or process success, establish the
permission outcome. The second run's init event still reported `permission_mode: request-review`
despite the `--mode accept-edits` argument. Do not claim that effective accept-edits behavior was
certified. This discrepancy is retained as evidence, not repaired or bypassed in this task.

The current observed stream transport is already denied, not a live approval candidate. This
result does not prove that no alternate Antigravity transport can support permission decisions.
Remote-control, native-child ownership, policy variants and restart behavior remain unmeasured.
The authenticated evidence is retained separately under `antigravity-auth/` in the local bundle;
these two real turns are distinct from the initial no-paid-call probe set.

## Evidence retention and remaining qualification

The local evidence bundle retains probe scripts, synthetic API request bodies, sent responses,
stdout/stderr and result summaries grouped as `claude/`, `codex/`, and `other/`. It excludes runtime
homes, credential/configuration stores, caches and binary installations. Its manifest records
SHA-256 hashes. Scripts are probe snapshots, not production test runners; use fresh temporary
roots when replaying them and retain their localhost/provider isolation.

Before shipping the first adapter, turn the successful Claude experiments into version-gated CLI
regression fixtures, then qualify actual Polybridge launch/resume/control-pump behavior. Still
required: caller authorization, concurrent cross-process decisions, replay/duplicate protection,
process-exit and cancellation races, durable send uncertainty, deadline enforcement, request bounds,
sensitive arguments, and real MCP/Monitor end-to-end validation. None of those product guarantees
is established by a standalone transport probe.

## Claude implementation qualification follow-up

The subsequent implementation uses the qualified transport only for Claude Code 2.1.302,
uncapped non-native Bash requests at `write_in_repo` or `publish`. The earlier feasibility
results above describe the pre-implementation probes.

An isolated root-owned probe held one real CLI permission request for **1800.097 seconds**.
Thirty periodic observations found the process alive and the marker absent. The probe then
sent an explicit correlated reject, observed the corresponding error tool result, and retained
an absent marker through exit code zero. This qualifies the harness's ability to keep the
request pending for the bridge's deadline; production expiry behavior is separately covered by
deadline and delivery-race tests. An earlier controller-interrupted hold was excluded and its
orphan process stopped before the successful probe began.

Version-gated no-paid-call fixtures now exercise actual Polybridge `TaskRegistry` start with
approve and reject, plus persisted-session resume with a fresh approval request. They verify
exact input, absence of effects before approval, correlated outcomes, and preserved session
identity and opt-in after resume. They use the installed CLI and a localhost fake Anthropic API.
The standalone probe evidence is retained in `claude-longhold/` in the local evidence bundle.

Unit coverage additionally exercises caller and workflow ownership, stale revisions, competing
cross-process reservations, bounded storage, pagination, cancellation, uncertain delivery,
deadline crossings, and the public MCP list/get/respond wire contract. These checks do not
extend support to another tool, version, transport or native child.
