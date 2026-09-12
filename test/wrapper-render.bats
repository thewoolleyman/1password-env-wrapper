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

    # A second rendering, identical except INSTALLED_WRAPPER points at
    # itself instead of a fake /usr/local/bin path — matching how a real
    # installed wrapper's INSTALLED_WRAPPER always resolves to its own
    # location. The keyring re-exec test below needs this: stage 2's
    # revoked-@s recovery re-execs `"$INSTALLED_WRAPPER" "$@"`, and that
    # must land back on a file that actually exists on disk.
    RENDERED_SELF="$BATS_FILE_TMPDIR/with-selfpath-env.sh"
    export RENDERED_SELF
    local harness_self="$BATS_FILE_TMPDIR/render-harness-self.sh"
    sed "s#INSTALLED_WRAPPER='/usr/local/bin/with-sample-env.sh'#INSTALLED_WRAPPER='$RENDERED_SELF'#" "$harness" \
        | sed "s#render_wrapper .*#render_wrapper '$RENDERED_SELF'#" > "$harness_self"
    bash "$harness_self"
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

# Mirror of the rendered stage-0 forward build, which decides what crosses
# the sudo boundary into the privileged stage. Kept byte-comparable with the
# template so a change to one without the other fails the structural tests
# above.
build_forward() {
    forward=()
    if [ -n "${OPENV_PRESERVE_VARS:-}" ]; then
        forward+=( "OPENV_PRESERVE_VARS=$OPENV_PRESERVE_VARS" )
        IFS=',' read -r -a _fwd_names <<< "$OPENV_PRESERVE_VARS"
        for _fwd_n in "${_fwd_names[@]}"; do
            _fwd_n="${_fwd_n#"${_fwd_n%%[![:space:]]*}"}"
            _fwd_n="${_fwd_n%"${_fwd_n##*[![:space:]]}"}"
            [ -n "$_fwd_n" ] || continue
            case "$_fwd_n" in
                [!A-Za-z_]*|*[!A-Za-z0-9_]*) continue ;;
                LD_*|BASH_*|GLIBC_*|PYTHON*|PERL5*) continue ;;
                ENV|BASHOPTS|SHELLOPTS|PS4|IFS|PATH|SHELL|HOME|TMPDIR) continue ;;
                SUDO_*|WRAPPER_STAGE|OP_SERVICE_ACCOUNT_TOKEN) continue ;;
                OPENV_PRESERVE_VARS|OPENV_KEEP_PRIVILEGES) continue ;;
            esac
            forward+=( "$_fwd_n=$(printenv "$_fwd_n" 2>/dev/null || true)" )
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
    # sudo supports `--`; it must stay. The stage-0 forward splice sits
    # between the TTL assignment and that separator, so the assertion is on
    # the whole hop rather than on one frozen substring.
    grep -Fq '"$sudo_path" -n WRAPPER_STAGE=1 OP_ENV_WRAPPER_CACHE_TTL="${OP_ENV_WRAPPER_CACHE_TTL:-}" "${forward[@]}" -- "$INSTALLED_WRAPPER" "$@"' "$RENDERED"
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
# Stage-0 forwarding of the OPENV_PRESERVE_VARS allowlist across the sudo hop.
#
# sudo's env_reset destroys the caller's ambient environment at stage 0, and
# stage 1 is the only place that reads OPENV_PRESERVE_VARS. Before this
# forwarding existed, both the allowlist and every variable it named were
# already gone by the time anything looked at them, so the documented
# mechanism silently did nothing through a plain invocation. What crosses the
# boundary is deliberate: the privileged stage must not be steerable by a
# caller who can only name variables.
# ---------------------------------------------------------------------------

@test "stage-0 builds a forward array and splices it into the sudo hop" {
    grep -Fq 'forward=()' "$RENDERED"
    grep -Fq 'forward+=( "OPENV_PRESERVE_VARS=$OPENV_PRESERVE_VARS" )' "$RENDERED"
    run grep -cF '"${forward[@]}"' "$RENDERED"
    [ "$output" -eq 1 ]
}

