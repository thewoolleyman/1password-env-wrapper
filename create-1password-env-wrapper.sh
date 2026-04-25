#!/usr/bin/env bash
set -Eeuo pipefail

# 1Password Environment Wrapper Factory installer.
# Renders ./with-<IDENTIFIER>-env.sh, persists the service account
# token under CONFIG_DIR (or as a systemd encrypted credential), and
# installs the wrapper under INSTALL_PREFIX. See SPECIFICATION.md.

PROG="create-1password-env-wrapper.sh"

err()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { err "$@"; exit 1; }
note() { printf '%s\n' "$*"; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Step 1: Linux only.
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || die "this installer only runs on Linux (got $(uname -s))"

# ---------------------------------------------------------------------------
# Step 2: must be root.
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root; rerun under: sudo -E env IDENTIFIER=... OP_SERVICE_ACCOUNT_TOKEN=... ./$PROG"

# ---------------------------------------------------------------------------
# Step 3: op installed.
# ---------------------------------------------------------------------------
command -v op >/dev/null 2>&1 || die "1Password CLI (\`op\`) is not on PATH; install it from https://developer.1password.com/docs/cli/"

# jq is needed by the rendered wrapper to parse op item list output.
command -v jq >/dev/null 2>&1 || die "\`jq\` is not on PATH; install it via your package manager (e.g. apt-get install jq)"

# ---------------------------------------------------------------------------
# Step 5: validate inputs (regex + presence). Step 4 (user/group existence)
# runs after IDENTIFIER is known to be well-formed.
# ---------------------------------------------------------------------------
IDENTIFIER="${IDENTIFIER:-}"
OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN:-}"
ONEPASSWORD_ENVIRONMENT_ID="${ONEPASSWORD_ENVIRONMENT_ID:-}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/onepassword-env-wrapper}"
TOKEN_STORAGE_MODE="${TOKEN_STORAGE_MODE:-root-owned-file}"
DEFAULT_SHELL="${DEFAULT_SHELL:-/bin/bash}"

missing=()
[ -n "$IDENTIFIER" ] || missing+=("IDENTIFIER")
[ -n "$OP_SERVICE_ACCOUNT_TOKEN" ] || missing+=("OP_SERVICE_ACCOUNT_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
    die "missing required input(s): ${missing[*]}"
fi

if ! [[ "$IDENTIFIER" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ ]]; then
    die "IDENTIFIER is malformed: must match ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ (got: $IDENTIFIER)"
fi

case "$TOKEN_STORAGE_MODE" in
    root-owned-file|systemd-credential) : ;;
    *) die "TOKEN_STORAGE_MODE must be 'root-owned-file' or 'systemd-credential' (got: $TOKEN_STORAGE_MODE)" ;;
esac

if [ "$TOKEN_STORAGE_MODE" = "systemd-credential" ]; then
    command -v systemd-creds >/dev/null 2>&1 \
        || die "TOKEN_STORAGE_MODE=systemd-credential but systemd-creds is not available on this host"
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
# Step 6: CONFIG_DIR.
# ---------------------------------------------------------------------------
if [ ! -d "$CONFIG_DIR" ]; then
    install -d -o root -g "$IDENTIFIER" -m 0750 "$CONFIG_DIR"
else
    chown root:"$IDENTIFIER" "$CONFIG_DIR"
    chmod 0750 "$CONFIG_DIR"
fi

# ---------------------------------------------------------------------------
# Step 7: render wrapper to ./with-<IDENTIFIER>-env.sh (mode 0755).
# ---------------------------------------------------------------------------
WRAPPER_BASENAME="with-${IDENTIFIER}-env.sh"
RENDERED_WRAPPER="${REPO_ROOT}/${WRAPPER_BASENAME}"
INSTALLED_WRAPPER="${INSTALL_PREFIX}/${WRAPPER_BASENAME}"
TOKEN_FILE="${CONFIG_DIR}/${IDENTIFIER}.token"
CONFIG_FILE="${CONFIG_DIR}/${IDENTIFIER}.conf"
SYSTEMD_CRED_NAME="1password-env-wrapper-${IDENTIFIER}"
RESOLVED_VAULT="${ONEPASSWORD_ENVIRONMENT_ID:-$IDENTIFIER}"

