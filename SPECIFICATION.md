# 1Password Environment Wrapper Factory

## Example Prompt

Run the following prompt in a fresh Claude Code (or equivalent) session
against a clone of this repository to (re)generate or update the
implementation whenever this specification changes:

> Read `SPECIFICATION.md` from top to bottom. Produce or update every
> file the specification prescribes so that the repository matches the
> spec exactly. Do not add files the spec does not describe. Never
> check any rendered `with-<identifier>-env.sh` into git; it is
> generated output. Never check `.env.local` into git; it is the
> gitignored bootstrap secret file. Every checked-in `*.sh` file must
> start with `#!/usr/bin/env bash`, enable `set -Eeuo pipefail`, be
> `chmod +x`, and pass `shellcheck` with no findings. Update
> `AGENTS.md` whenever the user-facing workflow changes. Do not
> execute the installer yourself at implementation time; after the
> implementation is in place, run the BATS integration test at
> `test/integration.bats` (which invokes the installer under `sudo`
> with the bootstrap token loaded from `.env.local`) to prove the
> happy path end-to-end. If `.env.local` is missing or still contains
> `PLACEHOLDER`, stop and tell the human operator to populate it
> instead of fabricating a token. Use your best judgement for
> implementation details that the spec does not nail down (exact `op`
> subcommand choice, shellcheck-friendly idioms, error wording);
> briefly note the judgements made at the end of the run. Only stop
> and ask the operator when the spec is flatly contradictory or
> requires information you cannot obtain.

## Overview