@test "forward build: unset OPENV_PRESERVE_VARS yields an empty array, safe under set -u" {
    set -u
    unset OPENV_PRESERVE_VARS || true
    build_forward
    [ "${#forward[@]}" -eq 0 ]
    run env -i HOME=/x "${forward[@]}" printenv HOME
    assert_success_local "$status" "/x" "$output"
}

@test "forward build: the allowlist crosses first, then each variable it names" {
    export OPENV_FWD_ONE='one' OPENV_FWD_TWO='two'
    OPENV_PRESERVE_VARS='OPENV_FWD_ONE,OPENV_FWD_TWO' build_forward
    [ "${#forward[@]}" -eq 3 ]
    [ "${forward[0]}" = "OPENV_PRESERVE_VARS=OPENV_FWD_ONE,OPENV_FWD_TWO" ]
    [ "${forward[1]}" = "OPENV_FWD_ONE=one" ]
    [ "${forward[2]}" = "OPENV_FWD_TWO=two" ]
    unset OPENV_FWD_ONE OPENV_FWD_TWO
}

@test "forward build: a caller-set variable outside the allowlist does not cross" {
    export OPENV_NAMED='named' OPENV_UNNAMED='unnamed'
    OPENV_PRESERVE_VARS='OPENV_NAMED' build_forward
    [ "${#forward[@]}" -eq 2 ]
    run printf '%s\n' "${forward[@]}"
    [[ "$output" != *OPENV_UNNAMED* ]]
    unset OPENV_NAMED OPENV_UNNAMED
}

@test "forward build: loader and shell names are refused so the root stage cannot be steered" {
    export LD_PRELOAD='/tmp/evil.so' BASH_ENV='/tmp/evil.sh' PATH_KEEP="$PATH"
    OPENV_PRESERVE_VARS='LD_PRELOAD,BASH_ENV,PATH,IFS,SHELLOPTS,ENV,PS4' build_forward
    # Only the allowlist itself crosses; every named entry is refused.
    [ "${#forward[@]}" -eq 1 ]
    [ "${forward[0]}" = "OPENV_PRESERVE_VARS=LD_PRELOAD,BASH_ENV,PATH,IFS,SHELLOPTS,ENV,PS4" ]
    unset LD_PRELOAD BASH_ENV PATH_KEEP
}

@test "forward build: OPENV_KEEP_PRIVILEGES is refused so group membership cannot become root" {
    # The installed sudoers fragment grants the IDENTIFIER group passwordless
    # sudo for this wrapper. Forwarding the keep-privileges flag through that
    # hop would let any group member run an arbitrary command as root, so the
    # flag keeps requiring an external `sudo -E` the caller had to earn.
    export OPENV_KEEP_PRIVILEGES='1'
    OPENV_PRESERVE_VARS='OPENV_KEEP_PRIVILEGES' build_forward
    [ "${#forward[@]}" -eq 1 ]
    run printf '%s\n' "${forward[@]}"
    [[ "$output" != *"OPENV_KEEP_PRIVILEGES=1"* ]]
    unset OPENV_KEEP_PRIVILEGES
}

@test "forward build: a name that is not a shell identifier is refused" {
    OPENV_PRESERVE_VARS='9LEADING,has-dash,has.dot,ok_name' build_forward
    [ "${#forward[@]}" -eq 2 ]
    [ "${forward[1]}" = "ok_name=" ]
}

@test "forward build: whitespace trimmed, empty entries skipped" {
    export OPENV_FWD_A='1' OPENV_FWD_B='2'
    OPENV_PRESERVE_VARS=' OPENV_FWD_A , , OPENV_FWD_B ,' build_forward
    [ "${#forward[@]}" -eq 3 ]
    [ "${forward[1]}" = "OPENV_FWD_A=1" ]
    [ "${forward[2]}" = "OPENV_FWD_B=2" ]
    unset OPENV_FWD_A OPENV_FWD_B
}

