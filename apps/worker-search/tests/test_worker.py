import io
import json
import sys

from gday_search.worker import CLSPWorker, serve


def test_health_does_not_load_model():
    worker = CLSPWorker()
    assert worker.handle({"operation": "health"})["ready"] is False
    assert worker.model is None


def test_protocol_recovers_after_malformed_request(monkeypatch, capsys):
    class Input:
        buffer = io.BytesIO(b'not json\n{"id":"health","operation":"health"}\n')
    monkeypatch.setattr(sys, "stdin", Input())
    serve(CLSPWorker())
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert len(lines) == 2
    assert "error" in lines[0]
    assert lines[1]["id"] == "health"
    assert lines[1]["final"] is True
    assert lines[1]["result"]["ready"] is False


def test_invalid_text_does_not_load_model(monkeypatch):
    import pytest
    worker = CLSPWorker()
    def unexpected_load():
        raise AssertionError("Invalid input must not load model weights")
    monkeypatch.setattr(worker, "load", unexpected_load)
    for texts in [None, [], [" "], ["x" * 4097], [2]]:
        with pytest.raises(ValueError):
            worker.handle({"operation": "embed_text", "texts": texts})
