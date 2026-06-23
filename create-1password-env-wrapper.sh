#!/usr/bin/env bash
set -Eeuo pipefail

# 1Password Environment Wrapper Factory installer.
#
# Renders ./with-<IDENTIFIER>-env.sh, stores the service account token
# in a platform-appropriate secure store, and installs the wrapper.
#
# Cross-platform:
#   - Linux: encrypts the token via systemd-creds into
#     /etc/credstore.encrypted/, installs the wrapper as root:<IDENTIFIER>
#     0750, drops a sudoers fragment, adds the invoking operator to the
#     IDENTIFIER group.
#   - macOS: stores the token in the per-user login Keychain under
#     service "<IDENTIFIER>", account "OP_SERVICE_ACCOUNT_TOKEN",
#     installs the wrapper as the invoking user, no sudo, no sudoers,
#     no group.
#
# The *rendered wrapper* is byte-identical between the two platforms
# given identical inputs (IDENTIFIER, ONEPASSWORD_ENVIRONMENT_ID,
# OP_SERVICE_ACCOUNT_TOKEN, INSTALL_PREFIX, DEFAULT_SHELL): both
# platform branches are present in both renderings; the wrapper picks
# the right one at runtime via `case "$(uname)"`. See SPECIFICATION.md.

PROG="create-1password-env-wrapper.sh"

err()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { err "$@"; exit 1; }
note() { printf '%s\n' "$*"; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Platform detection.
# ---------------------------------------------------------------------------
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Linux|Darwin) ;;
    *) die "unsupported platform: $PLATFORM (only Linux and Darwin are supported)" ;;
esac

# ---------------------------------------------------------------------------
# Platform-specific prerequisites.
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "Linux" ]; then
    command -v systemctl     >/dev/null 2>&1 || die "systemd is required (systemctl not on PATH)"
    command -v systemd-creds >/dev/null 2>&1 || die "systemd-creds is required (install systemd-container or upgrade systemd)"
    command -v setpriv       >/dev/null 2>&1 || die "setpriv is required (install util-linux)"
    [ "$(id -u)" -eq 0 ] || die "must run as root on Linux; rerun under: sudo -E ./$PROG"
else
    # macOS: `security` ships in /usr/bin and is part of the OS, so
    # this check is a belt-and-braces sanity test.
    command -v security >/dev/null 2>&1 || die "macOS 'security' CLI is required but not on PATH"
    # Refuse to run as root on macOS: per-user Keychain storage is the
    # whole point, and `security add-generic-password` for root would
    # write into /var/root's login keychain instead of the operator's.
    if [ "$(id -u)" -eq 0 ]; then
        die "do NOT run this installer under sudo on macOS; run it as your normal user so the Keychain entry lands in your login keychain"
    fi
fi

# Common prereq: the 1Password CLI with Environments support
# (introduced in the 2.33.0-beta.02 line). Probe with
# `op environment --help` rather than parsing version strings.
command -v op >/dev/null 2>&1 || die "1Password CLI ('op') is not on PATH; install from https://developer.1password.com/docs/cli/"
if ! op environment --help >/dev/null 2>&1; then
    die "the installed 'op' build does not support 1Password Environments (need 2.33.0-beta.02 or later from https://releases.1password.com/developers/cli-beta/ ; currently $(op --version 2>&1))"
fi

# ---------------------------------------------------------------------------
# Validate inputs.
# ---------------------------------------------------------------------------
IDENTIFIER="${IDENTIFIER:-}"
OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN:-}"
ONEPASSWORD_ENVIRONMENT_ID="${ONEPASSWORD_ENVIRONMENT_ID:-}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
DEFAULT_SHELL="${DEFAULT_SHELL:-/bin/bash}"

