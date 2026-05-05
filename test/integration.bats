#!/usr/bin/env bats

# Integration test for the 1Password Environment Wrapper Factory.
# See SPECIFICATION.md, section "Integration Test: test/integration.bats".
#
# Cross-platform: each test gates Linux-only / macOS-only assertions
# behind a `skip_unless_linux` / `skip_unless_macos` helper. Tests
# that apply to both platforms (rendered-wrapper bytes, .gitignore,
# wrapper output for the test target) run on both.
#
# Token-handling rule: the bootstrap token is loaded into a *local* shell
# variable inside setup_file and is *only* passed to subprocesses via
# `OP_SERVICE_ACCOUNT_TOKEN=$var ...` (bash local-env prefix [+ sudo
# --preserve-env on Linux]), which keeps the token in the env block
# but off the command line, so /var/log/auth.log and the systemd
# journal cannot capture it.

setup_file() {
    load '/usr/lib/bats/bats-support/load' 2>/dev/null \
        || load "$(brew --prefix bats-support 2>/dev/null)/lib/bats-support/load.bash" \
        || load '/opt/homebrew/lib/bats-support/load.bash' \
        || load '/usr/local/lib/bats-support/load.bash'
    load '/usr/lib/bats/bats-assert/load' 2>/dev/null \
        || load "$(brew --prefix bats-assert 2>/dev/null)/lib/bats-assert/load.bash" \
        || load '/opt/homebrew/lib/bats-assert/load.bash' \
        || load '/usr/local/lib/bats-assert/load.bash'

    PLATFORM="$(uname -s)"
    export PLATFORM

    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    INSTALLER="$REPO_ROOT/create-1password-env-wrapper.sh"
    export INSTALLER

    # On macOS, INSTALL_PREFIX defaults to /usr/local/bin but falls
    # back to ~/.local/bin if /usr/local/bin isn't writable. Probe
    # what the installer would actually pick so the test asserts
    # against the correct path.
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

    INSTALLED_WRAPPER="${INSTALL_PREFIX}/with-openbrain-env.sh"
    export INSTALLED_WRAPPER
    RENDERED_WRAPPER="$REPO_ROOT/with-openbrain-env.sh"
    export RENDERED_WRAPPER
    CRED_PATH="/etc/credstore.encrypted/1password-env-wrapper-openbrain"
    export CRED_PATH
    SUDOERS_PATH="/etc/sudoers.d/with-openbrain-env"
    export SUDOERS_PATH
    KEYCHAIN_SERVICE="openbrain"
    export KEYCHAIN_SERVICE
    KEYCHAIN_ACCOUNT="OP_SERVICE_ACCOUNT_TOKEN"
    export KEYCHAIN_ACCOUNT

    local env_file="$REPO_ROOT/.env.local"
    local file_token="" file_env_id=""
    if [ -f "$env_file" ]; then
        set -a
        # shellcheck source=/dev/null
        source "$env_file"
        set +a
        file_token="${OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN:-}"
        file_env_id="${OPENBRAIN_1PASSWORD_ENVIRONMENT_ID:-}"
        unset OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN
        unset OPENBRAIN_1PASSWORD_ENVIRONMENT_ID
    fi

    BOOTSTRAP_TOKEN=""
    BOOTSTRAP_ENV_ID=""
    BOOTSTRAP_TOKEN_SOURCE=""
    BOOTSTRAP_ENV_ID_SOURCE=""

    # Token: prefer .env.local, fall back to platform-appropriate store.
    if [ -n "$file_token" ] && [ "$file_token" != "PLACEHOLDER" ]; then
        BOOTSTRAP_TOKEN="$file_token"
        BOOTSTRAP_TOKEN_SOURCE=".env.local"
    elif [ "$PLATFORM" = "Linux" ]; then
        # /etc/credstore.encrypted/ is 0700 root:root, so existence
        # check must go through sudo.
        if sudo test -e "$CRED_PATH"; then
            if BOOTSTRAP_TOKEN="$(sudo systemd-creds decrypt \
                    --name=1password-env-wrapper-openbrain \
                    "$CRED_PATH" - 2>/dev/null)" \
                    && [ -n "$BOOTSTRAP_TOKEN" ]; then
                BOOTSTRAP_TOKEN_SOURCE="systemd-creds"
            fi
        fi
    else
        # macOS: try the user login Keychain.
        if BOOTSTRAP_TOKEN="$(security find-generic-password \
                -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null)" \
                && [ -n "$BOOTSTRAP_TOKEN" ]; then
            BOOTSTRAP_TOKEN_SOURCE="keychain"
        fi
    fi

    # Env ID: prefer .env.local, fall back to grepping the installed wrapper.
    if [ -n "$file_env_id" ] && [ "$file_env_id" != "PLACEHOLDER" ]; then
        BOOTSTRAP_ENV_ID="$file_env_id"
        BOOTSTRAP_ENV_ID_SOURCE=".env.local"
    elif [ -e "$INSTALLED_WRAPPER" ]; then
        if [ "$PLATFORM" = "Linux" ]; then
            # Installed wrapper may be 0750 root:openbrain — read via sudo.
            BOOTSTRAP_ENV_ID="$(sudo grep -E "^readonly ONEPASSWORD_ENVIRONMENT_ID=" \
                "$INSTALLED_WRAPPER" 2>/dev/null \
                | sed -E "s/.*='([^']+)'.*/\1/")"
        else
            BOOTSTRAP_ENV_ID="$(grep -E "^readonly ONEPASSWORD_ENVIRONMENT_ID=" \
                "$INSTALLED_WRAPPER" 2>/dev/null \
                | sed -E "s/.*='([^']+)'.*/\1/")"
        fi
        if [ -n "$BOOTSTRAP_ENV_ID" ]; then
            BOOTSTRAP_ENV_ID_SOURCE="installed-wrapper"
        fi
    fi

    if [ -z "$BOOTSTRAP_TOKEN" ]; then
        echo "FATAL: cannot resolve OP_SERVICE_ACCOUNT_TOKEN. Either populate OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN in $env_file, or run the installer at least once so the platform-appropriate token store is populated." >&2
        return 1
    fi
    if [ -z "$BOOTSTRAP_ENV_ID" ]; then
        echo "FATAL: cannot resolve ONEPASSWORD_ENVIRONMENT_ID. Either populate OPENBRAIN_1PASSWORD_ENVIRONMENT_ID in $env_file, or run the installer at least once so $INSTALLED_WRAPPER exists." >&2
        return 1
    fi

    # Visibility: log which source we used (without printing the token).
    echo "# platform: $PLATFORM" >&3 2>/dev/null || true
    echo "# bootstrap token from: $BOOTSTRAP_TOKEN_SOURCE" >&3 2>/dev/null || true
    echo "# bootstrap env-id from: $BOOTSTRAP_ENV_ID_SOURCE" >&3 2>/dev/null || true

    export BOOTSTRAP_TOKEN BOOTSTRAP_ENV_ID BOOTSTRAP_TOKEN_SOURCE BOOTSTRAP_ENV_ID_SOURCE
    unset OP_SERVICE_ACCOUNT_TOKEN
    unset ONEPASSWORD_ENVIRONMENT_ID

    STAGED_TARGET="$(mktemp /tmp/print-test-env-vars.XXXXXX.sh)"
    export STAGED_TARGET
    install -m 0755 "$REPO_ROOT/print-test-env-vars.sh" "$STAGED_TARGET"
}

