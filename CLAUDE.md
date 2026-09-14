# polybridge

MCP server (stdio) that dispatches coding tasks to headless agents — Claude Code, Codex, opencode and
vibe — without blocking the caller. See README.md for the tool surface; this file is what you need to
change it safely.

Sibling project: `~/Code/claude-code-bridge` is the single-agent version. Its hardened core
(registry, persistence, drainers, cancellation, progress-aware waiting, config editing) was ported
here; fixes worth having in both should be applied to both.

## Commands

```bash
uv sync
uv run pytest                                  # unit: fast, no auth, no tokens
PB_INTEGRATION=1 uv run pytest -m integration   # spawns real agent runs; costs real money
PB_CLI_INTEGRATION=1 uv run pytest -m cli_integration  # drives real client CLIs; free but binary-dependent
uv run mcp dev src/polybridge/server.py         # MCP Inspector
./install.sh                                    # install + register with the desktop app + each CLI found
uv tool install . --force --no-cache             # reinstall after changes; --no-cache is required
```

**`uv tool install --force` alone reinstalls stale code.** The version never changes, so uv reuses its
cached wheel: it prints `Installed 1 package` and leaves the old `.py` files in place, mtimes and all
(measured — a fix was "installed" three times before anyone checked). Always pass `--no-cache`, and
verify by grepping the installed copy under
`~/.local/share/uv/tools/<tool>/lib/python*/site-packages/`, not by trusting the output.

## Architecture: everything agent-specific lives behind `Backend`

`backends/base.py` defines the contract; `backends/claude.py`, `backends/codex.py`,
`backends/opencode.py` and `backends/vibe.py` implement it. **Nothing outside `backends/` may branch
on a backend's name.** If you find yourself writing `if backend == "codex"`, the seam is missing a
method.

Each backend supplies: argv builders, `assert_safe`, `enforcement`, `ingest` (normalise its stream
into `Accumulator`), and `classify` (decide the terminal status from its own signals). Adding a
backend should mean one new module plus a registry entry — nothing else. That held when `opencode`
was added: the only non-`backends/` changes were docs, the places that enumerated the two names, and
tests. It held again for `vibe`: no change to the `Backend` protocol was needed, even though vibe
rejects both `model` and `reasoning_effort` outright — that only needed a `supports_model_selection`
capability field beside the existing `reasoning_effort` one, not a protocol change. If your fifth
backend needs more than a module and a registry entry, the seam is missing a method.

`Capabilities` exists so callers are told, not surprised. Unsupported requests **fail loudly**:
`max_turns` on Codex raises rather than being dropped, checked both in `server.py` and again in the
backend itself.

## Installing is a second seam: `clients/`

`backends/` is *who we dispatch to*. `clients/` is *who can launch us* — the Claude desktop app,
Claude Code, Codex, opencode, vibe. Same rule: nothing outside `clients/` branches on a client's name,
and adding one should mean one module plus a registry entry.

The two kinds share only the interface. The desktop app has no CLI, so `desktop.py` edits its JSON
(merge, back up, atomic replace). The other four own config formats we have no business
reformatting — 78 KB of application state, hand-commented TOML, JSONC, and TOML again — so they are
driven through their own `mcp add`, which stores the entry in each one's own shape.

`Result.status` is five values, not two, for the same reason `Enforcement` is strict: `unknown` exists
because a CLI that times out may already have written the config, so `failed` there would be a guess
stated as a fact. And success is reported as "add command succeeded", never "registered" — exiting
zero is all that was observed.

## Verified CLI facts

Measured on this machine. Do not "tidy" these away:

**Claude Code (2.1.260)**
- `-p --output-format stream-json` refuses to start without `--verbose`.
- `--disallowedTools` is variadic — patterns must be one comma-separated value.
- `--max-turns` works but is undocumented in `--help`.
- Never symlink-resolve the `claude` path: `~/.local/bin/claude` points into a versioned directory,
  so resolving it pins `PATH` to today's version and breaks at the next update.
