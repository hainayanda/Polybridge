"""Native sibling batching preserves ownership, limits, and settlement evidence."""
import asyncio
import json
from dataclasses import replace

import pytest

from polybridge import store, workflows as w
from test_workflow_native import NativeRegistry, MODEL, native_events
from test_workflow_delegation import Task
from test_workflow_explicit_parallel import explicit
from test_workflow_traversal import policy


class BatchRegistry(NativeRegistry):
    def __init__(self, root, *, missing_child=False):
        super().__init__(root)
        self.policy = policy
        self.batches = []
        self.missing_child = missing_child

    async def resume(self, previous, prompt, **kwargs):
        if not kwargs.get("native_subagent") or not isinstance(json.loads(prompt.split("Agent arguments:\n", 1)[1]), list):
            return await super().resume(previous, prompt, **kwargs)
        arguments = json.loads(prompt.split("Agent arguments:\n", 1)[1])
        self.batches.append(arguments)
        record = store.read(self._log_dir, previous.task_id)
        observer = self._workflow_native_observers[kwargs["task_id"]]
        for index, args in enumerate(arguments):
            events = native_events(args["description"], args["prompt"], record.session_id)
            events = json.loads(json.dumps(events).replace('tool-child', 'tool-' + args["description"]).replace('native-child', 'child-' + args["description"]))
            if self.missing_child and index == len(arguments) - 1:
                events = events[:-1]
            for event in events:
                observer(event)
        observer({"type": "result", "session_id": record.session_id, "result": json.dumps({"native_dispatch_nonces": [a["description"] for a in arguments], "settled": True})})
        task = Task(kwargs["task_id"], {"summary": "Batch settled", "backend": "claude", "session_id": record.session_id})
        task.kwargs, task.repo = previous.kwargs, previous.repo
        self.tasks[task.task_id] = task
        store.write(self._log_dir, replace(record, task_id=task.task_id))
        return task


def graph(limit=2):
    definition = explicit()
    definition["max_parallel"] = limit
    definition["orchestrator"] = {"backend": "claude", "model": MODEL}
    for node in definition["nodes"]:
        if node["type"] == "agent":
            node.update(role="review", instructions="Review", agent={"backend": "claude", "model": MODEL}, execution_mode="prefer_subagent", session_mode="fresh")
    return definition


@pytest.mark.parametrize("limit, tree_limit", [(1, 1), (2, 2), (2, 1)])
async def test_native_parallel_batch_observes_children_and_releases_slots(tmp_path, monkeypatch, limit, tree_limit):
    monkeypatch.setattr(w.backends, "is_installed", lambda _: True)
    monkeypatch.setattr(w.backends, "version", lambda _: "2.1.295 (Claude Code)")
    storage, registry = w.WorkflowStore(tmp_path), BatchRegistry(tmp_path)
    run = storage.create_run(w.validate_definition(graph(limit)), "Review", tmp_path)
    from polybridge.workflow_invocation import WorkflowTree
    from polybridge.workflow_native import POLICY
    supervisor = w.WorkflowSupervisor(registry, storage, tree=WorkflowTree(storage, run["workflow_run_id"], permits=tree_limit, scheduling_policy=POLICY))
    await asyncio.wait_for(supervisor.execute(run["workflow_run_id"]), 10)
    observed = storage.get_run(run["workflow_run_id"])
    assert observed["status"] == "completed", observed.get("attention_reason")
    attempts = [t for a in observed["activations"] if a["role"] == "node" for t in a["tasks"]]
    assert len(attempts) == 3
    assert all(t["execution_kind"] == "native_subagent" and t["native_terminal"] for t in attempts)
    assert len({t["native_child_id"] for t in attempts}) == 3
    # Coalescing is opportunistic: slow sibling preparation may produce
    # separate batches, but it must never exceed either capacity.
    assert 1 <= max(map(len, registry.batches)) <= min(limit, tree_limit)
    assert supervisor.tree.slots.free == tree_limit
    assert supervisor.tree.control_slots.free == 1


async def test_missing_batch_child_retains_ownership_without_headless_duplicate(tmp_path, monkeypatch):
    monkeypatch.setattr(w.backends, "is_installed", lambda _: True)
    monkeypatch.setattr(w.backends, "version", lambda _: "2.1.295 (Claude Code)")
    storage, registry = w.WorkflowStore(tmp_path), BatchRegistry(tmp_path, missing_child=True)
    run = storage.create_run(w.validate_definition(graph()), "Review", tmp_path)
    supervisor = w.WorkflowSupervisor(registry, storage)
    await asyncio.wait_for(supervisor.execute(run["workflow_run_id"]), 10)
    observed = storage.get_run(run["workflow_run_id"])
    assert observed["status"] == "needs_attention"
    attempts = [t for a in observed["activations"] if a["role"] == "node" for t in a["tasks"]]
    assert all(t["execution_kind"] == "native_subagent" for t in attempts)
    assert any(t["status"] == "uncertain" for t in attempts)
    assert w.CheckoutLease(storage, str(tmp_path), write=True)._orphan_owner() is not None
    assert len(registry.batches) == 1


async def test_batch_queue_splits_at_adapter_limit_before_reserving(monkeypatch):
    from types import SimpleNamespace
    from polybridge import workflow_native_batch as batch
    seen = []
    async def execute(requests):
        seen.append(len(requests))
        return [(True, {"status": "completed"}) for _ in requests]
    monkeypatch.setattr(batch, "_execute", execute)
    loop = asyncio.get_running_loop()
    requests = [{"prepared": {"run": {"definition": {"max_parallel": 64}}, "native": SimpleNamespace(max_batch_size=16)}, "future": loop.create_future()} for _ in range(17)]
    tree = SimpleNamespace(worker_capacity=64, native_batches={"owner": requests})
    await batch._drain(tree, "owner")
    assert seen == [16, 1]
    assert all(r["future"].result()[0] for r in requests)
