# Monitor performance baselines

Issue #23 starts with measurement, before selecting a transport, cache, or catalog optimization.
These tools use synthetic history and never dispatch agents. Monitor remains a consumer of the
existing versioned CLI contracts.

## Reproduce the CLI baseline

From the checkout, after `uv sync`:

```bash
.venv/bin/python scripts/benchmark-monitor.py --size small --repeats 5 --output /tmp/monitor-small.json
.venv/bin/python scripts/benchmark-monitor.py --size large --repeats 5 --output /tmp/monitor-large.json
```

Each repeat uses a new temporary home. The small fixture contains 12 definitions, 24 runs,
12 nested runs, and 32 task records. The large fixture contains 240 definitions, 400 runs,
200 nested runs, and 1,200 task records. A separate malformed-history fixture exercises blocked
catalog preparation without changing permissions. IDs and timestamps are deterministic.

The runner launches the checkout interpreter and real CLI readers, measures whole scenarios and
each process, and records raw samples alongside nearest-rank p50/p95. Five samples provide a
descriptive baseline; their p95 is the maximum, not a stable tail estimate. Catalog-cold means a
new derivative catalog, with filesystem caches left intact. Later reads have warm catalog/OS
caches but still launch fresh CLI interpreters. These are CLI scenarios, not app launch or
rendering latency. The worker supplies synthetic human ancestry to avoid host process-table
permission variability; it rejects commands outside its read-only allowlist.

## Profile the actual app

```bash
macos/build-app.sh
.venv/bin/python scripts/benchmark-monitor.py --size large --fixture-home /tmp/monitor-fixture
.venv/bin/python scripts/profile-monitor.py --app 'macos/build/Polybridge Monitor.app' \
  --home /tmp/monitor-fixture --output /tmp/monitor-profile --seconds 30 --sample
```

Use a new fixture home and empty output directory. The fixture creates restricted CLI wrappers
and a versioned marker required by the profiler. The profiler copies and signs a temporary app
with a unique bundle identifier and removes its URL registration. It pins the tool directory,
isolates history and drafts with `HOME`, disables finish notifications, and terminates only its
own app process. It does not install the app or stop an existing Monitor.

Interact with the isolated window during the observation interval to open and reopen workflows,
switch workflows, and request older history. Record interactions separately. The harness itself
does not automate selection or determine pixel readiness. Leave unchanged polling visible for at
least 12 seconds to include the two-second workflow and ten-second task safety polls. `--sample`
captures stacks in a second launch; use that run for diagnosis rather than latency comparisons.
For Instruments, attach Time Profiler or SwiftUI to the isolated PID, without changing personal
profiling permissions. Record any unavailable capture explicitly.

## Opt-in instrumentation

`POLYBRIDGE_MONITOR_METRICS=1` enables version 1 JSONL records on the app's stderr. The default
is disabled. Labels are fixed: `transport`, `decode`, `workflowLoad`, `workflowReconciliation`,
`workflowViewUpdate`, `sidebarViewUpdate`, `sidebarContentReady`, and `workflowContentReady`.
Records contain monotonic timestamps, elapsed milliseconds, stdout/stderr byte counts, and the app's resident-memory high-water mark. They
exclude commands, identifiers, paths, prompts, and answers. Readiness markers mean populated
state has been applied, not that pixels have rendered. The profile harness derives first useful
sidebar state from the first readiness timestamp relative to its monotonic launch origin.
One transport record represents one CLI invocation attempt, including failures.

Workflow load includes waiting for reads; reconciliation and view-update durations measure
specific internal work. View updates do not establish that pixels have appeared. RSS sampled
by the profiling harness is a lower bound on the peak; app instrumentation uses `getrusage`.
Synchronous stderr recording has overhead outside the measured interval, so compare equivalent
instrumented runs and use separate profiler captures to investigate main-thread stalls.

