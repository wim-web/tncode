#!/usr/bin/python3
import json
import queue
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path


DIRECTORY = Path(__file__).resolve().parent


class Client:
    def __init__(self, process):
        self.process = process
        self.frames = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self.read_frames, daemon=True).start()

    def read_frames(self):
        for line in self.process.stdout:
            self.frames.put((time.monotonic(), line))
        self.frames.put((time.monotonic(), None))

    def send(self, **frame):
        self.process.stdin.write(json.dumps(frame) + "\n")
        self.process.stdin.flush()

    def recv(self, *, method=None, request_id=None):
        try:
            received_at, line = self.frames.get(timeout=5)
        except queue.Empty as error:
            raise AssertionError(f"Timed out waiting for {method or request_id}") from error
        assert line is not None, f"Peer closed stdout while waiting for {method or request_id}"
        frame = json.loads(line)
        if method is not None:
            assert frame.get("method") == method, frame
        else:
            assert frame.get("id") == request_id and "method" not in frame, frame
        return received_at, frame

    def request(self, method, **params):
        self.next_id += 1
        self.send(id=self.next_id, method=method, params=params)
        _, response = self.recv(request_id=self.next_id)
        assert "result" in response, response
        return response["result"]

    def turn(self, thread_id, prompt):
        turn = self.request("turn/start", threadId=thread_id, input=[{
            "type": "text", "text": prompt, "text_elements": [],
        }])["turn"]
        assert self.recv(method="thread/status/changed")[1]["params"]["status"]["type"] == "active"
        _, started = self.recv(method="turn/started")
        assert started["params"] == {"threadId": thread_id, "turn": turn}
        assert turn["status"] == "inProgress"
        return turn["id"]

    def delta(self, thread_id, turn_id):
        received_at, frame = self.recv(method="item/agentMessage/delta")
        params = frame["params"]
        assert (params["threadId"], params["turnId"]) == (thread_id, turn_id)
        return received_at, params

    def terminal(self, thread_id, turn_id, status):
        _, message = self.recv(method="item/completed")
        _, completed = self.recv(method="turn/completed")
        assert completed["params"]["threadId"] == thread_id
        turn = completed["params"]["turn"]
        assert turn["id"] == turn_id and turn["status"] == status, turn
        assert turn["items"] == [message["params"]["item"]]
        assert self.recv(method="thread/status/changed")[1]["params"]["status"]["type"] == "idle"
        return turn


@contextmanager
def connect(binary, home):
    with subprocess.Popen(
        [str(binary), "app-server", "-c", "thread_unload_delay_secs=0"],
        env={"CODEX_HOME": str(home)},
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ) as process:
        client = Client(process)
        try:
            initialized = client.request("initialize", clientInfo={
                "name": "turn-fixture-check", "version": "1.0.0",
            })
            assert initialized["codexHome"] == str(home)
            client.send(method="initialized")
            yield client
            process.stdin.close()
            exit_code = process.wait(timeout=2)
            stderr = process.stderr.read()
            assert exit_code == 0, (exit_code, stderr)
        finally:
            if process.poll() is None:
                process.kill()


def stream(client, thread_id, prompt, first_delta):
    turn_id = client.turn(thread_id, prompt)
    client.recv(method="item/started")
    first_at, first = client.delta(thread_id, turn_id)
    second_at, second = client.delta(thread_id, turn_id)
    third_at, third = client.delta(thread_id, turn_id)
    assert first["delta"] == first_delta
    assert first["itemId"] == second["itemId"] == third["itemId"]
    assert second_at - first_at >= 0.4 and third_at - second_at >= 0.4
    turn = client.terminal(thread_id, turn_id, "completed")
    assert turn["items"][0]["text"] == first_delta + "Second delta. Fixture complete."
    return turn_id


def approval(client, thread_id, decision, expected):
    turn_id = client.turn(thread_id, "fixture approval")
    _, request = client.recv(method="item/commandExecution/requestApproval")
    assert request["params"]["threadId"] == thread_id and request["params"]["turnId"] == turn_id
    assert request["params"]["reason"] == "Simulated approval. No command will run."
    assert client.frames.empty()
    client.send(id=request["id"], result={"decision": decision})
    _, resolved = client.recv(method="serverRequest/resolved")
    assert resolved["params"] == {"threadId": thread_id, "requestId": request["id"]}
    client.recv(method="item/started")
    assert client.delta(thread_id, turn_id)[1]["delta"] == expected
    client.terminal(thread_id, turn_id, "completed")


