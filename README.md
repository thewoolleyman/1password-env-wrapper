# 1Password Environment Wrapper Factory

Installer for a working-directory-agnostic shell command that runs
arbitrary commands — or an interactive subshell — with environment
variables loaded from a [1Password
Environment](https://developer.1password.com/docs/environments)
(the developer beta feature). The 1Password service-account token
is sealed as a `systemd-creds` encrypted credential under
`/etc/credstore.encrypted/`; the wrapper self-escalates via
`sudo -n`, decrypts the credential into memory, then drops
privileges via `setpriv` to the dedicated `IDENTIFIER` user before
invoking `op run --environment <env-id>` so the final child
process never sees `OP_SERVICE_ACCOUNT_TOKEN`.

The repo is opinionated for **single-VPS / single-operator personal
use on Linux + systemd**. It is not a general-purpose secrets-management
solution.

## Quick start

```sh
# Prerequisites: Linux with systemd, GNU sudo, setpriv,
#   the 1Password CLI BETA (op >= 2.33.0-beta.02 — the stable line
#   2.34.0 still lacks `op environment`), and a Linux user+group
#   matching your chosen IDENTIFIER (e.g. `openbrain`).

# 1. Populate .env.local in the repo root (gitignored):
cat > .env.local <<'EOF'
OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=ops_…your-real-token…
OPENBRAIN_1PASSWORD_ENVIRONMENT_ID=…env-id-from-the-1password-desktop-app…
EOF

# 2. Install (sudo writes /etc/credstore.encrypted/, /etc/sudoers.d/,
#    and ${INSTALL_PREFIX}/with-<IDENTIFIER>-env.sh):
OP_SERVICE_ACCOUNT_TOKEN="$(awk -F= '/^OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=/ {print $2}' .env.local)" \
ONEPASSWORD_ENVIRONMENT_ID="$(awk -F= '/^OPENBRAIN_1PASSWORD_ENVIRONMENT_ID=/ {print $2}' .env.local)" \
IDENTIFIER=openbrain \
sudo -E ./create-1password-env-wrapper.sh

# 3. Use the wrapper from anywhere:
with-openbrain-env.sh /absolute/path/to/some-command --flags
with-openbrain-env.sh                                 # interactive shell with vars injected

# 4. (Optional) Smoke-test:
bats test/integration.bats
```

## What's in this repo

| File | Purpose |
|---|---|
| `create-1password-env-wrapper.sh` | The installer. Renders + installs the wrapper, encrypts the token. |
| `print-test-env-vars.sh` | Test-target script that prints `TEST_*` env vars sorted. |
| `test/integration.bats` | End-to-end Bats integration test (15 cases, against real 1Password). |
| [`AGENTS.md`](AGENTS.md) | Operator-and-agent quick guide: install, run, rotate, run the integration test. |
| [`SPECIFICATION.md`](SPECIFICATION.md) | The full contract: invocation contract, runtime stages, security constraints, acceptance scenarios. Source of truth. |
| `.env.local` (gitignored) | Bootstrap token + Environment ID for the integration test. After the first install, the test can fall back to the on-host encrypted state and the file may be deleted. |

For deeper detail — including the three-stage `WRAPPER_STAGE`
re-exec model (sudo-escalate → `systemd-creds decrypt` → `setpriv`
drop-priv → `op run --environment`), the encrypted-state fallback,
the canonical-source header on every rendered wrapper, and every
acceptance scenario — read [`SPECIFICATION.md`](SPECIFICATION.md).
For day-to-day operator workflow, read [`AGENTS.md`](AGENTS.md).
