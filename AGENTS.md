# AGENTS.md

This file is the short operator's guide for this repository. For the
full contract, see [`SPECIFICATION.md`](SPECIFICATION.md); this file
deliberately does not duplicate it.

## What this repo is

A self-contained installer for a command that runs arbitrary commands
(or an interactive subshell) with environment variables loaded from
a **1Password Environment** (the developer beta feature —
[docs](https://developer.1password.com/docs/environments)). Variables
are read at wrapper runtime via `op run --environment <ENV-ID>`.
The wrapper does **not** enumerate any 1Password vault.

Cross-platform: same factory, same rendered wrapper bytes, on
**Linux** and **macOS**. The wrapper picks its credential-retrieval
path at runtime via `case "$(uname)"`:

- **Linux**: token stored as a systemd encrypted credential at
  `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>` —
  plaintext token files on disk are explicitly forbidden. The
  wrapper self-escalates via `sudo -n`, decrypts the credential
  with `systemd-creds`, then drops privileges via `setpriv` back to
  the **invoker** (the user who ran the wrapper, identified by
  `SUDO_UID` / `SUDO_GID` / `SUDO_USER`) before invoking `op`.
- **macOS**: token stored in the operator's per-user **login
  Keychain** under service `<IDENTIFIER>`, account
  `OP_SERVICE_ACCOUNT_TOKEN`. The wrapper retrieves it via
  `security find-generic-password -w` into a memory variable, then
  runs `op run --environment <env-id>`. No `sudo`, no privilege
  drop — the macOS login session is the security boundary.

On either platform, the token never appears on a command line and
never touches disk after retrieval.

A single `IDENTIFIER` value names the wrapper command name and the
secure-store scope (Linux group / Keychain service). It does NOT
determine the runtime UID — that is always the invoker's UID. The
1Password Environment itself is identified by a separate input,
`ONEPASSWORD_ENVIRONMENT_ID`, copied from the 1Password desktop
app: `Developer → View Environments → Manage environment → Copy
environment ID`.

## Prerequisites

**Common (both platforms):**
- The **1Password CLI beta** with Environments support
  (`op` `2.33.0-beta.02` or later — verified working on
  `2.35.0-beta.01`). Stable `op` 2.34.0 lacks the `op environment`
  subcommand and `op run --environment` flag. Download:
  <https://releases.1password.com/developers/cli-beta/>
- An existing 1Password **Environment** containing the variables
  to inject (each Environment entry is a `KEY=value` pair). Copy
  the Environment ID from the desktop app:
  `Developer → View Environments → Manage environment → Copy
  environment ID`
- A 1Password **service account** token with read access to that
  Environment

**Linux only:**
- Linux host with **systemd** (`systemctl`, `systemd-creds`),
  `sudo` (GNU sudo, not `sudo-rs` — `-E` / `--preserve-env=` is
  required), and `setpriv` (`util-linux`)
- A POSIX **`env(1)`** — GNU coreutils OR **uutils coreutils** both
  work, **because the rendered wrapper deliberately avoids GNU-only
  `env VAR=val -- cmd`**. Some hosts symlink `/usr/bin/env` to uutils
  coreutils, whose `env` rejects the `--` separator
  (`env: '--': No such file or directory` /
  `use -[v]S to pass options in shebang lines`). When editing the
  template, keep every `env` invocation `--`-free (use `env VAR=val cmd`);
  `sudo`'s and `setpriv`'s own `--` are fine, and the render tests assert
  no `env … --` remains. This portability bug was the first domino in a
  multi-layer credential-injection failure — do not reintroduce it.
- An existing Linux **group** named `IDENTIFIER`. (A Linux user
  named `IDENTIFIER` is NOT required — the wrapper drops
  privileges back to the invoker at runtime, not to a separate
  IDENTIFIER user.)

**macOS only:**
- The `security` CLI (always present in modern macOS).
- That's it. No `sudo`, no group, no Linux user. The installer
  refuses to run under `sudo` on macOS, because Keychain seeding
  under `sudo` would target `/var/root`'s login keychain instead
  of yours.

## Install the wrapper

Run the installer from the repository root. Put a leading space on
the command so most shells skip history (requires
`HISTCONTROL=ignorespace` or `ignoreboth`), and pass the token as a
**bash local-env prefix** so it never appears on a command-line
argument (auditd / `auth.log` / journal log argv but not env):

### Linux

```sh
  OP_SERVICE_ACCOUNT_TOKEN='ops_EXAMPLE_TOKEN_NOT_A_REAL_VALUE' \
   IDENTIFIER=openbrain \
   ONEPASSWORD_ENVIRONMENT_ID='blgexucrwfr2dtsxe2q4uu7dp4' \
   sudo -E ./create-1password-env-wrapper.sh
```

### macOS

```sh
  OP_SERVICE_ACCOUNT_TOKEN='ops_EXAMPLE_TOKEN_NOT_A_REAL_VALUE' \
   IDENTIFIER=openbrain \
   ONEPASSWORD_ENVIRONMENT_ID='blgexucrwfr2dtsxe2q4uu7dp4' \
   ./create-1password-env-wrapper.sh
```

Optional inputs (see `SPECIFICATION.md` for defaults and full list):

- `INSTALL_PREFIX` (default `/usr/local/bin`; on macOS, falls back
  to `~/.local/bin/` if `/usr/local/bin/` is not writable)
- `DEFAULT_SHELL` (default `/bin/bash`)

There is **no** `TOKEN_STORAGE_MODE` knob — token storage is the
platform's secure store (systemd-creds on Linux, login Keychain on
macOS).

### What the installer does

The installer renders the wrapper to `./with-<IDENTIFIER>-env.sh`
at the repository root (gitignored, inspect it before it is copied
in). The rendered bytes are **identical** regardless of which
platform did the rendering. Then per-platform:

**Linux:**
- encrypts the token via `systemd-creds encrypt` into
  `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
  (owner `root:root`, mode `0600`),
- installs the wrapper at
  `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` with owner
  `root:<IDENTIFIER>` and mode `0750`,
- drops a sudoers fragment at
  `/etc/sudoers.d/with-<IDENTIFIER>-env` granting `%<IDENTIFIER>`
  passwordless `sudo` for that one wrapper,
- adds `$SUDO_USER` to the `<IDENTIFIER>` group,
- ensures `.gitignore` contains both `/with-*-env.sh` and
  `.env.local`.

**macOS:**
- stores the token in the operator's login Keychain via
  `security add-generic-password -s "<IDENTIFIER>" -a
  OP_SERVICE_ACCOUNT_TOKEN -w "<token>" -U` (idempotent — `-U`
  updates an existing entry or creates a new one),
- installs the wrapper at
  `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` owned by the
  invoking user, mode `0755`,
- ensures `.gitignore` contains both `/with-*-env.sh` and
  `.env.local`.
- no sudoers fragment, no group, no `usermod` calls.

After the Linux installer completes, your existing shell does not
yet reflect the new group membership — but `sudo` evaluates
`/etc/group` on every invocation, so the wrapper's stage-0
`sudo -n` self-escalation works immediately. To get
`with-…-env.sh` into your interactive shell's idea of "my groups"
(so for example the wrapper's setgid bit on `0750` doesn't trip
`[ -x ]` for adjacent tooling), start a new login session or
`exec sg <IDENTIFIER> bash`.

## Run a command via the wrapper

Same on both platforms once installed:

```sh
with-openbrain-env.sh some-command arg1 arg2
```

On Linux, the caller must be a member of the `IDENTIFIER` group
(the installer adds `$SUDO_USER` to it during install). On macOS,
the caller is the user that ran the installer.

Use `--` to end wrapper option parsing if the child command starts
with a dash:

```sh
with-openbrain-env.sh -- ./some-tool --flag value
```

### Your environment reaches the wrapped command

Whatever you had set is what the command sees, plus the variables resolved from
the 1Password Environment. You do not opt in and there is nothing to list:

```sh
MY_VAR=hello with-<id>-env.sh some-command   # some-command sees MY_VAR=hello
```

Where a name is defined on both sides, **the 1Password value wins**.

How it works, because it is not obvious from the stage model. The wrapper
escalates through `sudo`, whose `env_reset` destroys your environment, so
stage 0 captures it first (`env -0`, into a private file on tmpfs) and forwards
only that file's *path* across the boundary. The privileged stage never opens
it. Stage 2 restores it after dropping back to you, then deletes it.

Root is needed for exactly one thing: decrypting the token out of the root-only
credstore. That step reads nothing you set. And the command itself runs as YOU,
so your own variables reaching your own child grant nothing you did not already
have. That is why there is no allowlist and no denylist anywhere on this path.

Three names do not come back, and none of them is yours:
`OP_SERVICE_ACCOUNT_TOKEN` and `WRAPPER_STAGE` are the wrapper's internals (the
first would leak the token into your command; the second would make a nested
wrapper skip its stages), and the third is the pointer to the capture itself.

**`OPENV_PRESERVE_VARS` is retired.** It was a comma-separated allowlist of
names permitted through the old scrub. It is accepted and ignored, so a caller
that still sets it is unaffected — every name it could have listed now crosses
anyway.

### `OPENV_KEEP_PRIVILEGES=1` — run the command as root (default-off)

Skips the drop back to you, so the command runs at the current uid (root, when
reached via `sudo`). Use it only for a child that genuinely needs a root-only
resource, such as a `0750`-guarded unix socket. It takes effect only when the
wrapper is invoked through an external `sudo -E`. In that branch `HOME` stays
root's own, so `op run` accepts its config directory, and your `HOME` is the one
variable the restore holds back.

```sh
OPENV_KEEP_PRIVILEGES=1 sudo -E with-<id>-env.sh <admin-command>
```

The wrapper stays project-agnostic — it hard-codes nothing about any consumer.

### TTL cache of the resolved environment: `OP_ENV_WRAPPER_CACHE_TTL`

Every wrapper invocation calls `op run --environment`, which costs
real CPU time regardless of `op`'s own `OP_CACHE` setting (see
SPECIFICATION.md). On Linux, the wrapper caches the *resolved
variables themselves* — outside of op, in the invoking user's kernel
**persistent keyring** (`keyctl get_persistent`, not the plain `@u`
keyring — `setpriv`'s privilege drop never establishes a login
session, so a plain `@u` entry would be unreadable by the very next
invocation) — so a repeated invocation within the TTL window skips
calling `op` entirely, with zero exceptions: framing is NUL-delimited,
so even a multi-line value (e.g. a PEM key) caches and replays
correctly. Default TTL is 300s; override per-invocation with
`OP_ENV_WRAPPER_CACHE_TTL=<seconds>`, or set `=0` to disable caching
for that call. Requires the `keyutils` package (`keyctl` on `PATH`)
— if it is missing, the wrapper falls open to the uncached path
automatically; no action is needed either way. Full design and
failure-mode contract: SPECIFICATION.md § "TTL cache of the
op-resolved environment".

**A revoked/dead session keyring is the common case, not an edge
case, and is handled automatically.** The Linux kernel session
keyring (`@s`) that the cache lives behind gets REVOKED by
`pam_keyinit.so force revoke` at SSH logout, and a process that
outlives that login — a detached `tmux` server reparented to init, a
long-lived daemon, `sudo` itself (no `pam_keyinit` of its own, so it
only ever inherits whatever `@s` it was handed) — keeps running with
a dead `@s` forever. The wrapper detects this and recovers in-place
via `keyctl new_session` (no re-exec, no subprocess) before falling
back to the uncached path. This is silent by default; set
`OP_ENV_WRAPPER_DEBUG=1` to see the one-line stderr note when it
fires. Any *unrecoverable* cache-path anomaly (keyutils missing, a
keyring quota exceeded, `@s` still unusable after recovery) is always
reported on stderr regardless of the debug flag — see
SPECIFICATION.md § "Revoked/unusable session keyring recovery" for
the measured behavior behind this (including that the recovery is
NOT purely local to the calling process — see that section).

**Keyring quota headroom matters once a host runs several
identifiers.** Each cached Environment costs kernel memory against
`kernel.keys.maxbytes`/`maxkeys` for the invoking uid (a resolved
Environment with a couple of secrets is commonly several KB; a
multi-line PEM-shaped secret pushes it further). The kernel
defaults (`maxbytes=20000`, `maxkeys=200`) fit only 3-4 wrapper
identifiers' worth of cache before `keyctl padd` starts failing with
EDQUOT — silently, unless `OP_ENV_WRAPPER_DEBUG=1` or you're
watching stderr, since a padd failure still lets the current call
succeed (falling back to a live `op run` resolve every time,
quietly re-consuming the 1Password service account's shared daily
rate limit). If a host runs several distinct identifiers, raise
`kernel.keys.maxbytes` and `kernel.keys.maxkeys` for that uid via a
sysctl drop-in before relying on the cache across all of them.

## Open an interactive shell via the wrapper

```sh
with-openbrain-env.sh
```

Exits back to the outer shell when you type `exit`.

## Verify the wrapper

Define at least two variables whose names start with `TEST_` in the
1Password Environment (for example `TEST_FOO=hello`,
`TEST_BAR=world`), then run the installed wrapper against the
checked-in test target:

```sh
with-openbrain-env.sh /absolute/path/to/print-test-env-vars.sh
```

Correct output is every `TEST_*` variable from the Environment,
sorted by name, in `NAME=value` form.

## Rotate the service account token

Rerun the installer with the replacement
`OP_SERVICE_ACCOUNT_TOKEN` and the same `IDENTIFIER`:

- **Linux**: the encrypted credential at
  `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
  and the rendered/installed wrapper are replaced atomically.
- **macOS**: the login-Keychain entry is updated in place via
  `security add-generic-password -U`.

No fetched Environment values, and no plaintext token, are
persisted to disk at any point.

## After changing the template: redeploy is manual, per host, per identifier

A merged change to `create-1password-env-wrapper.sh` changes nothing
on any already-installed wrapper by itself. Every host that has ever
installed a wrapper carries a byte-frozen copy from whenever it was
last (re-)installed — there is no update mechanism. After merging a
template fix:

- **Re-run the installer** for each affected `IDENTIFIER` on each
  host that has it installed. The installer needs the identifier's
  real `OP_SERVICE_ACCOUNT_TOKEN` again (it is not a pure
  re-render); on Linux you can decrypt the *existing* sealed
  credential as root (`systemd-creds decrypt --name=1password-env-wrapper-<id>
  /etc/credstore.encrypted/1password-env-wrapper-<id> -`) and feed
  that straight back into the installer's environment — no need to
  go find the token anywhere else, and no need to expose it on a
  command line or in a log.
- **Verify with behavior, not exit status.** A wrapper that "runs
  successfully" can still be running the OLD, buggy code path — for
  example the pre-fix uncached path also exits 0, just slower and
  wrapping the real command in a resident `op run` for its whole
  life. Verify with what actually changed: a timing measurement
  (cold vs. warm), absence of a lingering `op run` process around a
  long-running real command, and — if the change touches
  stdout/stderr behavior — a byte-comparison of a plain capture vs. a
  `2>&1`-merged capture.
- **Consumer repos that carry their own tracked copy of a rendered
  wrapper drift independently.** At least `openbrain` and `resume`
  commit their `with-<identifier>-env.sh` into their own repo
  (`DO-NOT-EDIT` header, canonical source pointing back here) rather
  than only relying on the installed copy — re-rendering on the host
  does NOT update that tracked copy; it has to be copied over and
  committed in that repo separately. `dolt-server`'s wrapper is a
  different case entirely: it is adopter-owned, NOT rendered from
  this template, and never calls `op` at all (systemd-creds-only
  backend) — do not "fix" it as part of a template change; it is
  out of scope by design.
- **macOS has no keyring-based cache at all** (the Darwin branch has
  no keyring code) — every call there is a full `op run`, always.
  This is a known, pre-existing gap, not a regression from any
  Linux-side cache fix, and is out of scope for a Linux keyring fix
  unless the PR says otherwise.

## Running the integration test

**Warning — this can silently reinstall a live production wrapper.**
`test/integration.bats` defaults `INSTALL_PREFIX` to `/usr/local/bin`
on Linux — the same location real wrappers are actually installed
to. If you run this suite on a host that also runs a live wrapper
for `IDENTIFIER=openbrain`, it reinstalls that production wrapper
from whatever is in *your current working tree* — including a dirty
or unmerged branch — with no confirmation and no log line calling it
out. This already happened once (see
[#12](https://github.com/thewoolleyman/1password-env-wrapper/issues/12)):
running the suite once to satisfy "tests must stay green" before a
PR quietly deployed that PR's own not-yet-merged code to production,
and the resulting mismatch (installed file older than the PR it was
supposedly testing, missing a commit that landed after) was initially
mistaken for something else entirely before the actual cause —
the test run — was traced down. Until #12 is fixed, treat
`bats test/integration.bats` as a deploy action on any host that also
runs a real installed wrapper for the identifier under test, not as a
side-effect-free test run — check whether that identifier is live on
the host you're about to run it on first.

The repository ships a Bats integration test at
`test/integration.bats` that drives the installer against real
1Password infrastructure, with platform-specific assertions gated
by `uname`. To run it:

1. Make sure the host has `bats`, `bats-support`, `bats-assert`,
   `op`, `jq`. On Linux, additionally `sudo` and the Linux group
   `openbrain` (a Linux *user* named `openbrain` is no longer
   required). On macOS, no extra preconditions.
2. Populate the gitignored bootstrap secret file `.env.local` at the
   repository root with a real service account token AND the
   Environment ID. Starting from placeholders:

   ```sh
   {
     printf 'OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=PLACEHOLDER\n'
     printf 'OPENBRAIN_1PASSWORD_ENVIRONMENT_ID=PLACEHOLDER\n'
   } > .env.local
   # then edit .env.local and replace each PLACEHOLDER with the real value
   ```

   The test will fail fast if either entry is missing or still
   reads `PLACEHOLDER` and no encrypted-state fallback is reachable.
3. Make sure the 1Password Environment identified by
   `OPENBRAIN_1PASSWORD_ENVIRONMENT_ID` contains
   `TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE` and
   `TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2`.
4. From the repository root, run:

   ```sh
   bats test/integration.bats
   ```

   On Linux, the test invokes `sudo` itself; the outer `bats`
   process does not need to run as root, but the session MUST be
   able to escalate via `sudo`. On macOS, the test runs entirely
   as the invoking user — no `sudo` at all.

## Example shell interaction (Linux)

The following transcript shows an operator installing the wrapper
with `IDENTIFIER=openbrain`, then running the verification target
and an interactive shell — both as the same operator (`admin`),
because the wrapper drops privileges back to the invoker, not to
a separate IDENTIFIER user. The token value is an obvious
placeholder.

```console
admin@vps:~/projects/1password-env-wrapper$ whoami
admin
admin@vps:~/projects/1password-env-wrapper$ OP_SERVICE_ACCOUNT_TOKEN='ops_EXAMPLE_TOKEN_NOT_A_REAL_VALUE' \
>   IDENTIFIER=openbrain \
>   sudo -E ./create-1password-env-wrapper.sh
added admin to group openbrain (next sudo invocation picks this up)
installed /usr/local/bin/with-openbrain-env.sh (root:openbrain, mode 0750)
encrypted credential: /etc/credstore.encrypted/1password-env-wrapper-openbrain
sudoers fragment:     /etc/sudoers.d/with-openbrain-env
1Password Environment ID: …env-id…
admin@vps:~/projects/1password-env-wrapper$ with-openbrain-env.sh /home/admin/projects/1password-env-wrapper/print-test-env-vars.sh
TEST_BAR=world
TEST_FOO=hello
admin@vps:~/projects/1password-env-wrapper$ with-openbrain-env.sh
admin@vps:~$ echo "$TEST_FOO"
hello
admin@vps:~$ echo "${OP_SERVICE_ACCOUNT_TOKEN:-<unset>}"
<unset>
admin@vps:~$ exit
exit
admin@vps:~/projects/1password-env-wrapper$
```

## Example shell interaction (macOS)

Same flow, no `sudo`. Note the success line refers to the Keychain
service/account instead of the systemd-creds path, and there is no
sudoers fragment line:

```console
admin@laptop ~/projects/1password-env-wrapper % whoami
admin
admin@laptop ~/projects/1password-env-wrapper % OP_SERVICE_ACCOUNT_TOKEN='ops_EXAMPLE_TOKEN_NOT_A_REAL_VALUE' \
>   IDENTIFIER=openbrain \
>   ./create-1password-env-wrapper.sh
installed /usr/local/bin/with-openbrain-env.sh (mode 0755, owned by admin)
Keychain entry: service=openbrain account=OP_SERVICE_ACCOUNT_TOKEN (user login keychain)
1Password Environment ID: …env-id…
admin@laptop ~/projects/1password-env-wrapper % with-openbrain-env.sh /Users/admin/projects/1password-env-wrapper/print-test-env-vars.sh
TEST_BAR=world
TEST_FOO=hello
admin@laptop ~/projects/1password-env-wrapper % with-openbrain-env.sh
admin@laptop ~ % echo "$TEST_FOO"
hello
admin@laptop ~ % echo "${OP_SERVICE_ACCOUNT_TOKEN:-<unset>}"
<unset>
admin@laptop ~ % exit
exit
admin@laptop ~/projects/1password-env-wrapper %
```
