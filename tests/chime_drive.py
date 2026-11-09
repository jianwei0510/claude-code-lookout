"""Drive a muted Lookout copy through each state change and record which ones play a sound.

Build a copy under a different name first, so its settings don't mix with your real Lookout's
(macOS keeps settings per program name), and put the sounds next to it:

    mkdir -p /tmp/lk/sounds && cp app/sounds/*.wav /tmp/lk/sounds/
    swiftc -O -swift-version 5 -parse-as-library app/Lookout.swift app/MonoSharpTokens.swift app/Logo.swift \
        -o /tmp/lk/lookout-chimetest
    python3 tests/chime_drive.py /tmp/lk/lookout-chimetest /tmp/lk/work      # ONLY=14 runs one case

Each case gets its own fresh fake ~/.claude and its own Lookout process, so cases can't leak into each other.
Nothing reads or writes your real ~/.claude, and the copy plays at volume 0 (LOOKOUT_CHIME_DRYRUN).
"""
import json, os, shutil, subprocess, sys, time, uuid

BIN, WORK = sys.argv[1], sys.argv[2]
EXTRA = sys.argv[3:]
POLL = 3.0  # Lookout refreshes every 2 s; wait a little longer than one cycle


class World:
    def __init__(self, name):
        self.home = os.path.join(WORK, name, "claude-home")
        self.state = os.path.join(WORK, name, "state")
        shutil.rmtree(os.path.join(WORK, name), ignore_errors=True)
        os.makedirs(self.home + "/sessions"); os.makedirs(self.state)
        self.log = os.path.join(WORK, name, "lookout.log")
        self.sleepers, self.s = [], {}

    def add(self, key, status, wrap=None, at=None):
        p = subprocess.Popen(["/bin/sleep", "600"]); self.sleepers.append(p)
        cwd = f"/Users/demo/code/{key}"
        sid = str(uuid.uuid4())
        self.s[key] = {"pid": p.pid, "sessionId": sid, "cwd": cwd, "name": key,
                       "hostSessionId": "local_" + uuid.uuid4().hex[:24]}
        slug = cwd.replace("/", "-").replace(".", "-")
        os.makedirs(f"{self.home}/projects/{slug}", exist_ok=True)
        self.s[key]["transcript"] = f"{self.home}/projects/{slug}/{sid}.jsonl"
        self.say_user(key, "start")
        if wrap: self.wrap(key, **wrap)
        self.status(key, status, at)

    def status(self, key, status, at=None):
        """at: when the status changed (seconds since epoch); default now. Backdate it to fake a long turn."""
        s = self.s[key]
        obj = {k: v for k, v in s.items() if k != "transcript"}
        obj.update(status=status, statusUpdatedAt=(at or time.time()) * 1000)
        tmp = f"{self.home}/sessions/{s['pid']}.json.tmp"
        json.dump(obj, open(tmp, "w")); os.replace(tmp, f"{self.home}/sessions/{s['pid']}.json")

    def _append(self, key, line):
        with open(self.s[key]["transcript"], "a") as f: f.write(json.dumps(line) + "\n")

    def say_user(self, key, text):
        self._append(key, {"type": "user", "origin": {"kind": "human"}, "message": {"role": "user", "content": text}})

    def wrap(self, key, ask="", blocked=False):
        inp = {"recap": "done", "ask": ask, "blocked": blocked, "actions": [{"label": "OK"}] if ask else []}
        self._append(key, {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "t", "name": "mcp__ccd_turn__wrap_up", "input": inp}]}})

    def start(self):
        env = dict(os.environ, LOOKOUT_CLAUDE_HOME=self.home,
                   LOOKOUT_MEMORY=self.state + "/remembered.json", LOOKOUT_CHIME_DRYRUN="1")
        self.proc = subprocess.Popen([BIN, *EXTRA], env=env, stdout=open(self.log, "w"), stderr=subprocess.STDOUT)
        time.sleep(POLL)

    def chimes(self):
        lines = open(self.log).read().splitlines()
        return [l for l in lines if l.startswith("CHIME ") or l.startswith("CHIME-MUTED")]

    def stop(self):
        self.proc.terminate(); self.proc.wait()
        for p in self.sleepers: p.terminate()


def case(name, expect, setup, steps):
    """setup(w) builds the starting state; steps(w) changes it. expect: list of chime log prefixes."""
    w = World(name)
    setup(w); w.start()
    before = len(w.chimes())
    steps(w); time.sleep(POLL)
    got = w.chimes()[before:]
    startup = w.chimes()[:before]
    w.stop()
    got_kinds = [l.split()[0] + " " + l.split()[1] for l in got]
    ok = got_kinds == expect
    print(f"{'PASS' if ok else 'FAIL'}  {name}\n      expected {expect or 'silence'}, got {got_kinds or 'silence'}"
          + (f"; at startup: {startup}" if startup else ""))
    return ok