- `--effort <level>` accepts `low, medium, high, xhigh, max`. **An invalid value is silently
  degraded**: stderr gets `Warning: Unknown --effort value '<v>' — ignoring it and using the default
  effort`, and the run proceeds anyway — the CLI never refuses to start. This is why polybridge
  validates `reasoning_effort` itself rather than passing an unrecognised value through: a dropped
  request would otherwise look like a run that honoured it.
- **Dropping the deny patterns does NOT let a run commit — the lever is `--allowedTools`.** This was
  the plan's assumed mechanism and it is wrong. Measured, three paired runs in a scratch repo with a
  local bare remote:
  - with `--disallowedTools "Bash(git commit:*),Bash(git push:*)"`: both refused,
    `Permission to use Bash with command ... has been denied.`
  - with those patterns simply **omitted**: still refused, but a *different* message —
    `This command requires approval`. `acceptEdits` auto-approves *edits*, not arbitrary Bash, and
    headless `-p` has nobody to approve, so the command dies either way.
  - with `--permission-mode acceptEdits --allowedTools "Bash(git commit:*),Bash(git push:*)"`: both
    **succeeded**, `permission_denials` empty, and the commit landed in the bare remote.
  So the `publish` freedom drops the git denies *and* adds the allow entries; passing both would be
  self-defeating, since deny beats allow. `--allowedTools` is variadic exactly like
  `--disallowedTools`, so its patterns are likewise one comma-separated value.
- **`-p` is a boolean flag and the prompt is a separate positional**, so a prompt token equal to a
  real option name is parsed by claude as that option. The prompt therefore rides after a `--`
  separator, as on codex and opencode. Measured both ways: without `--`, a prompt of
  `--dangerously-skip-permissions` reached claude's own parser and aborted for lack of a prompt;
  with it, the same text was delivered literally. Also measured on **resume** —
  `--resume <id> -- "<option-shaped prompt>"` preserved the session id and delivered the text
  verbatim, so the separator holds on both paths.
- **The approval layer refuses a chained command citing each part separately** — a run that bundled
  `git commit -am wip` with `echo "EXIT: $?"` was refused naming both — so an allow-listed command
  is still refused when it arrives chained to something else.
- `bypassPermissions` with the denies dropped permits commit and push (measured the same way:
  empty denials, commit in the remote). Note this makes `unrestricted` a **behaviour change** —
  before the `publish` work the denies were passed at every level, and deny beats bypass, so
  `unrestricted` did *not* permit an ordinary `git commit` despite its name.

**Codex (codex-cli 0.153.2)**
- **`codex exec` blocks forever reading stdin.** `stdin=DEVNULL` is mandatory, not tidiness.
- An approval prompt would hang a headless run equally, hence pinned `-c approval_policy="never"`.
- Prompt goes after `--`, so prompt text can never be parsed as an option.
- The stream is nothing like Claude's: session id is **`thread_id`** on `thread.started`; the final
  answer is an `item.completed` with `item.type == "agent_message"`; there is **no terminal
  success/failure event** and **no dollar cost**, only token counts on `turn.completed`.
- An `item.type == "error"` was observed in a *successful* run — error **items** are notices. A
  **top-level** `{"type": "error"}` event is a real failure. Do not conflate them.