missing=()
[ -n "$IDENTIFIER" ] || missing+=("IDENTIFIER")
[ -n "$OP_SERVICE_ACCOUNT_TOKEN" ] || missing+=("OP_SERVICE_ACCOUNT_TOKEN")
[ -n "$ONEPASSWORD_ENVIRONMENT_ID" ] || missing+=("ONEPASSWORD_ENVIRONMENT_ID")
if [ "${#missing[@]}" -gt 0 ]; then
    die "missing required input(s): ${missing[*]}"
fi

if ! [[ "$IDENTIFIER" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ ]]; then
    die "IDENTIFIER is malformed: must match ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ (got: $IDENTIFIER)"
fi

# On macOS, fall back to ~/.local/bin if the requested INSTALL_PREFIX
# is not writable by the current user. On Linux we leave INSTALL_PREFIX
# alone — it must exist and be writable by root (we are root).
if [ "$PLATFORM" = "Darwin" ]; then
    if [ ! -d "$INSTALL_PREFIX" ] || [ ! -w "$INSTALL_PREFIX" ]; then
        fallback_prefix="$HOME/.local/bin"
        note "INSTALL_PREFIX '$INSTALL_PREFIX' not writable; falling back to $fallback_prefix"
        mkdir -p -- "$fallback_prefix"
        INSTALL_PREFIX="$fallback_prefix"
    fi
else
    [ -d "$INSTALL_PREFIX" ] || die "INSTALL_PREFIX does not exist: $INSTALL_PREFIX"
fi

# ---------------------------------------------------------------------------
# Linux-only: verify the IDENTIFIER group exists. (A Linux *user* named
# IDENTIFIER is NOT required: the wrapper drops privileges back to the
# invoker at runtime, not to a separate IDENTIFIER user. See
# SPECIFICATION.md § Architecture Principles #5.) macOS has no
# IDENTIFIER group concept — single-user per-Keychain isolation
# replaces the group-gated sudoers model.
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "Linux" ]; then
    getent group "$IDENTIFIER" >/dev/null \
        || die "Linux group '$IDENTIFIER' does not exist (the installer SHALL NOT create it)"
fi

# ---------------------------------------------------------------------------
# Render the wrapper to ./with-<IDENTIFIER>-env.sh (mode 0755).
#
# IMPORTANT: the rendered output is byte-identical regardless of which
# host (Linux or macOS) ran this installer. Both platform branches are
# always emitted; the wrapper selects between them at runtime.
# ---------------------------------------------------------------------------
WRAPPER_BASENAME="with-${IDENTIFIER}-env.sh"
RENDERED_WRAPPER="${REPO_ROOT}/${WRAPPER_BASENAME}"
INSTALLED_WRAPPER="${INSTALL_PREFIX}/${WRAPPER_BASENAME}"
SYSTEMD_CRED_NAME="1password-env-wrapper-${IDENTIFIER}"
SYSTEMD_CRED_PATH="/etc/credstore.encrypted/${SYSTEMD_CRED_NAME}"
SUDOERS_FRAGMENT="/etc/sudoers.d/with-${IDENTIFIER}-env"
MACOS_KEYCHAIN_SERVICE="${IDENTIFIER}"
MACOS_KEYCHAIN_TOKEN_ACCOUNT="OP_SERVICE_ACCOUNT_TOKEN"

