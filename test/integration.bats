#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Integration (end-to-end) test for the 1Password Environment Wrapper Factory.
# See SPECIFICATION.md, section "Integration Test: test/integration.bats".
#
# ISOLATION: this suite never touches a real install. It drives the installer
# with its own reserved IDENTIFIER (default `openv-e2e`, override with
# OPENV_E2E_IDENTIFIER, which must end in `-e2e`). Every artifact the installer
# writes is named after IDENTIFIER (wrapper, sudoers fragment, credential,
# Keychain service, cache keys), so the suite owns them all. It creates the
# Linux group if missing, and teardown_file removes everything it created.
# Before it starts it fingerprints every OTHER installed wrapper, sudoers
# fragment and credential, and the last test fails if any of them changed.
# It is therefore safe to run on a host with live wrappers, and SHOULD be run
# before rolling out any template change.
#
# Credentials (never written anywhere by this suite):
#   1. .env.local: OPENV_E2E_1PASSWORD_SERVICE_ACCOUNT_TOKEN and
#      OPENV_E2E_1PASSWORD_ENVIRONMENT_ID (prefix follows the identifier:
#      upper case, hyphens -> underscores), or
#   2. OPENV_E2E_SOURCE_IDENTIFIER=<an existing install's identifier>: the
#      token and Environment ID are READ (never modified) from that install's
#      secure store and installed wrapper.
# The Environment must contain TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE and
# TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2.
#
# Cross-platform: Linux-only / macOS-only assertions are gated by
# skip_unless_linux / skip_unless_macos. The TTL cache is Linux-only.
#
# Token-handling rule: the bootstrap token lives in a shell variable and only
# reaches subprocesses via `OP_SERVICE_ACCOUNT_TOKEN=$var ...` (env, never
# argv), so auth.log and the journal cannot capture it.

load_bats_libs() {
    load '/usr/lib/bats/bats-support/load' 2>/dev/null \
        || load "$(brew --prefix bats-support 2>/dev/null)/lib/bats-support/load.bash" \
        || load '/opt/homebrew/lib/bats-support/load.bash' \
        || load '/usr/local/lib/bats-support/load.bash'
    load '/usr/lib/bats/bats-assert/load' 2>/dev/null \
        || load "$(brew --prefix bats-assert 2>/dev/null)/lib/bats-assert/load.bash" \
        || load '/opt/homebrew/lib/bats-assert/load.bash' \
        || load '/usr/local/lib/bats-assert/load.bash'
}

# Fingerprint of every install artifact NOT owned by this suite.
snapshot_foreign_installs() {
    local f
    {
        for f in "$INSTALL_PREFIX"/with-*-env.sh; do
            [ -e "$f" ] && [ "$f" != "$INSTALLED_WRAPPER" ] && printf '%s\n' "$f"
        done
        if [ "$PLATFORM" = "Linux" ]; then
            sudo -n find /etc/sudoers.d -maxdepth 1 -name 'with-*-env' ! -name "with-${E2E_ID}-env" 2>/dev/null
            sudo -n find /etc/credstore.encrypted -maxdepth 1 -name '1password-env-wrapper-*' ! -name "1password-env-wrapper-${E2E_ID}" 2>/dev/null
        fi
    } | LC_ALL=C sort | while read -r f; do
        if [ "$PLATFORM" = "Linux" ]; then
            sudo -n sha256sum "$f"
        else
            shasum -a 256 "$f"
        fi
    done
}

