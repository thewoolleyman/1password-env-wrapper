#!/usr/bin/env bats

# Integration test for the 1Password Environment Wrapper Factory.
# See SPECIFICATION.md, section "Integration Test: test/integration.bats".

setup_file() {
    load '/usr/lib/bats/bats-support/load'
    load '/usr/lib/bats/bats-assert/load'

    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    INSTALLER="$REPO_ROOT/create-1password-env-wrapper.sh"
    export INSTALLER
    INSTALLED_WRAPPER="/usr/local/bin/with-openbrain-env.sh"
    export INSTALLED_WRAPPER

    local env_file="$REPO_ROOT/.env.local"
    if [ ! -f "$env_file" ]; then
        echo "FATAL: $env_file is missing. Populate it with OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN=<real token>." >&2
        return 1
    fi
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    if [ -z "${OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN:-}" ] || \
       [ "$OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN" = "PLACEHOLDER" ]; then
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

run_installer() {
    run sudo --preserve-env=IDENTIFIER,OP_SERVICE_ACCOUNT_TOKEN \
        env IDENTIFIER=openbrain OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
        "$INSTALLER"
}

@test "installer rejects missing OP_SERVICE_ACCOUNT_TOKEN" {
    run sudo --preserve-env=IDENTIFIER env IDENTIFIER=openbrain "$INSTALLER"
    assert_failure
    assert_output --partial "OP_SERVICE_ACCOUNT_TOKEN"
    refute_output --partial "$BOOTSTRAP_TOKEN"
}

@test "installer rejects malformed IDENTIFIER" {
    run sudo --preserve-env=IDENTIFIER,OP_SERVICE_ACCOUNT_TOKEN \
        env IDENTIFIER=Open_Brain OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
        "$INSTALLER"
    assert_failure
    assert_output --partial "IDENTIFIER"
    refute_output --partial "$BOOTSTRAP_TOKEN"
}

@test "installer succeeds with valid inputs" {
    run_installer
    assert_success
    assert_output --partial "/usr/local/bin/with-openbrain-env.sh"
    refute_output --partial "$BOOTSTRAP_TOKEN"
    refute_output --partial "PLACEHOLDER"
}

@test "installed wrapper has correct ownership and mode" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    assert [ -e "$INSTALLED_WRAPPER" ]
    run stat -c '%U:%G %a' "$INSTALLED_WRAPPER"
    assert_output "root:openbrain 750"
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
