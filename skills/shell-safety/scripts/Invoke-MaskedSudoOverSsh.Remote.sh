#!/bin/sh
set -eu

protocol='SOLIS_SUDO_V1'
reader_pids=''
work_root=''

fail_preflight() {
    printf '%s ERROR %s\n' "$protocol" "$1"
    exit 95
}

[ "$#" -ge 2 ] || fail_preflight 'MAX_OUTPUT_BYTES_OR_TARGET_MISSING'
max_output_bytes=$1
shift
case "$max_output_bytes" in
    ''|*[!0-9]*) fail_preflight 'MAX_OUTPUT_BYTES_INVALID' ;;
esac
if [ "$max_output_bytes" -lt 1 ] || [ "$max_output_bytes" -gt 16777216 ]; then
    fail_preflight 'MAX_OUTPUT_BYTES_INVALID'
fi
case "$1" in
    /*) ;;
    *) fail_preflight 'TARGET_COMMAND_NOT_ABSOLUTE' ;;
esac

for required_tool in mktemp mkfifo base64 tr sudo rm rmdir mkdir sleep head wc cat; do
    command -v "$required_tool" >/dev/null 2>&1 || fail_preflight 'REMOTE_HELPER_PRECONDITION_FAILED'
done

umask 077
work_root=$(mktemp -d "${TMPDIR:-/tmp}/solis-sudo.XXXXXXXX") || fail_preflight 'REMOTE_WORK_ROOT_FAILED'
sudo_stdout="$work_root/sudo.stdout"
sudo_stderr="$work_root/sudo.stderr"
target_stdout="$work_root/target.stdout"
target_stderr="$work_root/target.stderr"
target_status="$work_root/target.status"
output_lock="$work_root/output.lock"

cleanup() {
    cleanup_exit=$?
    trap - 0 1 2 15
    for reader_pid in $reader_pids; do
        kill "$reader_pid" 2>/dev/null || :
    done
    for reader_pid in $reader_pids; do
        wait "$reader_pid" 2>/dev/null || :
    done
    if [ -n "$work_root" ] && [ -d "$work_root" ]; then
        rm -f -- "$sudo_stdout" "$sudo_stderr" "$target_stdout" "$target_stderr" "$target_status"
        rmdir -- "$output_lock" 2>/dev/null || :
        rmdir -- "$work_root" 2>/dev/null || :
    fi
    exit "$cleanup_exit"
}
trap cleanup 0 1 2 15

mkfifo "$sudo_stdout" "$sudo_stderr" "$target_stdout" "$target_stderr"
: > "$target_status"

capture_fifo() {
    fifo_path=$1
    record_name=$2
    (
        exec 3< "$fifo_path"
        encoded_payload=$(head -c "$max_output_bytes" <&3 | base64 | tr -d '\r\n')
        extra_byte_count=$(head -c 1 <&3 | wc -c | tr -d ' \r\n')
        cat <&3 >/dev/null
        exec 3<&-
        while ! mkdir "$output_lock" 2>/dev/null; do
            sleep 0.01
        done
        printf '%s %s %s\n' "$protocol" "$record_name" "$encoded_payload"
        if [ "$extra_byte_count" -ne 0 ]; then
            printf '%s LIMIT %s max=%s\n' "$protocol" "$record_name" "$max_output_bytes"
        fi
        rmdir -- "$output_lock"
    ) &
    reader_pids="$reader_pids $!"
}

capture_fifo "$sudo_stdout" 'SUDO_STDOUT'
capture_fifo "$sudo_stderr" 'SUDO_STDERR'
capture_fifo "$target_stdout" 'TARGET_STDOUT'
capture_fifo "$target_stderr" 'TARGET_STDERR'

set +e
sudo -S -p '' -- /bin/sh -c '
    status_path=$1
    stdout_path=$2
    stderr_path=$3
    shift 3
    printf "%s\n" started > "$status_path"
    "$@" </dev/null > "$stdout_path" 2> "$stderr_path"
    target_exit=$?
    printf "exit=%s\n" "$target_exit" >> "$status_path"
    exit "$target_exit"
' sh "$target_status" "$target_stdout" "$target_stderr" "$@" > "$sudo_stdout" 2> "$sudo_stderr"
sudo_exit=$?
set -e

target_started=0
target_exit='NA'
if [ -f "$target_status" ]; then
    while IFS= read -r status_line; do
        case "$status_line" in
            started) target_started=1 ;;
            exit=*) target_exit=${status_line#exit=} ;;
        esac
    done < "$target_status"
else
    : > "$target_stdout"
    : > "$target_stderr"
fi

for reader_pid in $reader_pids; do
    wait "$reader_pid"
done
reader_pids=''

printf '%s RESULT sudo_exit=%s target_started=%s target_exit=%s\n' \
    "$protocol" "$sudo_exit" "$target_started" "$target_exit"
exit 0