setup_file() {
    load_bats_libs

    PLATFORM="$(uname -s)"
    export PLATFORM
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    INSTALLER="$REPO_ROOT/create-1password-env-wrapper.sh"
    export INSTALLER
    ME="$(id -un)"
    export ME

    E2E_ID="${OPENV_E2E_IDENTIFIER:-openv-e2e}"
    case "$E2E_ID" in
        *-e2e) ;;
        *) echo "FATAL: OPENV_E2E_IDENTIFIER must end in '-e2e' (got '$E2E_ID'): this suite installs, then DELETES, everything named after it" >&2; return 1 ;;
    esac
    export E2E_ID

    # macOS: the installer falls back to ~/.local/bin when /usr/local/bin is
    # not writable; mirror that so assertions use the real path. Linux always
    # uses a root-owned prefix: the sudoers fragment grants passwordless root
    # to the installed path, so it must never live in a user-writable dir.
    if [ "$PLATFORM" = "Darwin" ]; then
        if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
            INSTALL_PREFIX="/usr/local/bin"
        else
            INSTALL_PREFIX="$HOME/.local/bin"
        fi
    else
        INSTALL_PREFIX="/usr/local/bin"
    fi
    export INSTALL_PREFIX

    INSTALLED_WRAPPER="${INSTALL_PREFIX}/with-${E2E_ID}-env.sh"
    RENDERED_WRAPPER="$REPO_ROOT/with-${E2E_ID}-env.sh"
    CRED_NAME="1password-env-wrapper-${E2E_ID}"
    CRED_PATH="/etc/credstore.encrypted/${CRED_NAME}"
    SUDOERS_PATH="/etc/sudoers.d/with-${E2E_ID}-env"
    KEYCHAIN_SERVICE="$E2E_ID"
    KEYCHAIN_ACCOUNT="OP_SERVICE_ACCOUNT_TOKEN"
    export INSTALLED_WRAPPER RENDERED_WRAPPER CRED_NAME CRED_PATH SUDOERS_PATH KEYCHAIN_SERVICE KEYCHAIN_ACCOUNT

    # --- credentials ---
    local prefix env_file="$REPO_ROOT/.env.local" file_token="" file_env_id=""
    prefix="$(printf '%s' "$E2E_ID" | tr 'a-z-' 'A-Z_')"
    if [ -f "$env_file" ]; then
        file_token="$(sed -n "s/^${prefix}_1PASSWORD_SERVICE_ACCOUNT_TOKEN=//p" "$env_file" | tail -1)"
        file_env_id="$(sed -n "s/^${prefix}_1PASSWORD_ENVIRONMENT_ID=//p" "$env_file" | tail -1)"
    fi
    BOOTSTRAP_TOKEN="" BOOTSTRAP_ENV_ID="" BOOTSTRAP_SOURCE=""
    if [ -n "$file_token" ] && [ "$file_token" != PLACEHOLDER ] \
        && [ -n "$file_env_id" ] && [ "$file_env_id" != PLACEHOLDER ]; then
        BOOTSTRAP_TOKEN="$file_token" BOOTSTRAP_ENV_ID="$file_env_id" BOOTSTRAP_SOURCE=".env.local"
    elif [ -n "${OPENV_E2E_SOURCE_IDENTIFIER:-}" ]; then
        local src="$OPENV_E2E_SOURCE_IDENTIFIER" src_wrapper
        src_wrapper="${INSTALL_PREFIX}/with-${src}-env.sh"
        if [ "$PLATFORM" = "Linux" ]; then
            BOOTSTRAP_TOKEN="$(sudo -n systemd-creds decrypt --name="1password-env-wrapper-${src}" \
                "/etc/credstore.encrypted/1password-env-wrapper-${src}" - 2>/dev/null)" || BOOTSTRAP_TOKEN=""
            BOOTSTRAP_ENV_ID="$(sudo -n sed -n "s/^readonly ONEPASSWORD_ENVIRONMENT_ID='\(.*\)'$/\1/p" "$src_wrapper" 2>/dev/null)" || BOOTSTRAP_ENV_ID=""
        else
            BOOTSTRAP_TOKEN="$(security find-generic-password -s "$src" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null)" || BOOTSTRAP_TOKEN=""
            BOOTSTRAP_ENV_ID="$(sed -n "s/^readonly ONEPASSWORD_ENVIRONMENT_ID='\(.*\)'$/\1/p" "$src_wrapper" 2>/dev/null)" || BOOTSTRAP_ENV_ID=""
        fi
        BOOTSTRAP_SOURCE="existing install '$src' (read-only)"
    fi
    if [ -z "$BOOTSTRAP_TOKEN" ] || [ -z "$BOOTSTRAP_ENV_ID" ]; then
        echo "FATAL: no e2e credentials. Set ${prefix}_1PASSWORD_SERVICE_ACCOUNT_TOKEN and ${prefix}_1PASSWORD_ENVIRONMENT_ID in $env_file, or OPENV_E2E_SOURCE_IDENTIFIER=<existing identifier> to borrow an installed one read-only." >&2
        return 1
    fi
    echo "# platform: $PLATFORM; e2e identifier: $E2E_ID; credentials from: $BOOTSTRAP_SOURCE" >&3 2>/dev/null || true
    export BOOTSTRAP_TOKEN BOOTSTRAP_ENV_ID
    unset OP_SERVICE_ACCOUNT_TOKEN ONEPASSWORD_ENVIRONMENT_ID

    # --- isolation guard: fingerprint everything we must not touch ---
    snapshot_foreign_installs > "$BATS_FILE_TMPDIR/foreign.before"

    # --- the Linux group the installer requires (it never creates one) ---
    if [ "$PLATFORM" = "Linux" ] && ! getent group "$E2E_ID" >/dev/null; then
        sudo -n groupadd "$E2E_ID"
        touch "$BATS_FILE_TMPDIR/created-group"
    fi

    STAGED_TARGET="$(mktemp /tmp/print-test-env-vars.XXXXXX.sh)"
    export STAGED_TARGET
    install -m 0755 "$REPO_ROOT/print-test-env-vars.sh" "$STAGED_TARGET"

    # An `op` shim that fails loudly once $OP_BLOCK_FLAG exists: proves a
    # cache hit performs ZERO op calls. The flag is a file, not an env var,
    # so toggling it does not change the caller fingerprint.
    REAL_OP="$(command -v op)"
    SHIM_DIR="$BATS_FILE_TMPDIR/op-shim"
    OP_BLOCK_FLAG="$BATS_FILE_TMPDIR/op-blocked"
    mkdir -p "$SHIM_DIR"
    printf '#!/usr/bin/env bash\n[ -e %q ] && { echo "op-shim: op was called while blocked" >&2; exit 97; }\nexec %q "$@"\n' \
        "$OP_BLOCK_FLAG" "$REAL_OP" > "$SHIM_DIR/op"
    chmod 0755 "$SHIM_DIR/op"
    chmod 0755 "$BATS_FILE_TMPDIR"
    export SHIM_DIR OP_BLOCK_FLAG
}