# ---------------------------------------------------------------------------
# Feature C — TTL cache of the op-resolved environment
# (OP_ENV_WRAPPER_CACHE_TTL). See SPECIFICATION.md § "TTL cache of the
# op-resolved environment" for the full design.
#
# Framing is NUL-delimited throughout (env -0; keyctl padd/pipe fed through
# a real pipe into `mapfile`, never through a bash variable), not
# newline-delimited: a POSIX environment variable name or value cannot
# contain a NUL byte, so a value containing a literal newline (e.g. a
# multi-line PEM private key) is cached and replayed correctly with zero
# ambiguity, unlike a newline-delimited format.
# ---------------------------------------------------------------------------

@test "cache is gated on OP_ENV_WRAPPER_CACHE_TTL (default 300s), keyctl, and get_persistent availability" {
    grep -Fq 'cache_ttl="${OP_ENV_WRAPPER_CACHE_TTL:-300}"' "$RENDERED"
    grep -Fq 'command -v keyctl >/dev/null 2>&1 && keyctl_available=1' "$RENDERED"
    grep -Fq 'if [ "$cache_ttl" -gt 0 ] && [ "$keyctl_available" -eq 1 ]; then' "$RENDERED"
    grep -Fq 'persistent_kr="$(keyctl get_persistent @s 2>/dev/null)"' "$RENDERED"
    grep -Fq 'if [ -n "$persistent_kr" ]; then' "$RENDERED"
}

@test "a revoked/unusable session keyring (@s) recovers in-place via keyctl new_session, no re-exec" {
    # Bug-fix 3: PR #9's own predecessor bug was invisible in every
    # synthetic bash-to-bash test because an interactive login shell's
    # session keyring already worked via PAM. A dead/revoked @s (a detached
    # tmux server, sudo with no pam_keyinit) is the actual failure mode.
    #
    # `keyctl new_session` joins a fresh anonymous session keyring on the
    # ALREADY-RUNNING process directly (the same underlying join operation
    # `keyctl session -` performs, but without forking/exec'ing a subcommand)
    # — so recovery never re-enters this script. That eliminates an entire
    # class of past design (re-exec + recursion guard) rather than merely
    # gating it: there is nothing to bound, no probe-then-commit dance
    # needed (a failed join leaves this process completely unaffected, so
    # it simply falls through), and — the concrete regression that forced
    # this redesign — no risk of `keyctl session -`'s own "Joined session
    # keyring: N" prose banner landing on a caller's stdout when merged
    # with stderr (a real downstream caller did exactly that and had its
    # JSON output corrupted). `new_session` only ever emits a bare keyring
    # ID, fully discarded here.
    grep -Fq 'if keyctl new_session >/dev/null 2>&1; then' "$RENDERED"
    ! grep -Fq 'OPENV_KEYRING_REEXEC' "$RENDERED"
    ! grep -Eq 'exec.*keyctl session' "$RENDERED"
}

@test "every genuine cache-bypass reason is reported loudly and unconditionally on stderr" {
    # Silence is what let this run at the uncached 8.5s baseline, unnoticed,
    # for the caching feature's entire life. TTL=0 is excluded: that's a
    # deliberate opt-out, not a bypass. These three ARE genuine bypasses —
    # the cache really was skipped and the caller really pays full op-run
    # cost — so none of them may be gated behind OP_ENV_WRAPPER_DEBUG.
    for msg in \
        'session keyring (@s) is unusable and a fresh one could not be created' \
        'joined a fresh session keyring but still could not obtain the persistent keyring' \
        'keyctl not found on PATH' \
        'failed to store the resolved Environment'
    do
        line="$(grep -F "$msg" "$RENDERED")"
        [ -n "$line" ]
        case "$line" in
            *OP_ENV_WRAPPER_DEBUG*)
                echo "genuine bypass message gated behind debug flag: $msg" >&2
                return 1
                ;;
        esac
    done
}

@test "a successful keyring recovery is quiet by default (only a genuine bypass is loud)" {
    # Recovery is the NORMAL path on any host where @s is revoked by
    # construction (a detached tmux server, sudo with no pam_keyinit) —
    # not an anomaly, so it must not print unconditionally on every single
    # invocation. Unlike the genuine-bypass messages above, this one MUST
    # be gated behind OP_ENV_WRAPPER_DEBUG=1: an unconditional message here
    # trains callers to filter it out.
    grep -Fq 'session keyring (@s) was unusable' "$RENDERED"
    grep -Fq 'if [ "${OP_ENV_WRAPPER_DEBUG:-0}" = 1 ]; then' "$RENDERED"
}

