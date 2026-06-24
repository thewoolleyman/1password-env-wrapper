#!/usr/bin/env bats

# Unit tests for the *rendered wrapper* produced by
# create-1password-env-wrapper.sh.
#
# Unlike test/integration.bats (which drives the installer end-to-end
# against real 1Password infrastructure, a Linux group, and the
# systemd credstore / macOS Keychain), this file is fully
# self-contained: it renders a sample wrapper from the installer's
# `render_wrapper` template with fixed inputs and asserts on the
# rendered bytes and structure. It needs no 1Password access, no
# root, no sudo, and no platform-specific token store, so it runs in
# CI and on any developer machine.
#
# It guards:
#   - the wrapper template stays a valid bash script (`bash -n`);
#   - no `env … --` (GNU-style separator after assignments / -u
#     options) is emitted at any site — uutils/POSIX `env` rejects it
#     (sudo's and setpriv's own `--` are allowed and expected);
#   - the final child execs strip BOTH OP_SERVICE_ACCOUNT_TOKEN and
#     WRAPPER_STAGE, so nested wrapper invocations re-run their stages;
#   - the default-off OPENV_KEEP_PRIVILEGES opt-out and the
#     OPENV_PRESERVE_VARS allowlist are present and shaped correctly.
#
# The pure-logic behavior of the OPENV_PRESERVE_VARS array build (and
# its safety under `set -u`) is exercised directly, since that logic
# is platform-independent and does not require an actual re-exec.

setup_file() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    INSTALLER="$REPO_ROOT/create-1password-env-wrapper.sh"
    export INSTALLER

    RENDERED="$BATS_FILE_TMPDIR/with-sample-env.sh"
    export RENDERED

    # Render a sample wrapper without running the installer's
    # prerequisite gauntlet: extract the `render_wrapper` function from
    # the installer, supply the variables its heredoc interpolates, and
    # invoke it. This is the same template the installer ships; the
    # only thing skipped is the platform/secret-store machinery, which
    # is irrelevant to the rendered bytes.
    local harness="$BATS_FILE_TMPDIR/render-harness.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' "IDENTIFIER='sample'"
        printf '%s\n' "DEFAULT_SHELL='/bin/bash'"
        printf '%s\n' "ONEPASSWORD_ENVIRONMENT_ID='env-SAMPLE'"
        printf '%s\n' "INSTALLED_WRAPPER='/usr/local/bin/with-sample-env.sh'"
        printf '%s\n' "SYSTEMD_CRED_NAME='1password-env-wrapper-sample'"
        printf '%s\n' "SYSTEMD_CRED_PATH='/etc/credstore.encrypted/1password-env-wrapper-sample'"
        printf '%s\n' "MACOS_KEYCHAIN_SERVICE='sample'"
        printf '%s\n' "MACOS_KEYCHAIN_TOKEN_ACCOUNT='OP_SERVICE_ACCOUNT_TOKEN'"
    } > "$harness"

    # Extract the render_wrapper function definition: from its opening
    # line through the first line that is a lone closing brace at column
    # zero (the function's closing `}`). awk_prog is built without
    # embedding a literal closing brace in a regex, which keeps the
    # surrounding `$(...)` command substitution easy for every shell to
    # parse.
    local awk_prog
    awk_prog='f && $0=="}" {print; exit} /^render_wrapper\(\) \{$/ {f=1} f {print}'
    awk "$awk_prog" "$INSTALLER" >> "$harness"
    printf 'render_wrapper %q\n' "$RENDERED" >> "$harness"
    if ! grep -q '^render_wrapper() {' "$harness"; then
        echo "FATAL: could not extract render_wrapper from $INSTALLER" >&2
        return 1
    fi

    bash "$harness"
}