This repository is a self-contained installer for a
working-directory-agnostic wrapper command that runs arbitrary
commands, or an interactive subshell, with environment variables
loaded from a **1Password Environment** — specifically the
1Password developer "Environments" feature
([docs](https://developer.1password.com/docs/environments)),
*not* arbitrary items in a vault. Variables are read at wrapper
runtime via `op run --environment <ENV-ID>`. The wrapper SHALL NOT
enumerate items in any 1Password vault.

The installer renders the wrapper, stores the 1Password service
account token in a platform-appropriate secure store, and installs
the wrapper under `${INSTALL_PREFIX}` (default `/usr/local/bin`).

The installer's supported runtime targets are **Linux with systemd**
and **macOS**. See [Platform Support](#platform-support) below for
the full per-platform contract; the short version is that Linux
stores the token as an encrypted systemd credential under
`/etc/credstore.encrypted/` and gates wrapper invocation behind a
sudoers fragment + group membership, while macOS stores the token
in the per-user login Keychain and relies on the user's login
session as the security boundary. Any plaintext-on-disk token
storage (e.g. a root-owned `*.token` file under `/etc/`) is
explicitly forbidden on either platform — outside of the gitignored
`.env.local` bootstrap file at the repository root, the raw token
SHALL never exist on disk.

The 1Password CLI (`op`) MUST be a build that supports
`op environment read` and `op run --environment` — these are the
"1Password Environments" beta features introduced in the
`2.33.0-beta.02` line. The earliest verified compatible build is
`2.35.0-beta.01`.

The installer is intended for VPS setup and ad-hoc maintenance work.
It is not specific to Open Brain, although Open Brain is the first
target use case. The example identifier used throughout this
documentation is `openbrain`, which yields a wrapper installed as
`with-openbrain-env.sh`.

The installer script and the test target are checked into this
repository. The rendered wrapper script is a gitignored build
artifact, so an operator can review the exact script that is about to
be installed before privileged copy-in, but the rendered file never
reaches version control.

## Platform Support

The installer and the rendered wrapper run on **Linux with systemd**
and on **macOS**. Windows is out of scope.

### Byte-identicality invariant

For identical inputs (`IDENTIFIER`, `OP_SERVICE_ACCOUNT_TOKEN`,
`ONEPASSWORD_ENVIRONMENT_ID`, `INSTALL_PREFIX`, `DEFAULT_SHELL`),
the rendered wrapper at `${INSTALL_PREFIX}/with-${IDENTIFIER}-env.sh`
SHALL be **byte-identical** whether the installer ran on Linux or on
macOS. `diff -q` between the two renderings SHALL exit 0.

This holds because the rendered wrapper always contains BOTH the
Linux runtime branch and the macOS runtime branch; it dispatches
between them at execution time via `case "$(uname -s)"`. The
installer's *behavior* differs per host (different secure stores,
different filesystem permissions, different sudoers handling); the
wrapper's *bytes* do not.

A consumer project MAY commit the rendered wrapper to its own
repository and trust that the same file works on both Linux VPSs
and macOS dev machines without diff thrash.

### Linux runtime model (recap)

The Linux path is a 3-stage `WRAPPER_STAGE` re-exec:

1. **Stage 0 — escalate.** `sudo -n` self-escalate to root,
   targeting the *installed* wrapper path (so the sudoers fragment
   only ever needs to whitelist one absolute path).
2. **Stage 1 — decrypt and drop.** As root, `systemd-creds decrypt`
   the credential at
   `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
   into a memory variable, then `setpriv --reuid=$SUDO_UID
   --regid=$SUDO_GID --init-groups` re-exec the wrapper as the
   *invoker* with the token in env (`WRAPPER_STAGE=2`).
3. **Stage 2 — run.** As the invoker, `op run --environment
   <ONEPASSWORD_ENVIRONMENT_ID> -- env -u
   OP_SERVICE_ACCOUNT_TOKEN -- "$@"` (so the final child never
   sees the token).

The full Stage-1 contract — including the `SUDO_UID`/`SUDO_GID`/
`SUDO_USER` invariant, the `getent passwd` invoker-home lookup,
the deterministic `PATH`, and the failure modes — is documented
under "Runtime Behavior" below. That section applies to the Linux
branch only; the macOS branch has its own contract in the next
subsection.

### macOS runtime model

macOS is a **single-stage** path with **no privilege escalation
and no privilege drop**:

1. `security find-generic-password -s "<IDENTIFIER>" -a
   "OP_SERVICE_ACCOUNT_TOKEN" -w` retrieves the token from the
   per-user login Keychain into a memory variable.
2. `unset OP_CONNECT_HOST OP_CONNECT_TOKEN; export OP_CACHE=false`
   (parity with the Linux Stage-2 hardening).
3. `exec env OP_SERVICE_ACCOUNT_TOKEN="$token" op run
   --no-masking --environment <ONEPASSWORD_ENVIRONMENT_ID> -- env
   -u OP_SERVICE_ACCOUNT_TOKEN -- "$@"` so the final child never
   sees the token.

Rationale for the asymmetry: single-user macOS dev machines do not
have a separate IDENTIFIER user that needs isolating from the
invoker, and macOS has no sudo-equivalent of "escalate to read the
credstore then drop back." The login Keychain itself provides the
access control — only the user's logged-in session can read it,
and macOS does not give other users on the same system any way to
read it without that session's authentication. If a future
deployment scenario requires per-user isolation on macOS, that is
a separate, larger design problem.

The macOS path SHALL fail closed with a non-zero exit code and an
error message (no secret values) when:

- the Keychain entry is missing (`security find-generic-password`
  exits non-zero);
- the Keychain entry is present but empty;
- the configured Environment ID cannot be resolved by `op run
  --environment`;
- the service account token cannot read the Environment;
- `op`'s injection mechanism returns a non-zero exit status before
  the child command runs.

When the child command runs, the wrapper SHALL propagate the
child's exit code as its own.

### Per-platform installer behavior

| Aspect | Linux | macOS |
|---|---|---|
| Invocation | `sudo -E ./create-…sh` | `./create-…sh` (no sudo) |
| Token store | `systemd-creds encrypt` → `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>` (root:root, 0600) | `security add-generic-password -U` → login Keychain (service `<IDENTIFIER>`, account `OP_SERVICE_ACCOUNT_TOKEN`) |
| Wrapper owner | `root:<IDENTIFIER>`, mode `0750` | invoking user, mode `0755` |
| Sudoers fragment | `/etc/sudoers.d/with-<IDENTIFIER>-env` (root:root, 0440) | none |
| Group membership | invoker added to `<IDENTIFIER>` group | none |
| Linux IDENTIFIER group required | yes | no |
| Default `INSTALL_PREFIX` | `/usr/local/bin` | `/usr/local/bin` (falls back to `~/.local/bin/` if not writable) |
| Prereqs | `sudo`, `setpriv`, `systemd-creds`, `op` (Environments-aware) | `security` (always present), `op` (Environments-aware) |

Both platforms share the inputs (`IDENTIFIER`,
`OP_SERVICE_ACCOUNT_TOKEN`, `ONEPASSWORD_ENVIRONMENT_ID`,
`INSTALL_PREFIX`, `DEFAULT_SHELL`), the rendered wrapper bytes, the
`.gitignore` discipline, and the validation step (decrypt/recover
the token, then `op environment read` to confirm the Environment
is reachable).

## The `IDENTIFIER` concept

A single `IDENTIFIER` input names the wrapper-side coupled entities:

- the wrapper command name `with-<IDENTIFIER>-env.sh` (both platforms);
- on **Linux**, the Linux **group** that owns the installed wrapper
  binary so only its members may execute it (members of this group
  are the operators allowed to invoke the wrapper without a sudo
  password prompt) and the systemd encrypted credential name
  `1password-env-wrapper-<IDENTIFIER>` under
  `/etc/credstore.encrypted/`;
- on **macOS**, the Keychain **service name** under which the
  service-account token is stored (`security add-generic-password
  -s "<IDENTIFIER>" -a OP_SERVICE_ACCOUNT_TOKEN -w ...`).

`IDENTIFIER` does NOT determine the runtime UID on either platform.
On Linux, the wrapper drops privileges back to the *invoker* at
runtime via `setpriv`, not to a separate IDENTIFIER user; a Linux
user named `IDENTIFIER` is not required. On macOS, the wrapper runs
as the invoking user throughout (no privilege escalation occurs).

The 1Password-side coupled entity — the **1Password Environment** —
is identified by its **Environment ID** (a 1Password-assigned
opaque string, copied via the 1Password desktop app:
`Developer → View Environments → Manage environment → Copy
environment ID`). The Environment ID is a *separate* required
input, `ONEPASSWORD_ENVIRONMENT_ID`. There is no implicit "vault
named after IDENTIFIER" linkage — the wrapper does not read
vault items at runtime.

`IDENTIFIER` SHALL match the regex `^[a-z][a-z0-9-]{0,30}[a-z0-9]$`:
lowercase letters, digits, and single hyphens; starting with a
letter; no trailing hyphen; total length 2–32. The installer SHALL
reject values that do not match. Example values: `openbrain`,
`acme-prod`.

The installer SHALL NOT attempt to create the Linux group (Linux),
nor the 1Password Environment (any platform). On Linux, the
IDENTIFIER group SHALL already exist before installation. The
operator SHALL provide `ONEPASSWORD_ENVIRONMENT_ID` for the
Environment on either platform.

## Repository Layout

The repository root SHALL contain exactly these files that are in the
scope of this spec. Files outside this table (e.g. `.git/`, `.idea/`,
editor state, license files) are permitted but out of scope.

| Path | Tracked in git | Purpose |
|---|---|---|
| `SPECIFICATION.md` | yes | This document. The source of truth for the repository contents. |
| `AGENTS.md` | yes | Human- and agent-facing usage guide; includes an example shell interaction using `openbrain` as the identifier. |
| `create-1password-env-wrapper.sh` | yes | Installer. Validates inputs, renders the wrapper, stores the service account token, and installs the wrapper on the system. |
| `print-test-env-vars.sh` | yes | Test target. Prints every environment variable whose name starts with `TEST_`. Used to prove injection works by invoking the installed wrapper against this script. |
| `test/integration.bats` | yes | BATS integration test that drives the installer with the `.env.local` bootstrap token and asserts the happy path end-to-end. |
| `.gitignore` | yes | Ignores the rendered wrapper (`/with-*-env.sh`) and the bootstrap secret file (`.env.local`). |
| `with-<IDENTIFIER>-env.sh` | **no (gitignored)** | Rendered wrapper build artifact produced by the installer; copied into `INSTALL_PREFIX` during installation. |
| `.env.local` | **no (gitignored)** | Bootstrap secret file holding real service account tokens used to run the integration test on a developer or operator machine. |

All shell scripts in this repository SHALL:

- begin with `#!/usr/bin/env bash`;
- enable strict mode via `set -Eeuo pipefail` before any other logic;
- be executable (`chmod +x`);
- pass `shellcheck` with no findings on the default severity level.

## Architecture Principles

1. **Service account token is secret zero.** The 1Password service
   account token is the only bootstrap secret the VPS needs. Every
   other runtime secret is fetched from 1Password at wrapper
   execution time.
2. **The 1Password Environment is the canonical env-var source.**
   The wrapper SHALL inject variables from the 1Password
   Environment whose ID is `ONEPASSWORD_ENVIRONMENT_ID` via
   `op run --environment <id> -- <child>`. A variable's name in the
   Environment SHALL be the environment variable name seen by the
   child process. The wrapper SHALL NOT read any 1Password vault,
   item, or secret reference outside of what the Environments
   feature itself resolves.
3. **No vault-item projection.** The wrapper SHALL NOT enumerate or
   project vault items into environment variables, regardless of
   whether a vault with the same name as `IDENTIFIER` exists. Vault
   contents are not part of this contract.
4. **No plaintext secrets on disk.** Outside of the gitignored
   `.env.local` bootstrap file at the repository root, the raw
   service account token SHALL never exist on disk. The installer
   and the wrapper MUST NOT write fetched 1Password Environment
   variables to `.env`, `.env.local`, shell profile files, or any
   other file on disk. Variables flow from `op run --environment`'s
   internal channel directly into the child process; no
   intermediate file is created.
5. **Token storage is the platform's secure store, only.** The
   service account token SHALL be persisted exclusively in a
   platform-appropriate secure store. A plaintext token file
   (or any other on-disk plaintext representation) is explicitly
   forbidden on either platform.
   - On **Linux**, the secure store is the systemd encrypted
     credential at
     `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`,
     created via `systemd-creds encrypt`. Decryption requires
     `root`, so the wrapper uses a brief `sudo -n` self-escalation
     to gain root, decrypts the credential into memory, then
     immediately drops privileges back to the **invoker** (the user
     who initiated the sudo self-escalation, identified by the
     `SUDO_UID` / `SUDO_GID` / `SUDO_USER` environment variables
     that `sudo` always sets on the elevated process) via
     `setpriv` before invoking `op`. The token never appears in a
     process command line and never touches disk after decryption.
     The runtime privilege target is the invoker, not the
     `IDENTIFIER` user. This aligns the wrapper with the project's
     single-VPS / single-operator scope: the operator owns the
     files they intend to operate on (repo checkouts, deploy
     tooling artifacts, build directories), and dropping into a
     separate shared identity creates filesystem-permission friction
     without increasing security on a host that already gates the
     wrapper through the operator's own sudo session. `IDENTIFIER`
     continues to scope the credential file, the wrapper command
     name, the 1Password Environment, and the sudoers gate (via
     group membership) — but NOT the runtime UID. There is no
     requirement that a Linux user named `IDENTIFIER` exists.
   - On **macOS**, the secure store is the per-user **login
     Keychain**, stored as a generic password under service name
     `<IDENTIFIER>` and account name `OP_SERVICE_ACCOUNT_TOKEN`,
     created via `security add-generic-password -U`. macOS
     restricts Keychain reads to the user's logged-in session, so
     no privilege escalation is needed and none is performed; the
     wrapper runs entirely as the invoking user, retrieves the
     token via `security find-generic-password -w` into a memory
     variable, and execs `op run --environment …` with the token
     in env. As on Linux, the token never appears in a process
     command line and never touches disk after retrieval.
6. **Linux: sudoers grants the `IDENTIFIER` group passwordless
   escalation for this one wrapper. macOS: no sudoers, no group.**
   On **Linux**, the installer SHALL drop a sudoers fragment under
   `/etc/sudoers.d/with-<IDENTIFIER>-env` that lets members of the
   `<IDENTIFIER>` group invoke the installed wrapper as `root` with
   `NOPASSWD`. The fragment SHALL be scoped to the one absolute
   path `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` and nothing
   else. The installer SHALL also add the invoking operator
   (`$SUDO_USER`, when set and not already `root`) to the
   `IDENTIFIER` group so they can use the wrapper directly after
   the next sudo evaluation. Group membership authorizes
   invocation; it does not determine the runtime UID, which is
   always the invoker's UID per principle 5.

   On **macOS**, no sudoers fragment is installed and no
   IDENTIFIER group is required or created — the per-user login
   Keychain is itself the access-control gate, and there is no
   privilege escalation to grant.
7. **Works from any directory.** The installed wrapper SHALL NOT
   depend on the caller's current working directory, repository
   location, or shell startup files.
8. **Ad-hoc first.** The primary workflows are
   `with-<IDENTIFIER>-env.sh [command ...]` and
   `with-<IDENTIFIER>-env.sh` (interactive shell). Long-running
   systemd service integration MAY be added later but is not required
   for v1.

## Installer Script: `create-1password-env-wrapper.sh`

The installer SHALL be invoked from the repository root.

- On **Linux**, the installer writes under `/etc` and
  `/usr/local/bin` and so requires root:
  ```text
  sudo -E ./create-1password-env-wrapper.sh
  ```
- On **macOS**, the installer writes only to the per-user login
  Keychain and to `${INSTALL_PREFIX}` (default `/usr/local/bin`,
  falling back to `~/.local/bin/` if not writable). It SHALL be run
  as the invoking user without `sudo`; the installer SHALL refuse
  to run under `sudo` on macOS, because Keychain seeding under
  `sudo` would target `/var/root`'s login keychain instead of the
  operator's:
  ```text
  ./create-1password-env-wrapper.sh
  ```

The installer SHALL be configured entirely by environment variables.
It SHALL validate all required inputs before making any filesystem
changes, and SHALL exit non-zero with a clear error naming the missing
input if any required input is absent.

### Required Inputs

- `IDENTIFIER` — shared name for the wrapper command and credential
  scope. On Linux it also names the Linux group that gates wrapper
  invocation; on macOS it also names the Keychain service entry.
  MUST match the regex defined in "The `IDENTIFIER` concept".
- `OP_SERVICE_ACCOUNT_TOKEN` — token for a 1Password service
  account with read access to the 1Password Environment identified
  by `ONEPASSWORD_ENVIRONMENT_ID`.
- `ONEPASSWORD_ENVIRONMENT_ID` — opaque ID of the 1Password
  Environment. Obtain via the desktop app:
  `Developer → View Environments → Manage environment → Copy
  environment ID`. Resolution by name is **not** supported (the
  CLI's `op environment` subcommand has only `read`, no `list`).

### Optional Inputs

- `INSTALL_PREFIX` — directory for the installed wrapper. Default:
  `/usr/local/bin`.
- `DEFAULT_SHELL` — shell to execute when the wrapper is invoked
  without a command. Default: `/bin/bash`.

There is no `TOKEN_STORAGE_MODE` knob: token storage is always the
systemd encrypted credential at
`/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`.
There is no `CONFIG_DIR`: nothing other than the encrypted
credential needs to be persisted on disk; identifier,
Environment ID, and default shell are baked into the rendered
wrapper at install time.

Nothing else in the wrapper's identity is configurable: the installer
always renders and installs `with-<IDENTIFIER>-env.sh`.

### Behavior

The installer SHALL, in order:

1. **Detect the platform** via `uname -s`. If the value is neither
   `Linux` nor `Darwin`, exit non-zero with a clear message naming
   the unsupported platform, before doing any other work.
2. **Verify platform-specific prerequisites.**
   - On **Linux**: `systemctl --version`, `systemd-creds --version`,
     and `setpriv --version` SHALL all succeed; the process SHALL be
     running as `uid 0` (exit non-zero with guidance to rerun under
     `sudo` otherwise).
   - On **macOS**: `security` SHALL be on `PATH` (it is part of the
     OS, but check anyway); the process SHALL **not** be running as
     `uid 0` (exit non-zero with guidance to rerun without `sudo`,
     because Keychain seeding under `sudo` would target
     `/var/root`'s login keychain).
3. **Verify common tooling.** `op` SHALL be installed and on `PATH`
   (`op --version` succeeds), and the installed `op` SHALL support
   the Environments feature (`op environment --help` exits
   successfully). The `environment` subcommand was introduced in
   the `2.33.0-beta.02` line; if the check fails, exit non-zero
   with a clear message instructing the operator to install the
   `op` beta from
   <https://releases.1password.com/developers/cli-beta/>.
4. **Linux only — verify the IDENTIFIER group exists.** (A Linux
   user named `IDENTIFIER` is NOT required; the runtime UID is the
   invoker's per [Architecture Principles §5](#architecture-principles).)
   On macOS, no group lookup is performed.
5. **Validate all required inputs**, including the `IDENTIFIER`
   regex. Exit non-zero on missing or invalid input, naming each
   offending input, without writing any files and without printing
   secret values. On macOS, if `INSTALL_PREFIX` does not exist or
   is not writable by the invoker, fall back to `~/.local/bin/`
   (creating it if necessary) and log the fallback.
6. **Render the wrapper** to `./with-<IDENTIFIER>-env.sh` at the
   repository root with mode `0755`, baking in the resolved
   `IDENTIFIER`, `ONEPASSWORD_ENVIRONMENT_ID`, installed path,
   `DEFAULT_SHELL`, and the platform-scoped constants
   (`LINUX_SYSTEMD_CRED_NAME` / `LINUX_SYSTEMD_CRED_PATH` for the
   Linux runtime branch, `MACOS_KEYCHAIN_SERVICE` /
   `MACOS_KEYCHAIN_TOKEN_ACCOUNT` for the Darwin runtime branch).
   The rendered wrapper SHALL contain BOTH platform branches
   regardless of which host did the rendering — see
   [Byte-identicality invariant](#byte-identicality-invariant).
   This file is the gitignored build artifact an operator can
   inspect before install.
7. **Store the service account token** in the platform-appropriate
   secure store, replacing any prior value:
   - On **Linux**: encrypt the token via `systemd-creds encrypt`
     into `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`,
     atomically (write a sibling temp file in the same directory,
     then `mv` into place; the encrypted file SHALL be owner
     `root:root` and mode `0600`). Ensure `/etc/credstore.encrypted/`
     exists with owner `root:root` and mode `0700` if it does not
     already.
   - On **macOS**: invoke `security add-generic-password -s
     "<IDENTIFIER>" -a OP_SERVICE_ACCOUNT_TOKEN -w "<token>" -U`.
     The `-U` flag updates an existing entry in place and creates a
     new one otherwise — making rotation idempotent. The Keychain
     entry lands in the operator's login keychain.
8. **Install the wrapper** by copying `./with-<IDENTIFIER>-env.sh`
   to `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh`, atomically
   (write to a sibling temp file in the same directory, then `mv`
   into place):
   - On **Linux**: owner `root:<IDENTIFIER>`, mode `0750`.
   - On **macOS**: owner = the invoking user (no `chown`), mode
     `0755`.
9. **Linux only — drop a sudoers fragment** at
   `/etc/sudoers.d/with-<IDENTIFIER>-env` with owner `root:root`
   and mode `0440` containing exactly:
   ```
   %<IDENTIFIER> ALL=(root) NOPASSWD: SETENV: ${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh
   ```
   The installer SHALL `visudo -cf` validate the fragment before
   moving it into `/etc/sudoers.d/`. The fragment SHALL be
   path-scoped to the installed wrapper and SHALL NOT grant any
   broader sudo permission. The `SETENV:` tag is required so the
   wrapper can propagate `WRAPPER_STAGE` through the
   self-escalation step. On macOS, no sudoers fragment is written
   and `/etc/sudoers.d/` is not touched.
10. **Linux only — add the invoking operator to the IDENTIFIER
    group.** If `$SUDO_USER` is set in the installer's environment
    and it is neither empty nor `root` nor `$IDENTIFIER`, add
    `$SUDO_USER` to the `IDENTIFIER` group via `usermod -aG
    <IDENTIFIER> "$SUDO_USER"` so that user gains NOPASSWD access
    via the sudoers fragment from step 9. The operator may need to
    start a fresh login session for the new primary-group lookup to
    apply to interactive shells, but `sudo` itself evaluates
    `/etc/group` on each invocation and SHALL pick up the new
    membership immediately. On macOS, no group operation is
    performed.
11. **Read-only validation against 1Password.** Recover the
    just-stored token from its platform-appropriate store
    (`systemd-creds decrypt` on Linux, `security
    find-generic-password -w` on macOS) and confirm the configured
    Environment is reachable via `op environment read
    "<ONEPASSWORD_ENVIRONMENT_ID>"`. Exit non-zero on failure,
    leaving any pre-existing installed wrapper and stored
    credential unchanged.
12. **Ensure `.gitignore` entries** at the repository root contain
    the entries `/with-*-env.sh` and `.env.local`. For each entry
    that is already present, leave `.gitignore` unchanged; any
    missing entry SHALL be appended on its own line. The installer
    SHALL NOT rewrite or reorder unrelated `.gitignore` contents.
13. **Print a success line** naming the installed wrapper path and
    the platform-appropriate token-store location:
    - On Linux: the encrypted-credential path
      (`/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`)
      and the sudoers fragment path.
    - On macOS: the Keychain service/account.
    The success line SHALL NOT include the token value.

The installer SHALL be idempotent on either platform: rerunning it
with the same inputs SHALL produce the same filesystem (and
Keychain) state without duplicating `.gitignore` or sudoers
entries, without leaving stale temp files, and without creating
additional credentials.

## Installed Wrapper: `with-<IDENTIFIER>-env.sh`

The installed wrapper lives at
`${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` (default
`/usr/local/bin/with-<IDENTIFIER>-env.sh`), is owned by
`root:<IDENTIFIER>`, and has mode `0750`. The rendered build artifact
in the repository root is byte-identical to the installed file.

### Header / "do not edit" notice

Both the rendered build artifact at the repo root and the installed
copy under `${INSTALL_PREFIX}/` SHALL begin with a fixed header
comment block, immediately after the `#!/usr/bin/env bash` shebang
and before any executable code. The header is the operator's first
defense against drift from the canonical source. It SHALL contain,
at minimum, all of the following on separate `#`-prefixed lines:

1. **Canonical-source URL** of the project that owns this script:
   `https://github.com/thewoolleyman/1password-env-wrapper`.
2. **Strong "do not edit" notice** stating that this file is a
   *generated* build artifact, that any local edit will be silently
   reverted the next time the operator reruns
   `create-1password-env-wrapper.sh`, and that direct edits SHALL
   NOT be made under any circumstances — including emergencies and
   one-off debugging sessions.
3. **Where to send fixes** instruction: bugs and improvements MUST
   be submitted as Pull Requests against the canonical repository
   above; local-only changes are forbidden.
4. **Regeneration instruction**: the file is regenerated by
   rerunning `sudo -E create-1password-env-wrapper.sh` from the
   repository root with the same inputs.

The header SHALL be present in identical form in both the rendered
artifact and the installed copy (because the installer copies the
rendered file byte-identically). The installer SHALL NOT make the
header configurable — it is part of the wrapper's identity.

### Invocation Contract

```text
with-<IDENTIFIER>-env.sh [--] [command [arg ...]]
```

- When invoked with a command, the wrapper SHALL execute that command
  with all configured 1Password Environment variables injected.
- When invoked without a command, the wrapper SHALL execute
  `DEFAULT_SHELL` as an interactive shell with all configured
  Environment variables injected.
- A literal `--` as the first argument SHALL end wrapper option
  parsing; all remaining arguments SHALL be treated as the child
  command and its arguments.

### Runtime Behavior

The wrapper begins by dispatching on `uname -s`:

- `Linux` → run the three-stage `WRAPPER_STAGE` re-exec model
  detailed below.
- `Darwin` → run the single-stage Keychain → `op run` path
  detailed in [macOS runtime model](#macos-runtime-model).
- anything else → exit non-zero with a clear "unsupported platform"
  message.

The remainder of this section describes the **Linux runtime
contract** in full. The macOS contract is in
[Platform Support](#platform-support); when this subsection refers
to "the wrapper" it means the Linux branch unless otherwise noted.

The Linux branch runs in three stages, gated by an internal sentinel
environment variable (e.g. `WRAPPER_STAGE`) so a single script file
covers all three:

1. **Stage 0 — escalate.** When invoked with `WRAPPER_STAGE` unset,
   if the wrapper is not already `uid 0` it SHALL re-exec itself
   under `sudo -n` with `WRAPPER_STAGE=1` and the absolute path of
   the **installed** wrapper as the target — never the path the
   caller used. This means invoking the gitignored rendered build
   artifact at the repository root delegates to the installed copy
   for the privileged step, so the sudoers fragment only ever
   needs to whitelist the one installed path.
2. **Stage 1 — decrypt and drop.** Running as `uid 0`, the wrapper
   SHALL read the invoker's identity from the `SUDO_UID`,
   `SUDO_GID`, and `SUDO_USER` environment variables (which `sudo`
   always sets on the elevated process). It SHALL fail closed with
   a clear error if any of these is unset (e.g. when the wrapper
   was invoked as `root` directly without going through `sudo`).
   It SHALL resolve the invoker's home directory via
   `getent passwd <SUDO_UID>`. It SHALL then decrypt
   `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
   via `systemd-creds decrypt` directly into a memory variable,
   and re-exec itself via `setpriv --reuid=<SUDO_UID>
   --regid=<SUDO_GID> --init-groups` with a clean environment
   (`env -i`) carrying only `HOME` (the invoker's home), `PATH`
   (a deterministic safe value: `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`),
   `OP_SERVICE_ACCOUNT_TOKEN` (the just-decrypted token), and
   `WRAPPER_STAGE=2`. The token never appears on a command line
   and never touches disk after decryption.
3. **Stage 2 — run.** Running as the invoker with the token in
   env, the wrapper SHALL:
   - `unset OP_CONNECT_HOST OP_CONNECT_TOKEN` so 1Password Connect
     does not override `OP_SERVICE_ACCOUNT_TOKEN`;
   - export `OP_CACHE=false`;
   - exec `op run --no-masking --environment <ONEPASSWORD_ENVIRONMENT_ID>
     -- env -u OP_SERVICE_ACCOUNT_TOKEN -- <command>` so the final
     child never sees the service-account token;
   - when no command was supplied, run `DEFAULT_SHELL -i` instead.

The wrapper SHALL NOT call `op item list`, `op item get`, `op read`,
or any other vault-touching operation. Variables come from the
1Password Environment exclusively, via the single
`op run --environment` invocation above.

The wrapper SHALL fail closed with a non-zero exit code and an error
message (but no secret values) when:

- the encrypted credential is missing or `systemd-creds decrypt`
  fails;
- `sudo -n` escalation fails (the operator is not in the
  `IDENTIFIER` group, or the sudoers fragment is missing);
- `SUDO_UID` / `SUDO_GID` / `SUDO_USER` are unset in stage 1
  (e.g. the wrapper was invoked directly as `root` without
  `sudo`, so there is no invoker identity to drop back to);
- `getent passwd <SUDO_UID>` cannot resolve the invoker's home
  directory;
- the configured Environment ID cannot be resolved by
  `op run --environment`;
- the service account token cannot read the Environment;
- `op`'s injection mechanism returns a non-zero exit status before
  the child command runs.

When the child command runs, the wrapper SHALL propagate the child's
exit code as its own exit code.

### Environment Variable Contract

- Every variable defined in the configured 1Password Environment
  SHALL be present in the child process environment with the same
  name and value.
- The wrapper SHALL NOT synthesize, rename, or transform Environment
  variable names.
- If the configured Environment contains a variable name that is
  invalid for a POSIX process environment, the wrapper SHALL fail
  and identify the variable name without printing its value.
- If the caller's shell already has an environment variable with the
  same name as a 1Password Environment variable, the 1Password value
  SHALL win.
- `OP_SERVICE_ACCOUNT_TOKEN` SHALL NOT be present in the final child
  process environment.

## Test Target: `print-test-env-vars.sh`

`print-test-env-vars.sh` is the canonical test target used to prove
that the installed wrapper is injecting Environment variables
correctly. It SHALL:

- print every environment variable whose name starts with `TEST_`,
  one variable per line, in `NAME=value` form;
- sort the output by variable name, ascending;
- exit `0` when no matching variables are present (printing nothing);
- exit `0` on success in the normal case;
- produce no output on stderr in the normal case.

The 1Password Environment referenced by the wrapper SHOULD contain at
least two variables whose names start with `TEST_` so that this
script's output can be used as a human-readable smoke test. For the
integration test described below, the Environment MUST contain
`TEST_CREDENTIAL=TEST_VALUE`. A typical verification run is:

```text
sudo -u <IDENTIFIER> with-<IDENTIFIER>-env.sh /absolute/path/to/print-test-env-vars.sh
```

## Bootstrap Secret File: `.env.local`

`.env.local` is the gitignored bootstrap secret file used to drive
the installer during development and integration testing. It is not
part of the installer's production input surface — production
operators pass `OP_SERVICE_ACCOUNT_TOKEN` directly on the installer
command line. `.env.local` exists so that automated checks (including
the BATS integration test) can run repeatably without an operator
re-entering secrets.

Required properties:

- Location: repository root.
- Always gitignored. The repository's `.gitignore` SHALL list
  `.env.local`.
- Format: a plain `KEY=VALUE` file, one entry per line, no quoting,
  no surrounding whitespace, no inline comments. Lines beginning with
  `#` and blank lines are permitted.
- Naming convention: two entries per supported identifier:
  `<IDENTIFIER_UPPERCASE>_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<token>`
  and
  `<IDENTIFIER_UPPERCASE>_1PASSWORD_ENVIRONMENT_ID=<env-id>`,
  where `<IDENTIFIER_UPPERCASE>` is the identifier in upper case
  with any hyphens replaced by underscores. For the default
  identifier `openbrain`, the entries are:
  ```
  OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<token>
  OPENBRAIN_1PASSWORD_ENVIRONMENT_ID=<env-id>
  ```
- When a fresh clone ships placeholder values (`PLACEHOLDER`),
  consumers SHALL treat those as "not yet configured" and refuse
  to proceed unless they can recover the missing values from a
  prior successful install (see "Encrypted-state fallback" below).

Consumers of `.env.local` (the integration test; any future
developer-mode runner) SHALL read it directly (for example via
`set -a; source ./.env.local; set +a` in a clean subshell) and SHALL
NOT modify it.

### Encrypted-state fallback

After a successful install, both pieces of bootstrap state are
already on the host: the service-account token is sealed in the
platform-appropriate secure store, and the Environment ID is baked
into `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` as a `readonly
ONEPASSWORD_ENVIRONMENT_ID='…'` line. Consumers MAY fall back to
those sources when `.env.local` is missing, missing the relevant
key, or the relevant key is `PLACEHOLDER`:

- **Token fallback (Linux)**:
  `sudo systemd-creds decrypt --name=1password-env-wrapper-<IDENTIFIER>
  /etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER> -`
- **Token fallback (macOS)**:
  `security find-generic-password -s "<IDENTIFIER>" -a
  OP_SERVICE_ACCOUNT_TOKEN -w`
- **Environment-ID fallback (both platforms)**: parse the
  `readonly ONEPASSWORD_ENVIRONMENT_ID='…'` line out of
  `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` (e.g. via `grep` +
  `sed`; on Linux, prefix with `sudo` if the file is mode `0750`
  and the caller is not in the `<IDENTIFIER>` group).

The fallback lets an operator delete `.env.local` once the install
has succeeded so the raw token no longer lives in plaintext on
their dev machine. Consumers that hit a fallback SHOULD log the
fact (without printing the recovered token) so the operator
understands they relied on host state.

## Integration Test: `test/integration.bats`

`test/integration.bats` is a [Bats](https://bats-core.readthedocs.io/)
test file that exercises the installer and the installed wrapper
end-to-end against real 1Password infrastructure. It is the
authoritative proof that the repository satisfies the happy-path
acceptance scenarios in this specification.

The test SHALL use the identifier `openbrain` and assume that:

- on Linux, the group `openbrain` exists on the host (a Linux
  *user* named `openbrain` is not required); on macOS, no group or
  user precondition applies;
- a 1Password service account exists with read access to a
  1Password Environment (the Environment's name is irrelevant to
  the wrapper; only its ID is used);
- that Environment contains the variables
  `TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE` and
  `TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2`;
- the bootstrap inputs are reachable: either `.env.local` at the
  repository root contains both
  `OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<real token>` and
  `OPENBRAIN_1PASSWORD_ENVIRONMENT_ID=<env id>`, OR a previous
  successful install left the platform-appropriate token store
  populated and the installed wrapper on the host so the
  encrypted-state fallback (see the `.env.local` section above)
  can recover them;
- the host provides `bats`, an Environments-aware `op` build
  (`2.33.0-beta.02`+), and the BATS support libraries
  `bats-support` and `bats-assert` (or equivalents) available on
  `PATH` or via `load`. On Linux, the host additionally provides
  `sudo` (GNU sudo, with env-preservation), `setpriv`, and the
  systemd userspace (`systemctl`, `systemd-creds`). On macOS, the
  host additionally provides the `security` CLI (always present).

Test cases SHALL be platform-gated where they assert
platform-specific filesystem state — Linux-only assertions (sudoers
fragment, systemd-creds file, root:openbrain ownership, `sudo -u
openbrain` invocations) SHALL be skipped on macOS via a Bats
`skip` guard, and macOS-only assertions (Keychain entry,
user-owned wrapper) SHALL be skipped on Linux. Assertions that
apply to both platforms (rendered-wrapper canonical-source header,
`.gitignore` entries, wrapper output for the test target) run on
both.

### Behavior

The test file SHALL:

1. In `setup_file` (or equivalent), load `.env.local` if present,
   then resolve each bootstrap value (token and Environment ID)
   in this order:
   1. value from `.env.local` (if present and not `PLACEHOLDER`);
   2. value from the platform-appropriate encrypted-state fallback:
      - Linux: decrypt
        `/etc/credstore.encrypted/1password-env-wrapper-openbrain`
        via `sudo systemd-creds decrypt --name=…` for the token;
      - macOS: read `security find-generic-password -s openbrain
        -a OP_SERVICE_ACCOUNT_TOKEN -w` for the token.
      Both platforms grep
      `${INSTALL_PREFIX}/with-openbrain-env.sh` for the Environment
      ID.

   If neither source yields a real value for either input, fail
   fast with a clear error naming the missing input and
   instructing the operator to populate `.env.local`. Pass the
   resolved token (as `OP_SERVICE_ACCOUNT_TOKEN`) and Environment
   ID (as `ONEPASSWORD_ENVIRONMENT_ID`) into each installer
   invocation only — not as global test-process env vars.
2. Invoke the installer with `IDENTIFIER=openbrain` and
   `ONEPASSWORD_ENVIRONMENT_ID` set, capturing stdout, stderr, and
   exit status. On Linux the invocation is under `sudo -E`; on
   macOS the invocation is direct (no `sudo`). Assert exit status
   `0`, that the installer reported installing
   `${INSTALL_PREFIX}/with-openbrain-env.sh`, and that the
   installer output contains neither the raw token value nor the
   placeholder string.
3. Assert that `${INSTALL_PREFIX}/with-openbrain-env.sh` exists,
   with the platform-appropriate ownership and mode:
   - Linux: owned by `root:openbrain`, mode `0750`.
   - macOS: owned by the invoking user, mode `0755`.
4. Assert that the platform-appropriate token store is populated:
   - Linux: the encrypted credential file
     `/etc/credstore.encrypted/1password-env-wrapper-openbrain`
     exists, is owned by `root:root` with mode `0600`, AND no
     plaintext-token file exists anywhere under
     `/etc/onepassword-env-wrapper/` (the directory itself MUST
     NOT exist; this is the "no plaintext on disk" invariant).
   - macOS: `security find-generic-password -s openbrain -a
     OP_SERVICE_ACCOUNT_TOKEN -w` returns a non-empty string.
5. Assert that `.gitignore` at the repository root contains the
   patterns `/with-*-env.sh` and `.env.local` (both platforms).
6. **Linux only**: assert that the sudoers fragment
   `/etc/sudoers.d/with-openbrain-env` exists, is owned by
   `root:root`, has mode `0440`, and contains the expected
   `%openbrain ALL=(root) NOPASSWD: SETENV: …` line. Skip on
   macOS.
7. Run the installed wrapper against `print-test-env-vars.sh`.
   - Linux: run as the `openbrain` user via `sudo -u openbrain`.
     Because the repository checkout MAY sit under a path that the
     `openbrain` user cannot traverse, the test SHALL stage an
     executable copy of `print-test-env-vars.sh` at a
     world-readable path (for example
     `/tmp/print-test-env-vars.<random>.sh`, `chmod 0755`).
   - macOS: run as the BATS-invoking user (no `sudo -u`); the
     stage-and-chmod step is unnecessary but harmless.
   On both platforms, assert:
   - exit status `0`;
   - the output contains the lines
     `TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE` and
     `TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2`;
   - the output does **not** contain any line starting with
     `TEST_CREDENTIAL_FROM_VAULT=` (this guards against
     regressing back to the vault-enumeration model);
   - the output is sorted by variable name;
   - the output contains no `OP_SERVICE_ACCOUNT_TOKEN=` line.
8. Run the installed wrapper with the command `env` (as the
   `openbrain` user on Linux, as the BATS-invoking user on macOS);
   assert `TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE` appears in
   the output and `OP_SERVICE_ACCOUNT_TOKEN` does not.
9. Run the installed wrapper with the command
   `printenv OP_SERVICE_ACCOUNT_TOKEN` (same user-selection rule
   as 8) and assert the wrapper exit status is `1` (variable
   unset), confirming that the secret-zero token is not inherited
   by the child.
10. Run the **rendered** build artifact at the repository root
    (`./with-openbrain-env.sh`) directly as the BATS-invoking user
    (with the staged `print-test-env-vars.sh` as the argument) and
    assert it succeeds and produces
    `TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE`. On Linux this
    proves stage-0 self-escalation via the sudoers fragment works
    end-to-end for the operator who just ran the installer (whose
    user was added to the `openbrain` group in installer step 10);
    on macOS this proves the rendered artifact and installed copy
    behave identically (no escalation involved).
11. Assert the rendered build artifact at the repository root
    (`./with-openbrain-env.sh`) is byte-identical to the installed
    wrapper at `${INSTALL_PREFIX}/with-openbrain-env.sh`
    (`cmp` exits `0`). This holds on both platforms and supports
    the cross-platform byte-identicality invariant.

The test SHALL be idempotent on either platform: rerunning it SHALL
succeed whether or not a prior install exists. The test SHOULD NOT
remove the installed wrapper, the platform-appropriate token store,
the sudoers fragment (Linux), or the group membership (Linux) on
teardown; cleanup is an operator concern.

### Invocation

Operators run the test from the repository root on either platform:

```text
bats test/integration.bats
```

On Linux, the test invokes `sudo` where needed; the outer `bats`
process does not need to run as root, but the session MUST be able
to escalate via `sudo` without a password prompt, or the operator
MUST be prepared to enter their password at the first escalation.
On macOS, the test runs entirely as the invoking user — no `sudo`
escalation is performed.

## Usage Documentation: `AGENTS.md`

`AGENTS.md` SHALL document, for both human and agent readers:

1. **What this repo is** — one short paragraph.
2. **Prerequisites** — split into common and platform-specific:
   - Common: an Environments-aware 1Password CLI (`op`
     `2.33.0-beta.02`+) installed and on `PATH`, an existing
     1Password Environment, and a 1Password service account token
     with read access to that Environment.
   - **Linux**: a host with `systemd` (`systemctl`,
     `systemd-creds`), `sudo` (GNU, with env-preservation),
     `setpriv`, and an existing Linux *group* named `IDENTIFIER`
     (a Linux *user* named `IDENTIFIER` is not required).
   - **macOS**: a host with the `security` CLI (always present);
     no group, no `sudo`, no `setpriv`.
3. **Installing the wrapper** — exact commands per platform:
   - **Linux**: `sudo -E ./create-1password-env-wrapper.sh`.
   - **macOS**: `./create-1password-env-wrapper.sh` (no `sudo`).
   Document how to supply `IDENTIFIER`,
   `OP_SERVICE_ACCOUNT_TOKEN`, and `ONEPASSWORD_ENVIRONMENT_ID`
   without recording the token in shell history (e.g. bash
   local-env prefix with leading-space history skipping). Document
   how to obtain `ONEPASSWORD_ENVIRONMENT_ID` via the 1Password
   desktop app (`Developer → View Environments → Manage
   environment → Copy environment ID`). Document the
   platform-appropriate token-store location (systemd-creds path
   on Linux, Keychain service/account on macOS).
4. **Running a command via the wrapper** — exact commands for the
   arbitrary-command form. On Linux, the caller must be a member
   of the `IDENTIFIER` group (the installer adds `$SUDO_USER` to
   it automatically); on macOS, the caller is the user that ran
   the installer.
5. **Opening an interactive shell via the wrapper** — exact command
   and a note that `exit` returns to the outer shell.
6. **Verifying the wrapper** — how to run the installed wrapper
   against `/path/to/print-test-env-vars.sh` and what correct output
   looks like.
7. **Rotating the service account token** — rerun the installer with
   the replacement `OP_SERVICE_ACCOUNT_TOKEN`; the stored credential
   and the rendered/installed wrapper are replaced atomically.
8. **Running the integration test** — how to populate `.env.local`
   with a real
   `OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<token>` (starting from
   the placeholder), and how to run `bats test/integration.bats`.
9. **Example shell interaction** — a transcript using `openbrain` as
   the identifier (so the wrapper command name is
   `with-openbrain-env.sh`), showing: an operator running the
   installer under `sudo`; `openbrain` running a wrapped command;
   `openbrain` opening and exiting an interactive shell. The
   transcript SHALL NOT contain real service account tokens; it
   SHALL use an obvious placeholder such as
   `ops_EXAMPLE_TOKEN_NOT_A_REAL_VALUE`.

`AGENTS.md` SHALL NOT duplicate architectural requirements from this
specification; it SHALL point to `SPECIFICATION.md` for contract
details.

## Gitignore: `.gitignore`

`.gitignore` at the repository root SHALL contain at least these
entries:

```text
/with-*-env.sh
.env.local
```

- `/with-*-env.sh` ignores the rendered wrapper build artifact at
  the repository root for any `IDENTIFIER` value.
- `.env.local` ignores the bootstrap secret file used by the
  integration test.

The installer MAY append either line if it is missing. The installer
SHALL NOT rewrite, reorder, or remove any other `.gitignore` entries.

## Security Constraints

- The installer and the wrapper MUST NOT write fetched 1Password
  Environment variables to `.env`, `.env.local`, shell profile files,
  or any other file on disk.
- The installer and the wrapper MUST NOT print the service account
  token in normal output, error output, or diagnostics.
- The installer MUST NOT store the service account token inside the
  repository working tree, in command history, in generated shell
  snippets, or in world-readable unit files.
- The token SHALL be stored exclusively in the platform-appropriate
  secure store:
  - **Linux**: a systemd encrypted credential at
    `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
    with owner `root:root` and mode `0600`. A plaintext token file
    under any path (e.g. `/etc/onepassword-env-wrapper/*.token`)
    is explicitly forbidden, and the installer SHALL NOT create
    `/etc/onepassword-env-wrapper/` at all.
  - **macOS**: the operator's login Keychain, as a generic
    password under service `<IDENTIFIER>`, account
    `OP_SERVICE_ACCOUNT_TOKEN`. No on-disk plaintext file is
    created on macOS either.
- The installed wrapper at
  `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` SHALL be owned with
  the platform-appropriate ownership and mode:
  - **Linux**: `root:<IDENTIFIER>`, mode `0750`.
  - **macOS**: the invoking user, mode `0755`.
- **Linux only**: a sudoers fragment at
  `/etc/sudoers.d/with-<IDENTIFIER>-env` (owner `root:root`, mode
  `0440`) SHALL grant only members of the `<IDENTIFIER>` group
  passwordless `sudo` for **only** the absolute path of the
  installed wrapper. No other binary, no other group, no
  wildcard. macOS installs no sudoers fragment.
- The 1Password service account SHOULD have read-only access to only
  the Environment named `IDENTIFIER` and the vault named
  `IDENTIFIER`.
- The vault named `IDENTIFIER` SHOULD contain only operational
  secrets for that domain.
- Service account token rotation SHALL be a supported maintenance
  operation: rerunning the installer with a new
  `OP_SERVICE_ACCOUNT_TOKEN` SHALL replace the stored credential.
  Because 1Password service-account-to-Environment access is
  immutable, changing Environment access SHALL require creating a
  replacement service account and rerunning the installer.
- These controls reduce accidental exposure and limit blast radius;
  they do not protect against a fully compromised root account on
  the host (Linux) or a fully compromised user login session
  (macOS). A compromise of either exposes the service account
  token and every secret it can reach.

## Acceptance Scenarios

### Scenario: Installer refuses missing inputs

Given `./create-1password-env-wrapper.sh` is invoked under `sudo`
without `OP_SERVICE_ACCOUNT_TOKEN` *or* `ONEPASSWORD_ENVIRONMENT_ID`
set, with `IDENTIFIER=openbrain`

When the installer validates its inputs

Then it exits non-zero before creating or modifying any files

And it reports each missing input name

And it does not print any secret values

### Scenario: Installer rejects malformed `IDENTIFIER`

Given `IDENTIFIER=Open_Brain` (contains an underscore and uppercase)

When the installer validates its inputs

Then it exits non-zero before creating or modifying any files

And it reports that `IDENTIFIER` is malformed

### Scenario: Installer stores only secret zero, encrypted (Linux)

Given all required inputs are present with `IDENTIFIER=openbrain`
on a Linux host

When `sudo -E ./create-1password-env-wrapper.sh` completes successfully

Then the service account token is persisted **only** as a systemd
encrypted credential at
`/etc/credstore.encrypted/1password-env-wrapper-openbrain` (owner
`root:root`, mode `0600`)

And no plaintext token file exists anywhere on the host outside the
gitignored `.env.local`; in particular,
`/etc/onepassword-env-wrapper/` does not exist

And `${INSTALL_PREFIX}/with-openbrain-env.sh` exists with owner
`root:openbrain` and mode `0750`

And `/etc/sudoers.d/with-openbrain-env` exists with owner
`root:root`, mode `0440`, and a single line granting
`%openbrain` `NOPASSWD` on the installed wrapper

And `.gitignore` at the repository root ignores both `/with-*-env.sh`
and `.env.local`

And no `.env` or similar file has been written with fetched
Environment variables (the pre-existing `.env.local` bootstrap file
SHALL NOT have been rewritten by the installer)

### Scenario: Installer stores only secret zero, encrypted (macOS)

Given all required inputs are present with `IDENTIFIER=openbrain`
on a macOS host

When `./create-1password-env-wrapper.sh` (no `sudo`) completes successfully

Then the service account token is persisted **only** as a generic
password in the operator's login Keychain under service
`openbrain`, account `OP_SERVICE_ACCOUNT_TOKEN` (recoverable via
`security find-generic-password -s openbrain -a
OP_SERVICE_ACCOUNT_TOKEN -w`)

And no plaintext token file exists anywhere on the host outside the
gitignored `.env.local`

And `${INSTALL_PREFIX}/with-openbrain-env.sh` exists, is owned by
the invoking user, and is mode `0755`

And `/etc/sudoers.d/with-openbrain-env` does NOT exist (no sudoers
fragment is created on macOS)

And `/etc/credstore.encrypted/1password-env-wrapper-openbrain` does
NOT exist (no systemd-creds storage is used on macOS)

And `.gitignore` at the repository root ignores both `/with-*-env.sh`
and `.env.local`

### Scenario: Rendered wrapper bytes are identical across platforms

Given a Linux host and a macOS host that have both received the
identical inputs (same `IDENTIFIER`, same
`OP_SERVICE_ACCOUNT_TOKEN`, same `ONEPASSWORD_ENVIRONMENT_ID`, same
`INSTALL_PREFIX`, same `DEFAULT_SHELL`)

When `create-1password-env-wrapper.sh` is run on each host with
those inputs

Then the resulting `${INSTALL_PREFIX}/with-${IDENTIFIER}-env.sh`
files on the two hosts are byte-identical (`diff -q` exits `0`)

And the rendered build artifact at the repository root
(`./with-${IDENTIFIER}-env.sh`) on each host is byte-identical to
the installed wrapper on that same host (so a consumer that
copies the rendered artifact between hosts gets the same bytes
that an in-place install on the target host would have produced)

### Scenario: Wrapper starts an interactive shell

Given the wrapper is installed with `IDENTIFIER=openbrain` and the
service account can read the configured 1Password Environment

When `openbrain` runs `with-openbrain-env.sh`

Then an interactive shell starts

And every variable from the 1Password Environment is present inside
that shell

And `OP_SERVICE_ACCOUNT_TOKEN` is not present inside that shell

### Scenario: Wrapper runs an arbitrary command

Given the wrapper is installed with `IDENTIFIER=openbrain` and the
service account can read the configured 1Password Environment

When `openbrain` runs
`with-openbrain-env.sh /absolute/path/to/print-test-env-vars.sh`

Then `print-test-env-vars.sh` runs with every variable from the
1Password **Environment** (NOT the vault) available

And the output contains every `TEST_*` variable defined in the
Environment, in `NAME=value` form, sorted by name

And the output does NOT contain any variable that exists only as a
vault item (proving the wrapper does not enumerate vault items)

And the command does not receive `OP_SERVICE_ACCOUNT_TOKEN`

### Scenario: 1Password values override caller values

Given `openbrain`'s shell has `SUPABASE_URL=wrong` exported

And the configured 1Password Environment has `SUPABASE_URL=correct`

When `openbrain` runs `with-openbrain-env.sh printenv SUPABASE_URL`

Then the command prints `correct`

### Scenario: Missing 1Password access fails closed

Given the stored service account token has been revoked in 1Password

When `openbrain` runs `with-openbrain-env.sh`

Then no child shell or command is started with partial secrets

And the wrapper exits non-zero

And the wrapper reports that 1Password Environment injection failed

### Scenario: Token rotation replaces secret zero

Given the service account token has been rotated in 1Password

When an administrator reruns the installer with the replacement
`OP_SERVICE_ACCOUNT_TOKEN` and the same `IDENTIFIER` (on Linux:
`sudo -E ./create-1password-env-wrapper.sh`; on macOS:
`./create-1password-env-wrapper.sh`)

Then the platform-appropriate token store is replaced atomically:
- on **Linux**, the encrypted credential at
  `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>` is
  rewritten via sibling-temp-file + `mv`;
- on **macOS**, the Keychain entry under service `<IDENTIFIER>`,
  account `OP_SERVICE_ACCOUNT_TOKEN`, is updated in place via
  `security add-generic-password -U`.

And subsequent wrapper invocations use the replacement token

And no fetched Environment variables have been persisted to disk

And no plaintext token has been persisted to disk

### Scenario: BATS integration test proves the happy path

Given `.env.local` at the repository root contains a real
`OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN` and a real
`OPENBRAIN_1PASSWORD_ENVIRONMENT_ID` (neither equal to
`PLACEHOLDER`)

And on Linux, the `openbrain` group exists (a Linux *user* named
`openbrain` is not required); on macOS, no group/user precondition
applies

And the 1Password Environment identified by
`OPENBRAIN_1PASSWORD_ENVIRONMENT_ID` contains
`TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE` and
`TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2`

When the operator runs `bats test/integration.bats`

Then the installer completes successfully with `IDENTIFIER=openbrain`

And the installed wrapper injects
`TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE` and
`TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2` into the child
process invoked against `print-test-env-vars.sh`

And the wrapper does NOT inject any vault-only variable (e.g. it
does not produce `TEST_CREDENTIAL_FROM_VAULT=…`)

And `OP_SERVICE_ACCOUNT_TOKEN` is not present in the child process

And every BATS assertion passes
