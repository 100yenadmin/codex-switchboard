---
name: codex-switchboard
description: Use when an agent orchestrator needs to inspect Codex Desktop or Codex CLI auth capacity, choose a usable paid Codex profile, perform an explicit local Codex Switchboard profile switch, or lease an account's token into a separate CODEX_HOME for an automated lane and return it.
---

# Codex Switchboard

## Overview

Use the local `codex-switchboard` CLI to inspect Codex Desktop/CLI auth surfaces and switch profiles only when the caller explicitly asks for a switch. Use `autoswap run-once` when the caller has enabled policy-driven failover. Treat all auth files as sensitive; never print tokens or raw `auth.json` contents.

## Required Rules

- Use only local CLI commands; do not read or print raw `~/.codex/auth.json` or captured profile auth files.
- Prefer paid usable accounts: `is_free_plan == false`, `usable_for_codex == true`, and `needs_relogin == false`.
- Do not switch to free-plan accounts unless the user explicitly requests that exact profile.
- Do not use `--stop-consumers` unless the user explicitly authorized stopping running Codex Desktop/CLI consumers.
- Prefer `autoswap run-once --dry-run` before a policy-driven switch so the decision and candidate are visible without mutating auth.
- After any switch, verify the selected surface reports the requested `active_profile_key`.
- Report counts, chosen rationale, and safe commands. Avoid pasting full account JSON into chat or logs.
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

3. Find paid usable profiles:

```bash
codex-switchboard status --json --surface all --paid-only --usable-only \
  | jq '{generated_at, surfaces: [.surfaces[] | {kind, detected, running, active_profile_key, auth_store_mode, shared_auth_store}], accounts: [.accounts[] | {profile_key, plan, usable_for_codex, needs_relogin, session_free_percent, weekly_free_percent, score}]}'
```

4. Choose the highest `score` account that is not free, is usable, and does not need relogin. If no such account exists, stop and report that no paid usable profile is available.

5. Switch only with an explicit local command:

```bash
codex-switchboard switch --profile-key "$PROFILE_KEY" --surface cli --json
```

Use `--surface desktop` or `--surface both` only when that target was requested. Add `--stop-consumers` only after explicit authorization.

6. Verify:

```bash
codex-switchboard status --json --surface cli \
  | jq --arg key "$PROFILE_KEY" '.surfaces[] | select(.kind == "cli") | {kind, active_profile_key, matched: (.active_profile_key == $key)}'
```

If `matched` is not `true`, treat the switch as failed and report the blocker.

## Auto-swap Workflow

Use auto-swap when the user has asked for low-quota failover rather than one specific profile.

1. Inspect the current policy and decisions:

```bash
codex-switchboard autoswap status --json \
  | jq '{policy, decisions: [.decisions[] | {surface, decision, reason, active_profile_key, candidate_profile_key}]}'
```

2. Enable policy only when explicitly requested:

```bash
codex-switchboard autoswap enable --surface cli --json
```

3. Dry-run the policy decision:

```bash
codex-switchboard autoswap run-once --surface cli --json --dry-run \
  | jq '{consumer_count, decisions: [.decisions[] | {surface, decision, reason, active_profile_key, candidate_profile_key}]}'
```

4. Execute only through the policy engine:

```bash
codex-switchboard autoswap run-once --surface cli --json
```

Add `--stop-consumers` only when the caller explicitly authorized stopping running Codex consumers. If the result is `blocked`, report the `reason` and do not manually edit auth files.

## Lease Workflow

A lease lends one account's captured auth to a separate `CODEX_HOME`, so an automated lane runs on its own account without touching the main CLI or Desktop sign-in. While a lease is active its home is the account's only live holder: `switch`, `autoswap`, and the app's own switching, sign-in, removal and token refresh all leave the account alone, and the Switchboard app writes every token rotation in the home back to the stored profile. `return` writes the latest token back and clears the lease.

Lease commands name an account by an opaque **handle**, `acct_` plus 12 hex digits, never by email or profile key. `--profile-key` accepts a handle or a profile key.

1. See which accounts you can lease. Every account listed is unleased, not registry-reserved, on a known paid plan, with usable quota, no re-login needed, not the active account of the CLI or Desktop surface, and not being refreshed by the app right now (`lease` refuses `refresh_in_progress` meanwhile):

```bash
codex-switchboard status --json --leasable-only \
  | jq '[.accounts[] | {handle, plan, session_free_percent, weekly_free_percent, score, next_reset_at}]'
```

Drop `--leasable-only` to see every account with its `handle`, `plan`, free percentages, `leased`, `lease_holder`, `lease_quarantined`, `reserved` and `leasable`. `reserved: true` means the codex-logins registry (`~/.config/codex-logins/registry.json`) sets the account aside for one consumer with its own sign-in; it is never leased or picked by auto-swap, and no lease or switch goes into a registered home. If that registry cannot be read, lists a login without a `profile_key`, or lists a key Switchboard no longer has (a stale reservation), nothing is leasable.

