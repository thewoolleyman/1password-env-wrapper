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
loaded from a 1Password Environment. The installer renders the
wrapper, stores the 1Password service account token **only** as an
encrypted systemd credential under `/etc/credstore.encrypted/`, and
installs the wrapper under `/usr/local/bin` for a dedicated Linux
user.

The installer's only supported runtime target is **Linux with
systemd**. Any plaintext-on-disk token storage (e.g. a root-owned
`*.token` file under `/etc/`) is explicitly forbidden — outside of
the gitignored `.env.local` bootstrap file at the repository root,
the raw token SHALL never exist on disk.

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

## The `IDENTIFIER` concept

A single `IDENTIFIER` input names every coupled entity in the domain:

- the Linux **user** that runs the wrapper;
- the Linux **group** that owns the wrapper binary so only its
  members may execute it (members of this group are also the
  operators allowed to invoke the wrapper without a sudo password
  prompt);
- the 1Password **vault** holding the domain's secrets;
- the 1Password **Environment** whose variables are injected;
- the wrapper command name `with-<IDENTIFIER>-env.sh`;
- the systemd encrypted credential name
  `1password-env-wrapper-<IDENTIFIER>` under
  `/etc/credstore.encrypted/`.

`IDENTIFIER` SHALL match the regex `^[a-z][a-z0-9-]{0,30}[a-z0-9]$`:
lowercase letters, digits, and single hyphens; starting with a
letter; no trailing hyphen; total length 2–32. The installer SHALL
reject values that do not match. Example values: `openbrain`,
`acme-prod`.

The installer SHALL NOT attempt to create the Linux user, the Linux
group, the 1Password vault, or the 1Password Environment. All four
SHALL already exist with the chosen identifier before installation.

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
2. **1Password Environment is the canonical env-var source.** The
   wrapper SHALL inject variables from the 1Password Environment
   named by `IDENTIFIER`. A variable's name in the Environment SHALL
   be the environment variable name seen by the child process.
3. **Vault access is scoped but not enumerated by default.** The
   associated 1Password vault (also named by `IDENTIFIER`) SHALL hold
   only secrets relevant to the same operational domain, but the
   wrapper's v1 behaviour SHALL NOT enumerate arbitrary vault items
   into environment variables. Vault item projection MAY be added
   later under an explicit naming convention.
4. **No plaintext secrets on disk.** Outside of the gitignored
   `.env.local` bootstrap file at the repository root, the raw
   service account token SHALL never exist on disk. The installer
   and the wrapper MUST NOT write fetched 1Password Environment
   variables to `.env`, `.env.local`, shell profile files, or any
   other file on disk. The wrapper SHALL pass Environment values to
   the child process directly in memory, using whatever injection
   mechanism the current `op` CLI provides (for example
   `op run --env-file=<path>` reading from a process substitution,
   or an equivalent subcommand). The implementer is expected to
   consult the 1Password CLI documentation and pick the simplest
   mechanism that satisfies this principle.
5. **Token storage is the systemd encrypted credential, only.** The
   service account token SHALL be persisted exclusively as a
   systemd encrypted credential at
   `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`,
   created via `systemd-creds encrypt`. A plaintext root-owned
   token file (or any other on-disk plaintext representation) is
   explicitly forbidden. Decryption requires `root`, so the wrapper
   uses a brief `sudo -n` self-escalation to gain root, decrypts
   the credential into memory, then immediately drops privileges
   to the `IDENTIFIER` user via `setpriv` before invoking `op`.
   The token never appears in a process command line and never
   touches disk after decryption.
6. **Sudoers grants the `IDENTIFIER` group passwordless escalation
   for this one wrapper.** The installer SHALL drop a sudoers
   fragment under `/etc/sudoers.d/with-<IDENTIFIER>-env` that lets
   members of the `<IDENTIFIER>` group invoke the installed wrapper
   as `root` with `NOPASSWD`. The fragment SHALL be scoped to the
   one absolute path `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh`
   and nothing else. The installer SHALL also add the invoking
   operator (`$SUDO_USER`, when set and not already the
   `IDENTIFIER` user) to the `IDENTIFIER` group so they can use
   the wrapper directly after the next sudo evaluation.
7. **Works from any directory.** The installed wrapper SHALL NOT
   depend on the caller's current working directory, repository
   location, or shell startup files.
