# Draft: Monitor intermittent stall

Status: bounded history implementation and final review fixes verified by backend and native tests, release build, isolated fixture measurements, and completed multi-turn activity, sidebar paging, and late-file Summary recovery checks. The original intermittent stall remains unconfirmed; no causal hang fix has been identified.

## Observation

On 2026-10-05 (Asia/Jakarta), the user reported that Monitor appeared hung for approximately one minute, then recovered without intervention while a workflow was running.

A read-only process snapshot during the report showed the installed Monitor process alive: PID 30445, state S, CPU 34.6%, memory 1.3%, elapsed 02:25:08. This single observation does not establish a main-thread block or its cause. No hang sample was captured before recovery.

## Later investigation

- Capture a process sample during the next stall before restarting.
- Record the visible view, active run size, interaction that preceded the stall, and whether scrolling or the entire app stopped responding.
- Distinguish main-thread rendering/decoding work from CLI loading, snapshot pagination, and competing system load.
- Profile with an isolated copy of run data; preserve live workflow execution and saved state.
- Reproduce before implementing a fix. Do not infer the cause from CPU usage alone.

## Proposed task and activity pagination

Implementation is authorized by the approved development plan. Missing pagination remains a hypothesis, not a confirmed cause of the reported stall. Existing offset-based workflow history sliced only after decoding its run collection; activity tails seeded from the complete file. The new paths separate live records from retained historical pages and use bounded cursor reads.

- Initially load a bounded chunk of sidebar tasks rather than all historical tasks.
- Show a **Load more** button when another chunk is available. Each click loads only the next chunk, not the entire remaining history; support repeated incremental loads.
- Apply the same pattern to activity history: initially load a bounded recent chunk and let **Load more** retrieve the next older chunk. Do not turn an existing **Show all steps** action into an unbounded fetch/render.
- Pagination must bound backend retrieval, decoding, and rendered content; hiding already-loaded records alone does not satisfy the proposal.
- Preserve stable ordering and deduplicate identities when live updates arrive between pages. Use cursor/snapshot semantics appropriate to changing data rather than relying on shifting offsets.
- Preserve workflow/parallel grouping. Child history should load incrementally without flattening groups or losing their parent relationships.
- Keep active task updates and new activity live while older history remains paginated. Follow live must not fetch all history or jump the user's position while older pages load.
- Preserve loaded pages and scroll position across ordinary refreshes; reset pagination deliberately when filters or the selected task change. Provide loading, error/retry, and end-of-history states.
- Choose chunk sizes after measuring representative large task and activity histories. Test repeated loads, live inserts, filtering, grouped children, duplicate prevention, and navigation/scroll stability.

Verification uses temporary stores and an isolated Monitor copy. The cancelled workflow and production history remain untouched.

## Activity reader measurement

An isolated 100,000-record, 107,088,890-byte activity fixture returned three successive 100-event pages in 6.62, 6.61, and 6.41 ms. Each read consumed 1,000,256 bytes including integrity anchors and decoded exactly 100 records; traced peak allocation was 1,294,507 bytes. These Python retrieval measurements do not establish native rendering performance or the cause of the original stall. Native release-mode measurements on a 100,000-unique-edit fixture (approximately 105 MB) returned three 100-event pages in 5.94, 5.33 and 5.27 ms. Actual reads were 1,048,960, 1,049,024 and 1,049,024 bytes including snapshot anchors. Cumulative indexing retained 100,000 edit counts and path entries, published only 100 file entries initially, and completed 1,588 bounded batches in 3,782.94 ms. Each batch attempted at most 100 records.

The measurement exposed repeated forward reads of unused 1 MiB windows and rebuilding the entire file projection each chunk. Summary bootstrap now reads 64 KiB chunks, retains a compact mutable accumulator, publishes at most ten times per second, and exposes another 100 file entries per explicit Load more files action. These changes address measured large-fixture work; they are not a diagnosis of the original intermittent stall. The isolated UI checks below supplement these measurements. Final post-fix checks passed: 5,500 backend tests, 322 opt-in integration tests skipped, and 1,491 tests across all nine native packages. Format, lint, private-reference guard, and signed release build passed.

## Sidebar measurement and remaining boundary

A 1,000-record temporary Python catalog returned three 100-record pages in 44.18, 21.03,
and 15.13 ms (approximately 66.3 KiB each); JSON encoding took 0.22–0.39 ms and decoding
0.22–0.48 ms. These debug measurements overlapped native compilation.
The native debug fixture contained 1,000 headers with nested parents and shared sessions.
A 100-row page plus ten ancestor headers (42,550 bytes) took 0.036–0.079 ms to read,
11.88–13.22 ms to decode, and 1.58–4.75 ms for the actual conversation grouping and Sidebar
view-model computation. Grouping all ten explicitly loaded pages took 12.37–12.93 ms.
Optimized benchmark builds hit a compiler crash in a third-party dependency, so these sidebar
figures are explicitly debug measurements. Native activity measurements above used release mode.

