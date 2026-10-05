# Monitor intermittent stall investigation

Status: unresolved observation. The original minute-long stall was not reproduced, and no causal
hang fix has been identified. Implemented workflow and history behavior is documented in
[workflow mechanics](../workflows.md).

## Original observation

On 2026-10-05 (Asia/Jakarta), the user reported that Monitor appeared hung for approximately one
minute, then recovered without intervention while a workflow was running.

A read-only process snapshot during the report showed the installed Monitor process alive:
PID 30445, state S, CPU 34.6%, memory 1.3%, elapsed 02:25:08. This single observation does not
establish a main-thread block or its cause. No hang sample was captured before recovery.

## Later observations and limits

During an isolated 100,000-event single-turn UI check, initial selection, the first older page,
and the second older page took 1,150, 2,026, and 2,748 ms to the observed accessibility state.
A sidebar second-page load took 10,642 ms; scrolling back to the top and observing accessibility
state took 17,133 ms. These durations include automation and accessibility observation overhead.
They do not measure pure rendering latency or establish the cause of the slower actions.

A later 15-second sample of isolated app PID 60867, taken during a fast parent selection,
contained 11,967 main-thread samples; 10,835 were in Mach wait (approximately 90.5%). It was
captured after the slower actions and does not diagnose those actions or the original stall.
Isolated checks preserved production history and saved workflows.

## Separate large-answer reproduction

An isolated 1,750,021-byte answer pasted into the single-line recovery instructions field
reproduced a sustained layout stall. All 4,150 sampled main-thread stacks passed through
text-field intrinsic cell sizing and CoreText glyph measurement. This is a distinct reproducible
input case; it does not establish the cause of the earlier intermittent workflow stall.

The field now uses a fixed-height scrolling editor. Repeating the paste reached an enabled Resume
control in 4,000 ms including automation/accessibility overhead. Resume and Recover each delivered
byte-identical UTF-8 through private disposable files, with bounded argument vectors of 245 and
200 bytes, and cleaned those files after completion. These isolated commands used fixture responses
and dispatched no real workers.

## Investigation still needed

- Capture a process sample during the next stall before restarting.
- Record the visible view, active run size, preceding interaction, and whether scrolling or the
  entire app stopped responding.
- Distinguish main-thread rendering and decoding from CLI loading and competing system load.
- Reproduce and profile with isolated data before attributing a cause or implementing a hang fix.