render_wrapper() {
    local out="$1"
    cat > "$out" <<WRAPPER_EOF
#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# GENERATED BUILD ARTIFACT — DO NOT EDIT THIS FILE.
# =============================================================================
#
# Canonical source:
#   https://github.com/thewoolleyman/1password-env-wrapper
#
# Cross-platform (Linux + macOS). The bytes of this file are identical
# whether it was rendered on Linux or macOS for the same inputs; the
# wrapper dispatches on \`uname\` at runtime to pick the right
# credential-retrieval path.
#
# This file was rendered by create-1password-env-wrapper.sh from the
# wrapper template that lives in that repository. It is NOT
# hand-maintained. Any edit you make here will be SILENTLY REVERTED
# the next time an operator runs the installer (which renders this
# file fresh and overwrites whatever was at this path).
#
# DO NOT edit this file directly under any circumstances — not for
# emergencies, not for one-off debugging, not for "I will copy it
# back into the repo afterwards." If you find a bug or want an
# improvement:
#
#   1. Open the repository above.
#   2. Edit the wrapper template inside create-1password-env-wrapper.sh
#      (or the appropriate spec section in SPECIFICATION.md).
#   3. Open a Pull Request.
#   4. Once merged, rerun the installer on each host to regenerate
#      this file. (\`sudo -E ./create-1password-env-wrapper.sh\` on
#      Linux; \`./create-1password-env-wrapper.sh\` without sudo on
#      macOS.)
#
# To regenerate locally with the same inputs you used last time, run
# the installer again from the repository root. The rendering is
# deterministic given the same inputs.
# =============================================================================

# IDENTIFIER is baked in as documentation / for the encrypted-state
# fallback (consumers grep this readonly out of the installed file).
# It is intentionally not referenced inside the wrapper itself.
# shellcheck disable=SC2034
readonly IDENTIFIER='${IDENTIFIER}'
readonly DEFAULT_SHELL='${DEFAULT_SHELL}'
readonly ONEPASSWORD_ENVIRONMENT_ID='${ONEPASSWORD_ENVIRONMENT_ID}'
readonly INSTALLED_WRAPPER='${INSTALLED_WRAPPER}'

# Linux-only constants (referenced only inside the Linux runtime branch).
readonly LINUX_SYSTEMD_CRED_NAME='${SYSTEMD_CRED_NAME}'
readonly LINUX_SYSTEMD_CRED_PATH='${SYSTEMD_CRED_PATH}'

# macOS-only constants (referenced only inside the Darwin runtime branch).
readonly MACOS_KEYCHAIN_SERVICE='${MACOS_KEYCHAIN_SERVICE}'
readonly MACOS_KEYCHAIN_TOKEN_ACCOUNT='${MACOS_KEYCHAIN_TOKEN_ACCOUNT}'

PROG="\$(basename -- "\$0")"
err()  { printf '%s: %s\n' "\$PROG" "\$*" >&2; }
die()  { err "\$@"; exit 1; }

# Drop -- separator if present.
if [ "\$#" -gt 0 ] && [ "\$1" = "--" ]; then
    shift
fi

case "\$(uname -s)" in
    Linux)
        # ---------------------------------------------------------------
        # Linux runtime path: 3-stage WRAPPER_STAGE re-exec model.
        # Stage 0: sudo -n self-escalate to root.
        # Stage 1: systemd-creds decrypt the token, setpriv drop back to
        #          the invoker (per SUDO_UID/SUDO_GID/SUDO_USER), re-exec
        #          stage 2 with the token in env.
        # Stage 2: op run --environment, with OP_SERVICE_ACCOUNT_TOKEN
        #          stripped from the final child env.
        # ---------------------------------------------------------------
        case "\${WRAPPER_STAGE:-0}" in
            0)
                # Stage 0 — escalate. Always re-exec the *installed* wrapper
                # (not \$0, which may be the gitignored rendered build artifact
                # at the repo root) so the sudoers rule only ever needs to
                # whitelist one path.
                # -e (existence) rather than -x (executable): the operator's
                # bash may have started before installer step 10 added them
                # to the IDENTIFIER group, so a 0750 root:<IDENTIFIER> file
                # can fail [ -x ] for them even though sudo (which evaluates
                # /etc/group fresh) will let them escalate to root, where
                # execution is unconstrained by the group bit.
                if [ ! -e "\$INSTALLED_WRAPPER" ]; then
                    die "installed wrapper not found at \$INSTALLED_WRAPPER (run create-1password-env-wrapper.sh first)"
                fi
                if [ "\$(id -u)" -eq 0 ]; then
                    # Already root; jump straight to stage 1 without sudo.
                    # No \`--\` after the assignment: uutils \`env\` (and POSIX
                    # \`env\`) reject a GNU-style \`--\` separator following
                    # NAME=value operands; the assignment list already ends at
                    # the first non-assignment word.
                    exec env WRAPPER_STAGE=1 "\$INSTALLED_WRAPPER" "\$@"
                fi
                if ! sudo_path="\$(command -v sudo)"; then
                    die "sudo not found on PATH; required to escalate for credential decryption"
                fi
                exec "\$sudo_path" -n WRAPPER_STAGE=1 -- "\$INSTALLED_WRAPPER" "\$@"
                ;;
            1)
                # Stage 1 — running as root. Decrypt the credential into memory,
                # then drop privileges back to the *invoker* (the user who ran
                # sudo to get here, identified by SUDO_UID / SUDO_GID / SUDO_USER
                # which sudo always sets on the elevated process), and re-exec
                # the wrapper as stage 2. We drop to the invoker — not to a
                # separate IDENTIFIER user — so files created or touched by the
                # child command end up owned by whoever invoked the wrapper.
                # See SPECIFICATION.md § Architecture Principles #5.
                [ "\$(id -u)" -eq 0 ] || die "stage 1 expected uid 0 (got \$(id -u))"
                [ -n "\${SUDO_UID:-}" ] \\
                    || die "stage 1 expected SUDO_UID in env (sudo did not set it; was the wrapper invoked directly as root without sudo?)"
                [ -n "\${SUDO_GID:-}" ] \\
                    || die "stage 1 expected SUDO_GID in env"
                [ -n "\${SUDO_USER:-}" ] \\
                    || die "stage 1 expected SUDO_USER in env"
                invoker_home="\$(getent passwd "\$SUDO_UID" | cut -d: -f6)"
                [ -n "\$invoker_home" ] \\
                    || die "could not resolve home directory for SUDO_UID=\$SUDO_UID via getent"
                [ -r "\$LINUX_SYSTEMD_CRED_PATH" ] \\
                    || die "encrypted credential missing or unreadable: \$LINUX_SYSTEMD_CRED_PATH"
                if ! token="\$(systemd-creds decrypt --name="\$LINUX_SYSTEMD_CRED_NAME" "\$LINUX_SYSTEMD_CRED_PATH" - 2>/dev/null)"; then
                    die "systemd-creds decrypt failed for \$LINUX_SYSTEMD_CRED_PATH"
                fi
                [ -n "\$token" ] || die "decrypted credential is empty"

                # OPENV_PRESERVE_VARS (default unset/empty) — generic,
                # caller-controlled allowlist of env var NAMES whose current
                # values are carried THROUGH the \`env -i\` scrub into the final
                # command. This is the generic mechanism for forwarding a
                # named secret/setting; the wrapper hard-codes no specific name.
                # Names are read from the runtime env, comma-separated;
                # whitespace is trimmed and empty entries are skipped.
                preserve=()
                if [ -n "\${OPENV_PRESERVE_VARS:-}" ]; then
                    IFS=',' read -r -a _openv_names <<< "\$OPENV_PRESERVE_VARS"
                    for _openv_n in "\${_openv_names[@]}"; do
                        # Trim leading/trailing whitespace.
                        _openv_n="\${_openv_n#"\${_openv_n%%[![:space:]]*}"}"
                        _openv_n="\${_openv_n%"\${_openv_n##*[![:space:]]}"}"
                        [ -n "\$_openv_n" ] || continue
                        preserve+=( "\$_openv_n=\$(printenv "\$_openv_n" 2>/dev/null || true)" )
                    done
                fi

                if [ "\${OPENV_KEEP_PRIVILEGES:-0}" = "1" ]; then
                    # OPENV_KEEP_PRIVILEGES=1 — explicit, default-off opt-OUT of
                    # the drop-to-invoker principle (SPECIFICATION.md
                    # § Architecture Principles #5). The command runs at the
                    # wrapper's current uid (root, when reached via sudo) so
                    # admin tooling can reach root-only resources. No setpriv.
                    # No \`--\` after the env assignments: uutils/POSIX \`env\`
                    # reject a GNU-style \`--\` following NAME=value operands.
                    #
                    # HOME must be the CURRENT uid's home, NOT the invoker's:
                    # the child stays root here, and \`op run\` refuses to use a
                    # config dir under a HOME owned by a different uid ("we
                    # can't safely access \"\$HOME/.config/op\" because it's not
                    # owned by the current user"). Resolve the current uid's
                    # home via getent, falling back to /root.
                    keep_home="\$(getent passwd "\$(id -u)" | cut -d: -f6)"
                    [ -n "\$keep_home" ] || keep_home="/root"
                    exec env -i \\
                        HOME="\$keep_home" \\
                        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \\
                        OP_SERVICE_ACCOUNT_TOKEN="\$token" \\
                        WRAPPER_STAGE=2 \\
                        "\${preserve[@]}" \\
                        "\$INSTALLED_WRAPPER" "\$@"
                else
                    # Default: drop privileges back to the *invoker* via setpriv.
                    # \`env\` has no trailing \`--\` (uutils/POSIX reject it after
                    # assignments); setpriv keeps ITS OWN \`--\` before the command.
                    exec env -i \\
                        HOME="\$invoker_home" \\
                        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \\
                        OP_SERVICE_ACCOUNT_TOKEN="\$token" \\
                        WRAPPER_STAGE=2 \\
                        "\${preserve[@]}" \\
                        setpriv --reuid="\$SUDO_UID" --regid="\$SUDO_GID" --init-groups -- \\
                        "\$INSTALLED_WRAPPER" "\$@"
                fi
                ;;
            2)
                # Stage 2 — running as the invoker with token in env.
                # Inject variables from the 1Password Environment (NOT from
                # any vault). The wrapper SHALL NOT call op item list,
                # op item get, op read, or any other vault-touching op
                # subcommand — only op run --environment.
                [ -n "\${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || die "stage 2 requires OP_SERVICE_ACCOUNT_TOKEN in env"
                unset OP_CONNECT_HOST OP_CONNECT_TOKEN
                export OP_CACHE=false

                if [ "\$#" -eq 0 ]; then
                    set -- "\$DEFAULT_SHELL" -i
                fi

                # Strip the service-account token AND the internal
                # WRAPPER_STAGE sentinel from the final child env. Unsetting
                # WRAPPER_STAGE lets one wrapper invoke another without the
                # inner wrapper inheriting a stale stage and skipping its own
                # stages. No \`env … --\`: uutils/POSIX reject the GNU \`--\`
                # after -u options (op's own \`--\` before \`env\` is kept).
                exec op run --no-masking --environment "\$ONEPASSWORD_ENVIRONMENT_ID" -- \\
                    env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE "\$@"
                ;;
            *)
                die "unexpected WRAPPER_STAGE: \${WRAPPER_STAGE}"
                ;;
        esac
        ;;
    Darwin)
        # ---------------------------------------------------------------
        # macOS runtime path: single stage, no privilege escalation.
        # The user's login session is the security boundary; the token
        # sits in the per-user login Keychain, so only that session can
        # read it. Read it, hand it to op run, exec the child.
        # ---------------------------------------------------------------
        if ! token="\$(security find-generic-password \\
                -s "\$MACOS_KEYCHAIN_SERVICE" \\
                -a "\$MACOS_KEYCHAIN_TOKEN_ACCOUNT" \\
                -w 2>/dev/null)"; then
            die "OP_SERVICE_ACCOUNT_TOKEN not found in macOS Keychain (service: \$MACOS_KEYCHAIN_SERVICE, account: \$MACOS_KEYCHAIN_TOKEN_ACCOUNT). Run create-1password-env-wrapper.sh to seed it."
        fi
        [ -n "\$token" ] || die "macOS Keychain entry is empty (service: \$MACOS_KEYCHAIN_SERVICE)"
        unset OP_CONNECT_HOST OP_CONNECT_TOKEN
        export OP_CACHE=false

        if [ "\$#" -eq 0 ]; then
            set -- "\$DEFAULT_SHELL" -i
        fi

        # Strip the service-account token AND the internal WRAPPER_STAGE
        # sentinel from the final child env, so a nested wrapper invocation
        # does not inherit a stale stage. No \`env … --\`: uutils/POSIX reject
        # the GNU \`--\` after assignments/-u options (op's own \`--\` is kept).
        exec env OP_SERVICE_ACCOUNT_TOKEN="\$token" \\
            op run --no-masking --environment "\$ONEPASSWORD_ENVIRONMENT_ID" -- \\
            env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE "\$@"
        ;;
    *)
        die "unsupported platform: \$(uname -s) (only Linux and Darwin are supported)"
        ;;