- `workspace-write` permits `[workdir, /tmp, $TMPDIR]` — it is **not** repo-only.
- `-c model_reasoning_effort="<level>"` is not validated by the CLI at all; an unsupported value
  reaches the API as a mid-run `400`/`turn.failed` rather than being rejected up front. Confirmed
  honoured end to end: a run at `"ultra"` (outside polybridge's four-level vocabulary) recorded
  `"reasoning_effort":"ultra"` in its own session rollout.
- `codex -C <dir>` into an untrusted directory now fails outright (0.153.2), where it previously
  worked — a behaviour change to account for, not a regression to chase, if a sandboxed test starts
  failing on a fresh `-C` target.
- **`workspace-write` defers network to the user's own config; `sandbox_workspace_write.network_access`
  is the switch.** Measured with one `curl https://example.com` per sandbox, on a config that does
  not set the key: `read-only` → blocked (`curl: (6) Could not resolve host`); `workspace-write` →
  blocked, same error; `workspace-write` plus `-c sandbox_workspace_write.network_access=true` →
  **HTTP 200**; `danger-full-access` → HTTP 200.
  **That "blocked at workspace-write" is a property of the config, not the sandbox** — measured
  again with `[sandbox_workspace_write] network_access = true` in the user's own `config.toml`, a
  plain `workspace-write` run reached the network (HTTP 200). So polybridge passes an explicit
  `...=false` wherever it reports `blocked` (measured: that returns it to exit 6), and names the
  override in the `Enforcement.mechanism` string. `read-only` was measured immune to the key even
  with it set true, so it takes no override. The first version of this note generalised from one
  clean machine — the same mistake as the vibe `mcp add` measurement below. That is what makes `publish` a genuine tier on codex rather than a relabelling: without
  it a push cannot reach a remote at all.
  The key name came from the binary's own strings — it carries both `[sandbox_workspace_write]` and
  the sentence *"In `workspace-write`, network access still depends on your Codex configuration (for
  example `[sandbox_workspace_write] network_access = true`)"* — which mattered, because **codex does
  not validate `-c` keys at all** (see `model_reasoning_effort` above): a guessed key would have been
  silently ignored, and "network still blocked" would have been indistinguishable from "wrong key".
  The switch opens **general** network access, not git or `gh` specifically — anything inside the
  sandbox can reach the network — so the enforcement block says that rather than implying it only
  unlocks pushing.

**opencode (1.18.18)**
- `run --format json` emits clean JSONL — `step_start`, `tool_use`, `text`, `step_finish`, `error` —
  with `sessionID` on every event, so the id is known from the first line.
- **`cost` on `step_finish` is per step, not cumulative.** A three-step run reported 0.0583 / 0.0149
  / 0.0148; the run cost 0.0881. Assigning instead of accumulating understates it fourfold. Token
  counts are per step for the same reason.
- `step_finish.reason` is `tool-calls` mid-run and `stop` on the last step. That is the *only*
  end-of-run signal — a `text` part can appear at any step, so "saw some text" cannot tell a finished
  run from one killed mid-flight.
- A top-level `error` event comes with exit code 1. There is no terminal success event.
- `--` is honoured; `-s <id>` resumes into the same session id (both verified).
- Its parser also accepts `--flag=value` and compact `-sID`, and **a later value wins**: appending
  `--format=default` after `--format json` disabled the JSON stream outright (measured). So
  `assert_safe` walks the option region and refuses any non-canonical token instead of searching for
  flags — a search sees one `--format` and passes while opencode honours the other one.
- No grandchild process: the server runs in-process, so the CLI leader is the only pid.
- **`--agent build` writes and runs commands without `--auto`** (measured: it created a file and ran
  `git status` unprompted). So `--auto` is not what separates writing from not writing. That is all
  that run establishes — it does *not* show what `build` permits in general, nor that `--auto` never
  matters, since per its help it auto-approves whatever would otherwise be *asked*. `--agent plan`
  *declined* to write — model restraint, not a layer refusing it. All enforcement booleans are False.