8. **Ad-hoc first.** The primary workflows are
   `with-<IDENTIFIER>-env.sh [command ...]` and
   `with-<IDENTIFIER>-env.sh` (interactive shell). Long-running
   systemd service integration MAY be added later but is not required
   for v1.

## Installer Script: `create-1password-env-wrapper.sh`

The installer SHALL be invoked from the repository root under `sudo`,
because it writes under `/etc` and `/usr/local/bin`:

```text
sudo -E ./create-1password-env-wrapper.sh
```

The installer SHALL be configured entirely by environment variables.
It SHALL validate all required inputs before making any filesystem
changes, and SHALL exit non-zero with a clear error naming the missing
input if any required input is absent.

### Required Inputs

- `IDENTIFIER` — shared name for the Linux user, Linux group,
  1Password vault, 1Password Environment, wrapper command, and token
  scope. MUST match the regex defined in "The `IDENTIFIER` concept".
- `OP_SERVICE_ACCOUNT_TOKEN` — token for a 1Password service account
  with read access to the Environment named by `IDENTIFIER`.

### Optional Inputs

- `ONEPASSWORD_ENVIRONMENT_ID` — explicit 1Password Environment ID.
  If omitted, the installer MAY resolve the Environment by name
  (`IDENTIFIER`) using the 1Password CLI.
- `INSTALL_PREFIX` — directory for the installed wrapper. Default:
  `/usr/local/bin`.
- `DEFAULT_SHELL` — shell to execute when the wrapper is invoked
  without a command. Default: `/bin/bash`.

There is no `TOKEN_STORAGE_MODE` knob: token storage is always the
systemd encrypted credential at
`/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`.
There is no `CONFIG_DIR`: nothing other than the encrypted
credential needs to be persisted on disk; identifier, vault, and
shell are baked into the rendered wrapper at install time.

Nothing else in the wrapper's identity is configurable: the installer
always renders and installs `with-<IDENTIFIER>-env.sh`.

### Behavior

The installer SHALL, in order:

1. Verify the host is Linux **with systemd**; exit non-zero
   otherwise. Specifically, `systemctl --version`,
   `systemd-creds --version`, and `setpriv --version` SHALL all
   return successfully.
2. Verify it is running as `uid 0`; exit non-zero with guidance to
   rerun under `sudo` otherwise.
3. Verify `op`, `jq`, and `setpriv` are installed and on `PATH`
   (`op --version`, `jq --version`, `setpriv --version` succeed).
   The installer SHALL NOT attempt a stricter semantic-version
   check on `op`; if the installed `op` lacks a feature the wrapper
   needs, the wrapper's own invocation will surface that at
   validation time.
4. Verify the Linux user `IDENTIFIER` and the Linux group
   `IDENTIFIER` both exist.
5. Validate all required inputs, including the `IDENTIFIER` regex.
   Exit non-zero on missing or invalid input, naming each offending
   input, without writing any files and without printing secret
   values.
6. Render the wrapper to `./with-<IDENTIFIER>-env.sh` at the
   repository root with mode `0755`, baking in the resolved
   `IDENTIFIER`, vault name, encrypted-credential name, installed
   path, and `DEFAULT_SHELL`. This file is the gitignored build
   artifact an operator can inspect before install.
7. Encrypt the service account token via `systemd-creds encrypt`
   into `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`,
   atomically (write a sibling temp file in the same directory,
   then `mv` into place; the encrypted file SHALL be owner
   `root:root` and mode `0600`). Ensure
   `/etc/credstore.encrypted/` exists with owner `root:root` and
   mode `0700` if it does not already.
8. Install the wrapper by copying `./with-<IDENTIFIER>-env.sh` to
   `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` with owner
   `root:<IDENTIFIER>` and mode `0750`, atomically (write to a
   sibling temp file in the same directory, then `mv` into place).
9. Drop a sudoers fragment at
   `/etc/sudoers.d/with-<IDENTIFIER>-env` with owner `root:root`
   and mode `0440` containing exactly:
   ```
   %<IDENTIFIER> ALL=(root) NOPASSWD: ${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh
   ```
   The installer SHALL `visudo -cf` validate the fragment before
   moving it into `/etc/sudoers.d/`. The fragment SHALL be
   path-scoped to the installed wrapper and SHALL NOT grant any
   broader sudo permission.
