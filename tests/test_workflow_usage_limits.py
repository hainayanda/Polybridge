"""No-model coverage for explicit usage-limit recovery decisions."""
import copy

import pytest

from polybridge import workflows as w
from polybridge import workflow_delegation as d
from test_workflow_delegation import Registry, graph, run_flow, storage, default_decision


LIMIT = {"status": "failed", "summary": "Partial progress retained", "failure_diagnostic": {"category": "usage_limit", "reason": "Provider usage exhausted", "source": "stream:error", "reset_at": "2026-10-10T00:00:00Z"}}


class LimitedRegistry(Registry):
    def __init__(self, root, policy=None, *, limited_role="worker", unknown=False):
        super().__init__(root, policy)
        self.limited_role = limited_role
        self.unknown = unknown

    async def start(self, prompt, repo, **kwargs):
        task = await super().start(prompt, repo, **kwargs)
        worker = "Assignment:\n" in prompt
        if worker == (self.limited_role == "worker") and kwargs.get("model") != "fallback-fixture":
            task.result.update(copy.deepcopy(LIMIT))
            if self.unknown:
                task.result["outcome_unknown"] = True
        return task


def definition():
    value = graph()
    value["nodes"][1]["agent"]["fallbacks"] = [{"backend": "codex", "model": "fallback-fixture"}]
    value["orchestrator"]["fallbacks"] = [{"backend": "codex", "model": "fallback-fixture"}]
    return value


async def test_worker_limit_never_automatically_dispatches_fallback(storage, tmp_path):
    def policy(context, registry):
        if context["current_stage"]["node_id"] == "work":
            return {"decision_id": context["decision_id"], "action": "needs_input", "reason": "Decide quota recovery", "question": "Choose a fallback?"}
        return default_decision(context, registry)
    run, registry = await run_flow(storage, tmp_path, definition(), LimitedRegistry(storage.root, policy), guided=True)
    assert run["status"] == "needs_input"
    workers = [a for a in run["activations"] if a["role"] == "node"]
    assert len(workers) == 1 and len(workers[0]["tasks"]) == 1
    result = workers[0]["node_result"]
    assert result["result"]["failure_kind"] == "usage_limit"
    assert result["result"]["failure_diagnostic"]["reset_at"] == LIMIT["failure_diagnostic"]["reset_at"]
    choices = registry.contexts[-1]["valid_continuations"]
    retry = next(c for c in choices if c["kind"] == "retry_execution")
    assert len(retry["available_candidates"]) == 2


async def test_explicit_worker_candidate_selection_dispatches_fresh_once(storage, tmp_path):
    def policy(context, registry):
        retry = next((c for c in context["valid_continuations"] if c.get("usage_limit_recovery")), None)
        if retry:
            candidate = next(c for c in retry["available_candidates"] if c["candidate"].get("model") == "fallback-fixture")
            return {"decision_id": context["decision_id"], "action": "continue", "reason": "Choose configured fallback", "next": [{"continuation_id": retry["continuation_id"], "prompt": "Finish retained work", "session_mode": "fresh", "candidate_id": candidate["candidate_id"]}]}
        return default_decision(context, registry)
    run, registry = await run_flow(storage, tmp_path, definition(), LimitedRegistry(storage.root, policy), guided=True)
    assert run["status"] == "completed"
    workers = [a for a in run["activations"] if a["role"] == "node"]
    assert len(workers) == 2
    assert workers[1]["tasks"][0]["candidate"]["model"] == "fallback-fixture"
    assert workers[1]["tasks"][0]["session_mode"] == "fresh"
    assert len(workers[0]["tasks"]) == 1


async def test_omitted_candidate_is_rejected_without_replacement(storage, tmp_path):
    def policy(context, registry):
        retry = next((c for c in context["valid_continuations"] if c.get("usage_limit_recovery")), None)
        if retry:
            return {"decision_id": context["decision_id"], "action": "continue", "reason": "Retry", "next": [{"continuation_id": retry["continuation_id"], "prompt": "Finish", "session_mode": "fresh"}]}
        return default_decision(context, registry)
    run, _ = await run_flow(storage, tmp_path, definition(), LimitedRegistry(storage.root, policy), guided=True)
    assert run["status"] == "needs_attention"
    assert len([a for a in run["activations"] if a["role"] == "node"]) == 1
    assert any("candidate_id" in e["error"] for e in run["decision_errors"])