Choose the highest `score`.

2. Lease it into a dedicated directory that holds no other sign-in. The CLI creates the directory with mode `0700`:

```bash
codex-switchboard lease --profile-key "$HANDLE" --home "$LANE_HOME" --holder "$LANE_NAME" --json \
  | jq '{handle, lease_id, home, holder, leased_at, auth_written, config_written}'
```

`lease` takes `$LANE_HOME/holder.lock` and writes only into a directory that is new, or whose `auth.json` is absent or a return's tombstone, never into a registry, CLI or Desktop home. It writes, in this order: `$LANE_HOME/lease.json` (the lease id, the holder and the time; no account), the lease journal entry as `leasing`, `$LANE_HOME/config.toml` when the home has none, then `auth.json` (mode `0600`), and then marks the lease `active`. The `config.toml` keeps Codex on the file store (`cli_auth_credentials_store = "file"`) and points `CODEX_HOME` for commands Codex runs at a path that does not exist, so a nested `codex` cannot share the home's token. An existing `config.toml` is kept as it is (`config_written: false`).

3. Run the lane with `CODEX_HOME="$LANE_HOME"`. Do not run `codex-switchboard` itself with `CODEX_HOME` pointing at the lease home.

   Run one Codex per lease home: the command is the native Codex binary, or a shell that `exec`s its only Codex as its last command. Two Codex processes need two leases on two homes. Switchboard cannot enforce this for processes a shell starts side by side; it is a rule for whoever writes the lane.

   A holder process takes `flock(LOCK_EX | LOCK_NB)` on `$LANE_HOME/holder.lock` before its first token read and keeps it for its whole lifetime. A holder that refreshes the token itself, instead of Codex, also takes `flock(LOCK_EX)` on `$LANE_HOME/auth.json.lock` around each read, refresh and write-back of `auth.json`, re-reads the file each time, and replaces it atomically. Use `flock` only, never `lockf` or `fcntl` locks, and never delete either lock file.

   If the holder stops after a credential refusal or a failed refresh, it writes `$LANE_HOME/auth.json.stopped` (a reason and a time, never a token). Switchboard then treats the home as quarantined: it never returns, swaps, mirrors or leases into it, and never deletes that file. Only the holder's owner removes it, after diagnosis.

4. Check active leases at any time:

```bash
codex-switchboard leases --json \
  | jq '[.leases[] | {handle, lease_id, state, holder, home, home_auth_present, home_matches_stored_profile, holder_running, active_on_surface, quarantined, quarantined_since}]'
```

`state` is `leasing` until the home's `auth.json` is written, then `active`, and `returning` once a return starts, until it finishes; every state counts as leased. `holder_running: true` means a process holds `holder.lock`. `home_matches_stored_profile: false` means the home holds a rotation the stored profile has not picked up yet; the running app mirrors it within seconds, and `return` always writes it back. `active_on_surface: true` means something switched a surface to the leased account outside Switchboard; stop and report it.

5. When the lane's account runs low, swap it between runs, after every process in the home has exited. Only the lease's holder swaps it, because the lane's run records name the account each run used: pass your own holder name, never one copied from `leases`:

```bash
codex-switchboard swap-lease --home "$LANE_HOME" --holder "$LANE_NAME" --json \
  | jq '{returned_handle, return_sync, leased_handle, lease_id, holder}'
```

This returns the current account (writing its latest token back) and leases the best leasable account into the same home under the same holder, all under one hold of `holder.lock`. Pass `--profile-key HANDLE` to choose the account, or `--exclude-profile-key HANDLE` (repeatable) to skip more accounts. A refusal before the return leaves the lane as it was; `swap_incomplete` means the return happened but the new lease failed, so the home holds no account.

6. When every process in the lane has exited for good, return the lease:

```bash
codex-switchboard return --profile-key "$HANDLE" --home "$LANE_HOME" --json \
  | jq '{handle, lease_id, holder, sync, home_auth_tombstoned}'
```

Return re-reads the home under both locks, writes its token into the stored profile, then replaces `auth.json` with a tombstone (`{"switchboard_returned": {"lease_id", "returned_at"}}`, no token) and removes the journal entry. `sync` is `rotated` when the home held a newer token, `unchanged` when it did not, `home_returned` when an earlier, interrupted return had already written this lease's tombstone, or `home_auth_missing` when the lease stopped while `leasing`, so it lent nothing. A tombstoned home can take a new lease.

Return is also the recovery path. After a crash, a kill or any refusal that leaves a lease `returning`, fix the cause and run `return` again; it always starts from a fresh read of the home. One window it cannot cover: a Codex lane or the app killed between sending a refresh token and writing the new one back leaves a spent chain, which shows up only at the next refresh.