- `--variant <level>` **is honoured, but silently ignored with no warning at all** on a value it
  doesn't recognise — worse than claude's stderr notice. Verified on
  `opencode/muse-spark-1.3-contributor-free`, one prompt, three paired runs per level: reasoning
  tokens rose monotonically with the variant — 75/95/99 at `minimal`, 172/201/230 at `low`,
  239/254/308 at `xhigh`. Non-overlapping, but note the low-to-xhigh margin is narrow (230 vs 239);
  the wide, unambiguous separation is `minimal` against `xhigh`, and `minimal` is deliberately
  outside polybridge's vocabulary. So the flag is directional, not a calibrated dial. Support is
  **per model**:
  `opencode models --verbose` lists each model's accepted `variants`; `muse-spark-1.2/1.3` accept
  `minimal, low, medium, high, xhigh`, `ling-3.0-flash-fin` accepts only `low, medium, high`, and
  `big-pickle`, `mimo-v2.5` and both `nemotron` models declare **no** `variants`, so `--variant` is a
  silent no-op on them. `max` — the value opencode's own `--help` gives as an example — appears in no
  model's variant list.

**vibe (Mistral Vibe CLI 2.25.1)**
- `get_prompt_from_stdin()` (`vibe/cli/cli.py:54-67`) runs unconditionally before mode dispatch and
  calls `sys.stdin.read()` whenever stdin is **not a tty** — a pipe that never closes blocks forever.
  `stdin=DEVNULL` is mandatory, same reason as codex's.
- Programmatic mode is `-p/--prompt TEXT` with `--output streaming` for newline-delimited JSON.
- **The `PROMPT` positional is ignored in programmatic mode.** `cli.py:172` reads
  `args.prompt or stdin_prompt`; the positional serves interactive mode and worktree naming only
  (`entrypoint.py:233`). So there is **no working `--` separator** of the kind codex and opencode
  rely on — the prompt must ride on `--prompt`, and `-p` is `nargs="?", const=""`, so a prompt
  starting with `-` is not taken as its value (it falls through to stdin and dies with
  `Error: No prompt provided for programmatic mode`, exit 1 — loud, not silent, but it rules out the
  space-separated form for such prompts). Hence the single canonical token `--prompt=<text>`, last in
  argv. Measured: a prompt beginning with `--max-turns` reached the model verbatim at exit 0,
  unparsed as a flag.
- `sessionId` is a UUID vibe mints itself, present on **every** stream entry including the first, so
  the id is known from line one — `chooses_session_id=False`.
- **No terminal event, no dollar cost, no token counts at all.** `--output streaming` emits only
  `PublicHistoryEntry` objects with `generation_status == COMPLETED`. Classification is
  exit-code-authoritative with the closing assistant message as corroboration — the same shape as
  codex, and codex only. opencode looks similar but is not: its `step_finish(reason="stop")` is a
  real end-of-run signal, so it can complete without an observed exit where codex and vibe cannot.
- **History replay on resume, measured.** A `--resume` run emitted, in order: the prior user message,
  the prior `reasoning`, the prior assistant message, a `checkpoint`, and only then the live turn.
  Replayed entries carry `turnId: null` and `source: "harness"`; the live turn's entries carry a real
  `turnId`, and its user message carries `source: "turn_start"`. Ingest must key off that
  `turn_start`/`turnId` marker, not off "first assistant message seen," or the replayed prefix leaks
  into the summary of a resumed task.
- **Turn-cap breach reads as failure, not a clean stop — unlike claude.** Hitting
  `--max-turns`/`--max-price`/`--max-tokens` raises `ProgrammaticLimitError` → exit 1. Measured with
  `--max-turns 1` on a prompt needing a tool call: exit **1**, stderr
  `<vibe_stop_event>Turn limit of 1 reached</vibe_stop_event>`. **The trap is in the stream, not just
  stderr:** the run also emits a *live-turn* `assistant` message whose text is that same
  `<vibe_stop_event>…</vibe_stop_event>` marker, so a naive ingest reports the marker itself as the
  agent's answer. `supports_turn_cap=True`, with that caveat attached.
