#!/usr/bin/env bash
# Fake busctl for headless tests. Emulates the subset the bridge uses:
#   list | get-property | call | monitor
# Shape of replies matches real `busctl --json=short` (verified live).

set -euo pipefail

# First non-option token is the command.
CMD=""
for a in "$@"; do
    case "$a" in
        --*) continue ;;
        *) CMD="$a"; break ;;
    esac
done

if [[ -n "${FAKE_CALL_LOG:-}" ]]; then
    echo "$@" >> "$FAKE_CALL_LOG"
fi

case "$CMD" in
    list)
        printf '%s\n' "org.mpris.MediaPlayer2.spotify  1234 adrien :1.60 user@1000.service - -"
        printf '%s\n' "org.freedesktop.Notifications   1438 plasmashell adrien :1.25 user@1000.service - -"
        exit 0
        ;;
    get-property)
        # args (after CMD): DEST PATH IFACE NAME ...
        name="${!#}"
        case "$name" in
            PlaybackStatus) printf '%s\n' '{"type":"s","data":"Playing"}' ;;
            Position)       printf '%s\n' '{"type":"x","data":42000000}' ;;
            Metadata)
                printf '%s\n' '{"type":"a{sv}","data":{"xesam:title":{"type":"s","data":"Bad Guy"},"xesam:artist":{"type":"as","data":["Billie Eilish"]},"mpris:artUrl":{"type":"s","data":"file:///tmp/opencode/cover.png"}}}'
                ;;
            *) echo "fake: unknown get-property: $name" >&2; exit 1 ;;
        esac
        exit 0
        ;;
    call)
        # args (after CMD): DEST PATH IFACE METHOD [sig args...]
        method="${3:-}"
        case "$method" in
            PlayPause|Next|Previous|Play) printf '%s' '' ; exit 0 ;;
            *)
                echo "fake: method not found: $method" >&2
                exit 1
                ;;
        esac
        ;;
    monitor)
        # Stream fixture lines then stop. Busctl-style per-event JSON; the
        # bridge tolerates extra/missing fields, requires iface/member/args.
        if [[ -n "${FAKE_MONITOR_JSON:-}" ]]; then
            printf '%s\n' "$FAKE_MONITOR_JSON"
        fi
        exit 0
        ;;
    *)
        echo "fake: unknown command: $CMD" >&2
        exit 1
        ;;
esac