esac
WRAPPER_EOF
    chmod 0755 "$out"
}

render_wrapper "$RENDERED_WRAPPER"

# ---------------------------------------------------------------------------
# Store the service account token in the platform-appropriate secure store.
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "Linux" ]; then
    install -d -o root -g root -m 0700 /etc/credstore.encrypted

    cred_tmp="$(mktemp -- "/etc/credstore.encrypted/.${SYSTEMD_CRED_NAME}.XXXXXX")"
    # Use --quiet because systemd-creds emits a non-fatal warning about
    # the credential.secret file not being on encrypted media.
    if ! printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" \
            | systemd-creds encrypt --name="$SYSTEMD_CRED_NAME" --quiet - "$cred_tmp" 2>/dev/null; then
        rm -f -- "$cred_tmp"
        die "systemd-creds encrypt failed (could not seal the service account token)"
    fi
    chown root:root "$cred_tmp"
    chmod 0600 "$cred_tmp"
    mv -f -- "$cred_tmp" "$SYSTEMD_CRED_PATH"
else
    # macOS: per-user login Keychain. -U updates the existing entry if
    # it exists (idempotent rotation), or creates a new one.
    if ! security add-generic-password \
            -s "$MACOS_KEYCHAIN_SERVICE" \
            -a "$MACOS_KEYCHAIN_TOKEN_ACCOUNT" \
            -w "$OP_SERVICE_ACCOUNT_TOKEN" \
            -A \
            -U >/dev/null 2>&1; then
        die "security add-generic-password failed (could not seal the service account token in the macOS Keychain)"
    fi