The isolated release app launched under a temporary HOME and issued bounded task/workflow
page calls. With the Mac unlocked, the actual conversation UI exposed a protocol-extension
default-argument dispatch bug: the task detail adapter selected the unsupported fallback rather
than the concrete session paging implementation. The adapter now passes the page limit explicitly,
and a real adapter/protocol/CLI regression verifies the session, cursor, limit, and related-member
lookup. This is a confirmed paging error, not evidence of the original intermittent stall.

The corrected release app loaded the recent 100 activity events (99 rendered steps after tool
call/result pairing) and one older 100-event page (199 steps). Initial selection to observed UI
was 1,291 ms, and Load more to observed UI was 893 ms. These durations include native automation
and accessibility observation overhead; they are not pure frame or render timings. Follow live
stayed off, and the visible activity remained around event 099903 after the prepend. The Mac
locked again before further checks on that build. The final post-fix checks below supersede that
paused activity verification. No original minute-long stall was reproduced or sampled; it remains
unconfirmed.


## Selected workflow transport follow-up

Review identified two additional loading costs: changed workflow digests triggered another full
snapshot, and each snapshot continuation reread and hashed the entire cached payload. Changed
polls now retain compact status and request only changed views and executions. Initial snapshots
seed the field cache; execution identities are reused only after their captured index digest is
verified. A changing index leaves the valid frozen snapshot visible for a later retry.

Monitor-only detail pages share the immutable snapshot transport. Each continuation reads at
most a 128 KiB chunk, a 4 KiB receipt plus one overflow sentinel byte, and a 32-byte page hash.
The receipt binds run, view, digest, and file identities; replacement, truncation, and in-place
modification invalidate the cursor. Continuations do not reload the durable run. Public detail
callers retain their existing semantics.

An isolated 5,242,923-byte snapshot required 40 continuation pages, using a fresh provider module
for each page. Median continuation time was 0.222 ms and maximum was 0.608 ms; the read ceiling
was 135,201 bytes per page. These direct Python provider timings exclude CLI startup and native
rendering. A regression verifies linear total reads, and native tests verify changed-summary,
changed-execution, status-only, and stale-bootstrap behavior. The isolated ParentFlow UI passed
initial snapshot/index loading. Updating only the temporary
fixture's technical plan and update time made the plan disclosure show the new text; CLI calls
confirmed only the technical-plan detail view was fetched, without a second root snapshot.
Opening the child showed its own canvas, assignment, plan, owning session, and nested sidebar;
the parent breadcrumb returned to the preserved parent plan. These checks establish changed-view
and navigation behavior, without measuring pure rendering latency or diagnosing the original stall.


## Final review fixes and isolated UI verification

Three final review findings were fixed and reviewed independently with Codex. Cancellation now
signals live tasks inside a terminal child run while preserving that run's recorded failure.
Activity paging checks every loaded conversation turn before opening another turn or advancing
session history. Summary leases retry missing or temporarily unreadable logs once per second,
using the last successful cursor and preserving cumulative counts and expanded file projection;
releasing the final lease cancels the queued retry.

The final isolated release UI used two conversation turns with 120 events each. Repeated activity
loads showed 100, 120, 220, and 240 steps, reaching both turns. These multi-turn checks did not
capture separate action timings. On the earlier 100,000-event single-turn fixture, initial
selection, the first older page, and the second older page took 1,150, 2,026, and 2,748 ms to the
observed accessibility state. The sidebar's second page load took 10,642 ms; scrolling back to
the top and observing accessibility state took 17,133 ms. These are automation-inclusive
action/observation durations, not pure rendering measurements or a diagnosis of the slow actions.
A Summary initially reported an unavailable
event file; creating an isolated fake Edit event changed it to one edited file,
`late-summary-proof.swift`, on the same lease without reselection. Production history and saved
workflows were preserved.

A later 15-second process sample of isolated app PID 60867, taken during a fast parent selection,
contained 11,967 main-thread samples; 10,835 were in Mach wait (approximately 90.5%). This sample
was taken after the slower actions and does not diagnose them or the original minute-long stall.
The original stall was not reproduced.

Final post-fix validation: 5,500 backend tests passed and 322 opt-in integration tests were skipped.
All nine native package builds/tests passed with 1,491 tests (17, 102, 19, 206, 237, 697, 55, 63,
and 95). Format, lint, private-reference guard, and signed release build passed. Publication and final-head
CI/review results are tracked in PR #3.
