# Issue #61: Claude implementation validation

Date: 18 October 2026. Branch: `codex/claude-caller-approvals`.

## Implemented scope

Opt-in exact-action Bash caller decisions for Claude Code 2.1.302, non-native uncapped
`write_in_repo` and `publish` tasks. Standalone tasks and workflow candidates persist the
setting; resumed sessions inherit it. MCP and CLI provide metadata listing, full inspection,
and revision-bound approve/reject responses. The Monitor exposes opt-in settings and individual
request inspection, with decision controls only for Monitor-owned requests.

The adapter preserves the existing permission mode and access rules. It does not install
reusable grants, support another backend, override sandbox restrictions, or enable native-child
approval. Process delivery and observed execution remain separate facts.

## Completed checks

- Version-gated installed-CLI fixtures: start approve/reject and persisted-session resume,
  using a localhost fake Anthropic API with no paid provider calls.
- Real CLI pending request held for 1800.097 seconds, followed by an explicit correlated reject:
  process remained alive, marker remained absent, rejection observed, exit zero.
- Approval and ownership regressions: exact payloads, stale revisions, cross-process decision
  reservation, deadline/send/result races, cancellation, uncertain delivery, bounded storage,
  active-first pagination and public MCP wire validation.
- Integration regression fixes: 412 tests passed; approval and wait regressions: 122 passed.
- Final full no-model Python regression: **7801 passed, 285 skipped, 55 deselected** in 688 seconds.
- Final installed-Claude start/approve/reject/resume fixtures: **3 passed** in 4.42 seconds.
- Guarded `PbRepository` Swift package: 289 tests passed in 30 suites.
- Guarded `MonitorCore` Swift package: 246 tests passed.
- Final MainWindowFeature coverage: **1281 tests in 171 suites passed** against fresh discovery.
  Four affected suites were rerun through the repository guard; the recorded event streams and
  stdout for 167 unchanged suites were revalidated against the current exact identities.
- Hosted approval controller tests: 8 passed. Window capture/accessibility test: 1 passed,
  including an actual accessibility press delivering exactly one response, caller-owned
  read-only presentation and long-command horizontal overflow. The primary inspected fresh
  2880 by 1800 light, dark and caller-owned window captures.
- MainWindowFeature debug build and Monitor release app build passed. The local app signature
  passed strict verification. The app was not installed.
- Changed production Swift files passed SwiftLint. SwiftFormat reported no changes under the
  repository configuration. Python compilation, private-reference guard and diff checks passed.

The broad MainWindowFeature run exposed outdated candidate-default expectations and a standalone
bar accessibility-label expectation. The candidate assertions now reflect the reviewed implicit
cap contract; an additional test protects the explicit-cap behavior. The standalone-bar fixture
now uses the existing production label while retaining its geometry assertions. The initial
guarded rerun correctly rejected a discovery/execution mismatch after the cap test was added.
Fresh discovery and exhaustive partition validation resolved that bookkeeping mismatch; no test
was silently omitted. Post-formatting compilation and the affected guarded suites also passed.

## Review and execution

The reviewed plan includes the locked implementation contract in
[`issue-61-permission-escalation.md`](issue-61-permission-escalation.md). Astra code review
identified three valid issues: a delivery/outcome race, approval crossing expiry during awaits,
and missing attention for uncertain delivery. All were accepted and corrected; none were rejected.
The second review found no new actionable issues. Final review also approved the subsequent
test/documentation updates, including the unchanged baseline label and explicit-cap regression.
All validation gates are complete; no actionable review findings remain.

Claude Opus reached its session usage limit earlier in this task; remaining Opus reviews were
skipped under the repository's explicit exception. Vibe failed before editing with
`billing_vibe_budget_exhausted`; implementation used the prescribed native fallback. Dedicated
test writers produced the regression tests. Validation did not install the application or change
the installed Polybridge service.

The local evidence bundle groups transport probes, `claude-longhold/` and completed validation
logs under `implementation/`. Its manifest records hashes; runtime homes and credentials are
excluded. Transport evidence and its limits are described in
[`issue-61-certification.md`](issue-61-certification.md).
