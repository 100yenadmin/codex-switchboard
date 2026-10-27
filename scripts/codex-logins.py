#!/usr/bin/env python3
"""Reserved Codex logins, and a safe main-CLI account swap, on top of Codex Switchboard.

A reserved login is a private CODEX_HOME holding its own sign-in, set aside for one consumer (for example a
benchmark) so that its quota is never shared with the main CLI. The registry is ~/.config/codex-logins/registry.json
(dir 700, file 600). Switchboard reads it too: it never leases a reserved account, and its switch and auto-swap never
land on one.

  codex-logins.py status                          every account's email beside its handle, the main CLI account, leases, and each reserved login's
                                                  health; exits 1 if a reserved account is the main CLI's, 2 if the registry is unreadable
  codex-logins.py register --purpose LABEL --home DIR --consumer TEXT [--owner TEXT] [--notes TEXT]
  codex-logins.py check-switch --profile-key K    exit 0 only if K may become the main CLI account
  codex-logins.py swap [--dry-run]                move the main CLI to the best account check-switch allows

check-switch exits: 0 safe; 1 reserved; 2 the registry is missing, cannot be read, or reserves a key Switchboard does
not list; 3 leased by Switchboard; 4 Switchboard's account or lease state cannot be read, K names no account or
several, or an account the seat check compares has no stored email. Any nonzero means do not switch. K may be a profile key, a Switchboard handle (acct_ + 12 hex) or an email;
`codex-switchboard resolve` resolves it by the rules lease and switch use, and on exit 0 the handle checked is printed.
An account that shares its email with a reserved or leased one is refused too, since Switchboard can list one seat
under two keys.

swap exits: 0 switched (with --dry-run: an account passes); 2 or 4 as for check-switch; 5 no account passes;
6 Switchboard refused or failed the switch; 7 the switch did not take or cannot be confirmed.

Status shows each account's email beside its handle; other commands name accounts by handle only. Nothing here
prints an account id, profile key, holder name, token, or the registry's free text (consumer, owner, notes, home path).
Reserved logins appear by their purpose label; a purpose that is not a valid label stays hidden. register takes
Switchboard's own .auth.lock, so a reservation cannot land between a switch's registry check and its write.
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
import time
import unicodedata

REG_DIR = os.path.expanduser("~/.config/codex-logins")
REG = os.path.join(REG_DIR, "registry.json")
HANDLE = re.compile(r"acct_[0-9a-f]{12}")
ERROR_CODE = re.compile(r"[a-z_]{1,64}")
# A purpose is printed, so it must be a short label that cannot hold an email, a path or a token.
PURPOSE = re.compile(r"[a-z][a-z0-9-]{0,47}")
AUTH_LOCK_TIMEOUT = 60
CS_TIMEOUT = 120


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


class UnknownName(Refusal):
    """A name that matches no account or several: exit 4, but Switchboard's state was read fine."""
    def __init__(self, message):
        super().__init__(4, message)


def load_registry():
    """The registry for status and register: a missing one is empty. Refusal(2) if it cannot be read."""
    if not os.path.exists(REG):
        return {"version": 1, "logins": []}
    try:
        with open(REG) as f:
            reg = json.load(f)
    except (OSError, ValueError):
        raise Refusal(2, "the registry cannot be read as JSON")
    if not isinstance(reg, dict) or not isinstance(reg.get("logins"), list) or not all(
            isinstance(e, dict) and all(isinstance(e.get(k, ""), str) for k in ("profile_key", "purpose", "codex_home"))
            for e in reg["logins"]):
        raise Refusal(2, "the registry does not hold a list of logins with text fields")
    return reg


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


def app_support_dir():
    """Switchboard's storage folder, found the way its CLI finds it: an override is used exactly as given, since a
    trimmed one would lock a different .auth.lock than the CLI's."""
    override = os.environ.get("CODEX_SWITCHBOARD_APP_SUPPORT", "")
    if override.strip():
        return override
    namespace = os.environ.get("CODEX_SWITCHBOARD_STORAGE_NAMESPACE")
    if namespace is not None:
        namespace = namespace.strip()
        if not namespace or namespace in (".", "..") or "/" in namespace or ":" in namespace:
            sys.exit("refused: CODEX_SWITCHBOARD_STORAGE_NAMESPACE is not a single folder name")
    return os.path.expanduser(os.path.join("~/Library/Application Support", namespace or "CodexSwitchboard"))


