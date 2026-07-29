# polybridge

MCP server (stdio) that dispatches coding tasks to headless agents — Claude Code and Codex — without
blocking the caller. See README.md for the tool surface; this file is what you need to change it
safely.

Sibling project: `~/Code/claude-code-bridge` is the single-agent version. Its hardened core
(registry, persistence, drainers, cancellation, progress-aware waiting, config editing) was ported
here; fixes worth having in both should be applied to both.

## Commands

```bash
uv sync
uv run pytest                                  # unit: fast, no auth, no tokens
PB_INTEGRATION=1 uv run pytest -m integration   # spawns real agent runs; costs real money
uv run mcp dev src/polybridge/server.py         # MCP Inspector
./install.sh                                    # install + register with the desktop app
uv tool install . --force                       # reinstall the console scripts after changes
```

## Architecture: everything agent-specific lives behind `Backend`

`backends/base.py` defines the contract; `backends/claude.py` and `backends/codex.py` implement it.
**Nothing outside `backends/` may branch on a backend's name.** If you find yourself writing
`if backend == "codex"`, the seam is missing a method.

Each backend supplies: argv builders, `assert_safe`, `enforcement`, `ingest` (normalise its stream
into `Accumulator`), and `classify` (decide the terminal status from its own signals). Adding
`opencode` should mean one new module plus a registry entry — nothing else.

`Capabilities` exists so callers are told, not surprised. Unsupported requests **fail loudly**:
`max_turns` on Codex raises rather than being dropped, checked both in `server.py` and again in the
backend itself.

## Verified CLI facts

Measured on this machine. Do not "tidy" these away:

**Claude Code (2.1.220)**
- `-p --output-format stream-json` refuses to start without `--verbose`.
- `--disallowedTools` is variadic — patterns must be one comma-separated value.
- `--max-turns` works but is undocumented in `--help`.
- Never symlink-resolve the `claude` path: `~/.local/bin/claude` points into a versioned directory,
  so resolving it pins `PATH` to today's version and breaks at the next update.

**Codex (codex-cli 0.145.0)**
- **`codex exec` blocks forever reading stdin.** `stdin=DEVNULL` is mandatory, not tidiness.
- An approval prompt would hang a headless run equally, hence pinned `-c approval_policy="never"`.
- Prompt goes after `--`, so prompt text can never be parsed as an option.
- The stream is nothing like Claude's: session id is **`thread_id`** on `thread.started`; the final
  answer is an `item.completed` with `item.type == "agent_message"`; there is **no terminal
  success/failure event** and **no dollar cost**, only token counts on `turn.completed`.
- An `item.type == "error"` was observed in a *successful* run — error **items** are notices. A
  **top-level** `{"type": "error"}` event is a real failure. Do not conflate them.
- `workspace-write` permits `[workdir, /tmp, $TMPDIR]` — it is **not** repo-only.

## Invariants — break these and the design stops holding

1. **Only `_monitor` publishes a terminal status and sets `Task.done`**, after process exit *and*
   pipe drain. Cancellation sets `cancel_requested` and lets the monitor decide.
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

## Enforcement must never overclaim

This is the point of the abstraction, and the easiest thing to get subtly wrong. Every boolean in
`Enforcement` is a strict claim: True only if the named thing genuinely **cannot** happen. A caveat
does not repair a boolean that says something untrue.

Worked example: Claude's deny patterns refuse `git commit` but are evaded by `git -C` and
`bash -c` (measured). So `commit_push_blocked` is **False**, and the weaker truth lives in
`direct_commit_commands_denied: True`. Likewise Codex confines writes by OS but to workspace *plus*
temp dirs, so `writes_confined: True` is paired with `writable_roots` naming them — never
"confined to the repo".

If you add a backend or a freedom level, re-measure rather than reasoning about it, and update the
tables in README.md. `tests/test_backends.py::test_enforcement_never_overclaims` enforces the shape;
it cannot check whether your claim is true.

## Telling the caller what happened

The caller is usually a model, and it only knows what the tool surface says. State changes it cannot
infer belong **in the payload**: `enforcement` on every task, `recovered: true` plus a `note` on
tasks from an earlier process, `next_step` when a wait returns still-running, `notices` for non-fatal
messages, and errors that say what to do instead of just what failed.

`wait_for_task`'s default stays under 60s because MCP clients time out requests around there and
report `-32001` while the run continues unharmed.
