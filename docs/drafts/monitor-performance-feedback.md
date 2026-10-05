# Draft: Monitor intermittent stall

Status: bounded history implementation verified by backend and native tests, release build, and isolated fixture measurements. Interactive paging and scroll checks remain pending because the Mac is locked. The original intermittent stall remains unconfirmed; no causal hang fix has been identified.

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

The measurement exposed repeated forward reads of unused 1 MiB windows and rebuilding the entire file projection each chunk. Summary bootstrap now reads 64 KiB chunks, retains a compact mutable accumulator, publishes at most ten times per second, and exposes another 100 file entries per explicit Load more files action. These changes address measured large-fixture work; they are not a diagnosis of the original intermittent stall. Isolated UI smoke and final delivery verification are pending.

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
page calls. Interactive rendering, Load more and scroll-anchor smoke remain pending because the
Mac is locked. No original minute-long stall was reproduced or sampled; it remains unconfirmed.