@contextlib.contextmanager
def auth_store_lock():
    """Switchboard's own .auth.lock, which its switch holds from its registry check to its auth write. A registry
    change made under it cannot slip in between that check and that write."""
    folder = app_support_dir()
    os.makedirs(folder, mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(folder, ".auth.lock"), os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600)
    try:
        deadline = time.monotonic() + AUTH_LOCK_TIMEOUT
        while True:
            try:
                fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    sys.exit("refused: another Switchboard process kept its store lock for %gs; try again" % AUTH_LOCK_TIMEOUT)
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)


def cs_run(*args):
    # Switchboard must judge the main CLI home, never a lease or reserved home in CODEX_HOME.
    env = {k: v for k, v in os.environ.items() if k != "CODEX_HOME"}
    return subprocess.run([CS, *args], capture_output=True, text=True, timeout=CS_TIMEOUT, env=env)


def cs_json(*args):
    """A Switchboard command's JSON object. Refusal(4) if it cannot run, fails or prints anything else."""
    try:
        r = cs_run(*args)
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError) as e:
        raise Refusal(4, "%s could not run or printed something that is not text (%s)" % (args[0], type(e).__name__))
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


def norm_email(value):
    # Casefold, then NFC, as Swift compares emails case-insensitively by canonical equivalence. Every email comparison
    # goes through this.
    return unicodedata.normalize("NFC", str(value or "").strip().casefold())


def email_of(account):
    return norm_email(account.get("email"))


def shown_email(account):
    value = account.get("email")
    if value is None:
        return "-"
    if not isinstance(value, str):
        return "?"
    if not value.strip():
        return "-"
    if any(c.isspace() or c == "|" or not c.isprintable() for c in value):
        return "?"
    return value.strip()


