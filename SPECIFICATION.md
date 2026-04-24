# 1Password Environment Wrapper Factory

This document specifies a standalone Linux utility that installs a
working-directory-agnostic wrapper for running arbitrary commands or
interactive subshells with secrets loaded from a 1Password service
account.

The wrapper factory is intended for VPS setup and ad-hoc maintenance
work. It is not specific to Open Brain, although Open Brain is the
first target use case.

## Overview

The system SHALL provide a self-contained setup script that installs a
wrapper command for a dedicated Linux user. The wrapper command SHALL
authenticate to 1Password with a service account token, fetch a named
1Password Environment, inject every Environment variable into the
child process environment, and then execute either an arbitrary command
or an interactive shell.

The system SHALL avoid writing the fetched Environment variables to a
plaintext `.env` file. The only secret persisted on the VPS SHALL be
the 1Password service account token, stored with root-owned restrictive
permissions or, when available, as an encrypted systemd credential.

The default naming convention SHALL use the same name for the
1Password service account, vault, and Environment. For Open Brain, the
default name is `OpenBrain`; callers MAY override the name via setup
environment variables.

## Architecture Principles

1. **Service account token is secret zero.** The service account token
   is the only bootstrap secret the VPS needs. Every other runtime
   secret is fetched from 1Password at wrapper execution time.
2. **1Password Environment is the canonical env-var source.** The
   wrapper SHALL inject variables from a 1Password Environment. A
   variable's name in the Environment SHALL be the environment
   variable name seen by the child process.
3. **Vault access is scoped but not enumerated by default.** The
   associated 1Password vault SHALL hold only secrets relevant to the
   same operational domain, but the wrapper's v1 behavior SHALL NOT
   enumerate arbitrary vault items into environment variables. Vault
   item projection MAY be added later under an explicit naming
   convention.
4. **No plaintext env file on VPS.** The wrapper SHALL use
   `op run --environment` or an equivalent 1Password CLI/SDK mechanism
   that passes secrets directly to the child process. It SHALL NOT use
   `op environment read > .env.local` as normal operation.
5. **Works from any directory.** The installed wrapper SHALL NOT depend
   on the caller's current working directory, repository location, or
   shell startup files.
6. **Ad-hoc first.** The primary workflow is `wrapper [command ...]`
   or `wrapper` for an interactive shell. Long-running systemd service
   integration MAY be added later but is not required for v1.

## Setup Inputs

The setup script SHALL be configured entirely by environment
variables. It SHALL fail before making changes if required inputs are
missing.

Required setup inputs:

- `WRAPPER_NAME` — command name to install, for example
  `with-openbrain-env`.
- `TARGET_USER` — Linux user that will run the wrapper, for example
  `openbrain`.
- `TARGET_GROUP` — Linux group that owns wrapper-readable
  configuration, for example `openbrain`.
- `ONEPASSWORD_DOMAIN_NAME` — shared convention name for the
  1Password service account, vault, and Environment, for example
  `OpenBrain`.
- `ONEPASSWORD_SERVICE_ACCOUNT_TOKEN` — token for a 1Password service
  account with read access to the Environment.

Optional setup inputs:

- `ONEPASSWORD_ENVIRONMENT_ID` — explicit 1Password Environment ID.
  If omitted, the setup script MAY resolve the Environment ID from
  `ONEPASSWORD_DOMAIN_NAME` using 1Password CLI support.
- `INSTALL_PREFIX` — directory for the installed wrapper, default
  `/usr/local/bin`.
- `CONFIG_DIR` — root-owned configuration directory, default
  `/etc/onepassword-env-wrapper`.
- `TOKEN_STORAGE_MODE` — either `systemd-credential` or
  `root-owned-file`. If omitted, the setup script SHOULD prefer
  `systemd-credential` when supported and fall back to
  `root-owned-file`.
- `DEFAULT_SHELL` — shell to execute when the wrapper is invoked
  without a command, default `/bin/bash`.

## Setup Behavior

The setup script SHALL verify that it is running on Linux.

The setup script SHALL verify that `op` is installed and supports
1Password service accounts. If Environment injection requires a newer
or beta CLI, the setup script SHALL detect that before installation and
report the required version.

The setup script SHALL verify that `TARGET_USER` and `TARGET_GROUP`
exist. It SHALL NOT create users or groups unless a future explicit
input enables that behavior.

The setup script SHALL create `CONFIG_DIR` with owner `root:root` and
mode `0700`.

The setup script SHALL store the service account token so that it is
not readable by the target user except through the installed wrapper's
controlled execution path. Acceptable token storage mechanisms:

- encrypted systemd credential under `/etc/credstore.encrypted`, when
  systemd credential encryption is available;
- root-owned token file under `CONFIG_DIR` with mode `0600`, as a
  portability fallback.

The setup script SHALL install the wrapper command at
`INSTALL_PREFIX/WRAPPER_NAME` with owner `root:TARGET_GROUP` and mode
`0750`.