fi

# Scrub the bootstrap token from this process's env so it cannot leak
# into anything we exec from here on.
unset OP_SERVICE_ACCOUNT_TOKEN

# ---------------------------------------------------------------------------
# Install the wrapper under INSTALL_PREFIX.
# ---------------------------------------------------------------------------
INSTALLED_TMP="$(mktemp -- "${INSTALL_PREFIX}/.${WRAPPER_BASENAME}.XXXXXX")"
cat -- "$RENDERED_WRAPPER" > "$INSTALLED_TMP"
if [ "$PLATFORM" = "Linux" ]; then
    chown "root:$IDENTIFIER" "$INSTALLED_TMP"
    chmod 0750 "$INSTALLED_TMP"
else
    # macOS: owner is the invoking user; readable + executable by them.
    chmod 0755 "$INSTALLED_TMP"
fi
mv -f -- "$INSTALLED_TMP" "$INSTALLED_WRAPPER"

# ---------------------------------------------------------------------------
# Linux-only: sudoers fragment + group membership.
# macOS skips this entire section — single-user Keychain isolation
# replaces the group-gated sudoers model.
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "Linux" ]; then
    sudoers_tmp="$(mktemp -- "/etc/sudoers.d/.with-${IDENTIFIER}-env.XXXXXX")"
    # SETENV: lets the wrapper propagate WRAPPER_STAGE through the
    # self-escalation step. The tag is scoped to this one command.
    printf '%%%s ALL=(root) NOPASSWD: SETENV: %s\n' "$IDENTIFIER" "$INSTALLED_WRAPPER" > "$sudoers_tmp"
    chown root:root "$sudoers_tmp"
    chmod 0440 "$sudoers_tmp"
    if ! visudo -cf "$sudoers_tmp" >/dev/null; then
        rm -f -- "$sudoers_tmp"
        die "generated sudoers fragment failed visudo validation; refusing to install"
    fi
    mv -f -- "$sudoers_tmp" "$SUDOERS_FRAGMENT"

    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ "$SUDO_USER" != "$IDENTIFIER" ]; then
        if id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$IDENTIFIER"; then
            : # already a member
        else
            usermod -aG "$IDENTIFIER" "$SUDO_USER" \
                || die "failed to add $SUDO_USER to group $IDENTIFIER"
            note "added $SUDO_USER to group $IDENTIFIER (next sudo invocation picks this up)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Read-only validation against 1Password. Recover the just-stored token