10. If `$SUDO_USER` is set in the installer's environment and it is
    neither empty, `root`, nor the `IDENTIFIER` user itself, add
    `$SUDO_USER` to the `IDENTIFIER` group via
    `usermod -aG <IDENTIFIER> "$SUDO_USER"` so that user gains
    NOPASSWD access via the sudoers fragment from step 9. The
    operator may need to start a fresh login session for the new
    primary-group lookup to apply to interactive shells, but
    `sudo` itself evaluates `/etc/group` on each invocation and
    SHALL pick up the new membership immediately.
11. Perform a read-only validation by invoking the installed
    wrapper against `printenv` (or an equivalent `op` invocation
    with the just-encrypted credential) and confirming the
    1Password Environment named by `IDENTIFIER` can be read. Exit
    non-zero on failure, leaving any pre-existing installed wrapper
    and credential unchanged.
12. Ensure `.gitignore` at the repository root contains the entries
    `/with-*-env.sh` and `.env.local`. For each entry that is
    already present, leave `.gitignore` unchanged; any missing entry
    SHALL be appended on its own line. The installer SHALL NOT
    rewrite or reorder unrelated `.gitignore` contents.
13. Print a success line naming the installed wrapper path and the
    encrypted-credential location
    (`/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`).
    The success line SHALL NOT include the token value.

The installer SHALL be idempotent: rerunning it with the same inputs
SHALL produce the same filesystem state without duplicating
`.gitignore` or sudoers entries, without leaving stale temp files,
and without creating additional credentials.

## Installed Wrapper: `with-<IDENTIFIER>-env.sh`

The installed wrapper lives at
`${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` (default
`/usr/local/bin/with-<IDENTIFIER>-env.sh`), is owned by
`root:<IDENTIFIER>`, and has mode `0750`. The rendered build artifact
in the repository root is byte-identical to the installed file.

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

The wrapper runs in three stages, gated by an internal sentinel
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
   SHALL decrypt
   `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
   via `systemd-creds decrypt` directly into a memory variable,
   then re-exec itself via `setpriv --reuid=<IDENTIFIER>
   --regid=<IDENTIFIER> --init-groups` with a clean environment
   (`env -i`) carrying only `HOME`, `PATH`, `OP_SERVICE_ACCOUNT_TOKEN`
   (the just-decrypted token), and `WRAPPER_STAGE=2`. The token
   never appears on a command line and never touches disk after
   decryption.
3. **Stage 2 — run.** Running as the `IDENTIFIER` user with the
   token in env, the wrapper SHALL:
   - `unset OP_CONNECT_HOST OP_CONNECT_TOKEN` so 1Password Connect
     does not override `OP_SERVICE_ACCOUNT_TOKEN`;
   - export `OP_CACHE=false`;
   - enumerate the items in the 1Password vault named by
     `IDENTIFIER` (e.g. `op item list --vault=<IDENTIFIER>
     --format=json | jq …`), validate each item title is a POSIX
     env-var name (`^[A-Za-z_][A-Za-z0-9_]*$`), and write a
     transient env-file of `op://<vault>/<title>/credential`
     references into a private `mktemp -d` directory cleaned up on
     exit;
   - exec `op run --no-masking --env-file=<that file> -- env -u
     OP_SERVICE_ACCOUNT_TOKEN -- <command>` so the final child
     never sees the token;
   - when no command was supplied, run `DEFAULT_SHELL -i` instead.

The wrapper SHALL fail closed with a non-zero exit code and an error
message (but no secret values) when:

- the encrypted credential is missing or `systemd-creds decrypt`
  fails;
- `sudo -n` escalation fails (the operator is not in the
  `IDENTIFIER` group, or the sudoers fragment is missing);
- the Environment ID cannot be resolved;
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
- Naming convention for tokens: one entry per supported identifier
  of the form
  `<IDENTIFIER_UPPERCASE>_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<token>`,
  where `<IDENTIFIER_UPPERCASE>` is the identifier in upper case
  with any hyphens replaced by underscores. For the default
  identifier `openbrain`, the entry is
  `OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<token>`.
- When a fresh clone ships a placeholder value (`PLACEHOLDER`),
  consumers SHALL treat that as "not yet configured" and refuse to
  proceed until a real token has been pasted in by the operator.