The CLI runner measures catalog bootstrap separately and parent-side JSON decoding; those
measurements are not Swift decoding or SQL-only timings. Process startup/import overhead is
included in wall time. A blocked response is a terminal diagnostic, not a completed load.

## Baseline and next-stage targets

Measured on 8 October 2026 (Asia/Jakarta), macOS 26.6.2 (25G83), arm64,
Python 3.13.5, release Monitor built from `11118f6` plus this measurement change.
Other desktop apps remained running. Exploratory profiling overlapped builds/tests; the
repeated CLI baseline ran after the full suites/builds finished, with a brief new-test run
and isolated app observation overlapping early samples. This is a developer-workstation
baseline, not a controlled hardware comparison. A production Monitor was observed using
approximately one CPU; it was left untouched.

Raw results: [small CLI](benchmarks/monitor-2026-10-08-small.json),
[large CLI](benchmarks/monitor-2026-10-08-large.json), and
[app readiness and timing records](benchmarks/monitor-2026-10-08-app.json).

CLI scenarios have five repeats. Times are milliseconds; bytes include stdout and stderr.
The cold-launch label in raw data means the initial workflow inventory CLI sequence,
not the entire app launch. Cold task inventory follows that sequence. Warm reopening
models an already cached snapshot by requesting status only; actual cache reuse was also
observed in Monitor. The runner does not implement Swift cache eviction or rendering.

| CLI scenario | Small p50 / p95 | Large p50 / p95 | Processes small / large | Median KiB small / large |
|---|---:|---:|---:|---:|
| Catalog-cold workflow inventory | 1298 / 2216 | 11931 / 16084 | 2 / 16 | 47.7 / 179.5 |
| Task inventory | 125 / 140 | 200 / 228 | 1 / 1 | 21.4 / 66.2 |
| Task summary | 128 / 135 | 553 / 664 | 1 / 1 | 2.0 / 2.0 |
| Saved workflow editor read | 675 / 758 | 1225 / 1405 | 1 / 1 | 1.2 / 1.2 |
| Cold run snapshot + index | 2553 / 4308 | 4053 / 4630 | 4 / 5 | 380.7 / 469.5 |
| Warm run status | 614 / 1021 | 667 / 711 | 1 / 1 | 5.0 / 5.0 |
| Switch run snapshot + index | 1329 / 1752 | 1406 / 1766 | 2 / 2 | 4.8 / 4.8 |
| Unchanged run poll | 683 / 945 | 718 / 793 | 1 / 1 | 5.0 / 5.0 |
| All workflow history pages | 599 / 1304 | 2839 / 6104 | 1 / 4 | 47.1 / 686.4 |
| Terminal blocked history | 112 / 169 | 131 / 140 | 1 / 1 | 1.8 / 1.8 |

The final app startup observations (one launch per size) reached populated sidebar state
in **5,198 ms small / 12,049 ms large**. Observed peak RSS was **117.2 / 150.7 MiB**.
Small observation lasted 15 seconds (12 ctl attempts, 159.8 KiB); large lasted 45 seconds
(41 ctl attempts, 2,937.3 KiB). Counts exclude tool discovery, login-shell, and setup processes.
App p50/p95 launch latency is not established by these single observations.

The final small-fixture run graph and nested child link were verified through the actual app.
Its first run load measured 3,867 ms at the internal load boundary; cached reopening showed
the complete graph in an 880 ms accessibility observation, including automation overhead.
Search by fixture ID disambiguated otherwise identical run titles for that reopening.
Earlier editor and run-selection checks also reached the expected canvas. Large-fixture
detail switching was not timed reliably through accessibility; its CLI sequences are in the
table, and the app startup/polling capture is separate.

### Ranked observations

1. **Repeated workflow reads are material.** Large initial inventory required 16 CLI
   processes and about 12 seconds median. Cold run opening required five processes and
   about four seconds. Small warm status spent about 614 ms despite transferring only
   5 KiB; current digest reuse already avoids the cold snapshot transfer.
