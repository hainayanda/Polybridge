"""Authoritative quota envelopes, without model calls."""
import pytest
from polybridge.backends import get as get_backend
from polybridge.backends.base import Accumulator

@pytest.mark.parametrize('name,envelope', [('claude','error'),('codex','turn.failed'),('opencode','error'),('vibe','error'),('antigravity','result')])
def test_limit_is_sticky_after_progress_and_success(name, envelope):
    backend = get_backend(name)
    acc = Accumulator(summary='partial work', saw_final_message=True)
    error = {'code':'usage_limit_reached', 'reset_at':'tomorrow'}
    event = {'event':'result', 'result':{'status':'ERROR','error':error}} if name == 'antigravity' else {'type':envelope,'error':error}
    backend.ingest(event, acc)
    assert acc.failure_diagnostic['category'] == 'usage_limit'
    assert acc.failure_diagnostic['reset_at'] == 'tomorrow'
    assert acc.error_result_seen
    assert backend.classify(acc, 0) == 'failed'
    first = acc.failure_diagnostic.copy()
    backend.ingest({'type':'assistant','message':{'content':[{'type':'text','text':'usage_limit_reached'}]}}, acc)
    assert acc.failure_diagnostic == first

@pytest.mark.parametrize('name', ['claude','codex','opencode','vibe','antigravity'])
def test_stderr_requires_error_prefix_and_excludes_auth(name):
    backend = get_backend(name)
    assert backend.stderr_usage_limit_diagnostic('quoted usage_limit_reached') is None
    assert backend.stderr_usage_limit_diagnostic('API Error: 401 usage_limit_reached') is None
    assert backend.stderr_usage_limit_diagnostic('API Error: rate_limit_exceeded')['source'] == 'stderr'
    assert backend.usage_limit_diagnostic({'type':'assistant','error':{'code':'usage_limit_reached'}}) is None

@pytest.mark.parametrize('status', ['allowed','allowed_warning','warning'])
def test_claude_warning_is_not_terminal(status):
    assert get_backend('claude').usage_limit_diagnostic({'type':'rate_limit_event','rate_limit_info':{'status':status}}) is None

def test_claude_rejected_reset_and_invalid_reset():
    backend = get_backend('claude')
    for value in [True, float('inf'), None]:
        diagnostic = backend.usage_limit_diagnostic({'type':'rate_limit_event','rate_limit_info':{'status':'rejected','resetsAt':value}})
        assert 'reset_at' not in diagnostic

def test_agy_terminal_error_string():
    assert get_backend('antigravity').usage_limit_diagnostic({'event':'result','result':{'status':'ERROR','error':'insufficient_quota'}})['category'] == 'usage_limit'

@pytest.mark.parametrize('envelope', ['turn.failed', 'error'])
@pytest.mark.parametrize('info', ['usage_limit_reached', {'code': 'usage_limit_reached'}])
def test_codex_typed_error_is_authoritative(envelope, info):
    backend = get_backend('codex')
    event = {'type': envelope, 'error': {'message': 'Limit reached', 'codex_error_info': info}}
    assert backend.usage_limit_diagnostic(event)['category'] == 'usage_limit'
    for status in (401, 403, 503):
        assert backend.usage_limit_diagnostic({**event, 'error': {**event['error'], 'status': status}}) is None
    assert backend.usage_limit_diagnostic({'type': 'item.completed', 'item': {'type': 'error', **event['error']}}) is None

@pytest.mark.parametrize('status', ['running', 'failed', 'cancelled'])
def test_recovered_live_limit_with_lost_owner_requires_attention(tmp_path, monkeypatch, status):
    from polybridge import store
    from test_store import make_record
    diagnostic = {'category': 'usage_limit', 'reason': 'Quota reached', 'source': 'stderr'}
    record = make_record(status=status, failure_diagnostic=diagnostic)
    monkeypatch.setattr(store, 'record_process_alive', lambda record: True)
    monkeypatch.setattr(store.identity, 'identity_check', lambda owner: 'unknown')
    snapshot = store.snapshot(tmp_path, record)
    assert snapshot['status'] == 'running'
    assert snapshot['failure_diagnostic']['settlement'] == 'needs_attention'
    assert store.brief(tmp_path, record)['failure_diagnostic']['settlement'] == 'needs_attention'
    assert any('needs attention' in notice for notice in snapshot['notices'])
    assert 'settlement' not in record.failure_diagnostic


