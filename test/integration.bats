#!/usr/bin/env bats

# Integration test for the 1Password Environment Wrapper Factory.
# See SPECIFICATION.md, section "Integration Test: test/integration.bats".
#
# Token-handling rule: the bootstrap token is loaded into a *local* shell
# variable inside setup_file and is *only* passed to subprocesses via
# `OP_SERVICE_ACCOUNT_TOKEN=$var sudo -E -- ...` (bash local-env prefix +
# sudo --preserve-env), which keeps the token in the env block but off
# the command line, so /var/log/auth.log and the systemd journal cannot
# capture it.

setup_file() {
    load '/usr/lib/bats/bats-support/load'
    load '/usr/lib/bats/bats-assert/load'

    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    INSTALLER="$REPO_ROOT/create-1password-env-wrapper.sh"
    export INSTALLER
    INSTALLED_WRAPPER="/usr/local/bin/with-openbrain-env.sh"
    export INSTALLED_WRAPPER
    RENDERED_WRAPPER="$REPO_ROOT/with-openbrain-env.sh"
    export RENDERED_WRAPPER
    CRED_PATH="/etc/credstore.encrypted/1password-env-wrapper-openbrain"
    export CRED_PATH
    SUDOERS_PATH="/etc/sudoers.d/with-openbrain-env"
    export SUDOERS_PATH

    local env_file="$REPO_ROOT/.env.local"
    if [ ! -f "$env_file" ]; then
        echo "FATAL: $env_file is missing. Populate it with OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<real token>." >&2
        return 1
    fi
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    if [ -z "${OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN:-}" ] \
       || [ "$OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN" = "PLACEHOLDER" ]; then
        echo "FATAL: OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN is missing or PLACEHOLDER in $env_file." >&2
        return 1
    fi
    BOOTSTRAP_TOKEN="$OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN"
    export BOOTSTRAP_TOKEN
    unset OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN
    unset OP_SERVICE_ACCOUNT_TOKEN

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
    load '/usr/lib/bats/bats-support/load'
    load '/usr/lib/bats/bats-assert/load'
}

# Run the installer with the bootstrap token passed via env (NEVER argv).
# The bash `VAR=value cmd ...` syntax exports VAR into cmd's environment
# only; combined with `sudo -E`, the token is preserved into the sudo
# child without appearing on the command line.
run_installer() {
    run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" IDENTIFIER=openbrain \
        sudo -E -- "$INSTALLER"
}

# Run the installer WITHOUT the token (used to assert that missing-input
# validation triggers and exits non-zero before any side effects).
run_installer_without_token() {
    run env -u OP_SERVICE_ACCOUNT_TOKEN IDENTIFIER=openbrain \
        sudo -E -- "$INSTALLER"
}

# Run the installer with a malformed IDENTIFIER (and a valid token, so
# the test exercises only the regex-rejection path).
run_installer_with_bad_identifier() {
    run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" IDENTIFIER='Open_Brain' \
        sudo -E -- "$INSTALLER"
}

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

@test "installed wrapper has correct ownership and mode" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    assert [ -e "$INSTALLED_WRAPPER" ]
    run stat -c '%U:%G %a' "$INSTALLED_WRAPPER"
    assert_output "root:openbrain 750"
}

@test "encrypted credential exists with correct ownership and mode" {
    [ -e "$CRED_PATH" ] || run_installer
    run sudo stat -c '%U:%G %a' "$CRED_PATH"
    assert_output "root:root 600"
}

@test "no plaintext token directory exists" {
    # The whole /etc/onepassword-env-wrapper/ tree from the old
    # root-owned-file design must not exist on disk anymore.
    run sudo test -e /etc/onepassword-env-wrapper
    assert_failure
}

@test "sudoers fragment is installed and well-formed" {
    [ -e "$SUDOERS_PATH" ] || run_installer
    run sudo stat -c '%U:%G %a' "$SUDOERS_PATH"
    assert_output "root:root 440"
    run sudo cat "$SUDOERS_PATH"
    assert_output "%openbrain ALL=(root) NOPASSWD: SETENV: $INSTALLED_WRAPPER"
}

@test ".gitignore contains required entries" {
    run grep -Fxq '/with-*-env.sh' "$REPO_ROOT/.gitignore"
    assert_success
    run grep -Fxq '.env.local' "$REPO_ROOT/.gitignore"
    assert_success
}

@test "wrapper injects TEST_CREDENTIAL when running as openbrain" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run sudo -u openbrain "$INSTALLED_WRAPPER" "$STAGED_TARGET"
    assert_success
    assert_line "TEST_CREDENTIAL=TEST_VALUE"
    refute_output --partial "OP_SERVICE_ACCOUNT_TOKEN="
}

@test "wrapper output is sorted by variable name" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run sudo -u openbrain "$INSTALLED_WRAPPER" "$STAGED_TARGET"
    assert_success
    sorted="$(printf '%s\n' "$output" | LC_ALL=C sort)"
    [ "$output" = "$sorted" ]
}

@test "wrapper-spawned env shows TEST_CREDENTIAL but not OP_SERVICE_ACCOUNT_TOKEN" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run sudo -u openbrain "$INSTALLED_WRAPPER" env
    assert_success
    assert_line "TEST_CREDENTIAL=TEST_VALUE"
    refute_line --regexp '^OP_SERVICE_ACCOUNT_TOKEN='
}

@test "OP_SERVICE_ACCOUNT_TOKEN does not leak: printenv exits 1" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run sudo -u openbrain "$INSTALLED_WRAPPER" printenv OP_SERVICE_ACCOUNT_TOKEN
    assert_failure 1
}

@test "installer is idempotent: second run still succeeds" {
    run_installer
    assert_success
    run_installer
    assert_success
}

@test "rendered wrapper at repo root works for the installing operator" {
    # The build artifact at $REPO_ROOT/with-openbrain-env.sh is mode
    # 0755 per installer step 6 and stage-0 self-escalates via
    # `sudo -n` to the *installed* wrapper. The installer also added
    # $SUDO_USER to the openbrain group during step 10 — combined with
    # the sudoers fragment from step 9, the BATS-invoking user
    # therefore SHALL be able to run the rendered wrapper directly.
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    [ -x "$RENDERED_WRAPPER" ] || skip "rendered wrapper missing: $RENDERED_WRAPPER"
    run "$RENDERED_WRAPPER" "$STAGED_TARGET"
    assert_success
    assert_line "TEST_CREDENTIAL=TEST_VALUE"
    refute_output --partial "OP_SERVICE_ACCOUNT_TOKEN="
}
