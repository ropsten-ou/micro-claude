#!/usr/bin/env python3
"""Stand-in for claude-agent-acp: speaks just enough ACP to exercise the plugin.

Each prompt gets a streamed reply, one tool call, and one permission request;
the reply after the permission says which option the client picked. A prompt
of the form "append <file>" also appends a line to <file> when allowed; one
starting "slow" waits 2 s before asking.
"""
import json
import sys
import time


def send(msg):
    msg["jsonrpc"] = "2.0"
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def update(sid, u):
    send({"method": "session/update", "params": {"sessionId": sid, "update": u}})


def chunk(sid, text):
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})


def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)


while True:
    msg = read()
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        send({"id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    elif method == "session/new":
        send({"id": mid, "result": {"sessionId": "fake-1"}})
    elif method == "session/prompt":
        sid = msg["params"]["sessionId"]
        texts = [b.get("text", "") for b in msg["params"]["prompt"]]
        sys.stderr.write("prompt blocks: %r\n" % texts)
        for part in ["You said: ", texts[0], ". Let me ", "check — ünïcödé ok 🙂."]:
            chunk(sid, part)
        for extra in texts[1:]:
            chunk(sid, "\n[context] " + extra)
        if texts[0].startswith("slow"):  # time to be typing elsewhere when it asks
            time.sleep(2)
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "t1",
                     "title": "`echo hi > out.txt`", "kind": "execute", "status": "pending"})
        send({"id": 900, "method": "session/request_permission", "params": {
            "sessionId": sid,
            "toolCall": {"toolCallId": "t1", "title": "`echo hi > out.txt`"},
            "options": [
                {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
                {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
            ]}})
        resp = read()
        while resp.get("id") != 900:  # e.g. a session/cancel notification
            resp = read()
        outcome = resp["result"]["outcome"]
        allowed = outcome.get("optionId") in ("allow", "always")
        # "append <file>" makes the tool call really edit that file on disk
        if allowed and texts[0].startswith("append "):
            with open(texts[0].split(" ", 1)[1], "a") as f:
                f.write("appended by fake agent\n")
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "t1",
                     "status": "completed" if allowed else "failed"})
        chunk(sid, "\n\nPermission outcome: %s." % outcome.get("optionId", outcome["outcome"]))
        send({"id": mid, "result": {"stopReason": "end_turn"}})
