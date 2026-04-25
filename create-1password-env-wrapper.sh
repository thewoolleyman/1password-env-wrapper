#!/usr/bin/env bash
set -Eeuo pipefail

# 1Password Environment Wrapper Factory installer.
# Renders ./with-<IDENTIFIER>-env.sh, encrypts the service account
# token as a systemd credential under /etc/credstore.encrypted/, and
# installs the wrapper with passwordless-sudo for the IDENTIFIER
# group. See SPECIFICATION.md.

PROG="create-1password-env-wrapper.sh"

err()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { err "$@"; exit 1; }
note() { printf '%s\n' "$*"; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Step 1: Linux + systemd only.
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || die "this installer only runs on Linux (got $(uname -s))"
command -v systemctl     >/dev/null 2>&1 || die "systemd is required (systemctl not on PATH)"
command -v systemd-creds >/dev/null 2>&1 || die "systemd-creds is required (install systemd-container or upgrade systemd)"
command -v setpriv       >/dev/null 2>&1 || die "setpriv is required (install util-linux)"

# ---------------------------------------------------------------------------
# Step 2: must be root.
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root; rerun under: sudo -E ./$PROG"

# ---------------------------------------------------------------------------
# Step 3: required tooling. The wrapper reads variables from a 1Password
# Environment, which requires an Environments-aware op build (introduced
# in the 2.33.0-beta.02 line). Probe with `op environment --help` rather
# than parsing version strings: if the subcommand is present, we are good.
# ---------------------------------------------------------------------------
command -v op >/dev/null 2>&1 || die "1Password CLI ('op') is not on PATH; install from https://developer.1password.com/docs/cli/"
if ! op environment --help >/dev/null 2>&1; then
    die "the installed 'op' build does not support 1Password Environments (need 2.33.0-beta.02 or later from https://releases.1password.com/developers/cli-beta/ ; currently $(op --version 2>&1))"
fi

# ---------------------------------------------------------------------------
# Step 5: validate inputs.
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

[ -d "$INSTALL_PREFIX" ] || die "INSTALL_PREFIX does not exist: $INSTALL_PREFIX"

# ---------------------------------------------------------------------------
# Step 4: Linux user and group exist.
# ---------------------------------------------------------------------------
getent passwd "$IDENTIFIER" >/dev/null \
    || die "Linux user '$IDENTIFIER' does not exist (the installer SHALL NOT create it)"
getent group "$IDENTIFIER" >/dev/null \
    || die "Linux group '$IDENTIFIER' does not exist (the installer SHALL NOT create it)"

# ---------------------------------------------------------------------------
# Step 6: render wrapper to ./with-<IDENTIFIER>-env.sh (mode 0755).
# ---------------------------------------------------------------------------
WRAPPER_BASENAME="with-${IDENTIFIER}-env.sh"
RENDERED_WRAPPER="${REPO_ROOT}/${WRAPPER_BASENAME}"
INSTALLED_WRAPPER="${INSTALL_PREFIX}/${WRAPPER_BASENAME}"
SYSTEMD_CRED_NAME="1password-env-wrapper-${IDENTIFIER}"
SYSTEMD_CRED_PATH="/etc/credstore.encrypted/${SYSTEMD_CRED_NAME}"
SUDOERS_FRAGMENT="/etc/sudoers.d/with-${IDENTIFIER}-env"

render_wrapper() {
    local out="$1"
    cat > "$out" <<WRAPPER_EOF
#!/usr/bin/env bash
set -Eeuo pipefail

# Rendered by create-1password-env-wrapper.sh — do not edit by hand.
# Regenerate by rerunning the installer.

readonly IDENTIFIER='${IDENTIFIER}'
readonly DEFAULT_SHELL='${DEFAULT_SHELL}'
readonly ONEPASSWORD_ENVIRONMENT_ID='${ONEPASSWORD_ENVIRONMENT_ID}'
readonly SYSTEMD_CRED_NAME='${SYSTEMD_CRED_NAME}'
readonly SYSTEMD_CRED_PATH='${SYSTEMD_CRED_PATH}'
readonly INSTALLED_WRAPPER='${INSTALLED_WRAPPER}'

PROG="\$(basename -- "\$0")"
err()  { printf '%s: %s\n' "\$PROG" "\$*" >&2; }
die()  { err "\$@"; exit 1; }

# Drop -- separator if present.
if [ "\$#" -gt 0 ] && [ "\$1" = "--" ]; then
    shift
fi

case "\${WRAPPER_STAGE:-0}" in
    0)
        # Stage 0 — escalate. Always re-exec the *installed* wrapper (not
        # \$0, which may be the gitignored rendered build artifact at the
        # repo root) so the sudoers rule only ever needs to whitelist one
        # path.
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
            exec env WRAPPER_STAGE=1 -- "\$INSTALLED_WRAPPER" "\$@"
        fi
        if ! sudo_path="\$(command -v sudo)"; then
            die "sudo not found on PATH; required to escalate for credential decryption"
        fi
        exec "\$sudo_path" -n WRAPPER_STAGE=1 -- "\$INSTALLED_WRAPPER" "\$@"
        ;;
    1)
        # Stage 1 — running as root. Decrypt the credential into memory,
        # then drop privileges to the IDENTIFIER user with the token in
        # the env, and re-exec the wrapper as stage 2.
        [ "\$(id -u)" -eq 0 ] || die "stage 1 expected uid 0 (got \$(id -u))"
        [ -r "\$SYSTEMD_CRED_PATH" ] \\
            || die "encrypted credential missing or unreadable: \$SYSTEMD_CRED_PATH"
        if ! token="\$(systemd-creds decrypt --name="\$SYSTEMD_CRED_NAME" "\$SYSTEMD_CRED_PATH" - 2>/dev/null)"; then
            die "systemd-creds decrypt failed for \$SYSTEMD_CRED_PATH"
        fi
        [ -n "\$token" ] || die "decrypted credential is empty"
        exec env -i \\
            HOME="/home/\$IDENTIFIER" \\
            PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \\
            OP_SERVICE_ACCOUNT_TOKEN="\$token" \\
            WRAPPER_STAGE=2 \\
            setpriv --reuid="\$IDENTIFIER" --regid="\$IDENTIFIER" --init-groups -- \\
            "\$INSTALLED_WRAPPER" "\$@"
        ;;
    2)
        # Stage 2 — running as IDENTIFIER user with token in env.
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

        exec op run --no-masking --environment "\$ONEPASSWORD_ENVIRONMENT_ID" -- \\
            env -u OP_SERVICE_ACCOUNT_TOKEN -- "\$@"
        ;;
    *)
        die "unexpected WRAPPER_STAGE: \${WRAPPER_STAGE}"
        ;;
