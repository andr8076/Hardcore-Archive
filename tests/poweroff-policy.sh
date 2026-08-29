#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-poweroff-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/app" "$TMP/bin" "$TMP/home/.config/hardcore-archive"
cp "$ROOT/hardcore-archive.sh" "$TMP/app/hardcore-archive.sh"
cp "$ROOT/config" "$TMP/app/config"

cat > "$TMP/app/hardcore-archive-runner.sh" <<'EOF_RUNNER'
#!/usr/bin/env bash
printf 'POWER_ENV=%s\n' "${HARDCORE_ARCHIVE_POWER_OFF_REQUESTED:-unset}"
printf 'ARG=%s\n' "$@"
exit "${FAKE_RUNNER_RC:-0}"
EOF_RUNNER
chmod +x "$TMP/app/hardcore-archive.sh" "$TMP/app/hardcore-archive-runner.sh"

cat > "$TMP/bin/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
[[ ${1:-} == poweroff ]] || exit 90
printf 'poweroff\n' >> "${POWEROFF_MARKER:?}"
exit "${FAKE_POWEROFF_RC:-0}"
EOF_SYSTEMCTL
chmod +x "$TMP/bin/systemctl"

run_launcher() {
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" PATH="$TMP/bin:$PATH" \
        POWEROFF_MARKER="$TMP/poweroff.log" \
        bash "$TMP/app/hardcore-archive.sh" "$@"
}
assert_contains() { local out=$1 text=$2; grep -Fq -- "$text" <<< "$out" || { printf 'Expected text: %s\n%s\n' "$text" "$out" >&2; exit 1; }; }
assert_lacks() { local out=$1 text=$2; ! grep -Fq -- "$text" <<< "$out" || { printf 'Unexpected text: %s\n%s\n' "$text" "$out" >&2; exit 1; }; }

# Default remains off.
: > "$TMP/poweroff.log"
out=$(run_launcher source 2>&1)
assert_contains "$out" 'POWER_ENV=0'
[[ ! -s $TMP/poweroff.log ]] || { printf 'Default unexpectedly powered off.\n' >&2; exit 1; }

# Explicit flag arms poweroff, is not forwarded to the archive core, and fires
# only after a successful runner exit.
: > "$TMP/poweroff.log"
out=$(run_launcher --poweroff source 2>&1)
assert_contains "$out" 'POWER_ENV=1'
assert_lacks "$out" 'ARG=--poweroff'
assert_contains "$out" 'Archive completed successfully. Powering off the computer...'
grep -Fqx 'poweroff' "$TMP/poweroff.log"

# Archive failure must never power the machine off.
: > "$TMP/poweroff.log"
set +e
out=$(FAKE_RUNNER_RC=7 run_launcher --poweroff source 2>&1); rc=$?
set -e
(( rc == 7 )) || { printf 'Expected runner rc=7, got %s\n%s\n' "$rc" "$out" >&2; exit 1; }
[[ ! -s $TMP/poweroff.log ]] || { printf 'Poweroff ran after archive failure.\n' >&2; exit 1; }

# Config can make it the installation default, and CLI can explicitly disable it.
printf '\nPOWER_OFF_ON_SUCCESS=true\n' >> "$TMP/app/config"
: > "$TMP/poweroff.log"
out=$(run_launcher source 2>&1)
assert_contains "$out" 'POWER_ENV=1'
grep -Fqx 'poweroff' "$TMP/poweroff.log"
: > "$TMP/poweroff.log"
out=$(run_launcher --no-poweroff source 2>&1)
assert_contains "$out" 'POWER_ENV=0'
[[ ! -s $TMP/poweroff.log ]] || { printf '--no-poweroff did not override config.\n' >&2; exit 1; }

# Configured poweroff is inert for diagnostic/read-only modes.
: > "$TMP/poweroff.log"
out=$(run_launcher --doctor source 2>&1)
assert_contains "$out" 'POWER_ENV=0'
[[ ! -s $TMP/poweroff.log ]] || { printf 'Doctor unexpectedly powered off.\n' >&2; exit 1; }

# Explicitly asking for poweroff with a non-create command is an input error.
set +e
out=$(run_launcher --poweroff --doctor source 2>&1); rc=$?
set -e
(( rc == 2 )) || { printf 'Expected rc=2 for --poweroff --doctor, got %s\n%s\n' "$rc" "$out" >&2; exit 1; }
assert_contains "$out" '--poweroff is only valid for archive create/batch jobs'

# Shutdown failure is reported distinctly after a successful archive.
: > "$TMP/poweroff.log"
set +e
out=$(FAKE_POWEROFF_RC=5 run_launcher --poweroff source 2>&1); rc=$?
set -e
(( rc == 4 )) || { printf 'Expected rc=4 for failed poweroff command, got %s\n%s\n' "$rc" "$out" >&2; exit 1; }
assert_contains "$out" 'archive completed successfully, but the requested poweroff command failed'

printf 'Poweroff-on-success policy tests passed.\n'