@test "a malformed OP_ENV_WRAPPER_CACHE_TTL is normalized to 0 (disabled), not a crash" {
    grep -Fq "''|*[!0-9]*) cache_ttl=0 ;;" "$RENDERED"
}

@test "lastpipe is enabled so mapfile can populate arrays used after the pipeline" {
    grep -Fq 'shopt -s lastpipe' "$RENDERED"
}

@test "cache key is scoped to the user's persistent keyring by IDENTIFIER + Environment ID" {
    # Deliberately NOT the plain @u user keyring: setpriv's raw uid change
    # never grants kernel "Possessor" status over @u (no PAM/login session
    # links it in), so a key added there is unreadable — even by the
    # process that just created it — from any other process, including a
    # later, separate invocation as the exact same uid. get_persistent
    # both creates-or-fetches a uid-scoped keyring AND links it into the
    # calling process's session, so reads actually work across invocations.
    grep -Fq 'cache_desc="op-env-wrapper-cache:${IDENTIFIER}:${ONEPASSWORD_ENVIRONMENT_ID}"' "$RENDERED"
    grep -Fq 'persistent_kr="$(keyctl get_persistent @s 2>/dev/null)"' "$RENDERED"
    grep -Fq 'keyctl search "$persistent_kr" user "$cache_desc"' "$RENDERED"
    grep -Fq 'keyctl padd user "$cache_desc" "$persistent_kr"' "$RENDERED"
    grep -Fq 'keyctl timeout "$new_key_id" "$cache_ttl"' "$RENDERED"
    ! grep -Eq 'keyctl (search|padd)[^"]*"[^"]*"[^"]* @u\b' "$RENDERED"
}

@test "cache read and write both use NUL delimiting through a real pipe, not a bash variable" {
    grep -Fq "keyctl pipe \"\$key_id\" 2>/dev/null | mapfile -d '' -t assign" "$RENDERED"
    grep -Fq "keyctl padd user \"\$cache_desc\" \"\$persistent_kr\"" "$RENDERED"
    grep -Fq "printf '%s" "$RENDERED"
    grep -Fq "env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE -0 | mapfile -d '' -t baseline_arr" "$RENDERED"
}

@test "a cache-hit replay entry is sanity-checked for '=' before being trusted as an env operand" {
    # A cache entry missing '=' entirely would otherwise be read by `env`
    # as the START OF THE COMMAND rather than an assignment — this guards
    # only against a corrupted/incompatible cache entry, not against
    # legitimate multi-line values (NUL framing already makes those safe).
    grep -Fq 'case "$kv" in' "$RENDERED"
    grep -Fq '*=*) ;;' "$RENDERED"
}

@test "both cache-path child execs strip OP_SERVICE_ACCOUNT_TOKEN and WRAPPER_STAGE" {
    # One for the cache-hit replay, one for the freshly-resolved cache-miss
    # launch — both bypass op entirely for the child, so both must repeat
    # the same -u strip the uncached op-run path gets from op's own env -u.
    run grep -cF 'exec env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE "${assign[@]}" "$@"' "$RENDERED"
    [ "$output" -eq 2 ]
}

@test "a cache miss resolves via an introspection target (env -0), never the real command, under op" {
    grep -Fq 'op run --no-masking --environment "$ONEPASSWORD_ENVIRONMENT_ID" -- env -u OP_SERVICE_ACCOUNT_TOKEN -u WRAPPER_STAGE -0' "$RENDERED"
}

@test "op's exit status on the cache-populate resolve is read via PIPESTATUS, not a bare \$?" {
    # The resolve call is the left side of a pipeline into mapfile, so a
    # bare $? after it would report mapfile's status, not op's.
    grep -Fq 'op_rc="${PIPESTATUS[0]}"' "$RENDERED"
}