def test_live_and_recovered_briefs_retain_durable_usage_evidence(tmp_path):
    from datetime import datetime, timezone
    from polybridge import store
    from polybridge.tasks import Task
    from test_store import make_record
    diagnostic = {'category': 'usage_limit', 'reason': 'Quota reached', 'source': 'stderr', 'reset_at': 1234}
    record = make_record(status='failed', exit_code=1, failure_diagnostic=diagnostic)
    live = Task(task_id='t', backend='claude', session_id='s', repo_path=tmp_path,
                prompt='work', max_turns=5, log_path=tmp_path / 't.jsonl',
                started_at=datetime.now(timezone.utc))
    live.acc.failure_diagnostic = diagnostic
    assert live.brief()['failure_diagnostic'] == store.brief(tmp_path, record)['failure_diagnostic'] == diagnostic


@pytest.mark.parametrize('name', ['claude', 'codex', 'opencode', 'vibe', 'antigravity'])
@pytest.mark.parametrize('line', ["You've hit your limit", 'Credit balance is too low', 'usage_limit_reached', 'insufficient_quota', 'rate_limit_exceeded', 'rate_limit_error', 'Warning: rate_limit_exceeded'])
def test_plain_quota_stderr_never_authorizes_automatic_fallback(name, line):
    backend = get_backend(name)
    assert backend.stderr_usage_limit_diagnostic(line) is None
    assert backend.workflow_stderr_availability_failure(line) is None


@pytest.mark.parametrize('name,envelope', [('claude', 'error'), ('codex', 'turn.failed'), ('opencode', 'error'), ('vibe', 'error'), ('antigravity', 'result')])
def test_authoritative_quota_remains_separate_from_automatic_availability(name, envelope):
    backend = get_backend(name)
    error = {'code': 'rate_limit_exceeded'}
    event = {'event': 'result', 'result': {'status': 'ERROR', 'error': error}} if name == 'antigravity' else {'type': envelope, 'error': error}
    assert backend.usage_limit_diagnostic(event)['category'] == 'usage_limit'
    assert backend.workflow_availability_failure(event) is None
    line = 'API Error: rate_limit_exceeded'
    assert backend.stderr_usage_limit_diagnostic(line)['category'] == 'usage_limit'
    assert backend.workflow_stderr_availability_failure(line) is None
    assert backend.workflow_stderr_availability_failure('API Error: 503 Service unavailable')


@pytest.mark.parametrize('name', ['claude', 'codex', 'opencode', 'vibe'])
def test_missing_model_still_authorizes_availability_fallback(name):
    backend = get_backend(name)
    assert backend.workflow_stderr_availability_failure('model_not_found')
    assert backend.stderr_usage_limit_diagnostic('API Error: model_not_found') is None


def test_rejected_claude_rate_envelope_does_not_authorize_automatic_fallback():
    backend = get_backend('claude')
    event = {'type': 'rate_limit_event', 'rate_limit_info': {'status': 'rejected'}}
    assert backend.usage_limit_diagnostic(event)
    assert backend.workflow_availability_failure(event) is None


@pytest.mark.parametrize('name,envelope', [('claude', 'error'), ('codex', 'turn.failed'), ('opencode', 'error'), ('vibe', 'error'), ('antigravity', 'result')])
def test_mixed_quota_transport_codes_never_authorize_automatic_fallback(name, envelope):
    backend = get_backend(name)
    error = {'type': 'overloaded_error', 'code': 'rate_limit_exceeded'}
    event = {'event': 'result', 'result': {'status': 'ERROR', 'error': error}} if name == 'antigravity' else {'type': envelope, 'error': error}
    assert backend.workflow_availability_failure(event) is None
    assert backend.usage_limit_diagnostic(event)
    assert backend.workflow_stderr_availability_failure('API Error: rate_limit_exceeded; provider timed out') is None


def test_claude_api_error_with_quota_code_is_not_transport_fallback():
    backend = get_backend('claude')
    event = {'type': 'error', 'error': {'type': 'api_error', 'code': 'rate_limit_error'}}
    assert backend.workflow_availability_failure(event) is None
    assert backend.usage_limit_diagnostic(event)