# from its platform-appropriate store and probe the configured Environment.
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "Linux" ]; then
    if ! validation_token="$(systemd-creds decrypt --name="$SYSTEMD_CRED_NAME" "$SYSTEMD_CRED_PATH" - 2>/dev/null)"; then
        die "validation: unable to decrypt the credential we just installed"
    fi
    # Override HOME so op uses /root/.config/op (creates it on demand)
    # rather than whatever HOME the invoking sudo session preserved
    # (e.g. /home/ubuntu, which would belong to a non-root user and
    # trip op's "config dir not owned by current user" guard).
    if ! validation_output="$(HOME=/root OP_SERVICE_ACCOUNT_TOKEN="$validation_token" \
            op environment read "$ONEPASSWORD_ENVIRONMENT_ID" 2>&1)"; then
        die "validation: 1Password could not read Environment '$ONEPASSWORD_ENVIRONMENT_ID': $validation_output"
    fi
else
    if ! validation_token="$(security find-generic-password \
            -s "$MACOS_KEYCHAIN_SERVICE" \
            -a "$MACOS_KEYCHAIN_TOKEN_ACCOUNT" \
            -w 2>/dev/null)"; then
        die "validation: unable to read the credential we just stored in the macOS Keychain"
    fi
    if ! validation_output="$(OP_SERVICE_ACCOUNT_TOKEN="$validation_token" \
            op environment read "$ONEPASSWORD_ENVIRONMENT_ID" 2>&1)"; then
        die "validation: 1Password could not read Environment '$ONEPASSWORD_ENVIRONMENT_ID': $validation_output"
    fi