teardown_file() {
    rm -f "${STAGED_TARGET:-/nonexistent}" "${RENDERED_WRAPPER:-/nonexistent}"
    [ -n "${E2E_ID:-}" ] || return 0
    if [ "$PLATFORM" = "Linux" ]; then
        sudo -n rm -f "$INSTALLED_WRAPPER" "$SUDOERS_PATH" "$CRED_PATH"
        if command -v keyctl >/dev/null 2>&1; then
            keyctl session - bash -c 'keyctl get_persistent @s >/dev/null && keyctl purge -p user "op-env-wrapper-cache:$1:"' _ "$E2E_ID" >/dev/null 2>&1 || true
        fi
        if [ -e "$BATS_FILE_TMPDIR/created-group" ]; then
            sudo -n groupdel "$E2E_ID" || true
        fi
    else
        rm -f "$INSTALLED_WRAPPER"
        security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
    fi
    # Belt and braces: the last test asserts this too, but a run that aborts
    # early must still shout if a foreign install changed.
    if [ -f "$BATS_FILE_TMPDIR/foreign.before" ] \
        && ! snapshot_foreign_installs | cmp -s - "$BATS_FILE_TMPDIR/foreign.before"; then
        echo "FATAL: an install NOT owned by this suite changed during the run" >&2
        return 1
    fi
}

setup() {
    load_bats_libs
}

skip_unless_linux() { [ "$PLATFORM" = "Linux"  ] || skip "Linux-only test (platform=$PLATFORM)"; }
skip_unless_macos() { [ "$PLATFORM" = "Darwin" ] || skip "macOS-only test (platform=$PLATFORM)"; }
skip_unless_keyctl() { command -v keyctl >/dev/null 2>&1 || skip "keyctl (keyutils) not installed"; }

