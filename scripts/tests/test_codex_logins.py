#!/usr/bin/env python3
"""codex-logins check-switch and swap against a fake Switchboard CLI and a temporary registry.

Touches no real account, registry or Switchboard install. Run: python3 -I scripts/tests/test_codex_logins.py
"""
import copy
import hashlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("codex_logins", os.path.join(os.path.dirname(HERE), "codex-logins.py"))
cl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cl)

work = tempfile.mkdtemp(prefix="codex-logins-test-")
FAKE = os.path.join(HERE, "fake-codex-switchboard")
cl.CS = FAKE
cl.REG_DIR = work
cl.REG = os.path.join(work, "registry.json")
FIX = os.path.join(work, "fixture.json")
os.environ["FAKE_CS_FIXTURE"] = FIX
assert cl.REG.startswith(work)


def h(k):
    return "acct_" + hashlib.sha256(k.encode()).hexdigest()[:12]


MAIN, FREE, LEASED, DUP, RES, RES2, FREEPLAN, RELOGIN = (
    "cli:main@example.invalid", "cli:free@example.invalid", "cli:leased@example.invalid",
    "cli:LEASED@example.invalid#2", "cli:reserved@example.invalid", "cli:reserved@example.invalid#2",
    "cli:freeplan@example.invalid", "cli:relogin@example.invalid")


def acct(k, email, score, leased=False, holder=None, free_plan=False, relogin=False):
    return {"profile_key": k, "handle": h(k), "email": email, "plan": "free" if free_plan else "pro",
            "leased": leased, "lease_holder": holder, "score": score, "usable_for_codex": True,
            "is_free_plan": free_plan, "needs_relogin": relogin, "weekly_free_percent": score,
            "session_free_percent": score}


BASE = {
    "status": {"accounts": [acct(MAIN, "main@example.invalid", 5),
                            acct(FREE, "free@example.invalid", 60),
                            acct(LEASED, "leased@example.invalid", 99, True, "holder@example.invalid"),
                            acct(DUP, "Leased@Example.invalid", 98),
                            acct(RES, "reserved@example.invalid", 97),
                            acct(RES2, "Reserved@example.invalid", 96),
                            acct(FREEPLAN, "freeplan@example.invalid", 100, free_plan=True),
                            acct(RELOGIN, "relogin@example.invalid", 100, relogin=True)],
               "surfaces": [{"kind": "cli", "active_profile_key": MAIN}]},
    "leases": {"leases": [{"handle": h(LEASED), "state": "active", "holder": "holder@example.invalid"}]},
    "switch": "!ok",
}
REGISTRY = {"version": 1, "logins": [{"purpose": "bench", "profile_key": RES}]}
MISSING = object()


def run(argv, fixture=BASE, registry=REGISTRY, codex_home=None):
    with open(FIX, "w") as f:
        json.dump(fixture, f)
    if registry is MISSING:
        if os.path.exists(cl.REG):
            os.unlink(cl.REG)
    elif isinstance(registry, str):
        with open(cl.REG, "w") as f:
            f.write(registry)
    else:
        with open(cl.REG, "w") as f:
            json.dump(registry, f)
    if codex_home:
        os.environ["CODEX_HOME"] = codex_home
    else:
        os.environ.pop("CODEX_HOME", None)
    sys.argv = ["codex-logins.py", *argv]
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            cl.main()
        code = 0
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
    with open(FIX) as f:
        after = json.load(f)
    return code, (out.getvalue() + err.getvalue()).strip(), after


def mut(fn):
    d = copy.deepcopy(BASE)
    fn(d)
    return d


def check(key, **kw):
    return run(["check-switch", "--profile-key", key], **kw)