def switchboard_state():
    """(accounts, leased handles, active CLI profile key or None, the surfaces). Refusal(4) on anything unexpected.

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
    return accounts, leased, active, [s for s in surfaces if isinstance(s, dict)]


def find_account(given, accounts):
    """The one account in `status` that `given` (a profile key or a handle) names. UnknownName otherwise."""
    hits = [a for a in accounts if given in (a["profile_key"], a["handle"])]
    if len(hits) != 1:
        raise UnknownName("Switchboard lists %d accounts for this name (need exactly 1)" % len(hits))
    return hits[0]


def resolve_handle(given):
    """The handle Switchboard gives `given` (a profile key, a handle or an email) by the rules lease and switch use, over
    its whole account list; `status` can omit or merge accounts. UnknownName if the name matches no account or several,
    Refusal(4) if Switchboard cannot answer."""
    try:
        r = cs_run("resolve", "--profile-key", given, "--json")
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        raise Refusal(4, "resolve could not run or printed something that is not text (%s)" % type(e).__name__)
    try:
        d = json.loads(r.stdout)
    except ValueError:
        raise Refusal(4, "resolve did not print JSON (exit %d)" % r.returncode)
    if not isinstance(d, dict):
        raise Refusal(4, "resolve did not print a JSON object")
    if r.returncode == 0 and isinstance(d.get("handle"), str) and HANDLE.fullmatch(d["handle"]):
        return d["handle"]
    if r.returncode == 2 and d.get("error") == "ambiguous_account":
        details = d.get("details") if isinstance(d.get("details"), list) else []
        handles = [x.split(" ")[0] for x in details if isinstance(x, str) and HANDLE.fullmatch(x.split(" ")[0])]
        raise UnknownName("this name matches %d accounts; pass one of their handles: %s"
                          % (len(handles), ", ".join(handles)))
    if r.returncode == 2 and d.get("error") == "unknown_profile":
        raise UnknownName("Switchboard lists no account with this name")
    raise Refusal(4, "resolve failed (exit %d)" % r.returncode)


def verdict(given, reserved, accounts, leased):
    """(exit code, reason) for switching the main CLI to `given`. UnknownName unless it names exactly one account."""
    target = find_account(given, accounts)
    handle = target["handle"]
    by_key = {a["profile_key"]: a for a in accounts}
    if target["profile_key"] in reserved:
        return 1, "%s is reserved in the registry" % handle
    if reserved - set(by_key):
        return 2, "the registry reserves a key Switchboard does not list (a new sign-in can re-key an account); register that login again"
    email = email_of(target)
    leased_exact = handle in leased or handle_for(target["profile_key"]) in leased
    # The seat checks below match by email; an account without a stored email could be any seat's, so fail closed.
    protected = [by_key[k] for k in reserved] + [a for a in accounts if a["handle"] in leased]
    if not leased_exact and any(not email_of(a) for a in protected):
        raise Refusal(4, "a reserved or leased account has no stored email, so the other keys of its seat cannot be found")
    if not leased_exact and not email:
        return 4, "%s has no stored email, so Switchboard cannot tell which seat it is" % handle
    if email and email in {email_of(by_key[k]) for k in reserved}:
        return 1, "%s shares its email with a reserved account" % handle
    if leased_exact:
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
    try:
        r = cs_run("status", "--json", "--surface", "cli")
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError) as e:
        sys.exit("switchboard status could not run (%s)" % type(e).__name__)
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
    if not isinstance(entry.get("codex_home"), str):
        return "home not recorded"
    try:
        return home_health(os.path.expanduser(entry["codex_home"]))
    except (OSError, ValueError):
        return "home cannot be checked"


def home_health(home):
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


def label(entry):
    purpose = entry.get("purpose")
    return purpose if isinstance(purpose, str) and PURPOSE.fullmatch(purpose) else "(purpose not a plain label; hidden)"


def cmd_status(_):
    try:
        reg = load_registry()
    except Refusal as r:
        return refuse(r.code, r.message)
    by_key = {e["profile_key"]: e for e in reg["logins"] if e.get("profile_key")}
    accounts, active = switchboard()
    email_width = max((len(shown_email(a)) for a in accounts), default=1)
    print("Switchboard accounts (CLI surface; numbers are Switchboard's list order):")
    for i, a in enumerate(accounts, 1):
        k = a.get("profile_key")
        tag = []
        if k in active:
            tag.append("MAIN CLI (active)")
        if k in by_key:
            tag.append("RESERVED: " + label(by_key[k]))
        if a.get("leased"):
            tag.append("LEASED to an agent lane")
        print("  #%d %s %-*s %-8s %-4s weekly_free %-4s session_free %-4s relogin %-5s %s" % (
            i, a.get("handle", "?"), email_width, shown_email(a), a.get("plan"), "free" if a.get("is_free_plan") else "paid",
            a.get("weekly_free_percent"), a.get("session_free_percent"), a.get("needs_relogin"), " | ".join(tag)))
    # Consumer, owner, notes and the home path are free text, so only the label and the home's health are shown.
    print("\nReserved logins (~/.config/codex-logins/registry.json):")
    if not reg["logins"]:
        print("  none")
    for e in reg["logins"]:
        num = next((i for i, a in enumerate(accounts, 1) if a.get("profile_key") == e.get("profile_key")), None)
        clash = " !! IS THE MAIN CLI ACCOUNT" if e.get("profile_key") in active else ""
        print("  %s -> Switchboard #%s%s  [%s]" % (label(e), num if num else "? (not matched)", clash, health(e)))
    return 1 if any(e.get("profile_key") in active for e in reg["logins"]) else 0


def cmd_register(a):
    if not PURPOSE.fullmatch(a.purpose):
        sys.exit("refused: --purpose must be a lowercase label (a letter, then letters, digits or dashes; at most 48)")
    home = os.path.abspath(os.path.expanduser(a.home))
    try:
        email = norm_email(home_email(home))
    except (OSError, ValueError, AttributeError):
        email = ""
    if not email:
        sys.exit("no id_token email claim in the home's auth.json; sign in first")
    user_home = os.path.expanduser("~")
    home_out = "~" + home[len(user_home):] if home == user_home or home.startswith(user_home + os.sep) else home
    # Switchboard's switch reads the registry and writes auth under .auth.lock, so this check and write go under it
    # too: a switch to this account either finishes first, and is seen here, or sees the reservation.
    with auth_store_lock(), registry_lock():
        try:
            accounts, leased, _, surfaces = switchboard_state()
            hits = [(i, x) for i, x in enumerate(accounts, 1) if email_of(x) == email]
            leased_seat = len(hits) == 1 and verdict(hits[0][1]["profile_key"], set(), accounts, leased)[0] == 3
        except Refusal as r:
            sys.exit("refused: Switchboard's state cannot be checked: %s" % r.message)
        if len(hits) != 1:
            sys.exit("refused: %d Switchboard accounts match this login (need exactly 1)" % len(hits))
        num, acct = hits[0]
        key = acct["profile_key"]
        if any(s.get("detected") is True and s.get("supports_file_switching") is not True for s in surfaces):
            sys.exit("refused: a CLI or Desktop surface keeps its sign-in in a keychain or auto store, so Switchboard "
                     "cannot tell which account it is on; register once every surface uses the file store")
        actives = {s.get("active_profile_key") for s in surfaces} - {None, ""}
        active_emails = {norm_email(s.get("active_email")) for s in surfaces} - {""}
        if key in actives or email in active_emails or email in {email_of(x) for x in accounts if x["profile_key"] in actives}:
            sys.exit("refused: this login is Switchboard #%d, the account a CLI or Desktop surface is on; "
                     "move that surface off it first (codex-logins.py swap)" % num)
        if acct.get("is_free_plan"):
            sys.exit("refused: Switchboard #%d is a free-plan account" % num)
        if leased_seat:
            sys.exit("refused: Switchboard #%d is leased to an agent lane; return the lease first" % num)
        try:
            reg = load_registry()
        except Refusal as r:
            sys.exit("refused: %s" % r.message)
        for e in reg["logins"]:
            if e.get("profile_key") == key and e.get("purpose") != a.purpose:
                sys.exit("refused: Switchboard #%d is already reserved under another purpose" % num)
        reg["logins"] = [e for e in reg["logins"] if e.get("purpose") != a.purpose]
        reg["logins"].append({"purpose": a.purpose, "codex_home": home_out, "consumer": a.consumer, "owner": a.owner or "",
                              "notes": a.notes or "", "profile_key": key,
                              "registered": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
        save_registry(reg)
    print("registered %s -> Switchboard #%d %s (%s, weekly_free %s)" % (
        a.purpose, num, acct["handle"], acct.get("plan"), acct.get("weekly_free_percent")))


def cmd_check_switch(a):
    try:
        reserved = reserved_keys()
        if a.profile_key in reserved:
            return refuse(1, "this key is reserved in the registry")
        handle = resolve_handle(a.profile_key)
        accounts, leased, _, _ = switchboard_state()
        code, why = verdict(handle, reserved, accounts, leased)
    except UnknownName as r:
        return refuse(r.code, r.message)
    except Refusal as r:
        return refuse(r.code, "Switchboard's state cannot be checked: %s" % r.message if r.code == 4 else r.message)
    if code:
        return refuse(code, why)
    # The handle, so the switch that follows names the same account whichever name was given.
    print(handle)
    return 0


def cmd_swap(a):
    try:
        reserved = reserved_keys()
        accounts, leased, active, _ = switchboard_state()
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
    try:
        r = cs_run("switch", "--profile-key", chosen["handle"], "--surface", "cli", "--json")
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError) as e:
        # A switch killed on timeout, or one whose output cannot be decoded, may or may not have written.
        return refuse(7, "the switch to %s did not finish cleanly (%s), so it cannot be confirmed" % (chosen["handle"], type(e).__name__))
    if r.returncode != 0:
        try:
            error = json.loads(r.stdout or r.stderr).get("error")
        except (ValueError, AttributeError):
            error = None
        return refuse(6, "Switchboard did not switch to %s (%s)" % (
            chosen["handle"], error if isinstance(error, str) and ERROR_CODE.fullmatch(error) else "exit %d" % r.returncode))
    try:
        _, _, now_active, _ = switchboard_state()
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
