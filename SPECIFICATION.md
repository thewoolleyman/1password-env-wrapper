# 1Password Environment Wrapper Factory

## Example Prompt

Run the following prompt in a fresh Claude Code (or equivalent) session
against a clone of this repository to (re)generate or update the
implementation whenever this specification changes:

> Read `SPECIFICATION.md` from top to bottom. Produce or update every
> file the specification prescribes so that the repository matches the
> spec exactly. Do not add files the spec does not describe. Never
> check any rendered `with-<identifier>-env.sh` into git; it is
> generated output. Every checked-in `*.sh` file must start with
> `#!/usr/bin/env bash`, enable `set -Eeuo pipefail`, be `chmod +x`,
> and pass `shellcheck` with no findings. Update `AGENTS.md` whenever
> the user-facing workflow changes. Do not execute the installer as
> part of implementing the repo — the installer must be run by a human
> operator with `sudo`. If any section of the spec is ambiguous or
> internally inconsistent, stop and report the ambiguity before making
> a judgement call.

## Overview

This repository is a self-contained installer for a
working-directory-agnostic wrapper command that runs arbitrary
commands, or an interactive subshell, with environment variables
loaded from a 1Password Environment. The installer renders the
wrapper, stores the 1Password service account token as an encrypted
systemd credential (or, as a portability fallback, a root-owned token
file), and installs the wrapper under `/usr/local/bin` for a dedicated
Linux user.

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
  members may execute it;
- the 1Password **vault** holding the domain's secrets;
- the 1Password **Environment** whose variables are injected;
- the wrapper command name `with-<IDENTIFIER>-env.sh`;
- the token storage scope (credential name or filename) under
  `CONFIG_DIR`.

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
| `.gitignore` | yes | Ignores any rendered wrapper at the repository root via the pattern `/with-*-env.sh`. |
| `with-<IDENTIFIER>-env.sh` | **no (gitignored)** | Rendered wrapper build artifact produced by the installer; copied into `INSTALL_PREFIX` during installation. |

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
4. **No plaintext env file on disk.** The installer and the wrapper
   MUST NOT write fetched 1Password Environment variables to `.env`,
   `.env.local`, shell profile files, or any other file on disk. The
   wrapper SHALL pass Environment values to the child process
   directly in memory, using whatever injection mechanism the current
   `op` CLI provides (for example `op run --env-file=<path>` reading
   from a process substitution, or an equivalent subcommand). The
   implementer is expected to consult the 1Password CLI documentation
   and pick the simplest mechanism that satisfies this principle.
5. **Token is not readable by the target user.** The service account
   token SHALL be persisted such that the Linux user named by
   `IDENTIFIER` cannot read it directly. Acceptable storage
   mechanisms are an encrypted systemd credential (preferred) and a
   root-owned token file with mode `0600` (portability fallback).
   The wrapper, executable by the Linux group named by `IDENTIFIER`,
   is the only supported path through which the token is used.
6. **Works from any directory.** The installed wrapper SHALL NOT
   depend on the caller's current working directory, repository
   location, or shell startup files.
7. **Ad-hoc first.** The primary workflows are
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
- `CONFIG_DIR` — root-owned configuration directory. Default:
  `/etc/onepassword-env-wrapper`.
- `TOKEN_STORAGE_MODE` — either `systemd-credential` or
  `root-owned-file`. If omitted, the installer SHALL prefer
  `systemd-credential` when supported on the host and fall back to
  `root-owned-file` otherwise.
- `DEFAULT_SHELL` — shell to execute when the wrapper is invoked
  without a command. Default: `/bin/bash`.

Nothing else in the wrapper's identity is configurable: the installer
always renders and installs `with-<IDENTIFIER>-env.sh`.

### Behavior

The installer SHALL, in order:

1. Verify the host is Linux; exit non-zero on other platforms.
2. Verify it is running as `uid 0`; exit non-zero with guidance to
   rerun under `sudo` otherwise.
3. Verify `op` is installed and is a version that supports service
   account tokens and Environment injection. Report the minimum
   required version in the failure message.
4. Verify the Linux user `IDENTIFIER` and the Linux group
   `IDENTIFIER` both exist.
5. Validate all required inputs, including the `IDENTIFIER` regex.
   Exit non-zero on missing or invalid input, naming each offending
   input, without writing any files and without printing secret
   values.
6. Create `CONFIG_DIR` with owner `root:root` and mode `0700` if it
   does not already exist.
7. Render the wrapper to `./with-<IDENTIFIER>-env.sh` at the
   repository root with mode `0755`, baking in the resolved
   `IDENTIFIER`, `CONFIG_DIR`, Environment identifier,
   `TOKEN_STORAGE_MODE`, and `DEFAULT_SHELL`. This file is the
   gitignored build artifact an operator can inspect before install.