2. **Large sidebar main-thread work deserves a separate investigation.** The final large
   startup capture recorded a 2,013 ms sidebar recomputation, versus 9.5 ms small; maximum
   decoding duration was 49 ms large. A separate 10-second stack sample recorded 649 of
   911 main-thread samples under SwiftUI view-graph transaction flushing, including sidebar
   row evaluation. A 15-second Instruments Time Profiler capture completed successfully.
   Exploratory captures also recorded much longer intervals under concurrent activity;
   those are not used as stable latency targets. These observations do not establish the
   cause of the original intermittent stall or a rendered-frame hitch count.
3. **Do not infer SQL dominance from these timers.** Catalog bootstrap is only one catalog
   boundary, not all SQL/file reads. In small initial inventory its median aggregate was
   24 ms out of 1,298 ms elapsed. Small cold-run parent JSON decoding totaled about 0.6 ms.
   Attribution among interpreter imports, server initialization, other metadata reads, and
   round trips needs a focused follow-up before choosing IPC or indexes.

### Targets for the optimization stage

- Same fixtures and comparable host load: initial workflow inventory p95 at most **1,550 ms
  small / 11,250 ms large** (roughly 30% below this baseline).
- Cold run snapshot plus index p95 at most **2,600 ms small / 2,800 ms large** (roughly 40%
  below baseline); warm status and unchanged poll p95 at most **500 ms**.
- Actual first populated sidebar state: **2,500 ms small / 6,000 ms large**, established
  with at least ten app launches before claiming tail latency improvements.
- Main-actor sidebar recomputation p95 at most **100 ms** on the large fixture. Preserve
  immediate valid cached run display, bounded history/memory, immutable page revisions,
  preparation/blocked semantics, selection, scroll, ownership, and cancellation guards.

These are proposed acceptance targets for the next stage, not achieved results. Reprofile
the highest-ranked paths and review the optimization choice before implementation.

## Validation record

- New Python benchmark/profile tests: **9 passed**; include complete runner execution,
  deterministic fixtures, real task summary replay, nested-link consistency, preparation,
  blocked completion semantics, pagination, and mutation rejection.
- All nine Swift package suites passed. After readiness-marker edits, MonitorCore
  **208 tests** and MainWindowFeature **800 tests** passed again.
- Release app build and signing verification, SwiftFormat (no changes), SwiftLint
  (zero violations), private-reference guard, and whitespace checks passed.
- Full Python suite: **5 failed, 5,972 passed, 327 skipped**. All five failures were timeout
  assertions in unchanged workflow tests. A separate rerun passed three and timed out two:
  `test_serial_worker_cap_never_blocks_barriers[True]` and
  `test_implicit_convergence_loop_uses_separate_activation_generations`. Python server
  source is unchanged; no timeout assertion was relaxed. The full suite is not green.
- Independent methodology and code reviews found missing index reads, malformed task
  associations, missing summary streams, unsupported getter flags, and parser robustness
  gaps; the harness corrections were applied and the new tests rerun.

Instruments traces and complete stack reports remain local under `/tmp/polybridge-issue23`:
they contain environment/device metadata and are not included in the repository. Numeric
records above contain no prompt or answer content. Issue #23 remains open for optimization.

## Sidebar background presentation stage

This stage changes sidebar computation and rendering publication; CLI reads and transport remain
unchanged. Sidebar source snapshots are separate from observed presentation. A detached utility
worker builds immutable presentation values and shared indexes; the main actor compares complete
presentation fields before applying changes. Clock inputs remain explicit, and command/reveal
notifications retain their event semantics.

Additional opt-in numeric stages distinguish `sidebarPreparation`, `sidebarBuild`, `sidebarApply`,
`sidebarScheduling`, and `sidebarUpdateLatency`. Scheduling measures latest-input enqueue to
detached worker entry, including a pending worker wait. Build records include numeric `background_thread`; apply records
include `rendering_writes` (changed presentation-field assignments, not SwiftUI frame counts).
These records still contain no task IDs, paths, prompts or answers. Background elapsed work,
main-actor work, scheduling delay and pixel rendering are different boundaries.