# Installer with token + Environment ID via env (NEVER argv). Extra
# arguments are leading env assignments (e.g. IDENTIFIER=Bad_Id overrides).
installer_cmd() {
    if [ "$PLATFORM" = "Linux" ]; then
        run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" IDENTIFIER="$E2E_ID" \
            ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" "$@" sudo -E -- "$INSTALLER"
    else
        run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" IDENTIFIER="$E2E_ID" \
            ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" "$@" "$INSTALLER"
    fi
}
run_installer() { installer_cmd; }
run_installer_with_bad_identifier() { installer_cmd IDENTIFIER='Open_Brain'; }
run_installer_without_token() {
    if [ "$PLATFORM" = "Linux" ]; then
        run env -u OP_SERVICE_ACCOUNT_TOKEN -u ONEPASSWORD_ENVIRONMENT_ID IDENTIFIER="$E2E_ID" sudo -E -- "$INSTALLER"
    else
        run env -u OP_SERVICE_ACCOUNT_TOKEN -u ONEPASSWORD_ENVIRONMENT_ID IDENTIFIER="$E2E_ID" "$INSTALLER"
    fi
}
ensure_installed() { [ -e "$INSTALLED_WRAPPER" ] || run_installer; }

# The command prefix that runs something as the invoking operator with a
# FRESH group list (Linux): the installer just added us to the e2e group,
# which this already-running shell does not reflect, and the installed
# wrapper is 0750 root:<group>. sudo -u re-reads /etc/group; `env` then
# applies any leading VAR=value caller variables.
as_member() {
    if [ "$PLATFORM" = "Linux" ]; then
        sudo -n -u "$ME" -- env "$@"
    else
        env "$@"
    fi
}
run_wrapper() {
    local pre=()
    while [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do pre+=("$1"); shift; done
    run as_member "${pre[@]}" "$INSTALLED_WRAPPER" "$@"
}
# stdout and stderr kept apart ($output is stdout only, $stderr is stderr): the cache's diagnostics
# go to stderr and must never reach the wrapped command's stdout.
run_wrapper_separated() { run --separate-stderr as_member "$INSTALLED_WRAPPER" "$@"; }

# ---------------------------------------------------------------------------
# Cross-platform tests (run on both Linux and macOS).
# ---------------------------------------------------------------------------

@test "installer rejects missing OP_SERVICE_ACCOUNT_TOKEN" {
    run_installer_without_token
    assert_failure
    assert_output --partial "OP_SERVICE_ACCOUNT_TOKEN"
    refute_output --partial "$BOOTSTRAP_TOKEN"
}

@test "installer rejects malformed IDENTIFIER" {
    run_installer_with_bad_identifier
    assert_failure
    assert_output --partial "IDENTIFIER"
    refute_output --partial "$BOOTSTRAP_TOKEN"
}

@test "installer succeeds with valid inputs" {
    run_installer
    assert_success
    assert_output --partial "$INSTALLED_WRAPPER"
    refute_output --partial "$BOOTSTRAP_TOKEN"
    refute_output --partial "PLACEHOLDER"
}

@test ".gitignore contains required entries" {
    run grep -Fxq '/with-*-env.sh' "$REPO_ROOT/.gitignore"
    assert_success
    run grep -Fxq '.env.local' "$REPO_ROOT/.gitignore"
    assert_success
}

@test "wrapper injects Environment values into the test target" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run_wrapper "$STAGED_TARGET"
    assert_success
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2"
    # Regression guard: the wrapper SHALL NOT enumerate vault items.
    refute_line --regexp '^TEST_CREDENTIAL_FROM_VAULT='
    refute_output --partial "OP_SERVICE_ACCOUNT_TOKEN="
}

@test "wrapper output is sorted by variable name" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    # print-test-env-vars.sh sorts its own printed TEST_* lines
    # (SPECIFICATION.md "sort the output by variable name, ascending"),
    # independent of process-environ ordering — so this is a check on
    # STDOUT specifically, not on whatever else `run` may have captured.
    run_wrapper_separated "$STAGED_TARGET"
    assert_success
    # --separate-stderr: $output holds stdout only (bats has no $stdout).
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    sorted="$(printf '%s\n' "$output" | LC_ALL=C sort)"
    [ "$output" = "$sorted" ]
}