render_wrapper() {
    local out="$1"
    cat > "$out" <<WRAPPER_EOF
#!/usr/bin/env bash
set -Eeuo pipefail

# Rendered by create-1password-env-wrapper.sh — do not edit by hand.
# Regenerate by rerunning the installer.

readonly IDENTIFIER='${IDENTIFIER}'
readonly CONFIG_DIR='${CONFIG_DIR}'
readonly TOKEN_STORAGE_MODE='${TOKEN_STORAGE_MODE}'
readonly DEFAULT_SHELL='${DEFAULT_SHELL}'
readonly ONEPASSWORD_VAULT='${RESOLVED_VAULT}'
readonly SYSTEMD_CRED_NAME='${SYSTEMD_CRED_NAME}'

PROG="\$(basename -- "\$0")"
err()  { printf '%s: %s\n' "\$PROG" "\$*" >&2; }
die()  { err "\$@"; exit 1; }

# Drop -- separator if present.
if [ "\$#" -gt 0 ] && [ "\$1" = "--" ]; then
    shift
fi

# Read the token.
case "\$TOKEN_STORAGE_MODE" in
    root-owned-file)
        token_path="\${CONFIG_DIR}/\${IDENTIFIER}.token"
        [ -r "\$token_path" ] || die "token file unreadable: \$token_path"
        token="\$(cat -- "\$token_path")"
        ;;
    systemd-credential)
        [ -n "\${CREDENTIALS_DIRECTORY:-}" ] \\
            || die "systemd credentials are not loaded; rerun under a unit/run that sets LoadCredentialEncrypted=\${SYSTEMD_CRED_NAME}"
        token_path="\${CREDENTIALS_DIRECTORY}/\${SYSTEMD_CRED_NAME}"
        [ -r "\$token_path" ] || die "credential unreadable: \$token_path"
        token="\$(cat -- "\$token_path")"
        ;;
    *)
        die "unknown TOKEN_STORAGE_MODE: \$TOKEN_STORAGE_MODE"
        ;;
esac
[ -n "\$token" ] || die "service account token is empty"

# 1Password Connect variables override OP_SERVICE_ACCOUNT_TOKEN; clear
# them and disable caching unless explicitly configured.
unset OP_CONNECT_HOST OP_CONNECT_TOKEN
export OP_CACHE=false

# Enumerate items in the vault and build an env-file of op:// references.
items_json="\$(OP_SERVICE_ACCOUNT_TOKEN="\$token" op item list --vault="\$ONEPASSWORD_VAULT" --format=json 2>&1)" \\
    || die "could not list items in 1Password vault '\$ONEPASSWORD_VAULT': \$items_json"

# Extract titles via jq, validate as POSIX env-var names, write into a
# temp env-file inside a private \$TMPDIR.
work_dir="\$(mktemp -d)"
trap 'rm -rf -- "\$work_dir"' EXIT
env_file="\$work_dir/env-references"
: > "\$env_file"
chmod 0600 "\$env_file"

mapfile -t titles < <(printf '%s' "\$items_json" | jq -r '.[].title')
for title in "\${titles[@]}"; do
    [ -n "\$title" ] || continue
    if ! [[ "\$title" =~ ^[A-Za-z_][A-Za-z0-9_]*\$ ]]; then
        die "1Password item title is not a valid POSIX env-var name: \$title"
    fi
    printf '%s=op://%s/%s/credential\n' "\$title" "\$ONEPASSWORD_VAULT" "\$title" >> "\$env_file"
done

# Decide what to run.
if [ "\$#" -eq 0 ]; then
    set -- "\$DEFAULT_SHELL" -i
fi

# Pass the token only into the op process; strip OP_SERVICE_ACCOUNT_TOKEN
# from the final child via env -u so the child cannot see secret zero.
exec env OP_SERVICE_ACCOUNT_TOKEN="\$token" \\
    op run --no-masking --env-file="\$env_file" -- \\
    env -u OP_SERVICE_ACCOUNT_TOKEN -- "\$@"