async def test_orchestrator_limit_requires_exact_caller_answer_and_preserves_checkpoint(storage, tmp_path):
    registry = LimitedRegistry(storage.root, limited_role="orchestrator")
    run, _ = await run_flow(storage, tmp_path, definition(), registry, guided=True)
    assert run["status"] == "needs_input"
    assert not any(a["role"] == "node" for a in run["activations"])
    assert LIMIT["failure_diagnostic"]["reset_at"] in run["input_question"]
    pending = copy.deepcopy(run["pending"])
    for answer in ("yes", "continue", "probably fallback please"):
        with pytest.raises(w.WorkflowError, match="exact offered fallback"):
            storage.control(run["workflow_run_id"], "resume", answer, decision_id=run["input_decision_id"])
    approved = storage.control(run["workflow_run_id"], "resume", "fallback", decision_id=run["input_decision_id"])
    assert approved["pending"][0]["id"] == pending[0]["id"]
    assert approved["orchestrator_recovery_candidate"]["model"] == "fallback-fixture"
    await w.WorkflowSupervisor(registry, storage).execute(run["workflow_run_id"])
    finished = storage.get_run(run["workflow_run_id"])
    assert finished["status"] == "completed"
    orchestrators = [a for a in finished["activations"] if a["role"] == "orchestrator"]
    assert orchestrators[1]["tasks"][0]["session_mode"] == "fresh"
    assert orchestrators[2]["tasks"][0]["session_mode"] == "resume"
    assert len([a for a in finished["activations"] if a["role"] == "node"]) == 1


async def test_unsettled_limit_blocks_every_replacement(storage, tmp_path):
    run, _ = await run_flow(storage, tmp_path, definition(), LimitedRegistry(storage.root, unknown=True), guided=True)
    assert run["status"] == "needs_attention"
    assert len([a for a in run["activations"] if a["role"] == "node"]) == 1


def test_usage_limit_never_authorizes_legacy_availability_fallback():
    assert w.availability_failure({**LIMIT, "backend": "codex", "stderr_tail": ["Usage limit exceeded"]}) is None


async def test_limit_after_completed_worker_restores_checkpoint_without_replaying_work(storage, tmp_path):
    class LateLimit(Registry):
        async def start(self, prompt, repo, **kwargs):
            task = await super().start(prompt, repo, **kwargs)
            if self.decode_context(prompt) is not None and len(self.contexts) == 2:
                task.result.update(copy.deepcopy(LIMIT))
            return task
    registry = LateLimit(storage.root)
    run, _ = await run_flow(storage, tmp_path, definition(), registry, guided=True)
    assert run["status"] == "needs_input"
    completed = next(a for a in run["activations"] if a["role"] == "node")
    assert completed["node_result"]["status"] == "succeeded"
    checkpoint_id = run["pending"][0]["id"]
    restarted = w.WorkflowStore(storage.root)
    restarted.control(run["workflow_run_id"], "resume", "fallback", decision_id=run["input_decision_id"])
    await w.WorkflowSupervisor(registry, restarted).execute(run["workflow_run_id"])
    finished = restarted.get_run(run["workflow_run_id"])
    assert finished["status"] == "completed"
    workers = [a for a in finished["activations"] if a["role"] == "node"]
    assert [a["id"] for a in workers] == [completed["id"]]
    assert finished["usage_recovery_history"][0]["token_id"] == checkpoint_id


async def test_live_unsettled_limit_returns_attention_without_waiting_forever(storage, tmp_path):
    class HangingLimit(LimitedRegistry):
        async def start(self, prompt, repo, **kwargs):
            task = await super().start(prompt, repo, **kwargs)
            if "Assignment:\n" in prompt:
                task.done.clear()
                task.result.update(status="running", failure_diagnostic={**LIMIT["failure_diagnostic"], "settlement": "needs_attention"})
            return task
    run, _ = await run_flow(storage, tmp_path, definition(), HangingLimit(storage.root), guided=True)
    assert run["status"] == "needs_attention"
    workers = [a for a in run["activations"] if a["role"] == "node"]
    assert len(workers) == 1 and workers[0]["tasks"][0]["status"] == "uncertain"
    assert workers[0]["tasks"][0]["result"]["status"] == "running"


def test_recovery_choices_are_exposed_in_bounded_response():
    from polybridge.workflow_responses import compact
    run = {"workflow_run_id": "r", "status": "needs_input", "input_decision_id": "d", "orchestrator_usage_recovery": {"decision_id": "d", "failure_diagnostic": LIMIT["failure_diagnostic"], "choices": [{"answer": "fallback", "candidate": {"backend": "codex", "model": "fallback-fixture"}}]}}
    response = compact(run)
    assert response["usage_limit_recovery"]["choices"][0]["answer"] == "fallback"
    assert response["usage_limit_recovery"]["failure_diagnostic"]["reset_at"] == LIMIT["failure_diagnostic"]["reset_at"]