def main():
    with tempfile.TemporaryDirectory(prefix="t3-turn-fixture-check-") as temp:
        run = Path(temp).resolve()
        subprocess.run([sys.executable, str(DIRECTORY / "configure.py"), str(run)],
                       check=True, capture_output=True, text=True)
        settings = json.loads((run / "userdata" / "settings.json").read_text())
        config = settings["providerInstances"]["codex"]["config"]
        assert config["setupMode"] == "existing"
        binary, home = Path(config["binaryPath"]), Path(config["homePath"])
        project = run / "project"
        assert subprocess.check_output([str(binary), "--version"], text=True).startswith("codex-cli ")
        refused = subprocess.run([str(binary), "app-server"], env={"CODEX_HOME": str(project)},
                                 capture_output=True, text=True, timeout=2)
        assert refused.returncode != 0 and "disposable CODEX_HOME" in refused.stderr

        with connect(binary, home) as client:
            assert client.request("account/read", refreshToken=False) == {
                "account": None, "requiresOpenaiAuth": False,
            }
            assert client.request("config/read", includeLayers=False)["config"]["mcp_servers"] == {}
            assert not client.request("skills/list", cwds=[str(project)])["data"][0]["skills"]
            model = client.request("model/list")["data"][0]["model"]
            thread = client.request("thread/start", cwd=str(project), model=model)["thread"]
            thread_id = thread["id"]
            assert thread["cwd"] == str(project)
            assert client.recv(method="thread/started")[1]["params"]["thread"] == thread
            stream_id = stream(client, thread_id, "fixture stream", "Fixture stream started. ")
            print("PASS discovery, startup, delayed text, completed turn")

            approval(client, thread_id, "accept", "Fixture approval accepted.")
            approval(client, thread_id, "decline", "Fixture approval declined.")
            assert not list(project.iterdir())
            print("PASS approval responses and no project writes")

            interrupted_id = client.turn(thread_id, "fixture interrupt")
            client.recv(method="item/started")
            assert client.delta(thread_id, interrupted_id)[1]["delta"] == "Fixture is waiting for Stop."
            assert client.request("turn/interrupt", threadId=thread_id, turnId=interrupted_id) == {}
            client.terminal(thread_id, interrupted_id, "interrupted")

            failed_id = client.turn(thread_id, "fixture fail")
            client.recv(method="item/started")
            assert client.delta(thread_id, failed_id)[1]["delta"] == "Fixture output before failure."
            failed = client.terminal(thread_id, failed_id, "failed")
            assert failed["error"]["message"] == "Fixture failure after the first text delta."
            assert client.request("thread/unsubscribe", threadId=thread_id)["status"] == "unsubscribed"
            assert client.recv(method="thread/closed")[1]["params"]["threadId"] == thread_id
            print("PASS interrupted and failed turns, clean unsubscribe")

        with connect(binary, home) as client:
            client.send(id="before-resume", method="turn/start", params={
                "threadId": thread_id, "input": [{"type": "text", "text": "fixture resume"}],
            })
            assert "error" in client.recv(request_id="before-resume")[1]
            resumed = client.request("thread/resume", threadId=thread_id, excludeTurns=True)
            assert (resumed["thread"]["id"], resumed["thread"]["turns"]) == (thread_id, [])
            prior = client.request("thread/read", threadId=thread_id, includeTurns=True)["thread"]["turns"]
            assert [turn["status"] for turn in prior] == [
                "completed", "completed", "completed", "interrupted", "failed",
            ]
            assert [prior[index]["id"] for index in (0, 3, 4)] == [stream_id, interrupted_id, failed_id]
            stream(client, thread_id, "fixture resume", "Fixture thread resumed. ")
            print("PASS restart, same native thread and history, resumed turn")


if __name__ == "__main__":
    main()