WRAPPER_EOF
    chmod 0755 "$out"
}

render_wrapper "$RENDERED_WRAPPER"

# ---------------------------------------------------------------------------
# Step 8: persist the token.
# ---------------------------------------------------------------------------
write_atomic() {
    # write_atomic <dest> <owner:group> <mode>
    # reads stdin into a sibling temp file, chowns/chmods, then renames.
    local dest="$1" owner="$2" mode="$3"
    local dir base tmp
    dir="$(dirname -- "$dest")"
    base="$(basename -- "$dest")"
    tmp="$(mktemp -- "${dir}/.${base}.XXXXXX")"
    cat > "$tmp"
    chown "$owner" "$tmp"
    chmod "$mode" "$tmp"
    mv -f -- "$tmp" "$dest"
}

case "$TOKEN_STORAGE_MODE" in
    root-owned-file)
        printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" | write_atomic "$TOKEN_FILE" "root:$IDENTIFIER" 0640
        ;;
    systemd-credential)
        install -d -o root -g root -m 0700 /etc/credstore.encrypted
        cred_path="/etc/credstore.encrypted/${SYSTEMD_CRED_NAME}"
        tmp_cred="$(mktemp -- "/etc/credstore.encrypted/.${SYSTEMD_CRED_NAME}.XXXXXX")"
        printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" \
            | systemd-creds encrypt --name="$SYSTEMD_CRED_NAME" - "$tmp_cred"
        chmod 0600 "$tmp_cred"
        mv -f -- "$tmp_cred" "$cred_path"
        ;;
esac

# ---------------------------------------------------------------------------
# Step 9: non-secret config file.
# ---------------------------------------------------------------------------
{
    printf 'IDENTIFIER=%s\n' "$IDENTIFIER"
    printf 'ONEPASSWORD_VAULT=%s\n' "$RESOLVED_VAULT"
    printf 'TOKEN_STORAGE_MODE=%s\n' "$TOKEN_STORAGE_MODE"
    printf 'DEFAULT_SHELL=%s\n' "$DEFAULT_SHELL"
} | write_atomic "$CONFIG_FILE" "root:$IDENTIFIER" 0640

# ---------------------------------------------------------------------------
# Step 10: install the wrapper under INSTALL_PREFIX, atomic.
# ---------------------------------------------------------------------------
INSTALLED_TMP="$(mktemp -- "${INSTALL_PREFIX}/.${WRAPPER_BASENAME}.XXXXXX")"
cat -- "$RENDERED_WRAPPER" > "$INSTALLED_TMP"
chown "root:$IDENTIFIER" "$INSTALLED_TMP"
chmod 0750 "$INSTALLED_TMP"
mv -f -- "$INSTALLED_TMP" "$INSTALLED_WRAPPER"

# ---------------------------------------------------------------------------
# Step 11: read-only validation against 1Password.
# ---------------------------------------------------------------------------
if ! validation_output="$(OP_SERVICE_ACCOUNT_TOKEN="$OP_SERVICE_ACCOUNT_TOKEN" \
        op item list --vault="$RESOLVED_VAULT" --format=json 2>&1)"; then
    die "1Password validation failed (could not list items in vault '$RESOLVED_VAULT'): $validation_output"
fi
unset validation_output

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
        # Append, ensuring trailing newline before our entry if file
        # didn't end in one.
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
case "$TOKEN_STORAGE_MODE" in
    root-owned-file)
        token_loc="$TOKEN_FILE"
        ;;
    systemd-credential)
        token_loc="systemd encrypted credential '$SYSTEMD_CRED_NAME' under /etc/credstore.encrypted"
        ;;
esac
note "installed $INSTALLED_WRAPPER (root:$IDENTIFIER, mode 0750)"
note "token storage mode: $TOKEN_STORAGE_MODE"
note "token location: $token_loc"
note "1Password vault: $RESOLVED_VAULT"
