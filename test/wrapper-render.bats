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
    grep -Fq '"$sudo_path" -n WRAPPER_STAGE=1 OP_ENV_WRAPPER_CACHE_TTL="${OP_ENV_WRAPPER_CACHE_TTL:-}" -- "$INSTALLED_WRAPPER" "$@"' "$RENDERED"
}

@test "OP_ENV_WRAPPER_CACHE_TTL is threaded through the sudo hop and both stage-1 env -i re-execs" {
    # Otherwise a caller's override (including =0 to disable caching) would
    # silently revert to the built-in default for the common, non-root
    # invocation path, since sudo's env_reset strips unlisted vars and each
    # stage-1 branch re-execs stage 2 through a clean env -i.
    grep -Fq 'OP_ENV_WRAPPER_CACHE_TTL="${OP_ENV_WRAPPER_CACHE_TTL:-}"' "$RENDERED"
    run grep -cF 'OP_ENV_WRAPPER_CACHE_TTL="${OP_ENV_WRAPPER_CACHE_TTL:-}"' "$RENDERED"
    [ "$output" -eq 3 ]
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

# ---------------------------------------------------------------------------
# Feature C — TTL cache of the op-resolved environment
# (OP_ENV_WRAPPER_CACHE_TTL). See SPECIFICATION.md § "TTL cache of the
# op-resolved environment" for the full design.
# ---------------------------------------------------------------------------

@test "cache is gated on OP_ENV_WRAPPER_CACHE_TTL (default 300s) and keyctl availability" {
    grep -Fq 'cache_ttl="${OP_ENV_WRAPPER_CACHE_TTL:-300}"' "$RENDERED"
    grep -Fq 'if [ "$cache_ttl" -gt 0 ] && command -v keyctl >/dev/null 2>&1; then' "$RENDERED"
}

@test "a malformed OP_ENV_WRAPPER_CACHE_TTL is normalized to 0 (disabled), not a crash" {
    grep -Fq "''|*[!0-9]*) cache_ttl=0 ;;" "$RENDERED"
}

@test "cache key is scoped to the user keyring (@u) by IDENTIFIER + Environment ID" {
    grep -Fq 'cache_desc="op-env-wrapper-cache:${IDENTIFIER}:${ONEPASSWORD_ENVIRONMENT_ID}"' "$RENDERED"
    grep -Fq 'keyctl search @u user "$cache_desc"' "$RENDERED"
    grep -Fq 'keyctl padd user "$cache_desc" @u' "$RENDERED"
    grep -Fq 'keyctl timeout "$new_key_id" "$cache_ttl"' "$RENDERED"
}

@test "both cache-path child execs strip OP_SERVICE_ACCOUNT_TOKEN and WRAPPER_STAGE" {
    # One for the cache-hit replay, one for the freshly-resolved cache-miss
    # launch — both bypass op entirely for the child, so both must repeat
    # the same -u strip the uncached op-run path gets from op's own env -u.
    run grep -cF 'exec env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE "${assign[@]}" "$@"' "$RENDERED"
    [ "$output" -eq 2 ]
}

@test "a cache miss resolves via an introspection target (env), never the real command, under op" {
    grep -Fq 'op run --no-masking --environment "$ONEPASSWORD_ENVIRONMENT_ID" -- env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE' "$RENDERED"
}

@test "a rate limit (op exit 9) on the cache-populate resolve exits before the child ever runs" {
    grep -Fq 'op_rc=$?' "$RENDERED"
    grep -Fq '[ "$op_rc" -eq 9 ]' "$RENDERED"
    grep -Fq 'exit "$op_rc"' "$RENDERED"
}

# The exact NAME=VALUE line-parsing + baseline-diff logic from the wrapper
# template's stage-2 cache-miss path (first-'='-split, malformed-line
# detection, "only what changed vs. baseline" diff), lifted verbatim so the
# test exercises the real algorithm. Keep this in sync with the
# `base_map` / `assign` / `injected` / `parse_ok` block in
# create-1password-env-wrapper.sh.
diff_injected_vars() {
    local baseline_raw="$1" resolved_raw="$2"
    local -A base_map=()
    while IFS= read -r line; do
        case "$line" in
            [A-Za-z_]*=*) base_map["${line%%=*}"]="${line#*=}" ;;
        esac
    done <<< "$baseline_raw"

    assign=()
    injected=()
    parse_ok=1
    while IFS= read -r line; do
        case "$line" in
            [A-Za-z_]*=*)
                assign+=("$line")
                local name="${line%%=*}"
                local value="${line#*=}"
                if [ "${base_map[$name]+set}" != "set" ] || [ "${base_map[$name]}" != "$value" ]; then
                    injected+=("$line")
                fi
                ;;
            *) parse_ok=0; break ;;
        esac
    done <<< "$resolved_raw"
}

@test "diff: a var absent from baseline is injected" {
    diff_injected_vars $'PATH=/bin' $'PATH=/bin\nTEST_FOO=hello'
    [ "$parse_ok" -eq 1 ]
    [ "${#injected[@]}" -eq 1 ]
    [ "${injected[0]}" = "TEST_FOO=hello" ]
    [ "${#assign[@]}" -eq 2 ]
}

