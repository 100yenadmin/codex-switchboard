---
name: codex-switchboard
description: Use when an agent orchestrator needs to inspect Codex Desktop or Codex CLI auth capacity, move the main Codex CLI to a usable paid account without touching a leased or reserved one, or lease an account's token into a separate CODEX_HOME for an automated lane and return it.
---

# Codex Switchboard

## Overview

Use the local `codex-switchboard` CLI to inspect Codex Desktop/CLI auth surfaces and to lease accounts to automated lanes. Move the main CLI to another account only through `scripts/codex-logins.py` in this repository, which checks leases and reservations first and names accounts by handle. Treat all auth files as sensitive; never print tokens or raw `auth.json` contents.

## Required Rules

- Use only local CLI commands; do not read or print raw `~/.codex/auth.json` or captured profile auth files.
- Name accounts by their email and handle (`acct_` plus 12 hex digits). Agents may print emails and handles, never tokens, account ids, raw auth files, profile keys, or another lane's holder name: pipe every `--json` command through a `jq` that keeps only the fields shown here.
- Swap the main CLI with `codex-logins.py swap`, never with a raw `switch` or a live `autoswap run-once`. Before any switch you were asked to make to one named account, run `codex-logins.py check-switch` on it and stop on any nonzero exit.
- Never switch to a leased account or a registry-reserved account. A leased account's token chain belongs to its lease home, and a second live copy logs both out; a reserved account's quota belongs to its own consumer.
- Do not switch to free-plan accounts unless the user explicitly requests that exact account.
- Do not use `--stop-consumers` unless the user explicitly authorized stopping running Codex Desktop/CLI consumers.
- Run `codex-switchboard` and `codex-logins.py` with `CODEX_HOME` unset (the tool unsets it for Switchboard itself).
- Never copy an auth file into another `CODEX_HOME` yourself. Use `lease` and `return`: a refresh token is single-use, so two live copies of one token chain log each other out.

## Workflow

1. Confirm the CLI exists:

```bash
command -v codex-switchboard
```

2. Inspect surfaces and consumer state:

```bash
codex-switchboard doctor --json \
  | jq '{consumers_running, consumer_count, unsupported_surfaces, surfaces: [.surfaces[] | {kind, detected, running, auth_store_mode, supports_file_switching, shared_auth_store}]}'
```

3. See every account by handle, with its quota, and which are the main CLI's, leased or reserved:

```bash
python3 scripts/codex-logins.py status
```

4. When the main CLI's account runs low, dry-run the swap. It picks the highest-`score` paid, usable account that needs no re-login and that `check-switch` allows, and prints the current and chosen handles:

```bash
python3 scripts/codex-logins.py swap --dry-run
```

5. Swap. Switchboard re-checks leases and reservations by seat under its own store lock before it writes, and the tool then checks that the CLI is on the chosen account:

```bash
python3 scripts/codex-logins.py swap
```

Exit codes, for `check-switch` and `swap`; any nonzero means the main CLI was not moved onto a forbidden account:

| Exit | `check-switch` | `swap` |
|------|----------------|--------|
| 0 | The account may become the main CLI account. | Switched and confirmed (with `--dry-run`: an account passes). |
| 1 | The account is registry-reserved, or shares its email with a reserved one. | |
| 2 | The registry is missing, cannot be read, or reserves a key Switchboard no longer lists. | Same; nothing was switched. |
| 3 | The account is leased (`leasing`, `active` or `returning`), or shares its email with a leased one. | |
| 4 | Switchboard's account or lease state cannot be read, or the name matches no account or several. | Same; nothing was switched. |
| 5 | | No paid, usable account other than the current one passes. |
| 6 | | Switchboard refused or failed the switch; the message gives its `error` code. |
| 7 | | The switch did not take, or cannot be confirmed. |

For a switch the user asked for by account, check it, switch it by handle, and confirm without printing keys. `check-switch` takes a handle, a profile key or an email and, on exit 0, prints the handle it checked; switch by that handle:

```bash
set -o pipefail
HANDLE=$(python3 scripts/codex-logins.py check-switch --profile-key "$ACCOUNT") \
  && codex-switchboard switch --profile-key "$HANDLE" --surface cli --json | jq '{error}' \
  && codex-switchboard status --json --surface cli \
  | jq -e --arg h "$HANDLE" '(.surfaces[] | select(.kind == "cli") | .active_profile_key) as $k | [.accounts[] | select(.profile_key == $k) | .handle] == [$h]'
```