@test "a rate limit (op exit 9) on the cache-populate resolve exits before the child ever runs" {
    grep -Fq '[ "$op_rc" -eq 9 ]' "$RENDERED"
    grep -Fq 'exit "$op_rc"' "$RENDERED"
}

# The exact baseline-diff logic from the wrapper template's stage-2
# cache-miss path (first-'='-split, "only what changed vs. baseline"
# diff), lifted verbatim so the test exercises the real algorithm against
# already-split arrays (mirroring what `mapfile -d ''` would have produced
# from NUL-delimited op/env output). Keep this in sync with the
# `base_map` / `assign` / `injected` loop in create-1password-env-wrapper.sh.
diff_injected_vars() {
    local -n _baseline_arr="$1"
    local -n _resolved_arr="$2"
    local -A base_map=()
    local kv
    for kv in "${_baseline_arr[@]}"; do
        base_map["${kv%%=*}"]="${kv#*=}"
    done

    assign=()
    injected=()
    for kv in "${_resolved_arr[@]}"; do
        assign+=("$kv")
        local name="${kv%%=*}"
        local value="${kv#*=}"
        if [ "${base_map[$name]+set}" != "set" ] || [ "${base_map[$name]}" != "$value" ]; then
            injected+=("$kv")
        fi
    done
}

@test "diff: a var absent from baseline is injected" {
    local baseline=('PATH=/bin')
    local resolved=('PATH=/bin' 'TEST_FOO=hello')
    diff_injected_vars baseline resolved
    [ "${#injected[@]}" -eq 1 ]
    [ "${injected[0]}" = "TEST_FOO=hello" ]
    [ "${#assign[@]}" -eq 2 ]
}

@test "diff: a var unchanged from baseline is NOT re-cached (only the delta is)" {
    local baseline=('PATH=/bin' 'SAME=1')
    local resolved=('PATH=/bin' 'SAME=1')
    diff_injected_vars baseline resolved
    [ "${#injected[@]}" -eq 0 ]
}

@test "diff: a var overridden by 1Password IS injected with the new (winning) value" {
    local baseline=('AMBIENT=original')
    local resolved=('AMBIENT=overridden')
    diff_injected_vars baseline resolved
    [ "${#injected[@]}" -eq 1 ]
    [ "${injected[0]}" = "AMBIENT=overridden" ]
}

@test "diff: a value containing a literal newline (e.g. a PEM key) is diffed and cached correctly" {
    # This is exactly the case the newline-delimited design could not
    # handle safely; NUL-delimited framing means it is just another array
    # element here, no special-casing needed.
    local pem=$'-----BEGIN KEY-----\nMIIEpQIBAAKC\nsomeline==\n-----END KEY-----'
    local baseline=('PATH=/bin')
    local resolved=('PATH=/bin' "PEM_KEY=$pem")
    diff_injected_vars baseline resolved
    [ "${#injected[@]}" -eq 1 ]
    [ "${injected[0]}" = "PEM_KEY=$pem" ]
}

# ---------------------------------------------------------------------------
# Live keyctl round-trip, including a genuine multi-line value. Skipped
# when keyutils is not installed — the structural gate test above proves
# the wrapper fails open (uncached) in that case, so this is extra
# assurance where the host allows it, not a hard requirement of the
# feature.
# ---------------------------------------------------------------------------

