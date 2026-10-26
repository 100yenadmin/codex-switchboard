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

A lease lends one account's captured auth to a separate `CODEX_HOME`, so an automated lane runs on its own account without touching the main CLI or Desktop sign-in. While a lease is active its home is the account's only live holder: `switch`, `autoswap`, and the app's own switching and token refresh all leave the account alone, and the Switchboard app writes every token rotation in the home back to the stored profile. `return` writes the latest token back and clears the lease.

1. Pick a paid, usable account that no surface is using. `--usable-only` already leaves out leased accounts:

```bash
codex-switchboard status --json --surface all --paid-only --usable-only \
  | jq '{active: [.surfaces[] | .active_profile_key], accounts: [.accounts[] | {profile_key, plan, needs_relogin, session_free_percent, weekly_free_percent, score, leased}]}'
```

Choose a `profile_key` that is not in `active`.

2. Lease it into a dedicated, empty directory. The CLI creates the directory with mode `0700` and writes `auth.json` with mode `0600`:

```bash
codex-switchboard lease --profile-key "$PROFILE_KEY" --home "$LANE_HOME" --holder "$LANE_NAME" --json \
  | jq '{profile_key, home, holder, leased_at, auth_written}'
```

3. Run the lane with `CODEX_HOME="$LANE_HOME"`. Do not run `codex-switchboard` itself with `CODEX_HOME` pointing at the lease home.

4. Check active leases at any time:

```bash
codex-switchboard leases --json \
  | jq '[.leases[] | {profile_key, holder, home, home_auth_present, home_matches_stored_profile, active_on_surface}]'
```

`home_matches_stored_profile: false` means the home holds a rotation the stored profile has not picked up yet; the running app mirrors it within seconds, and `return` always writes it back. `active_on_surface: true` means something switched a surface to the leased account outside Switchboard; stop and report it.

5. When every process in the lane has exited, return the lease:

```bash
codex-switchboard return --profile-key "$PROFILE_KEY" --home "$LANE_HOME" --json \
  | jq '{profile_key, holder, sync, home_auth_removed}'
```

`sync` is `rotated` when the home held a newer token, `unchanged` when it did not, or `home_auth_missing` when the lane already deleted `auth.json` (the stored profile then keeps the last mirrored token).

Refusals exit with status 2 and a JSON `error` code. Report the code; never work around it by editing auth files:

| `error` | Meaning |
|---------|---------|
| `active_account` | The account is the active CLI or Desktop account. Pick another. |
| `already_leased`, `home_already_leased` | The account, or the home, already has a lease. |
| `free_plan`, `plan_unknown`, `needs_relogin`, `unknown_profile` | The account cannot be leased. |
| `home_holds_other_account`, `home_holds_other_login` | The home already holds a sign-in (for example its own device-code login). Use an empty home. |
| `home_not_allowed` | The home is `~`, a Switchboard surface home such as `~/.codex`, or inside Switchboard's storage. |
| `app_not_lease_aware` | A running Switchboard app predates leases and would refresh the leased token itself. Update or quit it. |
| `refresh_in_progress` | The app is refreshing this account's token right now. Lease again in a few seconds. |
| `home_in_use` | `return` found processes holding files open in the home (pid and program name in `details`). Stop them first. |
| `account_leased`, `surface_is_lease_home` | `switch` refused a leased account, or a surface whose auth store is a lease home. |
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
