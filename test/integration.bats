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

    # Token: prefer .env.local, fall back to systemd-creds decrypt.
    # /etc/credstore.encrypted/ is 0700 root:root, so existence check
    # must go through sudo too.
    if [ -n "$file_token" ] && [ "$file_token" != "PLACEHOLDER" ]; then
        BOOTSTRAP_TOKEN="$file_token"
        BOOTSTRAP_TOKEN_SOURCE=".env.local"
    elif sudo test -e /etc/credstore.encrypted/1password-env-wrapper-openbrain; then
        if BOOTSTRAP_TOKEN="$(sudo systemd-creds decrypt \
                --name=1password-env-wrapper-openbrain \
                /etc/credstore.encrypted/1password-env-wrapper-openbrain - 2>/dev/null)" \
                && [ -n "$BOOTSTRAP_TOKEN" ]; then
            BOOTSTRAP_TOKEN_SOURCE="systemd-creds"
        fi
    fi

    # Env ID: prefer .env.local, fall back to grepping the installed wrapper.
    if [ -n "$file_env_id" ] && [ "$file_env_id" != "PLACEHOLDER" ]; then
        BOOTSTRAP_ENV_ID="$file_env_id"
        BOOTSTRAP_ENV_ID_SOURCE=".env.local"
    elif [ -e /usr/local/bin/with-openbrain-env.sh ]; then
        BOOTSTRAP_ENV_ID="$(sudo grep -E "^readonly ONEPASSWORD_ENVIRONMENT_ID=" \
            /usr/local/bin/with-openbrain-env.sh 2>/dev/null \
            | sed -E "s/.*='([^']+)'.*/\1/")"
        if [ -n "$BOOTSTRAP_ENV_ID" ]; then
            BOOTSTRAP_ENV_ID_SOURCE="installed-wrapper"
        fi
    fi

    if [ -z "$BOOTSTRAP_TOKEN" ]; then
        echo "FATAL: cannot resolve OP_SERVICE_ACCOUNT_TOKEN. Either populate OPENBRAIN_1PASSWORD_SERVICE_ACCOUNT_TOKEN in $env_file, or run the installer at least once so /etc/credstore.encrypted/1password-env-wrapper-openbrain exists." >&2
        return 1
    fi
    if [ -z "$BOOTSTRAP_ENV_ID" ]; then
        echo "FATAL: cannot resolve ONEPASSWORD_ENVIRONMENT_ID. Either populate OPENBRAIN_1PASSWORD_ENVIRONMENT_ID in $env_file, or run the installer at least once so /usr/local/bin/with-openbrain-env.sh exists." >&2
        return 1
    fi

    # Visibility: log which source we used (without printing the token).
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
    load '/usr/lib/bats/bats-support/load'
    load '/usr/lib/bats/bats-assert/load'
}

# Run the installer with the bootstrap token + Environment ID passed
# via env (NEVER argv). The bash `VAR=value cmd ...` syntax exports
# VAR into cmd's environment only; combined with `sudo -E`, the token
# is preserved into the sudo child without appearing on the command
# line.
run_installer() {
    run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
        IDENTIFIER=openbrain \
        ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" \
        sudo -E -- "$INSTALLER"
}

# Run the installer WITHOUT the token + Environment ID.
run_installer_without_token() {
    run env -u OP_SERVICE_ACCOUNT_TOKEN -u ONEPASSWORD_ENVIRONMENT_ID \
        IDENTIFIER=openbrain \
        sudo -E -- "$INSTALLER"
}

# Run the installer with a malformed IDENTIFIER.
run_installer_with_bad_identifier() {
    run env OP_SERVICE_ACCOUNT_TOKEN="$BOOTSTRAP_TOKEN" \
        IDENTIFIER='Open_Brain' \
        ONEPASSWORD_ENVIRONMENT_ID="$BOOTSTRAP_ENV_ID" \
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

@test "wrapper injects Environment values when running as openbrain" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run sudo -u openbrain "$INSTALLED_WRAPPER" "$STAGED_TARGET"
    assert_success
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT_2=TEST_VALUE_2"
    # Regression guard: the wrapper SHALL NOT enumerate vault items.
    refute_line --regexp '^TEST_CREDENTIAL_FROM_VAULT='
    refute_output --partial "OP_SERVICE_ACCOUNT_TOKEN="
}

@test "wrapper output is sorted by variable name" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run sudo -u openbrain "$INSTALLED_WRAPPER" "$STAGED_TARGET"
    assert_success
    sorted="$(printf '%s\n' "$output" | LC_ALL=C sort)"
    [ "$output" = "$sorted" ]
}

@test "wrapper-spawned env shows Environment vars but not OP_SERVICE_ACCOUNT_TOKEN" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    run sudo -u openbrain "$INSTALLED_WRAPPER" env
    assert_success
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    refute_line --regexp '^TEST_CREDENTIAL_FROM_VAULT='
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

@test "rendered + installed wrapper carry the canonical-source header" {
    [ -e "$INSTALLED_WRAPPER" ] || run_installer
    [ -e "$RENDERED_WRAPPER" ] || skip "rendered wrapper missing: $RENDERED_WRAPPER"

    # Anchor strings the spec mandates the header contain.
    local repo_url='https://github.com/thewoolleyman/1password-env-wrapper'
    local do_not_edit='DO NOT EDIT THIS FILE'
    local pr_phrase='Pull Request'

    # Rendered file (mode 0755, world-readable) — read directly.
    run grep -F -- "$repo_url" "$RENDERED_WRAPPER"
    assert_success
    run grep -F -- "$do_not_edit" "$RENDERED_WRAPPER"
    assert_success
    run grep -F -- "$pr_phrase" "$RENDERED_WRAPPER"
    assert_success

    # Installed file (mode 0750 root:openbrain) — read via sudo.
    run sudo grep -F -- "$repo_url" "$INSTALLED_WRAPPER"
    assert_success
    run sudo grep -F -- "$do_not_edit" "$INSTALLED_WRAPPER"
    assert_success
    run sudo grep -F -- "$pr_phrase" "$INSTALLED_WRAPPER"
    assert_success

    # Rendered and installed copies are byte-identical.
    run sudo cmp "$RENDERED_WRAPPER" "$INSTALLED_WRAPPER"
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
    assert_line "TEST_CREDENTIAL_FROM_ENVIRONMENT=TEST_VALUE"
    refute_line --regexp '^TEST_CREDENTIAL_FROM_VAULT='
    refute_output --partial "OP_SERVICE_ACCOUNT_TOKEN="
}