Refusals exit with status 2 and a JSON `error` code. Report the code; never work around it by editing auth files, lock files or the journal:

| `error` | Meaning |
|---------|---------|
| `active_account` | The account is the active CLI or Desktop account. Pick another. |
| `surface_identity_unknown` | A surface keeps its sign-in in a keychain or auto store, so Switchboard cannot tell which account it uses. Nothing is leased until it can. |
| `reserved_account`, `home_reserved` | The account is registry-reserved, or the home is a registry-reserved login's home. |
| `reserved_registry_unreadable`, `reserved_registry_stale` | The codex-logins registry cannot be read, lists a login without a `profile_key`, or reserves a key Switchboard no longer lists. Nothing is leased until it is fixed. |
| `stored_copies_disagree` | Switchboard's two stored copies of the account hold different tokens, so the one a lease would copy may be spent. Open the Switchboard app so it settles them, then lease again. |
| `home_quarantined` | The home holds `auth.json.stopped`. Nothing was synced, written or removed; its owner diagnoses the home. |
| `home_in_use` | A process holds `holder.lock`, has a file open in the home, or runs with `CODEX_HOME` set to it (pid and program name in `details`). Stop it first. |
| `home_scan_failed` | Switchboard could not check which processes use the home. Nothing changed. |
| `home_locked` | The home's holder kept `auth.json.lock` for 30 s, probably while refreshing. Nothing changed; try again. |
| `home_lock_unavailable` | A lock file in the home cannot be opened or locked. Nothing changed. |
| `auth_store_locked` | Another Switchboard process kept Switchboard's own store lock for 60 s. Nothing changed; try again. |
| `holder_mismatch` | `swap-lease`: the lease belongs to another holder. |
| `already_leased`, `home_already_leased` | The account, or the home, already has a lease (active or returning). |
| `not_leased`, `home_mismatch` | `return`: the account has no lease, or its lease is at another home. |
| `lease_id_mismatch`, `lease_marker_unreadable` | The home's `lease.json` names another lease, or cannot be read. Nothing changed; the home is not this lease's. |
| `home_auth_missing` | `return`: the lent `auth.json` is gone, holds no token, or holds an earlier lease's tombstone, so the latest token may be somewhere Switchboard cannot see. The lease stays `returning` and the account unleasable. |
| `lease_incomplete` | `lease` wrote `auth.json` but could not mark the lease `active`. Do not use the home; run `return` for it. |
| `home_auth_unreadable`, `home_holds_other_account`, `stored_profile_missing` | `return`: the home cannot be read as Codex auth, now holds another account, or the stored profile is gone. Nothing was removed; the lease stays `returning`. |
| `free_plan`, `plan_unknown`, `needs_relogin`, `unknown_profile` | The account cannot be leased. |
| `home_holds_other_login` | The home already holds a sign-in (for example its own device-code login). Use another home. |
| `home_not_allowed` | The home is `~`, a Switchboard surface home such as `~/.codex`, or inside Switchboard's storage. |
| `app_not_lease_aware` | A running Switchboard app predates leases and would refresh the leased token itself. Update or quit it. |
| `refresh_in_progress` | The app is refreshing this account's token right now. Lease again in a few seconds. |
| `no_lease_at_home`, `no_candidate`, `same_account`, `not_usable`, `swap_incomplete` | `swap-lease`: no lease at that home, no other leasable account, the target is already there, the target has no quota left, or the swap stopped halfway. |
| `account_leased`, `surface_is_lease_home` | `switch` refused a leased account, or a surface whose auth store is a lease home. |
| `surface_is_reserved_home`, `surface_is_lane_home` | `switch` refused a surface whose auth store is a reserved login's home, or a lane home (it has `holder.lock`). Unset `CODEX_HOME`. |
| `lease_store_unreadable` | Switchboard could not read `leases.json`; every writer fails closed. |

## Pressure Scenario

An orchestrator says: "A Codex CLI agent exhausted its current account. Put it back to work if a paid account has tokens."

Correct behavior:

- Run `doctor --json` and redacted `status --json --paid-only --usable-only`.
- Select a paid usable profile by `score`.
- If consumers are running, either run `switch` without `--stop-consumers` and report the refusal, or ask/confirm before stopping consumers.
- Verify `active_profile_key` after a successful switch.
- Do not print token fields, raw auth files, or full unredacted account dumps.

Incorrect behavior:

- Reading `auth.json` into chat.
- Choosing a free plan because it has reset sooner.
- Copying an `auth.json` into a lane's `CODEX_HOME` instead of leasing it.
- Using `--stop-consumers` without explicit authorization.
- Claiming success without verifying the active profile.