check_cases = [
    ("unleased account accepted", FREE, {}, 0),
    ("unleased account accepted by handle", h(FREE), {}, 0),
    ("CODEX_HOME never reaches Switchboard", FREE, {"codex_home": "/nonexistent/lease-home"}, 0),
    ("leased account refused", LEASED, {}, 3),
    ("leased account refused by handle", h(LEASED), {}, 3),
    ("returning lease still refused", LEASED,
     {"fixture": mut(lambda d: d["leases"]["leases"][0].update(state="returning"))}, 3),
    ("leasing lease still refused", LEASED,
     {"fixture": mut(lambda d: d["leases"]["leases"][0].update(state="leasing"))}, 3),
    ("leased per leases --json only (status flag false) refused", LEASED,
     {"fixture": mut(lambda d: d["status"]["accounts"][2].update(leased=False))}, 3),
    ("leased per status flag only (leases empty) refused", LEASED,
     {"fixture": mut(lambda d: d["leases"].update(leases=[]))}, 3),
    ("second key of a leased seat (same email, other case) refused", DUP, {}, 3),
    ("a lease Switchboard's account list does not show: fail closed", FREE,
     {"fixture": mut(lambda d: d["status"].update(accounts=[a for a in d["status"]["accounts"] if a["profile_key"] != LEASED]))}, 4),
    ("reserved account refused", RES, {}, 1),
    ("reserved account refused by handle", h(RES), {}, 1),
    ("second key of a reserved seat refused", RES2, {}, 1),
    ("registry missing: refused", FREE, {"registry": MISSING}, 2),
    ("registry empty list: accepted", FREE, {"registry": {"version": 1, "logins": []}}, 0),
    ("registry not JSON: refused", FREE, {"registry": "{not json"}, 2),
    ("registry zero bytes: refused", FREE, {"registry": ""}, 2),
    ("registry logins not a list: refused", FREE, {"registry": {"version": 1, "logins": {}}}, 2),
    ("registry login without key: refused", FREE, {"registry": {"version": 1, "logins": [{"purpose": "p"}]}}, 2),
    ("registry reserves a key Switchboard does not list: refused", FREE,
     {"registry": {"version": 1, "logins": [{"purpose": "p", "profile_key": "cli:gone@example.invalid"}]}}, 2),
    ("leases CLI exits nonzero: fail closed", FREE, {"fixture": mut(lambda d: d.update(leases="!exit"))}, 4),
    ("status CLI exits nonzero: fail closed", FREE, {"fixture": mut(lambda d: d.update(status="!exit"))}, 4),
    ("leases output unparseable: fail closed", FREE, {"fixture": mut(lambda d: d.update(leases="!garbage"))}, 4),
    ("status output unparseable: fail closed", FREE, {"fixture": mut(lambda d: d.update(status="!garbage"))}, 4),
    ("leases output a JSON list: fail closed", FREE, {"fixture": mut(lambda d: d.update(leases="!list"))}, 4),
    ("leases key missing: fail closed", FREE, {"fixture": mut(lambda d: d.update(leases={"generated_at": "x"}))}, 4),
    ("lease with malformed handle: fail closed", FREE,
     {"fixture": mut(lambda d: d["leases"]["leases"].append({"handle": "acct_XYZ", "state": "active"}))}, 4),
    ("lease without handle: fail closed", FREE,
     {"fixture": mut(lambda d: d["leases"]["leases"].append({"state": "active"}))}, 4),
    ("status account without lease flag: fail closed", FREE,
     {"fixture": mut(lambda d: d["status"]["accounts"][1].pop("leased"))}, 4),
    ("status account with malformed handle: fail closed", FREE,
     {"fixture": mut(lambda d: d["status"]["accounts"][1].update(handle="nope"))}, 4),
    ("key unknown to Switchboard: fail closed", "cli:nobody@example.invalid", {}, 4),
]

swap_cases = [
    # name, argv, kwargs, exit, handle the fake must have been switched to (None: no switch call)
    ("dry run picks the best account check-switch allows", ["swap", "--dry-run"], {}, 0, None),
    ("swap switches to it and verifies", ["swap"], {}, 0, h(FREE)),
    ("swap with every allowed account gone: nothing to do", ["swap"],
     {"fixture": mut(lambda d: d["status"]["accounts"][1].update(usable_for_codex=False))}, 5, None),
    ("swap refused by Switchboard", ["swap"], {"fixture": mut(lambda d: d.update(switch="!exit"))}, 6, h(FREE)),
    ("swap that does not take", ["swap"], {"fixture": mut(lambda d: d.update(switch="!noop"))}, 7, h(FREE)),
    ("swap with a stale reservation: refused before any switch", ["swap"],
     {"registry": {"version": 1, "logins": [{"purpose": "p", "profile_key": "cli:gone@example.invalid"}]}}, 2, None),
    ("swap with an unreadable lease store: refused", ["swap"], {"fixture": mut(lambda d: d.update(leases="!exit"))}, 4, None),
    ("swap with no registry: refused", ["swap"], {"registry": MISSING}, 2, None),
]

SECRETS = ("@example.invalid", "@Example.invalid", "cli:")
fails = 0
total = 0
for name, key, kw, want in check_cases:
    got, text, _ = check(key, **kw)
    leak = any(s in text for s in SECRETS)
    ok = got == want and not leak
    fails += not ok
    total += 1
    print("%s %-72s want %d got %d%s  %s" % ("PASS" if ok else "FAIL", name, want, got, "  LEAK" if leak else "", text))

for name, argv, kw, want, switched_to in swap_cases:
    got, text, after = run(argv, **kw)
    calls = after.get("switched", [])
    leak = any(s in text for s in SECRETS) or any(not cl.HANDLE.fullmatch(c) for c in calls)
    right_call = calls == ([switched_to] if switched_to else [])
    ok = got == want and not leak and right_call
    fails += not ok
    total += 1
    print("%s %-72s want %d got %d%s%s  %s" % ("PASS" if ok else "FAIL", name, want, got, "  LEAK" if leak else "",
                                              "" if right_call else "  switch calls %r" % calls, text))

_, dry, _ = run(["swap", "--dry-run"])
ok = h(FREE) in dry and h(MAIN) in dry
fails += not ok
total += 1
print("%s %-72s %s" % ("PASS" if ok else "FAIL", "dry run names the current and the chosen handle", dry))

cl.CS = os.path.join(work, "no-such-binary")
got, text, _ = check(FREE)
ok = got == 4
fails += not ok
total += 1
print("%s %-72s want 4 got %d  %s" % ("PASS" if ok else "FAIL", "Switchboard binary missing: fail closed", got, text))

shutil.rmtree(work, ignore_errors=True)
print("\n%d/%d passed" % (total - fails, total))
sys.exit(1 if fails else 0)