@test "live: keyctl round-trip stores, replays, and expires a cached diff containing a multi-line value" {
    if ! command -v keyctl >/dev/null 2>&1; then
        skip "keyctl (keyutils) not installed on this host"
    fi
    # Run entirely inside a fresh `keyctl session -` rather than trusting
    # the ambient @s of whatever process happens to be running bats: on a
    # host with a revoked @s (a detached tmux server, sudo with no
    # pam_keyinit — see bug-fix 3 below) the bats process's own @s can be
    # just as dead as the wrapper's ever was, which would fail this test
    # for a reason that has nothing to do with the round-trip logic it's
    # meant to check.
    run keyctl session - bash -c '
        set -e
        # Needed so mapfile, on the right of the pipe below, populates
        # `replay` in this shell rather than a subshell — same reason the
        # rendered wrapper itself enables it before using this pattern.
        shopt -s lastpipe
        desc="wrapper-render-bats-test:$$"
        persistent_kr="$(keyctl get_persistent @s)"
        keyctl purge -p user "$desc" >/dev/null 2>&1 || true

        pem=$'"'"'-----BEGIN KEY-----\nMIIEpQIBAAKC\nsomeline==\n-----END KEY-----'"'"'
        key_id="$(printf '"'"'%s\0'"'"' "TEST_FOO=hello" "PEM_KEY=$pem" | keyctl padd user "$desc" "$persistent_kr")"
        keyctl timeout "$key_id" 2

        found_id="$(keyctl search "$persistent_kr" user "$desc")"
        [ "$found_id" = "$key_id" ]

        replay=()
        keyctl pipe "$found_id" | mapfile -d "" -t replay
        [ "${#replay[@]}" -eq 2 ]
        [ "${replay[0]}" = "TEST_FOO=hello" ]
        [ "${replay[1]}" = "PEM_KEY=$pem" ]

        sleep 3
        if keyctl search "$persistent_kr" user "$desc" >/dev/null 2>&1; then
            echo "STILL PRESENT AFTER TTL" >&2
            exit 1
        fi
        echo "ROUND_TRIP_OK"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"ROUND_TRIP_OK"* ]]
}

@test "live: a REVOKED session keyring (@s) recovers in-place and reaches a cache HIT — zero op calls (bug-fix 3)" {
    if ! command -v keyctl >/dev/null 2>&1; then
        skip "keyctl (keyutils) not installed on this host"
    fi
    # This is the regression PR #9's own commit message warned about and
    # then reproduced one level up: its predecessor bug "was invisible in
    # every synthetic bash-to-bash test (an interactive login shell's
    # session already possesses @u via PAM at SSH login)". A bash-to-bash
    # test with a HEALTHY @s would be exactly that blind spot again. This
    # test instead forces @s into the REVOKED state PR #9 never covered
    # (a detached tmux server, sudo with no pam_keyinit — see the module
    # header) and asserts a cache HIT, not merely a successful exit: a
    # fake `op` on PATH that hard-fails if invoked proves the wrapper
    # never fell through to the uncached path despite @s being dead.
    # Deliberately do NOT touch keyctl in bats' own ambient shell here --
    # this test must not depend on whether the process running bats
    # itself happens to have a live @s (it may well not; that is the
    # whole premise). The pre-seed, the revoke, and the wrapper invocation
    # all happen inside ONE fresh, self-contained session below -- the
    # wrapper's own recovery (keyctl new_session) never spawns a second
    # one, unlike the old re-exec design.
    local cache_desc="op-env-wrapper-cache:sample:env-SAMPLE"

    local fakebin="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fakebin"
    cat > "$fakebin/op" <<'EOF'
#!/usr/bin/env bash
echo "FAKE OP WAS CALLED (should never happen on a cache hit): $*" >&2
exit 1
EOF
    chmod +x "$fakebin/op"

    run env \
        PATH="$fakebin:$PATH" \
        OP_SERVICE_ACCOUNT_TOKEN=dummy-token-value \
        WRAPPER_STAGE=2 \
        keyctl session - bash -c '
            set -e
            persistent_kr="$(keyctl get_persistent @s)"
            keyctl purge -p user "$1" >/dev/null 2>&1 || true
            key_id="$(printf "%s\0" "CACHED_VAR=from-cache" | keyctl padd user "$1" "$persistent_kr")"
            keyctl timeout "$key_id" 60
            keyctl revoke @s
            exec "$2" printenv CACHED_VAR
        ' _ "$cache_desc" "$RENDERED_SELF"

    [ "$status" -eq 0 ]
    [[ "$output" == *"from-cache"* ]]
    [[ "$output" != *"FAKE OP WAS CALLED"* ]]
    # Recovery is the NORMAL path on a host where @s is revoked by
    # construction, not an anomaly — the diagnostic must stay quiet by
    # default (OP_ENV_WRAPPER_DEBUG unset here) or it would fire on
    # essentially every invocation on such a host.
    [[ "$output" != *"session keyring (@s) was unusable"* ]]
    # Regression guard for the actual bug that forced this redesign: the
    # OLD re-exec design spawned a SECOND `keyctl session -` from inside
    # the wrapper's own recovery, printing a second "Joined session
    # keyring: N" banner that corrupted a real downstream caller's stdout
    # when merged with stderr. `keyctl new_session` never forks/execs, so
    # only the outer setup's ONE join banner should ever appear here.
    banner_count="$(printf '%s\n' "$output" | grep -c 'Joined session keyring' || true)"
    [ "$banner_count" -eq 1 ]
}