- **`publish` on vibe needs `--agent auto-approve`, and so is no narrower than `unrestricted`.**
  Measured: under `--agent accept-edits`, `git commit -am wip` in a throwaway repo emitted a
  `callback` (`detail.kind: "approval"`, `title: "Allow bash?"`), was auto-denied, produced an
  `effect` with `state.status: "cancelled"`, and **no commit landed** — `accept-edits` auto-approves
  `write_file`/`edit` only, leaving `bash` governed by the user's own `[tools.bash]` allowlist, which
  did not cover `git commit`. `auto-approve` is the only profile that can publish, and it sets
  `bypass_tool_permissions: true`, removing every *other* restriction with it. So on vibe the
  `publish` level is a relabelling of `unrestricted`, and `Enforcement` says exactly that.
- **Effort is unsupported outright, and the reason is config precedence, not the missing flag alone.**
  vibe has no `--model` and no reasoning-effort flag — both are config-only
  (`[[models]].thinking`, vocabulary `off/low/medium/high/max`). Its layer precedence, quoted from
  `default_orchestrator.py:30-33`, is *lowest to highest*: schema defaults, GrowthBook experiments,
  **user TOML, project TOML, `VIBE_*` env vars**, runtime overrides, agent profile overrides, enforced
  admin config. A *trusted* project `.vibe/config.toml` (and polybridge passes `--trust`) outranks the
  user TOML and can repoint `active_model`, so an env override keyed off the user config would apply
  to the **wrong model and silently no-op** — the agent-profile layer (polybridge always passes
  `--agent`) and any org admin layer both outrank an env var too, and neither is inspectable from
  here. That silent-no-op failure mode is exactly what this repo exists to prevent, so `model` and
  `reasoning_effort` are both declared unsupported and raised loudly rather than passed through best-
  effort.

All four CLIs mishandle an unsupported reasoning effort differently, which is exactly why polybridge
validates against its own closed `EFFORTS` vocabulary before any of them see a value: claude degrades
silently with a stderr warning, opencode ignores it silently with no warning at all, codex alone fails
loudly — as a mid-run API `400` — and vibe has no flag to mishandle at all: its equivalent
(`[[models]].thinking`) is config-only, several layers removed from anything on the command line, and
an unsupported value there would surface (if it ever did) as a config-resolution problem, not a CLI
error. Because that vocabulary is only four literals (`low`/`medium`/`high`/`xhigh`), none containing
a quote or `=`, TOML-quoting codex's `-c model_reasoning_effort="<v>"` value is a non-issue — no
encoder needed, just the literal interpolated between quotes.

**Registering with them as MCP clients (`mcp add`, measured 2026-08-12; vibe measured 2026-09-10)**
- All four accept `--` and run headless with stdin closed. `stdin=DEVNULL` still matters:
  `opencode mcp add` is prompt-capable, and so is `vibe mcp add`.
- **Only Claude Code refuses to overwrite.** Re-adding exits **1** with
  `MCP server <name> already exists in user config` and writes nothing, and there is no
  `--force`/`--replace` on `add` or `add-json`. So an update means `remove` first — which is why a
  failed replacement must tell the user to *assume* nothing is registered (a failed `add` is not proof
  it wrote nothing) and print the restoring command.
- `claude mcp remove` also exits **1** for a name that was absent
  (`No MCP server named "<name>" in user scope`). Tolerate that signature and *only* that one:
  reading every exit 1 as "wasn't there" turns a permission error into licence to delete.
- **Match those signatures whole, with the name delimited.** `<name> already exists` also matches
  `MCP server not-polybridge already exists…`, so a *different* server's collision would make us
  delete ours; the leading `mcp server ` and the quotes around the name in the not-found form are what
  make the checks safe.
- `claude mcp get` is not a readback. It prints human prose, not JSON, and **launches the server** to
  health-check it.
- Codex and opencode `mcp add` **overwrite**, and each preserved comments elsewhere in its own config
  (`config.toml`, `opencode.jsonc`). That is a property of the versions measured, not a promise.
- `codex mcp add` refuses an explicit `CODEX_HOME` that does not exist, but **creates** its default
  `~/.codex`. Only a sandboxed test needs to make the directory first.