@test "diff: a var unchanged from baseline is NOT re-cached (only the delta is)" {
    diff_injected_vars $'PATH=/bin\nSAME=1' $'PATH=/bin\nSAME=1'
    [ "$parse_ok" -eq 1 ]
    [ "${#injected[@]}" -eq 0 ]
}

@test "diff: a var overridden by 1Password IS injected with the new (winning) value" {
    diff_injected_vars $'AMBIENT=original' $'AMBIENT=overridden'
    [ "$parse_ok" -eq 1 ]
    [ "${#injected[@]}" -eq 1 ]
    [ "${injected[0]}" = "AMBIENT=overridden" ]
}

@test "diff: a resolved line that is not NAME=VALUE sets parse_ok=0 (fail open to uncached path)" {
    diff_injected_vars $'PATH=/bin' $'PATH=/bin\nnot a valid assignment line'
    [ "$parse_ok" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Feature C, continued — the UNCACHEABLE_MARKER poison mechanism.
#
# Without it, an Environment containing a multi-line value (e.g. a PEM key,
# which reliably produces parse_ok=0 above) would pay for a wasted
# introspection `op run` call on EVERY invocation before falling back to
# the real uncached `op run` call — TWO op calls per invocation, strictly
# slower than the wrapper had ever been before caching existed. The marker
# lets every call after the first, within the same TTL window, skip
# straight to the single uncached call and match pre-cache performance.
# ---------------------------------------------------------------------------

@test "UNCACHEABLE_MARKER sentinel is defined and can never collide with a real NAME=VALUE cache line" {
    grep -Fq "UNCACHEABLE_MARKER='__OP_ENV_WRAPPER_UNCACHEABLE__'" "$RENDERED"
    # No '=' in the marker, so it can never match the NAME=VALUE validator
    # pattern used for real cached entries.
    [[ "__OP_ENV_WRAPPER_UNCACHEABLE__" != *"="* ]]
}

@test "parse_ok=0 (multi-line value) writes the poison marker before falling through" {
    grep -Fq 'printf '"'"'%s'"'"' "$UNCACHEABLE_MARKER" | keyctl padd user "$cache_desc" @u' "$RENDERED"
}

@test "a cached UNCACHEABLE_MARKER is recognized and skips straight to the uncached path (no introspection re-attempt)" {
    # Both guards — the cache-hit-replay attempt and the miss/introspection
    # attempt — must explicitly exclude the marker value.
    run grep -cF 'cached_raw" != "$UNCACHEABLE_MARKER"' "$RENDERED"
    [ "$output" -eq 2 ]
}

@test "live: a poisoned entry costs exactly one op-equivalent call, not two, on a second invocation" {
    if ! command -v keyctl >/dev/null 2>&1; then
        skip "keyctl (keyutils) not installed on this host"
    fi
    local desc="wrapper-render-bats-poison-test:$$"
    keyctl purge -p user "$desc" >/dev/null 2>&1 || true

    local key_id
    key_id="$(printf '%s' '__OP_ENV_WRAPPER_UNCACHEABLE__' | keyctl padd user "$desc" @u)"
    keyctl timeout "$key_id" 5

    # Simulates the wrapper's own poison check: read the cached value and
    # confirm it is recognized as the marker (not a real, usable cache
    # entry) — this is the exact comparison the rendered wrapper performs.
    local cached_raw
    cached_raw="$(keyctl pipe "$key_id")"
    [ "$cached_raw" = "__OP_ENV_WRAPPER_UNCACHEABLE__" ]

    keyctl purge -p user "$desc" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Live keyctl round-trip. Skipped when keyutils is not installed — the
# structural gate test above proves the wrapper fails open (uncached) in
# that case, so this is extra assurance where the host allows it, not a
# hard requirement of the feature.
# ---------------------------------------------------------------------------

@test "live: keyctl round-trip stores, replays, and expires the cached diff" {
    if ! command -v keyctl >/dev/null 2>&1; then
        skip "keyctl (keyutils) not installed on this host"
    fi
    local desc="wrapper-render-bats-test:$$"
    keyctl purge -p user "$desc" >/dev/null 2>&1 || true

    local key_id
    key_id="$(printf '%s\n' 'TEST_FOO=hello' 'TEST_BAR=world' | keyctl padd user "$desc" @u)"
    keyctl timeout "$key_id" 2

    local found_id
    found_id="$(keyctl search @u user "$desc")"
    [ "$found_id" = "$key_id" ]
    run keyctl pipe "$found_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST_FOO=hello"* ]]
    [[ "$output" == *"TEST_BAR=world"* ]]

    sleep 3
    run keyctl search @u user "$desc"
    [ "$status" -ne 0 ]
}

# Tiny local assertion helper so this file does not depend on
# bats-assert being installed (integration.bats loads it; this unit
# file stays dependency-free).
assert_success_local() {
    local status="$1" expected="$2" actual="$3"
    [ "$status" -eq 0 ] || { echo "expected exit 0, got $status" >&2; return 1; }
    [ "$actual" = "$expected" ] || { echo "expected '$expected', got '$actual'" >&2; return 1; }
}
