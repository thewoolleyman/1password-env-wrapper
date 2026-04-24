# AGENTS.md

This file is the short operator's guide for this repository. For the
full contract, see [`SPECIFICATION.md`](SPECIFICATION.md); this file
deliberately does not duplicate it.

## What this repo is

A self-contained installer for a command that runs arbitrary commands
(or an interactive subshell) with environment variables loaded from a
1Password Environment. The 1Password service account token is stored
as an encrypted systemd credential (preferred) or as a root-owned
token file (fallback); the target user never has direct read access
to the token.

A single `IDENTIFIER` value names the Linux user, Linux group,
1Password vault, and 1Password Environment, and determines the
wrapper command name `with-<IDENTIFIER>-env.sh`.

## Prerequisites

- Linux host with `systemd` (for encrypted credentials) and `sudo`
- The [1Password CLI](https://developer.1password.com/docs/cli/) (`op`)
  installed and on `PATH`, in a version that supports service account
  tokens and Environment injection
- An existing Linux **user** and **group** both named `IDENTIFIER`
- An existing 1Password **vault** and **Environment** both named
  `IDENTIFIER`
- A 1Password service account token with read access to that
  Environment

## Install the wrapper

Run the installer from the repository root under `sudo`. Put a leading
space on the command so most shells skip history (requires
`HISTCONTROL=ignorespace` or `ignoreboth`), and use `sudo -E` so the
token env var reaches the installer:

```sh
 sudo -E env \
   IDENTIFIER=openbrain \
   OP_SERVICE_ACCOUNT_TOKEN='ops_EXAMPLE_TOKEN_NOT_A_REAL_VALUE' \
   ./create-1password-env-wrapper.sh
```

Optional inputs (see `SPECIFICATION.md` for defaults and full list):

- `ONEPASSWORD_ENVIRONMENT_ID`
- `INSTALL_PREFIX` (default `/usr/local/bin`)
- `CONFIG_DIR` (default `/etc/onepassword-env-wrapper`)
- `TOKEN_STORAGE_MODE` (`systemd-credential` or `root-owned-file`)
- `DEFAULT_SHELL` (default `/bin/bash`)

The installer renders the wrapper to `./with-<IDENTIFIER>-env.sh` at
the repository root (gitignored, inspect it before it is copied
in), persists the token as an encrypted systemd credential or
root-owned file, installs the wrapper at
`${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` with owner
`root:<IDENTIFIER>` and mode `0750`, and ensures `.gitignore`
contains `/with-*-env.sh`.

## Run a command via the wrapper

As the `IDENTIFIER` user (members of the `IDENTIFIER` group may also
execute the wrapper):

```sh
with-openbrain-env.sh some-command arg1 arg2
```

Use `--` to end wrapper option parsing if the child command starts
with a dash:

```sh
with-openbrain-env.sh -- ./some-tool --flag value
```

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
`OP_SERVICE_ACCOUNT_TOKEN` and the same `IDENTIFIER`. The stored
credential or token file, and the rendered/installed wrapper, are
replaced atomically. No fetched Environment values are persisted to
disk.

## Example shell interaction

The following transcript shows an operator installing the wrapper
with `IDENTIFIER=openbrain`, `openbrain` running the verification
target, and `openbrain` using an interactive shell. The token value
is an obvious placeholder.

```console
admin@vps:~/projects/1password-env-wrapper$ whoami
admin
admin@vps:~/projects/1password-env-wrapper$  sudo -E env \
>    IDENTIFIER=openbrain \
>    OP_SERVICE_ACCOUNT_TOKEN='ops_EXAMPLE_TOKEN_NOT_A_REAL_VALUE' \
>    ./create-1password-env-wrapper.sh
validated 1Password access for Environment "openbrain"
stored token as encrypted systemd credential 1password-env-wrapper-openbrain
installed /usr/local/bin/with-openbrain-env.sh (root:openbrain, mode 0750)
admin@vps:~/projects/1password-env-wrapper$ sudo -iu openbrain
openbrain@vps:~$ with-openbrain-env.sh /home/admin/projects/1password-env-wrapper/print-test-env-vars.sh
TEST_BAR=world
TEST_FOO=hello
openbrain@vps:~$ with-openbrain-env.sh
openbrain@vps:~$ echo "$TEST_FOO"
hello
openbrain@vps:~$ echo "${OP_SERVICE_ACCOUNT_TOKEN:-<unset>}"
<unset>
openbrain@vps:~$ exit
exit
openbrain@vps:~$ exit
logout
admin@vps:~/projects/1password-env-wrapper$
```