If the chain exits nonzero or prints `false`, treat the switch as failed and report the blocker. Use `--surface desktop` or `--surface both` only when that target was requested. Add `--stop-consumers` only after explicit authorization.

## Auto-swap

The app's auto-swap policy (`autoswap enable|disable|status|run-once`) is the user's own failover setting; enable or disable it only when the user asks. An agent never runs `autoswap run-once` without `--dry-run`: it picks its candidate again when it runs, so it can land on an account nobody checked. Use `codex-logins.py swap` instead.

## Lease Workflow

A lease lends one account's captured auth to a separate `CODEX_HOME`, so an automated lane runs on its own account without touching the main CLI or Desktop sign-in. While a lease is active its home is the account's only live holder: `switch`, `autoswap`, and the app's own switching, sign-in, removal and token refresh all leave the account alone, and the Switchboard app writes every token rotation in the home back to the stored profile. `return` writes the latest token back and clears the lease.

Lease commands show each account's **email beside its handle**, `acct_` plus 12 hex digits. `--profile-key` accepts a profile key, a handle or an email. Email lookup trims whitespace and ignores case. A shared email refuses with `ambiguous_account`, listing matching handles, plans and workspaces; pass one of those handles. `return` matches only leased keys. `--exclude-profile-key EMAIL` excludes every account matching that email.

1. See which accounts you can lease. Every account listed is unleased, not registry-reserved, on a known paid plan, with usable quota, no re-login needed, not the active account of the CLI or Desktop surface, and not being refreshed by the app right now (`lease` refuses `refresh_in_progress` meanwhile):

```bash
codex-switchboard status --json --leasable-only \
  | jq '[.accounts[] | {handle, email, plan, session_free_percent, weekly_free_percent, score, next_reset_at}]'
```

Drop `--leasable-only` to see every account with its `handle`, `email`, `plan`, free percentages, `leased`, `lease_holder`, `lease_quarantined`, `reserved` and `leasable`. `reserved: true` means the codex-logins registry (`~/.config/codex-logins/registry.json`) sets the account aside for one consumer with its own sign-in; it is never leased or picked by auto-swap, and no lease or switch goes into a registered home. If that registry cannot be read, lists a login without a `profile_key`, or lists a key Switchboard no longer has (a stale registry entry), nothing is leasable.

Choose the highest `score`.

2. Lease it into a dedicated directory that holds no other sign-in. The CLI creates the directory with mode `0700`:

```bash
codex-switchboard lease --profile-key "$HANDLE" --home "$LANE_HOME" --holder "$LANE_NAME" --json \
  | jq '{handle, email, lease_id, home, holder, leased_at, auth_written, config_written}'
```

`lease` takes `$LANE_HOME/holder.lock` and writes only into a directory that is new, or whose `auth.json` is absent, a return's tombstone, or already exactly the stored token, never into a registry, CLI or Desktop home. It writes, in this order: `$LANE_HOME/lease.json` (the lease id, the holder and the time; no account), the lease journal entry as `leasing`, `$LANE_HOME/config.toml` when the home has none, then `auth.json` (mode `0600`), and then marks the lease `active`. The `config.toml` keeps Codex on the file store (`cli_auth_credentials_store = "file"`) and points `CODEX_HOME` for commands Codex runs at a path that does not exist, so a `codex` started by a command Codex runs, without setting `CODEX_HOME` itself, does not inherit the home's token. A command that sets `CODEX_HOME` to the home itself is not covered, nor is a process the lane's shell starts (see one Codex per lease home, below). An existing `config.toml` is kept as it is (`config_written: false`) only when it already sets both; otherwise `lease` refuses `home_config_unsafe`.

3. Run the lane with `CODEX_HOME="$LANE_HOME"`. Do not run `codex-switchboard` itself with `CODEX_HOME` pointing at the lease home.

   Run one Codex per lease home: the command is the native Codex binary, or a shell that `exec`s its only Codex as its last command. Two Codex processes need two leases on two homes. Switchboard cannot enforce this for processes a shell starts side by side; it is a rule for whoever writes the lane.

   A holder process takes `flock(LOCK_EX | LOCK_NB)` on `$LANE_HOME/holder.lock` before its first token read and keeps it for its whole lifetime. A holder that refreshes the token itself, instead of Codex, also takes `flock(LOCK_EX)` on `$LANE_HOME/auth.json.lock` around each read, refresh and write-back of `auth.json`, re-reads the file each time, and replaces it atomically. Before each token POST it writes `$LANE_HOME/auth.json.stopped` with reason `refresh_in_flight`, and removes it only after the new token is durably written back (`F_FULLFSYNC`, rename, folder fsync). Use `flock` only, never `lockf` or `fcntl` locks, and never delete either lock file.

   If the holder stops after a credential refusal, a failed refresh, or while a refresh was in flight, it writes `$LANE_HOME/auth.json.stopped` (a reason and a time, never a token). Switchboard then treats the home as quarantined: it never returns, swaps, mirrors or leases into it, and never deletes that file. Only the holder's owner removes it, after diagnosis.