teardown_file() {
    if [ -n "${STAGED_TARGET:-}" ] && [ -f "$STAGED_TARGET" ]; then
        rm -f "$STAGED_TARGET"
    fi
}

setup() {
    load '/usr/lib/bats/bats-support/load' 2>/dev/null \
        || load "$(brew --prefix bats-support 2>/dev/null)/lib/bats-support/load.bash" \
        || load '/opt/homebrew/lib/bats-support/load.bash' \
        || load '/usr/local/lib/bats-support/load.bash'
    load '/usr/lib/bats/bats-assert/load' 2>/dev/null \
        || load "$(brew --prefix bats-assert 2>/dev/null)/lib/bats-assert/load.bash" \
        || load '/opt/homebrew/lib/bats-assert/load.bash' \
        || load '/usr/local/lib/bats-assert/load.bash'
}

skip_unless_linux() { [ "$PLATFORM" = "Linux"  ] || skip "Linux-only test (platform=$PLATFORM)"; }
skip_unless_macos() { [ "$PLATFORM" = "Darwin" ] || skip "macOS-only test (platform=$PLATFORM)"; }

# Run the installer with the bootstrap token + Environment ID passed
# via env (NEVER argv). On Linux, under sudo -E. On macOS, direct.
run_installer() {
    if [ "$PLATFORM" = "Linux" ]; then
        run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
            IDENTIFIER=openbrain \
            ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" \
            sudo -E -- "$INSTALLER"
    else
        run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
            IDENTIFIER=openbrain \
            ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" \
            "$INSTALLER"
    fi
}

# Run the installer WITHOUT the token + Environment ID.
run_installer_without_token() {
    if [ "$PLATFORM" = "Linux" ]; then
        run env -u OP_SERVICE_ACCOUNT_TOKEN -u ONEPASSWORD_ENVIRONMENT_ID \
            IDENTIFIER=openbrain \
            sudo -E -- "$INSTALLER"
    else
        run env -u OP_SERVICE_ACCOUNT_TOKEN -u ONEPASSWORD_ENVIRONMENT_ID \
            IDENTIFIER=openbrain \
            "$INSTALLER"
    fi
}

# Run the installer with a malformed IDENTIFIER.
run_installer_with_bad_identifier() {
    if [ "$PLATFORM" = "Linux" ]; then
        run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
            IDENTIFIER='Open_Brain' \
            ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" \
            sudo -E -- "$INSTALLER"
    else
        run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
            IDENTIFIER='Open_Brain' \
            ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" \
            "$INSTALLER"
    fi
}

# Run the installed wrapper against $1 with the platform-appropriate
# user. On Linux that's `sudo -u openbrain`; on macOS it's the
# current user.
run_wrapper() {
    if [ "$PLATFORM" = "Linux" ]; then
        run sudo -u openbrain "$INSTALLED_WRAPPER" "$@"
    else
        run "$INSTALLED_WRAPPER" "$@"
    fi
}

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
    run_wrapper "$STAGED_TARGET"
    assert_success
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

    # Installed file. On Linux it's 0750 root:openbrain — read via sudo.
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
    assert_output "root:openbrain 750"
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
    assert_output "%openbrain ALL=(root) NOPASSWD: SETENV: $INSTALLED_WRAPPER"
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
        IDENTIFIER=openbrain \
        ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" \
        "$INSTALLER"
    # Either the installer rejects (preferred), or sudo refused
    # to escalate (also acceptable on hosts without NOPASSWD).
    assert_failure
    refute_output --partial "$BOOTSTRAP_TOKEN"
}