@test "live: a revoked-@s recovery never pollutes the wrapped command's stdout, even under 2>&1" {
    # Directly reproduces the real downstream regression this design fix
    # exists for: openbrain/scripts/verify-openbrain-env.sh does
    # `env_dump="$("$WRAPPER" python3 -c '...json.dumps(os.environ)...' 2>&1)"`
    # -- a merged capture expecting PURE JSON on stdout. The OLD re-exec
    # design's `keyctl session -` printed "Joined session keyring: N" to
    # STDERR, which corrupted env_dump the moment @s was revoked. Fixing
    # only that would still have left `keyctl new_session` free to print
    # its own bare keyring ID straight to STDOUT (confirmed by direct
    # measurement) -- worse, since that would corrupt every caller's
    # payload channel, not just ones that merge streams. Assert BOTH: a
    # stdout-only capture and a stdout+stderr merged capture produce
    # IDENTICAL bytes on stdout, and that stdout is valid, parseable JSON.
    if ! command -v keyctl >/dev/null 2>&1; then
        skip "keyctl (keyutils) not installed on this host"
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not installed on this host"
    fi
    local cache_desc="op-env-wrapper-cache:sample:env-SAMPLE"
    local stdout_only="$BATS_TEST_TMPDIR/stdout_only.json"
    local merged="$BATS_TEST_TMPDIR/merged.out"

    # `keyctl new_session` (not the outer `keyctl session -` used
    # elsewhere in this file) sets up the test's OWN throwaway session, so
    # the test harness itself contributes no "Joined session keyring: N"
    # banner to compare against — otherwise that banner (a property of
    # THIS TEST's setup, unrelated to the wrapper under test) would show
    # up in the merged capture but not the stdout-only one and produce a
    # spurious diff. Every setup command's own output is discarded too,
    # so the ONLY thing that can differ between the two captures below is
    # whatever the WRAPPER itself does.
    env \
        OP_SERVICE_ACCOUNT_TOKEN=dummy-token-value \
        WRAPPER_STAGE=2 \
        bash -c '
            set -e
            keyctl new_session >/dev/null 2>&1
            persistent_kr="$(keyctl get_persistent @s)"
            keyctl purge -p user "$1" >/dev/null 2>&1 || true
            key_id="$(printf "%s\0" "CACHED_VAR=from-cache" | keyctl padd user "$1" "$persistent_kr")"
            keyctl timeout "$key_id" 60 >/dev/null 2>&1
            keyctl revoke @s
            exec "$2" python3 -c "import json,os; print(json.dumps({\"CACHED_VAR\": os.environ.get(\"CACHED_VAR\", \"\")}))"
        ' _ "$cache_desc" "$RENDERED_SELF" > "$stdout_only" 2>/dev/null

    env \
        OP_SERVICE_ACCOUNT_TOKEN=dummy-token-value \
        WRAPPER_STAGE=2 \
        bash -c '
            set -e
            keyctl new_session >/dev/null 2>&1
            persistent_kr="$(keyctl get_persistent @s)"
            keyctl purge -p user "$1" >/dev/null 2>&1 || true
            key_id="$(printf "%s\0" "CACHED_VAR=from-cache" | keyctl padd user "$1" "$persistent_kr")"
            keyctl timeout "$key_id" 60 >/dev/null 2>&1
            keyctl revoke @s
            exec "$2" python3 -c "import json,os; print(json.dumps({\"CACHED_VAR\": os.environ.get(\"CACHED_VAR\", \"\")}))"
        ' _ "$cache_desc" "$RENDERED_SELF" > "$merged" 2>&1

    diff "$stdout_only" "$merged"
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['CACHED_VAR']=='from-cache', d" "$merged"
}