For repeated actual-app observations, preserve a pre-change build and run ten fresh synthetic
homes per fixture size for each build. For example, substitute `before` or `after` for the label
and use the corresponding built app path:

```bash
label=after
app="macos/build/Polybridge Monitor.app"
for size in small large; do
  seconds=18
  if [ "$size" = large ]; then seconds=45; fi
  for repeat in $(seq 1 10); do
    home="/tmp/monitor-sidebar-$label-$size-$repeat-home"
    output="/tmp/monitor-sidebar-$label-$size-$repeat-profile"
    .venv/bin/python scripts/benchmark-monitor.py --size "$size" --fixture-home "$home"
    .venv/bin/python scripts/profile-monitor.py --app "$app" \
      --home "$home" --output "$output" --seconds "$seconds"
  done
done
```

Use distinct fresh paths for the second build. Keep builds/tests and UI automation out of the
latency observation interval where possible, and disclose any overlap. Profile interactive
search, selection, disclosure, pagination and unchanged polling separately from the launch series.

Sidebar history now loads automatically when its trailing row enters the actual List viewport.
Each source allows one request at a time. A new applied content revision requires fresh layout
before another page; unchanged cursors, preparation, blocked catalogs and errors stop automatic
paging. Retry stays explicit. Search and backend filters still apply to loaded history, and
automatic loading can continue while they are active. Closing the window cancels requests and
clears cursor claims so reopening can retry the same page. Activity-log pagination is unchanged.

### Before/after observations

Raw numeric records and executable hashes are in
[the sidebar comparison](benchmarks/monitor-2026-10-08-sidebar.json). Each build has ten launches
per size. Small homes contain 12 saved definitions, 24 runs (12 nested), and 32 tasks;
large homes contain 240 definitions, 400 runs (200 nested), and 1,200 tasks. These launch
observations exercise first-page inventory and unchanged polling, not exhaustive history.
Small launches run for 18 seconds; large launches run for 45 seconds. An earlier 18-second
large baseline omitted prepared workflow inventory and is excluded. The fresh synthetic
catalogs used warm filesystem caches on macOS 26.6.2 arm64, Python 3.13.5, release builds.
Before observations overlapped builds/tests; after observations did not. Other desktop apps,
including a production Monitor using about one CPU, remained running.

All quantiles below use nearest rank over the recorded stage events pooled within ten launches.
They describe this sample, not stable tail estimates. The old `sidebarViewUpdate` combines
synchronous building and application; it is not the same boundary as any single new stage.

| Boundary (milliseconds, p50 / p95) | Small before | Small after | Large before | Large after |
|---|---:|---:|---:|---:|
| Old synchronous sidebar update | 0.072 / 10.475 | — | 0.031 / 2061.010 | — |
| Main-actor snapshot/preparation | — | 0.023 / 0.088 | — | 0.032 / 0.236 |
| Background build | — | 0.359 / 0.670 | — | 1.159 / 12.198 |
| Main-actor comparison/application | — | 0.026 / 0.100 | — | 0.048 / 2.569 |
| Queue to worker entry | — | 0.016 / 0.244 | — | 0.020 / 0.360 |
| Capture to applied state | — | 0.868 / 55.646 | — | 2.454 / 48.508 |
| Launch to first populated state | 3722 / 4145 | 3517 / 3692 | 12056 / 14412 | 10492 / 10588 |

Large background-build p95 **12.198 ms** meets the **100 ms** target; its observed maximum
was 13.418 ms. A conservative combined main-actor bound is the sum of the largest preparation
and application events: **3.700 ms large / 0.205 ms small**, below the **16 ms** target.
This bounds every measured pair without adding separate p95 values. Queue p95 is 0.360 ms
large (maximum 3.949 ms). End-to-end state publication includes additional main-actor waiting;
its large maximum was 70.114 ms. None of these boundaries measures displayed frames.