async def test_pause_retains_limit_checkpoint_and_resume_requires_fallback_consent(storage, tmp_path):
    run, registry = await run_flow(storage, tmp_path, definition(), LimitedRegistry(storage.root, limited_role="orchestrator"), guided=True)
    paused = storage.control(run["workflow_run_id"], "pause")
    assert paused["status"] == "paused"
    assert paused["input_decision_id"] == run["input_decision_id"]
    assert paused["orchestrator_usage_recovery"] == run["orchestrator_usage_recovery"]
    assert paused["pending"] == run["pending"]
    with pytest.raises(w.WorkflowError, match="exact offered fallback"):
        storage.control(run["workflow_run_id"], "resume", "continue", decision_id=run["input_decision_id"])
    with pytest.raises(w.WorkflowError, match="current input decision_id"):
        storage.control(run["workflow_run_id"], "resume", "fallback", decision_id="stale")
    approved = storage.control(run["workflow_run_id"], "resume", "fallback", decision_id=run["input_decision_id"])
    assert approved["status"] == "running"
    await w.WorkflowSupervisor(registry, storage).execute(run["workflow_run_id"])
    assert storage.get_run(run["workflow_run_id"])["status"] == "completed"


async def test_cancel_limit_checkpoint_never_dispatches_fallback(storage, tmp_path):
    run, registry = await run_flow(storage, tmp_path, definition(), LimitedRegistry(storage.root, limited_role="orchestrator"), guided=True)
    before = len(registry.calls)
    storage.control(run["workflow_run_id"], "cancel")
    await w.WorkflowSupervisor(registry, storage).execute(run["workflow_run_id"])
    cancelled = storage.get_run(run["workflow_run_id"])
    assert cancelled["status"] == "cancelled"
    assert len(registry.calls) == before
    assert cancelled["orchestrator_usage_recovery"]["failure_diagnostic"] == LIMIT["failure_diagnostic"]


async def test_worker_limit_can_ask_caller_then_pause_and_select_fallback(storage, tmp_path):
    def policy(context, registry):
        retry = next((c for c in context["valid_continuations"] if c.get("usage_limit_recovery")), None)
        if retry and not context.get("recovery_instructions"):
            return {"decision_id": context["decision_id"], "action": "needs_input", "reason": "Let caller choose recovery", "question": "work reached quota; pause, cancel or choose configured fallback-fixture?"}
        if retry:
            selected = next(c for c in retry["available_candidates"] if c["candidate"].get("model") == "fallback-fixture")
            return {"decision_id": context["decision_id"], "action": "continue", "reason": "Caller chose fallback", "next": [{"continuation_id": retry["continuation_id"], "candidate_id": selected["candidate_id"], "session_mode": "fresh", "prompt": "Finish retained work"}]}
        return default_decision(context, registry)
    registry = LimitedRegistry(storage.root, policy)
    run, _ = await run_flow(storage, tmp_path, definition(), registry, guided=True)
    assert run["worker_usage_recovery"]["node_id"] == "work"
    assert storage.control(run["workflow_run_id"], "pause")["status"] == "paused"
    storage.control(run["workflow_run_id"], "resume", "Use configured fallback-fixture for work", decision_id=run["input_decision_id"])
    await w.WorkflowSupervisor(registry, storage).execute(run["workflow_run_id"])
    finished = storage.get_run(run["workflow_run_id"])
    assert finished["status"] == "completed"
    workers = [a for a in finished["activations"] if a["role"] == "node"]
    assert len(workers) == 2 and len(workers[0]["tasks"]) == 1
    assert workers[1]["tasks"][0]["candidate"]["model"] == "fallback-fixture"


async def test_current_child_uses_owner_config_before_restricting_approved_candidate(storage, tmp_path, monkeypatch):
    # This direct dispatch test bypasses execute()'s supervisor receipt; lease safety
    # has separate coverage, while this test exercises owner candidate selection.
    monkeypatch.setattr(w.CheckoutLease, "_orphan_owner", lambda self: None)
    owner_definition = definition()
    owner = storage.create_run(w.validate_definition(owner_definition), "Owner", tmp_path)
    child_definition = definition()
    child_definition["orchestrator"] = {"backend": "codex", "model": "different-child-config"}
    child = storage.create_run(w.validate_definition(child_definition), "Child", tmp_path)
    storage.update_run(child["workflow_run_id"], lambda r: r.update(orchestrator_recovery_candidate={"backend": "codex", "model": "fallback-fixture"}), "test_approval")
    storage.update_run(owner["workflow_run_id"], lambda r: r.update(status="running"), "test_running")
    storage.update_run(child["workflow_run_id"], lambda r: r.update(status="running"), "test_running")
    supervisor = w.WorkflowSupervisor(Registry(storage.root), storage)
    supervisor.run_id = child["workflow_run_id"]
    supervisor.orchestrator_override = (owner["workflow_run_id"], owner["definition"]["orchestrator"])
    activation = supervisor._activation("orchestrator", "orchestrator", {})
    outcome = await supervisor._dispatch({"id": "orchestrator"}, "Control assignment", "orchestrator", activation)
    assert outcome["status"] == "completed"
    observed = storage.get_run(child["workflow_run_id"])["activations"][0]["tasks"][0]
    assert observed["candidate"]["model"] == "fallback-fixture"
    assert observed["session_mode"] == "fresh"
    assert "orchestrator_recovery_candidate" not in storage.get_run(child["workflow_run_id"])