@test "wrapper-spawned env shows Environment vars but not OP_SERVICE_ACCOUNT_TOKEN" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run_wrapper env
    assert_success
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    refute_line --regexp '^TEST_CREDENTIAL_FROM_VAULT='
    refute_line --regexp '^OP_SERVICE_ACCOUNT_TOKEN='
}

@test "OP_SERVICE_ACCOUNT_TOKEN does not leak: printenv exits 1" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run_wrapper printenv OP_SERVICE_ACCOUNT_TOKEN
    assert_failure 1
}

@test "installer is idempotent: second run still succeeds" {
    run_installer
    assert_success
    run_installer
    assert_success
}

@test "rendered + installed wrapper carry the canonical-source header" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    [ -e "$RENDERED_WRAPPER" ] || skip "rendered wrapper missing: $RENDERED_WRAPPER"

    # Anchor strings the spec mandates the header contain.
    local repo_url='https://github.com/thewoolleyman/1password-env-wrapper'
    local do_not_edit='DO NOT EDIT THIS FILE'
    local pr_phrase='Pull Request'
    local cross_platform='Cross-platform'

    # Rendered file (mode 0755, world-readable) — read directly.
    run grep -F -- "$repo_url"        "$RENDERED_WRAPPER" ; assert_success
    run grep -F -- "$do_not_edit"     "$RENDERED_WRAPPER" ; assert_success
    run grep -F -- "$pr_phrase"       "$RENDERED_WRAPPER" ; assert_success
    run grep -F -- "$cross_platform"  "$RENDERED_WRAPPER" ; assert_success

    # Installed file. On Linux it's 0750 root:<identifier> — read via sudo.
    if [ "$PLATFORM" = "Linux" ]; then
        run sudo grep -F -- "$repo_url"        "$INSTALLED_WRAPPER" ; assert_success
        run sudo grep -F -- "$do_not_edit"     "$INSTALLED_WRAPPER" ; assert_success
        run sudo grep -F -- "$pr_phrase"       "$INSTALLED_WRAPPER" ; assert_success
        run sudo grep -F -- "$cross_platform"  "$INSTALLED_WRAPPER" ; assert_success
        run sudo cmp "$RENDERED_WRAPPER" "$INSTALLED_WRAPPER"
        assert_success
    else
        run grep -F -- "$repo_url"        "$INSTALLED_WRAPPER" ; assert_success
        run grep -F -- "$do_not_edit"     "$INSTALLED_WRAPPER" ; assert_success
        run grep -F -- "$pr_phrase"       "$INSTALLED_WRAPPER" ; assert_success
        run grep -F -- "$cross_platform"  "$INSTALLED_WRAPPER" ; assert_success
        run cmp "$RENDERED_WRAPPER" "$INSTALLED_WRAPPER"
        assert_success
    fi
}

@test "rendered wrapper carries BOTH platform branches (cross-platform invariant)" {
    [ -e "$RENDERED_WRAPPER" ] || skip "rendered wrapper missing: $RENDERED_WRAPPER"

    # Both platform branches MUST be present in the rendered bytes
    # regardless of which host did the rendering. This is the
    # precondition for byte-identicality across hosts.
    run grep -F 'case "$(uname -s)"' "$RENDERED_WRAPPER" ; assert_success
    run grep -F '    Linux)'         "$RENDERED_WRAPPER" ; assert_success
    run grep -F '    Darwin)'        "$RENDERED_WRAPPER" ; assert_success
    run grep -F 'systemd-creds decrypt' "$RENDERED_WRAPPER" ; assert_success
    run grep -F 'security find-generic-password' "$RENDERED_WRAPPER" ; assert_success
}

@test "rendered wrapper at repo root works for the installing operator" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    [ -x "$RENDERED_WRAPPER" ] || skip "rendered wrapper missing: $RENDERED_WRAPPER"
    run "$RENDERED_WRAPPER" "$STAGED_TARGET"
    assert_success
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    refute_line --regexp '^TEST_CREDENTIAL_FROM_VAULT='
    refute_output --partial "OP_SERVICE_ACCOUNT_TOKEN="
}

# ---------------------------------------------------------------------------
# Linux-only tests.
# ---------------------------------------------------------------------------

