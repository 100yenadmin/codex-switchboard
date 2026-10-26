#!/usr/bin/env python3
"""Reserved Codex logins, and a safe main-CLI account swap, on top of Codex Switchboard.

A reserved login is a private CODEX_HOME holding its own sign-in, set aside for one consumer (for example a
benchmark) so that its quota is never shared with the main CLI. The registry is ~/.config/codex-logins/registry.json
(dir 700, file 600). Switchboard reads it too: it never leases a reserved account, and its switch and auto-swap never
land on one.

  codex-logins.py status                          every account (redacted), the main CLI account, leases, and each reserved login's health
  codex-logins.py register --purpose P --home DIR --consumer TEXT [--owner TEXT] [--notes TEXT]
  codex-logins.py check-switch --profile-key K    exit 0 only if K may become the main CLI account
  codex-logins.py swap [--dry-run]                move the main CLI to the best account check-switch allows

check-switch exits: 0 safe; 1 reserved; 2 the registry is missing, cannot be read, or reserves a key Switchboard does
not list; 3 leased by Switchboard; 4 Switchboard's account or lease state cannot be read. Any nonzero means do not
switch. K may be a profile key or a Switchboard handle (acct_ + 12 hex). An account that shares its email with a
reserved or leased one is refused too, since Switchboard can list one seat under two keys.

swap exits: 0 switched (with --dry-run: an account passes); 2 or 4 as for check-switch; 5 no account passes;
6 Switchboard refused or failed the switch; 7 the switch did not take.

Nothing here prints an email, account id, profile key, holder name or token: accounts appear by handle.
Switchboard is found at $CODEX_SWITCHBOARD_CLI, else in this repository's release build, else on PATH.
"""
import argparse
import base64
import binascii
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

REG_DIR = os.path.expanduser("~/.config/codex-logins")
REG = os.path.join(REG_DIR, "registry.json")
HANDLE = re.compile(r"acct_[0-9a-f]{12}")
ERROR_CODE = re.compile(r"[a-z_]{1,64}")


def find_cli():
    if os.environ.get("CODEX_SWITCHBOARD_CLI"):
        return os.environ["CODEX_SWITCHBOARD_CLI"]
    repo = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    for build in (".build/out/Products/Release", ".build/release"):
        path = os.path.join(repo, build, "codex-switchboard")
        if os.access(path, os.X_OK):
            return path
    return shutil.which("codex-switchboard") or "codex-switchboard"


CS = find_cli()