Consumers of `.env.local` (the integration test; any future
developer-mode runner) SHALL read it directly (for example via
`set -a; source ./.env.local; set +a` in a clean subshell) and SHALL
NOT modify it.

## Integration Test: `test/integration.bats`

`test/integration.bats` is a [Bats](https://bats-core.readthedocs.io/)
test file that exercises the installer and the installed wrapper
end-to-end against real 1Password infrastructure. It is the
authoritative proof that the repository satisfies the happy-path
acceptance scenarios in this specification.

The test SHALL use the identifier `openbrain` and assume that:

- a Linux user and group `openbrain` exist on the host;
- a 1Password service account, vault, and Environment all named
  `openbrain` exist;
- that Environment contains at least the variable
  `TEST_CREDENTIAL=TEST_VALUE`;
- `.env.local` at the repository root contains
  `OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<real token>`;
- the host provides `bats`, `op`, `jq`, `sudo`, `setpriv`, the
  systemd userspace (`systemctl`, `systemd-creds`), and the BATS
  support libraries `bats-support` and `bats-assert` (or
  equivalents) available on `PATH` or via `load`.

### Behavior

The test file SHALL:

1. In `setup_file` (or equivalent), load `.env.local`, fail fast if
   the file is missing or if
   `OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN` is absent or equals
   `PLACEHOLDER`, and export the token as `OP_SERVICE_ACCOUNT_TOKEN`
   only for installer invocations (not as a global test-process
   env var).
2. Invoke the installer under `sudo -E` with `IDENTIFIER=openbrain`,
   capturing stdout, stderr, and exit status. Assert exit status
   `0`, that the installer reported installing
   `/usr/local/bin/with-openbrain-env.sh`, and that the installer
   output contains neither the raw token value nor the placeholder
   string.
3. Assert that `/usr/local/bin/with-openbrain-env.sh` exists, is
   owned by `root:openbrain`, and has mode `0750`.
4. Assert that the encrypted credential file
   `/etc/credstore.encrypted/1password-env-wrapper-openbrain`
   exists and is owned by `root:root` with mode `0600`, and that
   no plaintext-token file exists anywhere under
   `/etc/onepassword-env-wrapper/` (the directory itself MUST NOT
   exist; this is the "no plaintext on disk" invariant).
5. Assert that `.gitignore` at the repository root contains the
   patterns `/with-*-env.sh` and `.env.local`.
6. Assert that the sudoers fragment
   `/etc/sudoers.d/with-openbrain-env` exists, is owned by
   `root:root`, has mode `0440`, and contains the expected
   `%openbrain ALL=(root) NOPASSWD: …` line.
7. Run the installed wrapper as the `openbrain` user against
   `print-test-env-vars.sh`. Because the repository checkout MAY
   sit under a path that the `openbrain` user cannot traverse, the
   test SHALL stage an executable copy of `print-test-env-vars.sh`
   at a world-readable path that `openbrain` can reach (for example
   `/tmp/print-test-env-vars.<random>.sh`, `chmod 0755`), run the
   wrapper against that staged path, and remove the staged copy on
   teardown. Assert:
   - exit status `0`;
   - the output contains exactly the line `TEST_CREDENTIAL=TEST_VALUE`;
   - the output is sorted by variable name;
   - the output contains no `OP_SERVICE_ACCOUNT_TOKEN=` line.
8. Run the installed wrapper as the `openbrain` user with the
   command `env`; assert `TEST_CREDENTIAL=TEST_VALUE` appears in
   the output and `OP_SERVICE_ACCOUNT_TOKEN` does not.
9. Run the installed wrapper as the `openbrain` user with the
   command `printenv OP_SERVICE_ACCOUNT_TOKEN` and assert the
   wrapper exit status is `1` (variable unset), confirming that the
   secret-zero token is not inherited by the child.
10. Run the **rendered** build artifact at the repository root
    (`./with-openbrain-env.sh`) directly as the BATS-invoking user
    (with the staged `print-test-env-vars.sh` as the argument) and
    assert it succeeds and produces `TEST_CREDENTIAL=TEST_VALUE`.
    This proves stage-0 self-escalation via the sudoers fragment
    works end-to-end for the operator who just ran the installer
    (whose user was added to the `openbrain` group in installer
    step 10).

The test SHALL be idempotent: rerunning it SHALL succeed whether or
not a prior install exists. The test SHOULD NOT remove the installed
wrapper, encrypted credential, sudoers fragment, or group
membership on teardown; cleanup is an operator concern.

### Invocation

Operators run the test from the repository root:

```text
bats test/integration.bats
```

The test itself invokes `sudo` where needed; the outer `bats` process
does not need to run as root, but the session MUST be able to escalate
via `sudo` without a password prompt, or the operator MUST be
prepared to enter their password at the first escalation.

## Usage Documentation: `AGENTS.md`

`AGENTS.md` SHALL document, for both human and agent readers:

1. **What this repo is** — one short paragraph.
2. **Prerequisites** — Linux host with `systemd` (for encrypted
   credentials), `sudo`, the 1Password CLI (`op`) installed and on
   `PATH`, an existing Linux user and group both named `IDENTIFIER`,
   an existing 1Password vault and Environment both named
   `IDENTIFIER`, and a 1Password service account token with read
   access to that Environment.
3. **Installing the wrapper** — exact commands to run
   `sudo -E ./create-1password-env-wrapper.sh`, including how to
   supply `IDENTIFIER` and `OP_SERVICE_ACCOUNT_TOKEN` without
   recording the token in shell history.
4. **Running a command via the wrapper** — exact commands for the
   arbitrary-command form, as the `IDENTIFIER` user.
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
- The token SHALL be stored exclusively as a systemd encrypted
  credential at
  `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
  with owner `root:root` and mode `0600`. A plaintext token file
  under any path (e.g. `/etc/onepassword-env-wrapper/*.token`) is
  explicitly forbidden, and the installer SHALL NOT create
  `/etc/onepassword-env-wrapper/` at all.
- The installed wrapper at
  `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` SHALL be owned by
  `root:<IDENTIFIER>` with mode `0750`.
- A sudoers fragment at
  `/etc/sudoers.d/with-<IDENTIFIER>-env` (owner `root:root`, mode
  `0440`) SHALL grant only members of the `<IDENTIFIER>` group
  passwordless `sudo` for **only** the absolute path of the
  installed wrapper. No other binary, no other group, no
  wildcard.
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
  the host. A compromise of root exposes the service account token
  and every secret it can reach.

## Acceptance Scenarios

### Scenario: Installer refuses missing inputs

Given `./create-1password-env-wrapper.sh` is invoked under `sudo`
without `OP_SERVICE_ACCOUNT_TOKEN` set, with `IDENTIFIER=openbrain`

When the installer validates its inputs

Then it exits non-zero before creating or modifying any files

And it reports the missing input name

And it does not print any secret values

### Scenario: Installer rejects malformed `IDENTIFIER`

Given `IDENTIFIER=Open_Brain` (contains an underscore and uppercase)

When the installer validates its inputs

Then it exits non-zero before creating or modifying any files

And it reports that `IDENTIFIER` is malformed

### Scenario: Installer stores only secret zero, encrypted

Given all required inputs are present with `IDENTIFIER=openbrain`

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
1Password Environment available

And the output contains every `TEST_*` variable defined in the
Environment, in `NAME=value` form, sorted by name

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

When an administrator reruns
`sudo -E ./create-1password-env-wrapper.sh` with the replacement
`OP_SERVICE_ACCOUNT_TOKEN` and the same `IDENTIFIER`

Then the encrypted credential at
`/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>` is
replaced atomically (write sibling temp file, then `mv`)

And subsequent wrapper invocations use the replacement token

And no fetched Environment variables have been persisted to disk

And no plaintext token has been persisted to disk

### Scenario: BATS integration test proves the happy path

Given `.env.local` at the repository root contains a real
`OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN` (not `PLACEHOLDER`)

And the `openbrain` Linux user and group exist

And the 1Password Environment `openbrain` contains `TEST_CREDENTIAL=TEST_VALUE`

When the operator runs `bats test/integration.bats`

Then the installer completes successfully with `IDENTIFIER=openbrain`

And the installed wrapper injects `TEST_CREDENTIAL=TEST_VALUE` into
the child process invoked against `print-test-env-vars.sh`

And `OP_SERVICE_ACCOUNT_TOKEN` is not present in the child process

And every BATS assertion passes