def both(*fns):
    def run(w):
        for f in fns: f(w)
    return run


CASES = [
    ("1 working -> waiting for your reply (blocked question)", ["CHIME attention"],
     lambda w: w.add("a", "busy"),
     lambda w: (w.wrap("a", ask="Drop v1?", blocked=True), w.status("a", "idle"))),
    ("2 working -> has a question (not blocked)", ["CHIME attention"],
     lambda w: w.add("a", "busy"),
     lambda w: (w.wrap("a", ask="Mention pricing?"), w.status("a", "idle"))),
    ("3 working -> stuck on a permission prompt", ["CHIME stuck"],
     lambda w: w.add("a", "busy"),
     lambda w: w.status("a", "waiting")),
    ("4 working -> finished, nothing asked", [],
     lambda w: w.add("a", "busy"),
     lambda w: (w.wrap("a"), w.status("a", "idle"))),
    ("5 idle -> working (you sent a prompt)", [],
     lambda w: w.add("a", "idle", wrap={}),
     lambda w: (w.say_user("a", "go"), w.status("a", "busy"))),
    ("6 has a question -> waiting for reply (already needs you)", [],
     lambda w: w.add("a", "idle", wrap={"ask": "Q1?"}),
     lambda w: w.wrap("a", ask="Q2?", blocked=True)),
    ("7 two at once: one question + one permission prompt", ["CHIME stuck"],
     lambda w: (w.add("a", "busy"), w.add("b", "busy")),
     lambda w: (w.wrap("a", ask="Q?", blocked=True), w.status("a", "idle"), w.status("b", "waiting"))),
    ("8 Lookout starts while a session already needs you", [],
     lambda w: w.add("a", "waiting"),
     lambda w: None),
    ("9 you answer, it works, then asks again", ["CHIME attention"],
     lambda w: w.add("a", "idle", wrap={"ask": "Q1?", "blocked": True}),
     lambda w: (w.say_user("a", "yes"), w.status("a", "busy"), time.sleep(POLL),
                w.wrap("a", ask="Q2?", blocked=True), w.status("a", "idle"))),
    ("10 a status value Lookout has never seen", [],
     lambda w: w.add("a", "busy"),
     lambda w: w.status("a", "compacting")),
    ("11 long turn (5 min) -> finished, nothing asked", ["CHIME done"],
     lambda w: w.add("a", "busy", at=time.time() - 300),
     lambda w: (w.wrap("a"), w.status("a", "idle"))),
    ("12 just under the line (100 s) -> finished, nothing asked", [],
     lambda w: w.add("a", "busy", at=time.time() - 100),
     lambda w: (w.wrap("a"), w.status("a", "idle"))),
    ("13 long turn in a terminal session (no wrap_up at all)", ["CHIME done"],
     lambda w: w.add("a", "busy", at=time.time() - 300),
     lambda w: w.status("a", "idle")),
    ("14 long turn with a permission prompt in the middle", ["CHIME stuck", "CHIME done"],
     lambda w: w.add("a", "busy", at=time.time() - 300),
     lambda w: (w.status("a", "waiting"), time.sleep(POLL), w.status("a", "busy"), time.sleep(POLL),
                w.wrap("a"), w.status("a", "idle"))),
    ("15 long turn that ends with a question: question sound only", ["CHIME attention"],
     lambda w: w.add("a", "busy", at=time.time() - 300),
     lambda w: (w.wrap("a", ask="Ship it?"), w.status("a", "idle"))),
    ("16 one long turn done + one question at once: question wins", ["CHIME attention"],
     lambda w: (w.add("a", "busy", at=time.time() - 300), w.add("b", "busy")),
     lambda w: (w.wrap("a"), w.status("a", "idle"), w.wrap("b", ask="Q?"), w.status("b", "idle"))),
    ("17 unknown status, then a real question: still chimes", ["CHIME attention"],
     lambda w: w.add("a", "busy"),
     lambda w: (w.status("a", "compacting"), time.sleep(POLL), w.wrap("a", ask="Q?", blocked=True), w.status("a", "idle"))),
    ("18 Lookout starts mid-way through a long turn, then it finishes", ["CHIME done"],
     lambda w: w.add("a", "busy", at=time.time() - 600),
     lambda w: (w.wrap("a"), w.status("a", "idle"))),
]

if __name__ == "__main__":
    only = os.environ.get("ONLY")
    results = [case(*c) for c in CASES if not only or c[0].startswith(only + " ")]
    print(f"\n{sum(results)} of {len(results)} cases as expected")