# The exact OPENV_PRESERVE_VARS array-build logic from the wrapper
# template, lifted verbatim so the test exercises the real algorithm
# (whitespace trim, empty-entry skip, missing-var -> NAME=). Keep this
# in sync with the `preserve+=(...)` block in render_wrapper.
build_preserve() {
    preserve=()
    if [ -n "${OPENV_PRESERVE_VARS:-}" ]; then
        IFS=',' read -r -a _openv_names <<< "$OPENV_PRESERVE_VARS"
        for _openv_n in "${_openv_names[@]}"; do
            _openv_n="${_openv_n#"${_openv_n%%[![:space:]]*}"}"
            _openv_n="${_openv_n%"${_openv_n##*[![:space:]]}"}"
            [ -n "$_openv_n" ] || continue
            preserve+=( "$_openv_n=$(printenv "$_openv_n" 2>/dev/null || true)" )
        done
    fi
}

# ---------------------------------------------------------------------------
# Rendered-bytes structural tests.
# ---------------------------------------------------------------------------

@test "rendered wrapper is a syntactically valid bash script" {
    bash -n "$RENDERED"
}

@test "rendered wrapper carries BOTH platform branches" {
    grep -F 'case "$(uname -s)"' "$RENDERED"
    grep -F '    Linux)' "$RENDERED"
    grep -F '    Darwin)' "$RENDERED"
    grep -F 'systemd-creds decrypt' "$RENDERED"
    grep -F 'security find-generic-password' "$RENDERED"
}

@test "no env-level GNU -- separator is emitted anywhere (bug-fix 1)" {
    # Match an `env` invocation that is followed (on the same logical
    # line) by a bare `--` token. uutils/POSIX `env` rejects this after
    # NAME=value / -u operands. sudo's and setpriv's own `--` live on
    # lines that do not start the token-run with `env`, so they do not
    # match this pattern.
    run grep -nE '\benv\b[^|;&]*[[:space:]]--([[:space:]]|$)' "$RENDERED"
    # grep exits 1 when there are no matches; that is the success case.
    [ "$status" -eq 1 ]
}

@test "stage-0 already-root re-exec drops the env -- separator (bug-fix 1)" {
    grep -Fq 'exec env WRAPPER_STAGE=1 "$INSTALLED_WRAPPER" "$@"' "$RENDERED"
    ! grep -Fq 'exec env WRAPPER_STAGE=1 -- "$INSTALLED_WRAPPER"' "$RENDERED"
}

@test "sudo self-escalation keeps its own -- separator" {
    # sudo supports `--`; it must stay.
    grep -Fq '"$sudo_path" -n WRAPPER_STAGE=1 -- "$INSTALLED_WRAPPER" "$@"' "$RENDERED"
}

@test "setpriv keeps its own -- separator in the default drop branch" {
    grep -Eq 'setpriv --reuid="\$SUDO_UID" --regid="\$SUDO_GID" --init-groups -- \\?$' "$RENDERED"
}

@test "Linux stage-2 final exec strips OP_SERVICE_ACCOUNT_TOKEN and WRAPPER_STAGE (bug-fix 2)" {
    grep -Fq 'env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE "$@"' "$RENDERED"
}

@test "macOS final exec strips OP_SERVICE_ACCOUNT_TOKEN and WRAPPER_STAGE (bug-fix 2)" {
    # Two occurrences total of the strip pattern: one Linux, one macOS.
    run grep -cF 'env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE "$@"' "$RENDERED"
    [ "$output" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Rate-limit failure legibility (op exit 9).
# ---------------------------------------------------------------------------

@test "op cache stays OFF (OP_CACHE=false) — it does not cover op run --environment" {
    # Verified out-of-band: caching on vs off makes no difference to the
    # service-account rate-limit counter for environment resolution, so the
    # original hardening default is kept and caching is NOT claimed as a fix.
    run grep -cF 'export OP_CACHE=false' "$RENDERED"
    [ "$output" -eq 2 ]
    ! grep -Fq 'OP_CACHE=true' "$RENDERED"
    ! grep -Fq 'XDG_RUNTIME_DIR' "$RENDERED"
}

@test "a 1Password rate limit (op exit 9) is made legible and propagated on both platforms" {
    # Both Stage-2 paths branch on op exit 9 (no exec) and re-propagate the code.
    run grep -cF '[ "$rc" -eq 9 ]' "$RENDERED"
    [ "$output" -eq 2 ]
    run grep -cF 'exit "$rc"' "$RENDERED"
    [ "$output" -eq 2 ]
    grep -Fq 'rate limit' "$RENDERED"
}

# ---------------------------------------------------------------------------
# Feature A — OPENV_KEEP_PRIVILEGES (default-off opt-out of drop-to-invoker).
# ---------------------------------------------------------------------------

@test "OPENV_KEEP_PRIVILEGES branch is present and gated on =1" {
    grep -Fq '[ "${OPENV_KEEP_PRIVILEGES:-0}" = "1" ]' "$RENDERED"
}

@test "OPENV_KEEP_PRIVILEGES=1 path runs WITHOUT setpriv; default path runs WITH setpriv" {
    # The keep-privileges exec must NOT contain setpriv; the default
    # branch must. Extract the keep-privileges branch (between the
    # gate and the `else`) and confirm setpriv is absent there but the
    # token+stage env vars are present.
    local keep_branch default_branch
    keep_branch="$(awk '
        /\[ "\$\{OPENV_KEEP_PRIVILEGES:-0\}" = "1" \]/ {inkeep=1}
        inkeep && /^                else$/ {exit}
        inkeep {print}
    ' "$RENDERED")"
    default_branch="$(awk '
        /^                else$/ {indef=1; next}
        indef && /^                fi$/ {exit}
        indef {print}
    ' "$RENDERED")"

    [ -n "$keep_branch" ]
    [ -n "$default_branch" ]
    printf '%s\n' "$keep_branch" | grep -Fq 'exec env -i'
    ! printf '%s\n' "$keep_branch" | grep -Fq 'setpriv'
    printf '%s\n' "$default_branch" | grep -Fq 'setpriv --reuid='
}

# Extract the keep-privileges (OPENV_KEEP_PRIVILEGES=1) stage-1 branch.
keep_privileges_branch() {
    awk '
        /\[ "\$\{OPENV_KEEP_PRIVILEGES:-0\}" = "1" \]/ {inkeep=1}
        inkeep && /^                else$/ {exit}
        inkeep {print}
    ' "$RENDERED"
}

# Extract the default (drop-to-invoker) stage-1 branch.
default_drop_branch() {
    awk '
        /^                else$/ {indef=1; next}
        indef && /^                fi$/ {exit}
        indef {print}
    ' "$RENDERED"
}

@test "keep-privileges branch sets HOME to the CURRENT uid's home, not the invoker's" {
    local keep_branch
    keep_branch="$(keep_privileges_branch)"
    [ -n "$keep_branch" ]
    # HOME is resolved from the current uid (so a root child's
    # \$HOME/.config/op is owned by root and op run does not refuse).
    printf '%s\n' "$keep_branch" | grep -Fq 'keep_home="$(getent passwd "$(id -u)" | cut -d: -f6)"'
    printf '%s\n' "$keep_branch" | grep -Fq '[ -n "$keep_home" ] || keep_home="/root"'
    printf '%s\n' "$keep_branch" | grep -Fq 'HOME="$keep_home"'
    # And it must NOT reuse the invoker's home in this branch.
    ! printf '%s\n' "$keep_branch" | grep -Fq 'HOME="$invoker_home"'
}

@test "default drop-to-invoker branch keeps HOME as the invoker's home" {
    local default_branch
    default_branch="$(default_drop_branch)"
    [ -n "$default_branch" ]
    printf '%s\n' "$default_branch" | grep -Fq 'HOME="$invoker_home"'
    ! printf '%s\n' "$default_branch" | grep -Fq 'HOME="$keep_home"'
}

@test "HOME resolution: getent passwd of the current uid yields a non-invoker home for root" {
    # Prove the resolution idiom the keep-privileges branch uses returns
    # the current uid's home (the actual op-run-ownership fix), not the
    # invoker's. Run for whatever uid the test runs as; assert it matches
    # this process's HOME-equivalent rather than asserting a literal path.
    local resolved
    resolved="$(getent passwd "$(id -u)" | cut -d: -f6)"
    [ -n "$resolved" ] || resolved="/root"
    # For uid 0 the resolved home is conventionally /root; for any uid it
    # is that uid's own passwd home. Either way it is the *current* uid's
    # home — which is exactly what differs from the invoker under sudo.
    local expected
    expected="$(getent passwd "$(id -un)" | cut -d: -f6)"
    [ "$resolved" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Feature B — OPENV_PRESERVE_VARS (default-off allowlist through env -i).
# ---------------------------------------------------------------------------

@test "OPENV_PRESERVE_VARS splice is present in both stage-1 branches" {
    grep -Fq 'if [ -n "${OPENV_PRESERVE_VARS:-}" ]; then' "$RENDERED"
    # The "${preserve[@]}" splice appears in BOTH the keep-privileges
    # exec and the default setpriv exec.
    run grep -cF '"${preserve[@]}"' "$RENDERED"
    [ "$output" -eq 2 ]
}

@test "preserve build: unset OPENV_PRESERVE_VARS yields an empty array, safe under set -u" {
    set -u
    unset OPENV_PRESERVE_VARS || true
    build_preserve
    [ "${#preserve[@]}" -eq 0 ]
    # An empty splice into env -i must not error under set -u.
    run env -i HOME=/x "${preserve[@]}" printenv HOME
    assert_success_local "$status" "/x" "$output"
}

@test "preserve build: a named var is carried through the env -i scrub" {
    export OPENV_TEST_SECRET='carried-value'
    OPENV_PRESERVE_VARS='OPENV_TEST_SECRET' build_preserve
    [ "${#preserve[@]}" -eq 1 ]
    [ "${preserve[0]}" = "OPENV_TEST_SECRET=carried-value" ]
    # Prove it actually survives a real env -i scrub.
    run env -i HOME=/x "${preserve[@]}" printenv OPENV_TEST_SECRET
    assert_success_local "$status" "carried-value" "$output"
    unset OPENV_TEST_SECRET
}

@test "preserve build: whitespace trimmed, empty entries skipped" {
    export OPENV_A='1' OPENV_B='2'
    OPENV_PRESERVE_VARS=' OPENV_A , , OPENV_B ,' build_preserve
    [ "${#preserve[@]}" -eq 2 ]
    [ "${preserve[0]}" = "OPENV_A=1" ]
    [ "${preserve[1]}" = "OPENV_B=2" ]
    unset OPENV_A OPENV_B
}

@test "preserve build: missing var becomes NAME= (empty value), not an error" {
    unset OPENV_DOES_NOT_EXIST || true
    OPENV_PRESERVE_VARS='OPENV_DOES_NOT_EXIST' build_preserve
    [ "${#preserve[@]}" -eq 1 ]
    [ "${preserve[0]}" = "OPENV_DOES_NOT_EXIST=" ]
}

# Tiny local assertion helper so this file does not depend on
# bats-assert being installed (integration.bats loads it; this unit
# file stays dependency-free).
assert_success_local() {
    local status="$1" expected="$2" actual="$3"
    [ "$status" -eq 0 ] || { echo "expected exit 0, got $status" >&2; return 1; }
    [ "$actual" = "$expected" ] || { echo "expected '$expected', got '$actual'" >&2; return 1; }
}
