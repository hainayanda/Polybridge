# Scratch access outcome

Status: accepted documentation outcome. No Configure scratch access feature is added.

Write-capable tasks allocate a private, exact per-task directory and name it through
`PB_TASK_SCRATCH` and the internal launch context. Claude and Codex add that exact absolute path
with `--add-dir`; validators reject additional paths or a grant that does not match the
invocation's recorded scratch directory. Read-only tasks do not allocate or receive a writable
scratch grant. This does not change the saved workflow node access or persist a harness-wide
permission.

Directory access and Bash approval are separate. A writable scratch path permits filesystem
access under the selected harness sandbox/mode. It does not approve arbitrary Bash commands,
change the user's tool allowlist, or enable network access. A command can still be refused even
when its output directory is writable. Use the task's reported enforcement and refusal evidence
to distinguish these boundaries.

Persistent scratch grants would duplicate the launch grant or broaden access to other tasks'
artifacts, so there is no Configure scratch access control. Additional writable-directory launch
support remains an adapter capability: an adapter without the extension cannot claim an explicit
scratch grant merely because the bridge supplies the path. Implementing further harness launch
support is outside this stage. Existing broad/unrestricted harness access remains governed by
its own mode and settings.

Validation: 28 launch/validator and scratch-retention tests passed without real model calls;
fresh Codex review confirmed the existing behavior. This documentation stage does not alter user harness configuration or install a
new app.