- Run these from `$HOME`: a project-local `opencode.jsonc` in whatever directory the installer was
  run from would otherwise capture a registration meant to be global.
- **vibe is a fourth, distinct behaviour — it neither overwrites (codex, opencode) nor refuses
  outright (Claude Code). Its collision has _two_ shapes, and only one of them exits 0.** Measured
  against a sandboxed `VIBE_HOME`:
  - `vibe mcp add <new>` → `` Added MCP server `<name>`. ``, exit 0.
  - `vibe mcp add` with a **byte-for-byte identical** entry → `` MCP server `<name>` is already
    configured. ``, **exit 0, nothing written** — an idempotent no-op.
  - `vibe mcp add` with the **same name but different settings** — i.e. what an update actually is —
    → an argparse failure: a `usage:` block plus
    `` vibe mcp: error: MCP server name `<name>` is already configured. ``, **exit 2, nothing
    written**. Note the extra word **name**, which is what keeps the two signatures distinguishable.
  - `vibe mcp remove <existing>` → `` Removed MCP server `<name>`. ``, exit 0.
  - `vibe mcp remove <absent>` → `` MCP server `<name>` is not configured in the user config. ``,
    **exit 0** — unlike `claude mcp remove`, which exits 1 for the same case.
  - remove-then-add **does** update correctly (verified: the stored command changed). There is no
    `--force`/`--replace` on `add`, so that is the only way to replace an existing entry, and both
    collision signatures must route to it.
  - **A cautionary tale about measuring the easy case.** The first measurement here re-added an
    *identical* entry, saw exit 0, and recorded "silently skips at exit 0" as the general rule. The
    conflicting case — the only one an update ever hits — exits 2, so a client that treated any
    non-zero exit as fatal turned every update into a hard failure while leaving the stale entry in
    place. A real `PB_CLI_INTEGRATION=1` run against the binary is what caught it, not the unit
    tests written from the wrong fact. When measuring an idempotent-looking command, vary the
    payload, not just repeat the call.
  - Because every case *except* that conflict exits 0, **the exit code alone cannot tell success
    from a no-op for vibe** — the stdout message is the signal, and the exit code only narrows which
    message to expect. Match it whole, with the name delimited by its backticks, per the narrow
    signature rule above.
  - `vibe mcp add` also **rewrites the whole `config.toml` and destroys hand-written comments in it**
    (measured: a `# hand-written comment` was gone afterwards, and `args` was reformatted) — unlike
    codex's and opencode's own `add`, which preserved comments elsewhere in their configs.

## Invariants — break these and the design stops holding

1. **Only `_monitor` publishes a terminal status and sets `Task.done`**, after process exit *and*
   pipe drain. Cancellation sets `cancel_requested` and lets the monitor decide. The one status it
   must *not* publish is one for a process still alive: on its own `CancelledError` the server is
   being torn down, not the run, so it leaves the task `running` and re-raises — unless a
   cancellation is already in flight, whose intent nothing on disk could reconstruct. See "When the
   client restarts the server".
2. **Bookkeeping must never change an outcome.** A stale attribute in a *log line* once turned a
   successful run into `failed`, because the exception escaped into the monitor's handler. That log
   call is now individually guarded.
3. **Signal `Task.pgid` captured at spawn**, never `os.getpgid` — pids get reused.
4. **Drainers are load-bearing** (an unread pipe blocks the agent), and waiting on them is bounded by
   `DRAIN_GRACE_SECONDS` (a grandchild can hold stdout open forever).
5. **Persist a session id the moment it is disclosed.** Codex only reveals its `thread_id` mid-run;
   waiting until exit means a server that dies first loses any chance of resuming.
6. **Identity markers, not session ids, decide liveness.** Codex never receives its id on the command
   line, so `store.process_alive` matches backend-supplied markers instead. See
   `tasks._identity_markers`.
7. **One live run per session**, checked against disk so two server processes cannot both resume it.
8. **`task_id` is validated before becoming a path** — it arrives from a caller.