@test "installed wrapper has correct ownership and mode (Linux)" {
    skip_unless_linux
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    assert [ -e "$INSTALLED_WRAPPER" ]
    run stat -c '%U:%G %a' "$INSTALLED_WRAPPER"
    assert_output "root:${E2E_ID} 750"
}

@test "encrypted credential exists with correct ownership and mode (Linux)" {
    skip_unless_linux
    [ -e "$CRED_PATH" ] || run_installer
    run sudo stat -c '%U:%G %a' "$CRED_PATH"
    assert_output "root:root 600"
}

@test "no plaintext token directory exists (Linux)" {
    skip_unless_linux
    # The whole /etc/onepassword-env-wrapper/ tree from the old
    # root-owned-file design must not exist on disk anymore.
    run sudo test -e /etc/onepassword-env-wrapper
    assert_failure
}

@test "sudoers fragment is installed and well-formed (Linux)" {
    skip_unless_linux
    [ -e "$SUDOERS_PATH" ] || run_installer
    run sudo stat -c '%U:%G %a' "$SUDOERS_PATH"
    assert_output "root:root 440"
    run sudo cat "$SUDOERS_PATH"
    assert_output "%${E2E_ID} ALL=(root) NOPASSWD: SETENV: $INSTALLED_WRAPPER"
}

# ---------------------------------------------------------------------------
# macOS-only tests.
# ---------------------------------------------------------------------------

@test "installed wrapper has correct ownership and mode (macOS)" {
    skip_unless_macos
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    assert [ -e "$INSTALLED_WRAPPER" ]
    # On macOS, owner = invoking user, mode 0755.
    run stat -f '%Su %Lp' "$INSTALLED_WRAPPER"
    [ "$status" -eq 0 ]
    [[ "$output" == "$(id -un) 755" ]]
}

@test "Keychain entry exists post-install (macOS)" {
    skip_unless_macos
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run security find-generic-password -s "$KEYCHAIN_SERVICE" \
        -a "$KEYCHAIN_ACCOUNT" -w
    assert_success
    [ -n "$output" ]
}

@test "no systemd-creds path is created (macOS)" {
    skip_unless_macos
    # On macOS, /etc/credstore.encrypted/ should not be touched.
    run test -e "$CRED_PATH"
    assert_failure
}

@test "no sudoers fragment is created (macOS)" {
    skip_unless_macos
    run test -e "$SUDOERS_PATH"
    assert_failure
}

@test "installer refuses to run under sudo (macOS)" {
    skip_unless_macos
    # Just-in-case test: even if the operator types `sudo` out of
    # habit, the installer must die before touching anything.
    run sudo -n env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
        IDENTIFIER="$E2E_ID" \
        ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" \
        "$INSTALLER"
    # Either the installer rejects (preferred), or sudo refused
    # to escalate (also acceptable on hosts without NOPASSWD).
    assert_failure
    refute_output --partial "$BOOTSTRAP_TOKEN"
}

# ---------------------------------------------------------------------------
# Runtime behavior end to end (real installer, real sudo, real 1Password).
# ---------------------------------------------------------------------------

@test "caller variables reach the command; 1Password wins a name collision" {
    ensure_installed
    run_wrapper E2E_CALLER_VAR=from-caller TEST_CREDENTIAL_FROM_ENVIRONMENT=caller-value \
        bash -c 'printf "%s %s\n" "$E2E_CALLER_VAR" "$TEST_CREDENTIAL_FROM_ENVIRONMENT"'
    assert_success
    assert_line "from-caller TEST_VALUE"
}

@test "caller entries a shell cannot export still reach the command" {
    ensure_installed
    # An exported bash function, a dotted name and a readonly-name collision
    # each used to kill the wrapper during the caller-environment restore.
    run_wrapper 'BASH_FUNC_e2efn%%=() {  printf fn-ok
}' 'npm.e2e=dotted' IDENTIFIER=caller-id \
        bash -c 'printf "%s|%s|%s\n" "$(e2efn)" "$(printenv npm.e2e)" "$IDENTIFIER"'
    assert_success
    assert_line "fn-ok|dotted|caller-id"
}