esac
WRAPPER_EOF
    chmod 0755 "$out"
}

render_wrapper "$RENDERED_WRAPPER"

# ---------------------------------------------------------------------------
# Step 7: encrypt the token as a systemd credential.
# ---------------------------------------------------------------------------
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

# Scrub the bootstrap token from this process's env so it cannot leak
# into anything we exec from here on.
unset OP_SERVICE_ACCOUNT_TOKEN

# ---------------------------------------------------------------------------
# Step 8: install the wrapper under INSTALL_PREFIX.
# ---------------------------------------------------------------------------
INSTALLED_TMP="$(mktemp -- "${INSTALL_PREFIX}/.${WRAPPER_BASENAME}.XXXXXX")"
cat -- "$RENDERED_WRAPPER" > "$INSTALLED_TMP"
chown "root:$IDENTIFIER" "$INSTALLED_TMP"
chmod 0750 "$INSTALLED_TMP"
mv -f -- "$INSTALLED_TMP" "$INSTALLED_WRAPPER"

# ---------------------------------------------------------------------------
# Step 9: sudoers fragment for the IDENTIFIER group.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Step 10: add the invoking operator to the IDENTIFIER group.
# ---------------------------------------------------------------------------
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ "$SUDO_USER" != "$IDENTIFIER" ]; then
    if id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$IDENTIFIER"; then
        : # already a member
    else
        usermod -aG "$IDENTIFIER" "$SUDO_USER" \
            || die "failed to add $SUDO_USER to group $IDENTIFIER"
        note "added $SUDO_USER to group $IDENTIFIER (next sudo invocation picks this up)"
    fi
fi

# ---------------------------------------------------------------------------
# Step 11: read-only validation against 1Password.
# Decrypt the just-stored credential and probe the vault.
# ---------------------------------------------------------------------------
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
unset validation_token validation_output

# ---------------------------------------------------------------------------
# Step 12: ensure .gitignore entries.
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
# Step 13: success line.
# ---------------------------------------------------------------------------
note "installed $INSTALLED_WRAPPER (root:$IDENTIFIER, mode 0750)"
note "encrypted credential: $SYSTEMD_CRED_PATH"
note "sudoers fragment:     $SUDOERS_FRAGMENT"
note "1Password Environment ID: $ONEPASSWORD_ENVIRONMENT_ID"