## When the client restarts the server

The desktop app tears down and respawns the stdio server mid-conversation — `main.log` shows
`[LocalMcpServerManager] Closing <server>` followed by `Connecting` a second later. Nothing here
times a run out, so **every "the run died at ~N minutes" report is really this**, and the giveaway is
two tasks whose `finished_at` match to the second.

The agent survives it (`start_new_session=True`, so it reparents to pid 1 and keeps working), but
nothing reads its stdout any more, so its output is lost from that point on.

Three places conspired to turn that into a permanent lie, and all three now agree on one test —
`store.outcome_unobserved`: *a terminal status with no exit code was never observed.*

- `_monitor`'s `finally` backstop caught its own `CancelledError` and wrote `failed`.
- `store.write` refuses to move a task backwards, so that `failed` could never be corrected.
- `resolve_status` and `live_session_ids` only checked liveness for `status == "running"`, so every
  later server believed the record.

Measured on claude-code-bridge before the fix: two runs recorded `failed`, still alive ten minutes
later with live API connections, invisible to every tool — and because `live_session_ids` had written
them off, the session-busy guard let duplicates start against the same working trees. Do not
"simplify" the `abandoned` flag away.

One precedence rule falls out of this and is easy to get backwards. An unobserved **`failed`** is the
only status the run's own output may overrule, because it is the one the backstop *guesses*. Every
other status records something the bridge *did* — `cancelled` above all — so it stands even with no
exit code. Reversing those two turns a deliberate cancellation into `completed` (caught in review,
reproduced, now pinned by a test). For the same reason `cancel_recovered` waits for the SIGKILL to
land: `resolve_status` rechecks liveness on a `cancelled` record, so returning early would answer a
cancellation with "running".

A second, quieter overclaim lived in the same code path and is now fixed. `resolve_status`
reconstructed a status by calling `classify(state, exit_code if exit_code is not None else 0)` —
**fabricating a clean exit for a process nothing saw exit.** For the backends with no terminal event
of their own (codex, vibe) that turned "the agent said something" into `completed`, on no evidence at
all. `classify` now takes `exit_code: int | None`, and what `None` is worth is each backend's own
business:

- **claude** completes on its `result` event alone — that is a real terminal event — and only an
  *observed* non-zero exit overrules it. Note the trap: passing `None` through without also changing
  claude's `exit_code != 0` to `exit_code is not None and exit_code != 0` would have *regressed*
  claude, turning every recovered success into a failure.
- **opencode** likewise, on `step_finish(reason="stop")`.
- **codex** and **vibe** require an *observed* zero exit; with `None` they report `failed`. Their old
  `exit_code != 0` already rejected `None` by accident of Python comparison — it is now spelled out
  so the behaviour is intentional rather than incidental.

The recovery note had to change with it: "The run reported this result itself" is false for a codex
or vibe record whose `failed` is an inference from *missing* evidence rather than a reported failure.
It is now chosen from the accumulator and the resulting status — never from the backend's name, which
nothing outside `backends/` may branch on. `record.exit_code` was already nullable on disk, so there
is no migration; the intended behavioural change is that old unobserved codex/vibe records carrying a
final message now read `failed` instead of `completed`, which corrects a false claim rather than
losing data.

Everything that asks "has this settled?" must go through `resolve_status`, never read
`record.status` directly. `_poll_recovered` did the latter and so ended a 55s wait after one 5s tick
on a poisoned record — then reported that the full timeout had elapsed. A wait that returns early
while claiming otherwise is worse than one that blocks.

**What this does not fix.** The orphan's output is gone regardless: its pipes died with the server,
so the raw log stops at the teardown and no summary can ever arrive for the rest of that run — the
recovery note says so in as many words. Fixing that properly means durable spooling (spawn stdout
straight into the append-only log and have servers tail the file, rather than owning the pipe), which
would also make an orphan finish normally. Until then, judge a recovered-alive run by what it changed
on disk. Also still open, both pre-existing: `session_has_live_run` → spawn is check-then-act, so two
servers can still race a resume, and process identity is pid + marker substring matching in `ps`
output rather than pid + start time.