The setup script SHALL install a root-owned configuration file
containing non-secret values such as the 1Password Environment ID,
domain name, and default shell. The configuration file SHALL NOT
contain the service account token unless `TOKEN_STORAGE_MODE` is
`root-owned-file`, in which case the token SHALL live in a separate
mode-`0600` token file.

After installation, the setup script SHALL perform a read-only
validation by executing `op` with the stored service account token and
checking that the configured 1Password Environment can be read.

## Wrapper Contract

The installed wrapper SHALL have this command shape:

```text
WRAPPER_NAME [--] [command [arg ...]]
```

When invoked with a command, the wrapper SHALL execute that command
with all configured 1Password Environment variables injected.

When invoked without a command, the wrapper SHALL execute
`DEFAULT_SHELL` as an interactive shell with all configured 1Password
Environment variables injected.

The wrapper SHALL authenticate to 1Password using the stored service
account token. It SHALL set `OP_SERVICE_ACCOUNT_TOKEN` only for the
1Password CLI process and SHALL prevent the final child command or
shell from inheriting `OP_SERVICE_ACCOUNT_TOKEN`.

The wrapper SHALL unset `OP_CONNECT_HOST` and `OP_CONNECT_TOKEN` before
invoking `op`, because 1Password Connect variables take precedence
over `OP_SERVICE_ACCOUNT_TOKEN`.

The wrapper SHALL disable 1Password CLI caching by default via
`OP_CACHE=false` unless a future explicit configuration permits
caching.

The wrapper SHALL fail closed when:

- the token file or credential is missing;
- the Environment ID is missing or cannot be resolved;
- the service account token cannot read the Environment;
- `op run --environment` or equivalent injection fails.

The wrapper SHALL avoid printing secret values in normal output and
error messages.

## Environment Variable Contract

Every variable defined in the configured 1Password Environment SHALL
be present in the child process environment with the same name and
value.

The wrapper SHALL NOT synthesize, rename, or transform Environment
variable names.

If the configured Environment contains a variable name that is invalid
for a POSIX process environment, the wrapper SHALL fail and identify
the variable name without printing its value.

If the child process already has an environment variable with the same
name, the 1Password Environment value SHALL win.

The service account token SHALL NOT be present in the final child
process environment.

## Security Constraints

The setup script and wrapper MUST NOT write fetched 1Password
Environment variables to `.env`, `.env.local`, shell profile files, or
working-directory-local files.

The setup script and wrapper MUST NOT print the service account token.

The setup script and wrapper MUST NOT store the service account token
in command history, generated shell snippets, or world-readable unit
files.

The setup script SHALL warn that root compromise on the VPS can expose
the service account token and every secret reachable by that token.
This system reduces accidental exposure and limits blast radius; it
does not protect against a fully compromised root account.

The 1Password service account SHOULD have read-only access to only the
single operational Environment and its associated vault.

The associated vault SHOULD contain only operational secrets for the
same domain as the Environment.

Service account token rotation SHALL be treated as a supported
maintenance operation. Because 1Password service account access to
Environments is immutable, changing Environment access SHALL require
creating a replacement service account and replacing the stored token.

## Acceptance Scenarios

## Scenario: Setup refuses missing inputs

Given the setup script is invoked without `ONEPASSWORD_SERVICE_ACCOUNT_TOKEN`

When the setup script validates its inputs

Then it exits non-zero before creating or modifying files

And it reports the missing input name

And it does not print any secret values

## Scenario: Setup stores only secret zero

Given all required setup inputs are present

When the setup script completes successfully

Then the VPS contains a persisted 1Password service account token
using the configured token storage mode

And the VPS does not contain a generated `.env` or `.env.local` file
with fetched Environment variables

## Scenario: Wrapper starts an interactive shell

Given the wrapper is installed and the service account can read the
configured 1Password Environment

When the target user runs `WRAPPER_NAME`

Then an interactive shell starts

And every variable from the 1Password Environment is available inside
that shell

And `OP_SERVICE_ACCOUNT_TOKEN` is not available inside that shell

## Scenario: Wrapper runs an arbitrary command

Given the wrapper is installed and the service account can read the
configured 1Password Environment

When the target user runs `WRAPPER_NAME env`

Then the `env` command runs with every variable from the 1Password
Environment available

And the command does not receive `OP_SERVICE_ACCOUNT_TOKEN`

## Scenario: 1Password values override caller values

Given the caller's shell has `SUPABASE_URL=wrong`

And the configured 1Password Environment has `SUPABASE_URL=correct`

When the caller runs `WRAPPER_NAME printenv SUPABASE_URL`

Then the command prints `correct`

## Scenario: Missing 1Password access fails closed

Given the stored service account token has been revoked

When the target user runs `WRAPPER_NAME`

Then no child shell or command is started with partial secrets

And the wrapper exits non-zero

And the wrapper reports that 1Password Environment injection failed

## Scenario: Token rotation replaces secret zero

Given the service account token has been rotated in 1Password

When an administrator reruns the setup script with the replacement
`ONEPASSWORD_SERVICE_ACCOUNT_TOKEN`

Then the persisted token is replaced

And subsequent wrapper invocations use the replacement token

And no fetched Environment variables are persisted to disk
