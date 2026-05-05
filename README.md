# 1Password Environment Wrapper Factory

Installer for a working-directory-agnostic shell command that runs
arbitrary commands — or an interactive subshell — with environment
variables loaded from a [1Password
Environment](https://developer.1password.com/docs/environments)
(the developer beta feature). Cross-platform: same factory, same
rendered wrapper bytes, on **Linux** and **macOS**.

The wrapper picks its credential-retrieval path at runtime via
`case "$(uname)"`:

- **Linux**: the 1Password service-account token is sealed as a
  `systemd-creds` encrypted credential under
  `/etc/credstore.encrypted/`; the wrapper self-escalates via
  `sudo -n`, decrypts the credential into memory, then drops
  privileges via `setpriv` back to the **invoker** before invoking
  `op run --environment <env-id>`. The token never appears on a
  command line and never touches disk after decryption.
- **macOS**: the token sits in the per-user **login Keychain**
  (service `<IDENTIFIER>`, account `OP_SERVICE_ACCOUNT_TOKEN`).
  The wrapper retrieves it via `security find-generic-password
  -w` into a memory variable, then runs `op run --environment
  <env-id>`. No `sudo`, no privilege drop — the macOS login
  session is the security boundary.

The repo is opinionated for **single-VPS / single-operator personal
use**. It is not a general-purpose secrets-management solution.

## Platforms

| Platform | Required | Token store | Sudo? |
|---|---|---|---|
| Linux  | systemd, GNU `sudo`, `setpriv`, `op` (Env-aware), an existing Linux *group* named `IDENTIFIER` | `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>` (root:root, 0600) | yes (`sudo -E` on installer) |
| macOS  | `security` CLI (ships with the OS), `op` (Env-aware) | login Keychain entry (service `<IDENTIFIER>`, account `OP_SERVICE_ACCOUNT_TOKEN`) | **no** (refuses to run under sudo) |

The 1Password CLI must support **Environments**: `op
2.33.0-beta.02` or later from
<https://releases.1password.com/developers/cli-beta/>. Stable `op
2.34.0` is too old.

The rendered wrapper at `${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh`
is **byte-identical** across Linux and macOS for identical inputs,
so a consumer project can commit it to git and use the same file
on both kinds of host. See `SPECIFICATION.md § Platform Support`.

## Quick start

Both platforms share the `.env.local` bootstrap setup; only the
final installer invocation forks.

```sh
# 1. Populate .env.local in the repo root (gitignored):
cat > .env.local <<'EOF'
OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=ops_…your-real-token…
OPENBRAIN_1PASSWORD_ENVIRONMENT_ID=…env-id-from-the-1password-desktop-app…
EOF

# 2. Install. The wrapper bytes are the same regardless of platform;
#    only the installer's *behavior* differs (per-host token store,
#    permissions, sudoers).

# Linux:
 OP_SERVICE_ACCOUNT_TOKEN="$(awk -F= '/^OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=/ {print $2}' .env.local)" \
  ONEPASSWORD_ENVIRONMENT_ID="$(awk -F= '/^OPENBRAIN_1PASSWORD_ENVIRONMENT_ID=/ {print $2}' .env.local)" \
  IDENTIFIER=openbrain \
  sudo -E ./create-1password-env-wrapper.sh

# macOS (no sudo — Keychain seeding must run as your login user):
 OP_SERVICE_ACCOUNT_TOKEN="$(awk -F= '/^OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=/ {print $2}' .env.local)" \
  ONEPASSWORD_ENVIRONMENT_ID="$(awk -F= '/^OPENBRAIN_1PASSWORD_ENVIRONMENT_ID=/ {print $2}' .env.local)" \
  IDENTIFIER=openbrain \
  ./create-1password-env-wrapper.sh

# 3. Use the wrapper from anywhere (same on both platforms):
with-openbrain-env.sh /absolute/path/to/some-command --flags
with-openbrain-env.sh                                 # interactive shell with vars injected

# 4. (Optional) Smoke-test:
bats test/integration.bats
```

The leading space on the install command tells most shells with
`HISTCONTROL=ignorespace` (or `ignoreboth`) to skip it from
history — useful when the token is on the command line via the
bash local-env prefix.

## Where the token actually lives

After `create-1password-env-wrapper.sh` succeeds:

- **Linux**: `/etc/credstore.encrypted/1password-env-wrapper-<IDENTIFIER>`
  (root:root, 0600). Decryptable only as root via `systemd-creds
  decrypt --name=…`.
- **macOS**: macOS login Keychain. Inspect with `security
  find-generic-password -s <IDENTIFIER> -a OP_SERVICE_ACCOUNT_TOKEN
  -w` (no password prompt for first read after login; subsequent
  reads in scripts may prompt depending on Keychain policy).

In neither case does the raw token end up in a plaintext file on
disk (other than the gitignored `.env.local`, which the operator
may delete after a successful install).

## What's in this repo

| File | Purpose |
|---|---|
| `create-1password-env-wrapper.sh` | The installer. Renders + installs the wrapper, stores the token in the platform-appropriate secure store. |
| `print-test-env-vars.sh` | Test-target script that prints `TEST_*` env vars sorted. |
| `test/integration.bats` | End-to-end Bats integration test (cross-platform; gates Linux-only / macOS-only assertions per `uname`). |
| [`AGENTS.md`](AGENTS.md) | Operator-and-agent quick guide: install, run, rotate, run the integration test. |
| [`SPECIFICATION.md`](SPECIFICATION.md) | The full contract: invocation contract, runtime stages, security constraints, acceptance scenarios. Source of truth. |
| `.env.local` (gitignored) | Bootstrap token + Environment ID for the integration test. After the first install, the test can fall back to the on-host secure store and the file may be deleted. |

For deeper detail — including the three-stage `WRAPPER_STAGE`
re-exec model on Linux, the single-stage Keychain → `op run` path
on macOS, the byte-identicality invariant, the encrypted-state
fallback, the canonical-source header on every rendered wrapper,
and every acceptance scenario — read
[`SPECIFICATION.md`](SPECIFICATION.md). For day-to-day operator
workflow, read [`AGENTS.md`](AGENTS.md).