## Enforcement must never overclaim

This is the point of the abstraction, and the easiest thing to get subtly wrong. Every boolean in
`Enforcement` is a strict claim: True only if the named thing genuinely **cannot** happen. A caveat
does not repair a boolean that says something untrue.

Worked example: Claude's deny patterns refuse `git commit` but are evaded by `git -C` and
`bash -c` (measured). So `commit_push_blocked` is **False**, and the weaker truth lives in
`direct_commit_commands_denied: True`. Likewise Codex confines writes by OS but to workspace *plus*
temp dirs, so `writes_confined: True` is paired with `writable_roots` naming them — never
"confined to the repo".

**`freedom` is a requested ordering, not four distinct strengths everywhere.** Backends may collapse
adjacent levels, and two do: on opencode `publish` is byte-identical to `write_in_repo` (nothing was
ever enforced there), and on vibe it is byte-identical to `unrestricted` (only `auto-approve` can
publish). Where two levels produce the same argv, `assert_safe(argv, freedom)` genuinely cannot
refuse a mismatched freedom — there is no difference to detect — so those pairs are listed
explicitly, excluded from the cross-freedom refusal test, and covered by a test asserting they
really are identical. A collapse that is pinned by a test is a documented property; one that is
merely true is a hole waiting to be mistaken for enforcement.

The two fields `publish` added are named for what they assert. `publish_attempts_allowed_by_polybridge`
is deliberately **not** `publishing_permitted`: polybridge can say it removed the barriers under its
own control, and nothing more — credentials, remote permissions, branch protection, hooks, an
unauthenticated `gh`, and the agent's own behaviour all sit outside it. `network_access` is separate
because network is the material difference for pushing, and `not_controlled` (claude, opencode, vibe)
means the environment decides — which is not the same claim as `blocked`.

If you add a backend or a freedom level, re-measure rather than reasoning about it, and update the
tables in README.md. `tests/test_backends.py::test_enforcement_never_overclaims` enforces the shape;
it cannot check whether your claim is true.

## Telling the caller what happened

The caller is usually a model, and it only knows what the tool surface says. State changes it cannot
infer belong **in the payload**: `enforcement` on every task, `recovered: true` plus a `note` on
tasks from an earlier process, `next_step` when a wait returns still-running, `notices` for non-fatal
messages, and errors that say what to do instead of just what failed.

A dispatch at `publish` or `unrestricted` also checks whether the checkout is on the repository's
default branch, and says so on `bridge_notices` — a channel separate from `Accumulator.notices`
precisely because vibe's `ingest` resets those per turn and would discard a dispatch-level notice on
a resumed run. Three rules keep that honest:

- It is **disclosure, not a guard.** `start_task` returns after the process has spawned, so the
  notice cannot gate anything; it says to cancel the task, never implies the run was held. It also
  says the branch was read once, at spawn — the agent may switch branches later.
- The default branch is only ever what a remote's own locally recorded `HEAD` says. **Never fall
  back to "the branch is named `main` or `master`"** — a feature branch can be called `main` while
  the real default is something else, which is a test. No fetch, no `ls-remote`, no
  `remote set-head`.
- **Not being able to tell is reported too.** For a run authorized to publish, "which branch this
  would land on could not be determined" is material, so silence would be the wrong answer. Every
  failure mode — missing `git`, a timeout, a detached HEAD, several remotes with no `origin` — is
  absorbed into that notice rather than escaping, per the invariant that bookkeeping must never
  change an outcome. The probes run off the event loop, since they are blocking calls inside an
  async `_spawn`.

`wait_for_task`'s default stays under 60s because MCP clients time out requests around there and
report `-32001` while the run continues unharmed.