4. Check active leases at any time:

```bash
codex-switchboard leases --json \
  | jq '[.leases[] | {handle, email, lease_id, state, home, home_auth_present, home_matches_stored_profile, holder_running, active_on_surface, quarantined, quarantined_since}]'
```

`state` is `leasing` until the home's `auth.json` is written, then `active`, and `returning` once a return starts, until it finishes; every state counts as leased. `holder_running: true` means a process holds `holder.lock`. `home_matches_stored_profile: false` means the home holds a rotation the stored profile has not picked up yet; the running app mirrors it within seconds, and `return` always writes it back. `active_on_surface: true` means something switched a surface to the leased account outside Switchboard; stop and report it.

5. When the lane's account runs low, swap it between runs, after every process in the home has exited. Only the lease's holder swaps it, because the lane's run records name the account each run used: pass your own holder name, never one copied from `leases`:

```bash
codex-switchboard swap-lease --home "$LANE_HOME" --holder "$LANE_NAME" --json \
  | jq '{returned_handle, returned_email, return_sync, leased_handle, leased_email, lease_id, holder}'
```

This returns the current account (writing its latest token back) and leases the best leasable account into the same home under the same holder, all under one hold of `holder.lock`. Pass `--profile-key HANDLE` to choose the account, or `--exclude-profile-key HANDLE` (repeatable) to skip more accounts. A refusal before the return leaves the lane as it was; `swap_incomplete` means the return happened but the new lease failed, so the home holds no account.

6. When every process in the lane has exited for good, return the lease:

```bash
codex-switchboard return --profile-key "$HANDLE" --home "$LANE_HOME" --json \
  | jq '{handle, email, lease_id, holder, sync, home_auth_tombstoned}'
```

Return re-reads the home under both locks, writes its token into the stored profile, then replaces `auth.json` with a tombstone (`{"switchboard_returned": {"lease_id", "returned_at"}}`, no token) and removes the journal entry. `sync` is `rotated` when the home held a newer token, `unchanged` when it did not, `home_returned` when an earlier, interrupted return had already written this lease's tombstone, or `home_auth_missing` when the lease stopped while `leasing`, so it lent nothing. A tombstoned home can take a new lease.

Return is also the recovery path. After a crash, a kill or any refusal that leaves a lease `returning`, fix the cause and run `return` again; it always starts from a fresh read of the home. A kill -9 at any point never leaves two live holders of one chain: an interrupted lease, return or swap leaves the account `leasing` or `returning`, which count as leased. One window nothing here closes: any refresher (a self-refreshing holder, a Codex lane or the app) killed between its token POST and its durable write-back. A self-refreshing holder that follows step 3 quarantines that window with `auth.json.stopped`; a Codex lane or the app killed there leaves a spent chain that shows up only at the next refresh.

Refusals exit with status 2 and a JSON `error` code. Report the code; never work around it by editing auth files, lock files or the journal:

| `error` | Meaning |
|---------|---------|
| `ambiguous_account` | The email names more than one account; `details` lists each as `handle plan workspace`. Pass one of those handles. |
| `active_account` | The account is the active CLI or Desktop account. Pick another. |
| `surface_identity_unknown` | A surface keeps its sign-in in a keychain or auto store, so Switchboard cannot tell which account it uses. Nothing is leased until it can. |
| `reserved_account`, `home_reserved` | The account is registry-reserved, or the home is a registry-reserved login's home. |
| `reserved_registry_unreadable`, `reserved_registry_stale` | The codex-logins registry cannot be read, lists a login without a `profile_key`, or reserves a key Switchboard no longer lists. Nothing is leased until it is fixed. |
| `stored_copies_disagree` | Switchboard's two stored copies of the account hold different tokens, so the one a lease would copy may be spent. Open the Switchboard app so it settles them, then lease again. |
| `home_quarantined` | The home holds `auth.json.stopped`. Nothing was synced, written or removed; its owner diagnoses the home. |
| `home_in_use` | A process holds `holder.lock`, has a file open in the home, or runs with `CODEX_HOME` set to it (pid and program name in `details`). Stop it first. |
| `home_scan_failed` | Switchboard could not check which processes use the home. Nothing changed. |
| `home_locked` | The home's holder kept `auth.json.lock` for 30 s, probably while refreshing. Nothing changed; try again. |
| `home_lock_unavailable` | A lock file in the home cannot be opened or locked, for example because a folder above the home cannot be searched. Nothing changed. |
| `auth_store_locked` | `lease`, `return`, `swap-lease`: another Switchboard process kept Switchboard's own store lock for 60 s. Nothing changed; try again. |
| `home_config_unsafe` | The home's `config.toml` cannot be read, or does not set both `cli_auth_credentials_store = "file"` and a `CODEX_HOME` for nested commands under `[shell_environment_policy]` (a path that does not exist and is not the home, written without TOML escapes). Add both, or move the file away so `lease` writes its own. |
| `duplicate_account_keys` | Switchboard lists the account's seat under more than one key, so a lease check on one key would miss the other. Remove the account in the Switchboard app (that removes every key of the seat), sign in to it again, then lease. |
| `holder_mismatch` | `swap-lease`: the lease belongs to another holder. |
| `already_leased`, `home_already_leased` | The account, or the home, already has a lease (active or returning). |
| `not_leased`, `home_mismatch` | `return`: the account has no lease, or its lease is at another home. |
| `lease_id_mismatch`, `lease_marker_unreadable` | The home's `lease.json` names another lease, or cannot be read. Nothing changed; the home is not this lease's. |
| `home_auth_missing` | `return`: the lent `auth.json` is gone, holds no token, or holds an earlier lease's tombstone, so the latest token may be somewhere Switchboard cannot see. The lease stays `returning` and the account unleasable. |
| `lease_incomplete` | `lease` wrote `auth.json` but could not mark the lease `active`. Do not use the home; run `return` for it. |
| `home_auth_unreadable`, `home_holds_other_account`, `stored_profile_missing` | `return`: the home cannot be read as Codex auth, now holds another account, or the stored profile is gone. Nothing was removed; the lease stays `returning`. `lease` also refuses the first two for a home that already holds a file it cannot read, or another account. |
| `free_plan`, `plan_unknown`, `needs_relogin`, `unknown_profile` | The account cannot be leased. |
| `home_holds_other_login` | The home already holds a sign-in (for example its own device-code login). Use another home. |
| `home_not_allowed` | The home is `~`, a Switchboard surface home such as `~/.codex`, or inside Switchboard's storage. |
| `app_not_lease_aware` | A running Switchboard app predates leases and would refresh the leased token itself. Update or quit it. |
| `refresh_in_progress` | The app is refreshing this account's token right now. Lease again in a few seconds. |
| `no_lease_at_home`, `no_candidate`, `same_account`, `not_usable`, `swap_incomplete` | `swap-lease`: no lease at that home, no other leasable account, the target is already there, the target has no quota left, or the swap stopped halfway. |
| `account_leased`, `surface_is_lease_home` | `switch` refused a leased account, or a surface whose auth store is a lease home. |
| `surface_is_reserved_home`, `surface_is_lane_home` | `switch` refused a surface whose auth store is a registry-reserved login's home, or a lane home (it has `holder.lock`). Unset `CODEX_HOME`. A `switch` into a home other than `~/.codex` also refuses `reserved_registry_unreadable` while the registry cannot be read. |
| `lease_store_unreadable` | Switchboard could not read `leases.json`; every writer fails closed. |
| `storage_namespace_invalid` | Any command: `CODEX_SWITCHBOARD_STORAGE_NAMESPACE` is set (even empty) but is not a single folder name, so the CLI stops instead of using the default storage. Unset it or fix it. |

## Pressure Scenario

An orchestrator says: "A Codex CLI agent exhausted its current account. Put it back to work if a paid account has tokens."

Correct behavior:

- Run `doctor --json` and `codex-logins.py status`.
- Run `codex-logins.py swap --dry-run`, then `codex-logins.py swap`.
- If Switchboard refuses because consumers are running (exit 6, `consumers_running`), report it, or ask before stopping consumers.
- Report the exit code and the handles the tool printed.

Incorrect behavior:

- Reading `auth.json` into chat, or printing tokens, account ids, profile keys or raw account JSON.
- Switching with a raw `switch` or a live `autoswap run-once` instead of `codex-logins.py swap`.
- Switching to a leased or reserved account, or retrying around a nonzero `check-switch`.
- Choosing a free plan because it has reset sooner.
- Copying an `auth.json` into a lane's `CODEX_HOME` instead of leasing it.
- Using `--stop-consumers` without explicit authorization.
- Claiming success without the tool's confirmation.