@test "the command's exit status is propagated" {
    ensure_installed
    run_wrapper bash -c 'exit 7'
    assert_failure 7
}

@test "wrapped stdout is byte-identical with and without stderr merged" {
    ensure_installed
    local probe="E2E_STDOUT_PROBE=$$-$RANDOM" _pass
    for _pass in miss hit; do
        run --separate-stderr as_member "$probe" "$INSTALLED_WRAPPER" printf PAYLOAD
        assert_success
        [ "$output" = PAYLOAD ]   # --separate-stderr: $output is stdout only
        run as_member "$probe" "$INSTALLED_WRAPPER" printf PAYLOAD
        assert_success
        assert_output PAYLOAD
    done
}

# ---------------------------------------------------------------------------
# TTL cache (Linux-only; the macOS branch has no cache).
# ---------------------------------------------------------------------------

@test "cache: a warm hit makes zero op calls and replays the Environment (Linux)" {
    skip_unless_linux
    skip_unless_keyctl
    ensure_installed
    rm -f "$OP_BLOCK_FLAG"
    local caller=(PATH="$SHIM_DIR:$PATH" E2E_CACHE_PROBE="$$-$RANDOM")
    run_wrapper "${caller[@]}" "$STAGED_TARGET"
    assert_success
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    touch "$OP_BLOCK_FLAG"
    run_wrapper "${caller[@]}" "$STAGED_TARGET"
    rm -f "$OP_BLOCK_FLAG"
    assert_success
    refute_output --partial "op was called while blocked"
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2"
}

@test "cache: a different caller environment is a miss, never another caller's entry (Linux)" {
    skip_unless_linux
    skip_unless_keyctl
    ensure_installed
    local caller=(PATH="$SHIM_DIR:$PATH")
    run_wrapper "${caller[@]}" E2E_CACHE_PROBE="$$-a-$RANDOM" true
    assert_success
    touch "$OP_BLOCK_FLAG"
    run_wrapper "${caller[@]}" E2E_CACHE_PROBE="$$-b-$RANDOM" true
    rm -f "$OP_BLOCK_FLAG"
    assert_failure 97
    assert_output --partial "op was called while blocked"
}

@test "cache: OP_ENV_WRAPPER_CACHE_TTL=0 always calls op (Linux)" {
    skip_unless_linux
    ensure_installed
    local caller=(PATH="$SHIM_DIR:$PATH" E2E_CACHE_PROBE="$$-ttl0-$RANDOM")
    run_wrapper "${caller[@]}" true
    assert_success
    touch "$OP_BLOCK_FLAG"
    run_wrapper "${caller[@]}" OP_ENV_WRAPPER_CACHE_TTL=0 true
    rm -f "$OP_BLOCK_FLAG"
    assert_failure 97
}

@test "cache: a miss unlinks expired cache entries from the persistent keyring (Linux)" {
    skip_unless_linux
    skip_unless_keyctl
    ensure_installed
    local id
    id="$(keyctl session - bash -c '
        pk="$(keyctl get_persistent @s)" || exit 1
        id="$(printf x | keyctl padd user "op-env-wrapper-cache:$1:reap-probe:caller-v1:0" "$pk")" || exit 1
        keyctl timeout "$id" 1 && echo "$id"' _ "$E2E_ID" 2>/dev/null | tail -1)"
    [ -n "$id" ] || skip "could not seed a keyring entry (quota?)"
    sleep 2
    grep -q "^$(printf %08x "$id") .* expd " /proc/keys
    run_wrapper E2E_CACHE_PROBE="$$-reap-$RANDOM" true
    assert_success
    run keyctl session - bash -c 'keyctl rlist "$(keyctl get_persistent @s)"'
    [[ " $output " != *" $id "* ]]
}

# ---------------------------------------------------------------------------
# Isolation guard. Keep this LAST.
# ---------------------------------------------------------------------------

@test "no install outside this suite's own identifier was touched" {
    snapshot_foreign_installs > "$BATS_FILE_TMPDIR/foreign.after"
    run diff "$BATS_FILE_TMPDIR/foreign.before" "$BATS_FILE_TMPDIR/foreign.after"
    assert_success
}
