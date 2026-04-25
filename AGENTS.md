# AGENTS.md

This file is the short operator's guide for this repository. For the
full contract, see [`SPECIFICATION.md`](SPECIFICATION.md); this file
deliberately does not duplicate it.

## What this repo is

A self-contained installer for a command that runs arbitrary commands
(or an interactive subshell) with environment variables loaded from a
1Password Environment. The 1Password service account token is stored
**only** as a systemd encrypted credential at
`/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>` —
plaintext token files on disk are explicitly forbidden. The wrapper
self-escalates via `sudo -n`, decrypts the credential with
`systemd-creds`, then drops privileges via `setpriv` to the
`IDENTIFIER` user before invoking `op`. The token never appears on
a command line and never touches disk after decryption.

A single `IDENTIFIER` value names the Linux user, Linux group,
1Password vault, and 1Password Environment, and determines the
wrapper command name `with-<IDENTIFIER>-env.sh`.

## Prerequisites

- Linux host with **systemd** (`systemctl`, `systemd-creds`),
  `sudo` (GNU sudo, not `sudo-rs` — `-E` / `--preserve-env=` is
  required), and `setpriv` (`util-linux`)
- The [1Password CLI](https://developer.1password.com/docs/cli/)
  (`op`) installed and on `PATH`
- `jq` installed and on `PATH` (used by the wrapper to enumerate
  vault items)
- An existing Linux **user** and **group** both named `IDENTIFIER`
- An existing 1Password **vault** named `IDENTIFIER` whose items
  represent the variables to inject — each item's title is the
  environment variable name and the value lives in the item's
  `credential` field
- A 1Password service account token with read access to that vault

## Install the wrapper

Run the installer from the repository root under `sudo -E`. Put a
leading space on the command so most shells skip history (requires
`HISTCONTROL=ignorespace` or `ignoreboth`), and pass the token as a
**bash local-env prefix** so it never appears on a command-line
argument (auditd / `auth.log` / journal log argv but not env):

```sh
  OP_SERVICE_ACCOUNT_TOKEN='ops_EXAMPLE_TOKEN_NOT_A_REAL_VALUE' \
   IDENTIFIER=openbrain \
   sudo -E ./create-1password-env-wrapper.sh
```

Optional inputs (see `SPECIFICATION.md` for defaults and full list):

- `ONEPASSWORD_ENVIRONMENT_ID`
- `INSTALL_PREFIX` (default `/usr/local/bin`)
- `DEFAULT_SHELL` (default `/bin/bash`)

There is **no** `TOKEN_STORAGE_MODE` knob — token storage is always
the systemd encrypted credential. There is no `CONFIG_DIR` either:
the installer no longer writes any plaintext file under `/etc/`.

The installer renders the wrapper to `./with-<IDENTIFIER>-env.sh`
at the repository root (gitignored, inspect it before it is copied
in), encrypts the token via `systemd-creds encrypt` into
`/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
(owner `root:root`, mode `0600`), installs the wrapper at
`${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh` with owner
`root:<IDENTIFIER>` and mode `0750`, drops a sudoers fragment at
`/etc/sudoers.d/with-<IDENTIFIER>-env` granting `%<IDENTIFIER>`
passwordless `sudo` for that one wrapper, adds `$SUDO_USER` to
the `<IDENTIFIER>` group, and ensures `.gitignore` contains both
`/with-*-env.sh` and `.env.local`.

After the installer completes, your existing shell does not yet
reflect the new group membership — but `sudo` evaluates
`/etc/group` on every invocation, so the wrapper's stage-0
`sudo -n` self-escalation works immediately. To get `with-…-env.sh`
into your interactive shell's idea of "my groups" (so for example
the wrapper's setgid bit on `0750` doesn't trip `[ -x ]` for
adjacent tooling), start a new login session or `exec sg
<IDENTIFIER> bash`.

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
`OP_SERVICE_ACCOUNT_TOKEN` and the same `IDENTIFIER`. The encrypted
credential at
`/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>` and
the rendered/installed wrapper are replaced atomically. No fetched
Environment values, and no plaintext token, are persisted to disk
at any point.

## Running the integration test

The repository ships a Bats integration test at
`test/integration.bats` that drives the installer against real
1Password infrastructure. To run it:

1. Make sure the host has `bats`, `bats-support`, `bats-assert`,
   `op`, `jq`, `sudo`, and the Linux user/group `openbrain`.
2. Populate the gitignored bootstrap secret file `.env.local` at the
   repository root with a real service account token. Starting from
   the placeholder:

   ```sh
   printf 'OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=PLACEHOLDER\n' > .env.local
   # then edit .env.local and replace PLACEHOLDER with the real token
   ```

   The test will fail fast if the file is missing or the token still
   reads `PLACEHOLDER`.
3. Make sure the 1Password vault `openbrain` contains an item titled
   `TEST_CREDENTIAL` with a `credential` field equal to
   `TEST_VALUE`.
4. From the repository root, run:

   ```sh
   bats test/integration.bats
   ```

   The outer `bats` process does not need to run as root, but the
   session MUST be able to escalate via `sudo` (the test invokes
   `sudo` itself).

## Example shell interaction

The following transcript shows an operator installing the wrapper
with `IDENTIFIER=openbrain`, `openbrain` running the verification
target, and `openbrain` using an interactive shell. The token value
is an obvious placeholder.

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
1Password vault:      openbrain
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