@test "live: OP_ENV_WRAPPER_DEBUG=1 makes a successful keyring recovery visible on request" {
    if ! command -v keyctl >/dev/null 2>&1; then
        skip "keyctl (keyutils) not installed on this host"
    fi
    local cache_desc="op-env-wrapper-cache:sample:env-SAMPLE"
    run env \
        OP_ENV_WRAPPER_DEBUG=1 \
        OP_SERVICE_ACCOUNT_TOKEN=dummy-token-value \
        WRAPPER_STAGE=2 \
        keyctl session - bash -c '
            set -e
            persistent_kr="$(keyctl get_persistent @s)"
            keyctl purge -p user "$1" >/dev/null 2>&1 || true
            key_id="$(printf "%s\0" "CACHED_VAR=from-cache" | keyctl padd user "$1" "$persistent_kr")"
            keyctl timeout "$key_id" 60
            keyctl revoke @s
            exec "$2" printenv CACHED_VAR
        ' _ "$cache_desc" "$RENDERED_SELF"

    [ "$status" -eq 0 ]
    [[ "$output" == *"from-cache"* ]]
    [[ "$output" == *"session keyring (@s) was unusable"* ]]
}

@test "live: a plain @u keyring key is unreadable across a setpriv-only uid transition (the exact bug this design avoids)" {
    if ! command -v keyctl >/dev/null 2>&1; then
        skip "keyctl (keyutils) not installed on this host"
    fi
    if ! command -v setpriv >/dev/null 2>&1; then
        skip "setpriv (util-linux) not installed on this host"
    fi
    if ! sudo -n true 2>/dev/null; then
        skip "passwordless sudo not available for this regression check"
    fi
    if ! id nobody >/dev/null 2>&1; then
        skip "no 'nobody' account available for this regression check"
    fi
    # Deliberately targets 'nobody' rather than the test runner's own uid:
    # the test runner's login session already possesses @u via PAM at SSH
    # login time, which would mask the bug. 'nobody' has no login session,
    # matching a real non-interactive IDENTIFIER account like this repo's
    # own 'openbrain' or 'livespec' — the exact case this regression was
    # found against.
    local desc="wrapper-render-bats-atu-regression:$$"
    keyctl purge -p user "$desc" >/dev/null 2>&1 || true

    # Process A: root -> setpriv to nobody — exactly the wrapper's own
    # Stage 1 -> Stage 2 transition — creates a key directly in the plain
    # @u user keyring.
    sudo setpriv --reuid=65534 --regid=65534 --init-groups -- bash -c \
        'printf "%s\0" "FOO=bar" | keyctl padd user "'"$desc"'" @u >/dev/null'

    # Process B: a SEPARATE setpriv transition to the SAME uid tries to
    # read it. Without a login/PAM session, this process never becomes a
    # kernel "Possessor" of @u's contents, so the read fails with EPERM —
    # this is the actual regression that motivated switching to
    # get_persistent in the rendered wrapper (see the test above).
    run sudo setpriv --reuid=65534 --regid=65534 --init-groups -- bash -c \
        'kid=$(keyctl search @u user "'"$desc"'" 2>/dev/null); keyctl pipe "$kid"'
    [ "$status" -ne 0 ]

    keyctl purge -p user "$desc" >/dev/null 2>&1 || true
}

# Tiny local assertion helper so this file does not depend on
# bats-assert being installed (integration.bats loads it; this unit
# file stays dependency-free).
assert_success_local() {
    local status="$1" expected="$2" actual="$3"
    [ "$status" -eq 0 ] || { echo "expected exit 0, got $status" >&2; return 1; }
    [ "$actual" = "$expected" ] || { echo "expected '$expected', got '$actual'" >&2; return 1; }
}