fi
unset validation_token validation_output

# ---------------------------------------------------------------------------
# Ensure .gitignore entries.
# ---------------------------------------------------------------------------
GITIGNORE="${REPO_ROOT}/.gitignore"
ensure_gitignore_entry() {
    local entry="$1"
    if [ ! -f "$GITIGNORE" ]; then
        printf '%s\n' "$entry" > "$GITIGNORE"
        return
    fi
    if ! grep -Fxq -- "$entry" "$GITIGNORE"; then
        if [ -s "$GITIGNORE" ] && [ "$(tail -c1 -- "$GITIGNORE")" != "" ]; then
            printf '\n' >> "$GITIGNORE"
        fi
        printf '%s\n' "$entry" >> "$GITIGNORE"
    fi
}
ensure_gitignore_entry '/with-*-env.sh'
ensure_gitignore_entry '.env.local'

# ---------------------------------------------------------------------------
# Success line.
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "Linux" ]; then
    note "installed $INSTALLED_WRAPPER (root:$IDENTIFIER, mode 0750)"
    note "encrypted credential: $SYSTEMD_CRED_PATH"
    note "sudoers fragment:     $SUDOERS_FRAGMENT"
else
    note "installed $INSTALLED_WRAPPER (mode 0755, owned by $(id -un))"
    note "Keychain entry: service=$MACOS_KEYCHAIN_SERVICE account=$MACOS_KEYCHAIN_TOKEN_ACCOUNT (user login keychain)"
fi
note "1Password Environment ID: $ONEPASSWORD_ENVIRONMENT_ID"