class Refusal(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def load_registry():
    """The registry for status and register: a missing one is empty."""
    if not os.path.exists(REG):
        return {"version": 1, "logins": []}
    with open(REG) as f:
        return json.load(f)


def reserved_keys():
    """The reserved profile keys. Refusal(2) when the registry is missing, unreadable or malformed, or a login has no key."""
    if not os.path.exists(REG):
        raise Refusal(2, "there is no registry at ~/.config/codex-logins/registry.json; "
                         'if nothing is reserved, write {"version": 1, "logins": []} there')
    try:
        with open(REG) as f:
            reg = json.load(f)
    except (OSError, ValueError):
        raise Refusal(2, "the registry cannot be read as JSON")
    logins = reg.get("logins") if isinstance(reg, dict) else None
    if not isinstance(logins, list) or not all(isinstance(e, dict) for e in logins):
        raise Refusal(2, "the registry does not hold a list of logins")
    keys = [e.get("profile_key") for e in logins]
    if not all(isinstance(k, str) and k for k in keys):
        raise Refusal(2, "a reserved login has no profile_key")
    return set(keys)


def save_registry(reg):
    os.makedirs(REG_DIR, mode=0o700, exist_ok=True)
    os.chmod(REG_DIR, 0o700)
    fd, tmp = tempfile.mkstemp(dir=REG_DIR, prefix=".registry.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(reg, f, indent=1)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, REG)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


@contextlib.contextmanager
def registry_lock():
    os.makedirs(REG_DIR, mode=0o700, exist_ok=True)
    with open(os.path.join(REG_DIR, ".lock"), "a") as f:
        os.chmod(f.name, 0o600)
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def cs_run(*args):
    # Switchboard must judge the main CLI home, never a lease or reserved home in CODEX_HOME.
    env = {k: v for k, v in os.environ.items() if k != "CODEX_HOME"}
    return subprocess.run([CS, *args], capture_output=True, text=True, timeout=120, env=env)


def cs_json(*args):
    """A Switchboard command's JSON object. Refusal(4) if it cannot run, fails or prints anything else."""
    try:
        r = cs_run(*args)
    except (OSError, subprocess.SubprocessError) as e:
        raise Refusal(4, "%s could not run (%s)" % (args[0], type(e).__name__))
    if r.returncode != 0:
        raise Refusal(4, "%s failed (exit %d)" % (args[0], r.returncode))
    try:
        d = json.loads(r.stdout)
    except ValueError:
        raise Refusal(4, "%s did not print JSON" % args[0])
    if not isinstance(d, dict):
        raise Refusal(4, "%s did not print a JSON object" % args[0])
    return d


def handle_for(profile_key):
    return "acct_" + hashlib.sha256(profile_key.encode()).hexdigest()[:12]


def email_of(account):
    return str(account.get("email") or "").strip().lower()


def switchboard_state():
    """(accounts, leased handles, active CLI profile key or None). Refusal(4) on anything unexpected.

    `leases --json` fails when the lease store cannot be read, while `status --json` would show no leases, so leases
    come from the first and are cross-checked with the second's per-account flag."""
    leases = cs_json("leases", "--json").get("leases")
    if not isinstance(leases, list) or not all(
            isinstance(e, dict) and isinstance(e.get("handle"), str) and HANDLE.fullmatch(e["handle"]) for e in leases):
        raise Refusal(4, "leases --json is not a list of leases with handles")
    status = cs_json("status", "--json")
    accounts = status.get("accounts")
    if not isinstance(accounts, list) or not all(
            isinstance(a, dict) and isinstance(a.get("profile_key"), str) and isinstance(a.get("handle"), str)
            and HANDLE.fullmatch(a["handle"]) and isinstance(a.get("leased"), bool) for a in accounts):
        raise Refusal(4, "status --json is not a list of accounts with keys, handles and lease flags")
    listed = {a["handle"] for a in accounts}
    if any(e["handle"] not in listed for e in leases):
        raise Refusal(4, "a lease names an account Switchboard does not list, so its seat cannot be checked")
    leased = {e["handle"] for e in leases} | {a["handle"] for a in accounts if a["leased"]}
    surfaces = status.get("surfaces") if isinstance(status.get("surfaces"), list) else []
    active = next((s.get("active_profile_key") for s in surfaces
                   if isinstance(s, dict) and s.get("kind") == "cli" and s.get("active_profile_key")), None)
    return accounts, leased, active


def verdict(given, reserved, accounts, leased):
    """(exit code, reason) for switching the main CLI to `given`. Refusal(4) if Switchboard does not list it once."""
    hits = [a for a in accounts if given in (a["profile_key"], a["handle"])]
    if len(hits) != 1:
        raise Refusal(4, "Switchboard lists %d accounts for this key (need exactly 1)" % len(hits))
    target = hits[0]
    handle = target["handle"]
    by_key = {a["profile_key"]: a for a in accounts}
    if target["profile_key"] in reserved:
        return 1, "%s is reserved in the registry" % handle
    if reserved - set(by_key):
        return 2, "the registry reserves a key Switchboard does not list (a new sign-in can re-key an account); register that login again"
    email = email_of(target)
    if email and email in {email_of(by_key[k]) for k in reserved}:
        return 1, "%s shares its email with a reserved account" % handle
    if handle in leased or handle_for(target["profile_key"]) in leased:
        return 3, "%s is leased to an agent lane" % handle
    if email and email in {email_of(a) for a in accounts if a["handle"] in leased}:
        return 3, "%s shares its email with a leased account" % handle
    return 0, None


def describe(account):
    if not account:
        return "an account Switchboard does not list"
    return "%s (%s, weekly %s%% free, session %s%% free)" % (
        account["handle"], account.get("plan"), account.get("weekly_free_percent"), account.get("session_free_percent"))


def refuse(code, message):
    print("refused: %s" % message, file=sys.stderr)
    return code


def switchboard():
    r = cs_run("status", "--json", "--surface", "cli")
    if r.returncode != 0:
        sys.exit("switchboard status failed (exit %d)" % r.returncode)
    d = json.loads(r.stdout)
    active = {s.get("active_profile_key") for s in d.get("surfaces", []) if s.get("kind") == "cli"} - {None, ""}
    if not active:
        sys.exit("refused: Switchboard reported no active CLI profile")
    return d.get("accounts", []), active


def home_email(home):
    with open(os.path.join(home, "auth.json")) as f:
        tok = json.load(f).get("tokens", {}).get("id_token", "")
    if tok.count(".") != 2:
        return None
    part = tok.split(".")[1]
    part += "=" * (-len(part) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(part)).get("email")
    except (ValueError, binascii.Error, AttributeError):
        return None


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def health(entry):
    home = os.path.expanduser(entry["codex_home"])
    auth = os.path.join(home, "auth.json")
    out = []
    if not os.path.isdir(home):
        return "home missing"
    out.append("home %o" % mode(home) + ("" if mode(home) == 0o700 else " (want 700)"))
    if not os.path.exists(auth):
        out.append("no auth.json (sign-in pending)")
        return ", ".join(out)
    out.append("auth %o" % mode(auth) + ("" if mode(auth) == 0o600 else " (want 600)"))
    try:
        with open(auth) as f:
            last = json.load(f).get("last_refresh")
        if last:
            age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(last.replace("Z", "+00:00"))
            out.append("refreshed %.1f h ago" % (age.total_seconds() / 3600))
    except (OSError, ValueError, TypeError):
        out.append("auth unreadable")
    return ", ".join(out)


def cmd_status(_):
    reg = load_registry()
    by_key = {e["profile_key"]: e for e in reg["logins"] if e.get("profile_key")}
    accounts, active = switchboard()
    print("Switchboard accounts (CLI surface; numbers are Switchboard's list order):")
    for i, a in enumerate(accounts, 1):
        k = a.get("profile_key")
        tag = []
        if k in active:
            tag.append("MAIN CLI (active)")
        if k in by_key:
            tag.append("RESERVED: " + by_key[k]["purpose"])
        if a.get("leased"):
            tag.append("LEASED to an agent lane")
        print("  #%d %s %-8s %-4s weekly_free %-4s session_free %-4s relogin %-5s %s" % (
            i, a.get("handle", "?"), a.get("plan"), "free" if a.get("is_free_plan") else "paid",
            a.get("weekly_free_percent"), a.get("session_free_percent"), a.get("needs_relogin"), " | ".join(tag)))
    print("\nReserved logins (%s):" % REG)
    if not reg["logins"]:
        print("  none")
    for e in reg["logins"]:
        num = next((i for i, a in enumerate(accounts, 1) if a.get("profile_key") == e.get("profile_key")), None)
        clash = " !! IS THE MAIN CLI ACCOUNT" if e.get("profile_key") in active else ""
        print("  %s -> Switchboard #%s%s" % (e["purpose"], num if num else "? (not matched)", clash))
        print("     home: %s  [%s]" % (e["codex_home"], health(e)))
        print("     consumer: %s" % e.get("consumer", ""))
        if e.get("owner"):
            print("     owner: %s" % e["owner"])
        if e.get("notes"):
            print("     notes: %s" % e["notes"])
    return 1 if any(e.get("profile_key") in active for e in reg["logins"]) else 0


def cmd_register(a):
    home = os.path.abspath(os.path.expanduser(a.home))
    email = home_email(home)
    if not email:
        sys.exit("no id_token email claim in %s/auth.json; sign in first" % home)
    accounts, active = switchboard()
    hits = [(i, x) for i, x in enumerate(accounts, 1) if x.get("email") == email]
    if len(hits) != 1:
        sys.exit("refused: %d Switchboard accounts match this login (need exactly 1)" % len(hits))
    num, acct = hits[0]
    key = acct.get("profile_key")
    if not key:
        sys.exit("refused: Switchboard #%d reports no profile key" % num)
    if key in active:
        sys.exit("refused: this login is Switchboard #%d, the MAIN CLI account; sign in with a spare account" % num)
    if acct.get("is_free_plan"):
        sys.exit("refused: Switchboard #%d is a free-plan account" % num)
    if acct.get("leased"):
        sys.exit("refused: Switchboard #%d is leased to an agent lane; return the lease first" % num)
    user_home = os.path.expanduser("~")
    home_out = "~" + home[len(user_home):] if home == user_home or home.startswith(user_home + os.sep) else home
    with registry_lock():
        reg = load_registry()
        for e in reg["logins"]:
            if e.get("profile_key") == key and e["purpose"] != a.purpose:
                sys.exit("refused: Switchboard #%d is already reserved for %s" % (num, e["purpose"]))
        reg["logins"] = [e for e in reg["logins"] if e["purpose"] != a.purpose]
        reg["logins"].append({"purpose": a.purpose, "codex_home": home_out, "consumer": a.consumer, "owner": a.owner or "",
                              "notes": a.notes or "", "profile_key": key,
                              "registered": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
        save_registry(reg)
    print("registered %s -> Switchboard #%d (%s, weekly_free %s)" % (a.purpose, num, acct.get("plan"), acct.get("weekly_free_percent")))


def cmd_check_switch(a):
    try:
        reserved = reserved_keys()
        if a.profile_key in reserved:
            return refuse(1, "this key is reserved in the registry")
        accounts, leased, _ = switchboard_state()
        code, why = verdict(a.profile_key, reserved, accounts, leased)
    except Refusal as r:
        return refuse(r.code, "Switchboard's state cannot be checked: %s" % r.message if r.code == 4 else r.message)
    return refuse(code, why) if code else 0


def cmd_swap(a):
    try:
        reserved = reserved_keys()
        accounts, leased, active = switchboard_state()
        if not active:
            raise Refusal(4, "Switchboard reports no active CLI account")
        current = next((x for x in accounts if x["profile_key"] == active), None)
        candidates = sorted(
            (x for x in accounts if x["profile_key"] != active and x.get("usable_for_codex") is True
             and x.get("is_free_plan") is False and x.get("needs_relogin") is False),
            key=lambda x: -(x.get("score") or 0))
        chosen = None
        for c in candidates:
            code, why = verdict(c["handle"], reserved, accounts, leased)
            if code == 2:
                return refuse(2, why)
            if code == 0:
                chosen = c
                break
    except Refusal as r:
        return refuse(r.code, r.message)
    if not chosen:
        return refuse(5, "no paid, usable account other than the main CLI's passes check-switch")
    if a.dry_run:
        print("would switch the main CLI from %s to %s" % (describe(current), describe(chosen)))
        return 0
    # Switchboard re-checks leases and the registry by seat under its own lock before it writes.
    r = cs_run("switch", "--profile-key", chosen["handle"], "--surface", "cli", "--json")
    if r.returncode != 0:
        try:
            error = json.loads(r.stdout or r.stderr).get("error")
        except (ValueError, AttributeError):
            error = None
        return refuse(6, "Switchboard did not switch to %s (%s)" % (
            chosen["handle"], error if isinstance(error, str) and ERROR_CODE.fullmatch(error) else "exit %d" % r.returncode))
    try:
        _, _, now_active = switchboard_state()
    except Refusal as r:
        return refuse(7, "the switch to %s cannot be confirmed: %s" % (chosen["handle"], r.message))
    if now_active != chosen["profile_key"]:
        return refuse(7, "the main CLI is not on %s after the switch" % chosen["handle"])
    print("switched the main CLI from %s to %s" % (describe(current), describe(chosen)))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    r = sub.add_parser("register")
    r.add_argument("--purpose", required=True)
    r.add_argument("--home", required=True)
    r.add_argument("--consumer", required=True)
    r.add_argument("--owner")
    r.add_argument("--notes")
    c = sub.add_parser("check-switch")
    c.add_argument("--profile-key", required=True)
    s = sub.add_parser("swap")
    s.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    commands = {"status": cmd_status, "register": cmd_register, "check-switch": cmd_check_switch, "swap": cmd_swap}
    sys.exit(commands[a.cmd](a) or 0)


if __name__ == "__main__":
    main()