8. Persist the service account token per `TOKEN_STORAGE_MODE`:
   - `systemd-credential`: install an encrypted credential under
     `/etc/credstore.encrypted` named for the identifier (for
     example `1password-env-wrapper-<IDENTIFIER>`), scoped such that
     only the wrapper's runtime context can decrypt it;
   - `root-owned-file`: write the token to a file named
     `<IDENTIFIER>.token` inside `CONFIG_DIR` with owner `root:root`
     and mode `0600`. Write atomically: create a sibling temp file,
     `fsync`, `rename`.
9. Install a root-owned non-secret configuration file inside
   `CONFIG_DIR` (for example `<IDENTIFIER>.conf`) containing values
   such as the 1Password Environment ID, the identifier, and the
   default shell. The configuration file SHALL NOT contain the
   service account token.
10. Install the wrapper by copying `./with-<IDENTIFIER>-env.sh` to
    `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` with owner
    `root:<IDENTIFIER>` and mode `0750`, atomically (write to a
    sibling temp file, `fsync`, `rename`).
11. Perform a read-only validation by invoking the installed wrapper
    (or an equivalent `op` invocation with the stored token) and
    confirming the 1Password Environment named by `IDENTIFIER` can
    be read. Exit non-zero on failure, leaving any pre-existing
    installed wrapper and token unchanged.
12. Ensure `.gitignore` at the repository root contains the entry
    `/with-*-env.sh`. If the entry already exists, leave `.gitignore`
    unchanged. The installer SHALL NOT rewrite or reorder unrelated
    `.gitignore` contents.
13. Print a success line naming the installed wrapper path, the token
    storage mode, and the token location (credential name or file
    path). The success line SHALL NOT include the token value.

The installer SHALL be idempotent: rerunning it with the same inputs
SHALL produce the same filesystem state without duplicating
`.gitignore` entries, without leaving stale temp files, and without
creating additional credentials or config entries.

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

The wrapper SHALL:

- read the service account token via the configured
  `TOKEN_STORAGE_MODE` (systemd credential decrypt or root-owned file
  read); the file-mode read path requires the privileged execution
  path arranged by the installer (e.g. `setgid`-bound helper, systemd
  unit, or equivalent), since the user named by `IDENTIFIER` cannot
  read the raw token file directly;
- unset `OP_CONNECT_HOST` and `OP_CONNECT_TOKEN` before invoking
  `op`, because 1Password Connect variables take precedence over
  `OP_SERVICE_ACCOUNT_TOKEN`;
- set `OP_SERVICE_ACCOUNT_TOKEN` only in the environment of the `op`
  process itself, and ensure the final child command or shell does
  not inherit `OP_SERVICE_ACCOUNT_TOKEN`;
- set `OP_CACHE=false` unless a future explicit configuration permits
  caching;
- invoke `op` in a mode that injects Environment variables directly
  into the child process without writing them to disk.

The wrapper SHALL fail closed with a non-zero exit code and an error
message (but no secret values) when:

- the token credential or file is missing or unreadable;
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
script's output can be used as a human-readable smoke test. A typical
verification run is:

```text
sudo -u <IDENTIFIER> with-<IDENTIFIER>-env.sh /absolute/path/to/print-test-env-vars.sh
```

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
8. **Example shell interaction** — a transcript using `openbrain` as
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

`.gitignore` at the repository root SHALL contain a line that ignores
rendered wrapper build artifacts at the repository root:

```text
/with-*-env.sh
```

This pattern covers any `IDENTIFIER` value. The installer MAY append
this line if it is missing. The installer SHALL NOT modify any other
`.gitignore` entries.

## Security Constraints

- The installer and the wrapper MUST NOT write fetched 1Password
  Environment variables to `.env`, `.env.local`, shell profile files,
  or any other file on disk.
- The installer and the wrapper MUST NOT print the service account
  token in normal output, error output, or diagnostics.
- The installer MUST NOT store the service account token inside the
  repository working tree, in command history, in generated shell
  snippets, or in world-readable unit files.
- The token SHALL be stored as an encrypted systemd credential when
  supported, or as a root-owned file with mode `0600` inside
  `CONFIG_DIR` as a portability fallback. The raw token SHALL NOT be
  readable by the `IDENTIFIER` user other than through the installed
  wrapper's controlled execution path.
- `CONFIG_DIR` SHALL be owned by `root:root` with mode `0700`.
- The installed wrapper at
  `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` SHALL be owned by
  `root:<IDENTIFIER>` with mode `0750`.
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

### Scenario: Installer stores only secret zero

Given all required inputs are present with `IDENTIFIER=openbrain`

When `sudo -E ./create-1password-env-wrapper.sh` completes successfully

Then the service account token is persisted using the configured
`TOKEN_STORAGE_MODE` and is not readable by the `openbrain` user
directly

And `${INSTALL_PREFIX}/with-openbrain-env.sh` exists with owner
`root:openbrain` and mode `0750`

And `.gitignore` at the repository root ignores `/with-*-env.sh`

And no `.env`, `.env.local`, or similar file has been written with
fetched Environment variables

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

Then the persisted credential or token file is replaced atomically

And subsequent wrapper invocations use the replacement token

And no fetched Environment variables have been persisted to disk
