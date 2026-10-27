# Codex accounts for agent lanes

How an agent lane gets a Codex account from Switchboard, keeps it, and gives it back, and how an agent moves the main
CLI to another account when its quota runs out. The full command reference and every refusal code are in
[`skills/codex-switchboard/SKILL.md`](../skills/codex-switchboard/SKILL.md).

## Three kinds of account

| Kind | Where its sign-in lives | Who may switch to it |
|------|-------------------------|----------------------|
| Main | `~/.codex`, shared by the Codex CLI and Desktop | `codex-logins.py swap`, or the user |
| Leased | A lane's own `CODEX_HOME`, written by `codex-switchboard lease` | Nobody until it is returned. Its refresh token is single-use: a second live copy logs both holders out. |
| Reserved | A login listed in `~/.config/codex-logins/registry.json`, with its own sign-in in its own home | Nobody. Its quota belongs to its consumer. Switchboard never leases it, and never switches or auto-swaps onto it. |

`codex-switchboard leases --json` lists every lease (states `leasing`, `active` and `returning` all count as leased).
`python3 scripts/codex-logins.py status` lists every account by handle and email, marks the main, leased and reserved ones, and
shows each reserved home's health. The Switchboard CLI shows each account's email beside its handle (`acct_` plus
12 hex digits). Agents may print emails and handles, never tokens, account ids, profile keys or raw auth files.

## Swap the main CLI when its account runs low

```bash
python3 scripts/codex-logins.py swap --dry-run
python3 scripts/codex-logins.py swap
```

`swap` picks the best paid, usable account that is neither leased nor reserved (matched by seat, so another key of
the same account is refused too), switches the CLI to it by handle, and confirms the switch. Switchboard re-checks
leases and reservations under its own store lock before it writes. It never stops running Codex processes; if
Switchboard refuses because they are running, report it rather than adding `--stop-consumers`.

To check one account before a switch someone asked for: `python3 scripts/codex-logins.py check-switch --profile-key NAME`,
where NAME is a handle, a profile key or an email. It resolves NAME with `codex-switchboard resolve`, by the rules
`lease` and `switch` use, and on exit 0 prints the account's handle; switch by that handle.

| Exit | Meaning |
|------|---------|
| 0 | Safe (`check-switch`); switched and confirmed (`swap`; with `--dry-run`, an account passes) |
| 1 | Reserved, or shares its email with a reserved account |
| 2 | The registry is missing, unreadable, or reserves a key Switchboard no longer lists; if nothing is reserved, the registry is `{"version": 1, "logins": []}` |
| 3 | Leased, or shares its email with a leased account |
| 4 | Switchboard's account or lease state cannot be read, the name matches no account or several, or an account the seat check compares has no stored email |
| 5 | `swap`: no other account passes |
| 6 | `swap`: Switchboard refused or failed the switch (its `error` code is printed) |
| 7 | `swap`: the switch did not take or cannot be confirmed |

Any nonzero exit means do not switch. Do not retry around it.

## Lease an account for a lane

Switchboard's `--profile-key` accepts a profile key, a handle or an email (trimmed and case-insensitive).
An email shared by several keys refuses with `ambiguous_account`; pick a handle from the listed handles, plans
and workspaces. `return` considers only leased keys. `--exclude-profile-key EMAIL` excludes all matching accounts.

1. Pick one: `codex-switchboard status --json --leasable-only | jq '[.accounts[] | {handle, email, plan, weekly_free_percent, score}]'`.
2. Lease it into a new, empty directory under a holder name that is a lane label, never an email (holder names are
   shown by `leases`):
   `codex-switchboard lease --profile-key HANDLE --home LANE_HOME --holder LANE_NAME --json | jq '{handle, email, lease_id}'`.
3. Run the lane with `CODEX_HOME=LANE_HOME`: one Codex process per lease home, holding `flock(LOCK_EX | LOCK_NB)` on
   `LANE_HOME/holder.lock` for its lifetime. Run `codex-switchboard` itself with `CODEX_HOME` unset.
4. Codex refreshes the token in place; the Switchboard app writes each rotation back to its stored copy.
5. When the account runs low, between runs and with every process in the home stopped:
   `codex-switchboard swap-lease --home LANE_HOME --holder LANE_NAME --json`.
6. When the lane is finished: `codex-switchboard return --profile-key HANDLE --home LANE_HOME --json`. Return writes
   the latest token back and leaves a tombstone in place of `auth.json`. After a crash, run `return` again.

Never copy an `auth.json` between homes, never edit lease, lock or journal files, and never remove
`auth.json.stopped` from a quarantined home unless you own it.

## Reserve a login

A consumer that needs an account nobody else touches (for example a benchmark with its own device-code sign-in)
signs in inside its own home, then registers it:

```bash
python3 scripts/codex-logins.py register --purpose LABEL --home DIR --consumer TEXT
```

`LABEL` is a lowercase label; it is the only registry text the tool prints. Registration refuses the account a CLI
or Desktop surface is on, a leased account, a free-plan account, and an account reserved under another label, and
refuses while a surface keeps its sign-in in a keychain, where Switchboard cannot see which account it is on.