All 170 large and 101 small build records reported background execution. Of completed
applications, **136/166 large and 70/100 small wrote zero presentation fields**. Clock or
source changes can legitimately write; zero writes is a presentation assertion, not a count
of SwiftUI frames. Cancellation explains the difference between build and application counts.

Sampled peak RSS p50/p95 was 150.6/169.5 MiB before and 154.5/168.8 MiB after for large;
125.6/130.4 MiB before and 126.0/126.3 MiB after for small. Sampling every 100 ms yields a
lower bound, not a proven peak. Large transport-attempt median increased from 35 to 58
within the fixed observation window (small 22 to 26); This is consistent with more existing polls completing in the window;
reduced UI blocking is an inference, and the counts alone do not establish its cause. The repeated workload is therefore not a fixed number of CLI requests,
and these counts do not show a transport optimization. Large median transferred KiB was
2258 before / 5411 after; small 305 / 370. No CLI command or response shape changed.

The measured sidebar bottleneck is substantially reduced and moved off the main thread.
Remaining priorities are CLI/catalog loading and unrelated main-actor work; startup still
spends several seconds before useful state. The broader startup target remains unmet.
Issue #23 stays open until subsequent loading work has reproducible regression evidence.

### Interactive profiling and validation

A separate isolated large-fixture app session exercised search, switching between older tasks,
workflow expansion/collapse, and bottom-triggered loading. Scrolling appended older history;
a short unmatched filter continued loading until both sources displayed their end labels.
Searching then selected task 1 from the older pages, and switching selected task 10. Expanding
a workflow revealed its child shortcut; collapsing removed it. Synthetic tasks intentionally
have no activity events, so their detail pane reports empty/missing activity.

Two 20-second `sample` captures used 10 ms and 1 ms intervals, separately from the launch
series. The action capture placed `SidebarPresentationBuilder.compute/build/prepareIndexes`
on `com.apple.root.utility-qos.cooperative`; main-thread conversation indexing in that capture
belonged to `MenuBarVM.recompute`, outside this stage. During the longer, sampled interactive
session after loading more history, background build p95 was 33.989 ms (maximum 94.883),
main-actor preparation maximum 1.021 ms, and application maximum 3.877 ms. End-to-end
publication maximum was 290.169 ms. This perturbed session is exploratory, not another
latency series or a frame-stall measurement. Accessibility observations include automation
overhead and are not used as UI latency measurements.

Final verification: MainWindowFeature **820 tests**, MonitorCore **210**, PbUI **113**,
MenuBarFeature **55**, and app target **95** passed with serialized Swift tests. The Python
benchmark/profile tooling tests passed **9 tests**. SwiftFormat completed, SwiftLint reported
zero violations across 507 files, private-reference guard and whitespace check passed, and
an isolated release app built and verified its signature. The earlier full Python suite's
baseline failures remain documented above; no Python production behavior changed here.
Independent read-only Codex review found a canceled-pagination/reopen cursor claim defect;
it was fixed and covered for both history sources, then the final suites were rerun. The
second code-review pass found no further actionable defects. The final numeric review independently recomputed all reported quantiles, counters,
and bounds from the raw records and found no blocking findings. Its wording feedback
was applied to distinguish observed transport counts from a causal explanation.

The actual app's initial scrollbar reading changed during disclosure/layout settling. A
subsequent attempt to measure prolonged settled scroll stability was inconclusive: accessibility
observation stalled until the timed isolated app had exited (one tool call took about 746 seconds).
This is automation observation overhead, not a measured app interaction latency. Bottom paging,
older-task selection, and nested disclosure were verified before that failure; prolonged scroll
stability is supported by the passing serialized AppKit regression, not a reliable later UI
measurement. No stable frame-stall distribution or exact pixel latency is claimed.
