#!/bin/sh
set -eu

REAL_EXEC="$1"
shift

# ── Guard against recursive invocation ──
# The guard uses system utilities (cat, head, grep, perl, mktemp, awk, shasum).
# If any of those are also FocusShield-wrapped, calling them would spawn a new
# guard instance, causing a fork bomb. Strip wrapper dirs from PATH for the
# duration of this script; restore before the final exec.
_FS_SAVED_PATH="$PATH"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

TOOL_NAME="${FOCUSSHIELD_TOOL_NAME:-$(basename "$REAL_EXEC")}"
FILTER_MODE="${FOCUSSHIELD_FILTER_MODE:-blacklist}"
DOMAIN_RULES_B64="${FOCUSSHIELD_DOMAIN_RULES_B64:-}"
PAYLOAD_PROTECTION="${FOCUSSHIELD_PAYLOAD_PROTECTION:-0}"
PATTERNS_FILE="${FOCUSSHIELD_PAYLOAD_PATTERNS_FILE:-}"
ALLOWLIST_FILE="${FOCUSSHIELD_PAYLOAD_ALLOWLIST_FILE:-}"
SESSION_ALLOWLIST_FILE="${FOCUSSHIELD_PAYLOAD_SESSION_ALLOWLIST_FILE:-}"
SEATBELT_PROFILE="${FOCUSSHIELD_SEATBELT_PROFILE:-}"

# ── On-demand domain-add via env vars ──
# Usage: l=w curl facebook.com   (or list=whitelist, l=b, list=black, etc.)
# Extracts hostnames, writes to DB, updates in-memory rules for immediate effect.
FS_ONDEMAND_MODE=""
FS_LIST_VAL="${l:-${list:-}}"
case "$FS_LIST_VAL" in
    w|white|whitelist) FS_ONDEMAND_MODE="whitelist" ;;
    b|black|blacklist) FS_ONDEMAND_MODE="blacklist" ;;
    "") ;; # not set — normal execution
    *) echo "focusshield: unknown list mode '$FS_LIST_VAL'. Use l=w or l=b." >&2 ;;
esac

if [ -n "$FS_ONDEMAND_MODE" ]; then
    DB_PATH="$HOME/Library/Application Support/FocusShield/focusshield.sqlite"
    if [ -f "$DB_PATH" ]; then
        # Extract hostnames from command arguments
        FS_HOSTS=$(printf '%s\n' "$@" | /usr/bin/perl -ne 'while (/(?:https?:\/\/)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?(?:[\/\s"<>]|$)/g) { print lc($1), "\n"; }' | sort -u)

        if [ -n "$FS_HOSTS" ]; then
            # Look up the app_rule for this CLI tool
            APP_RULE_ID=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT id FROM app_rules WHERE executablePath = '$REAL_EXEC' AND ruleType = 'cliTool' LIMIT 1" 2>/dev/null || true)
            PROFILE_ID=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT profileID FROM app_rules WHERE id = '$APP_RULE_ID' LIMIT 1" 2>/dev/null || true)

            if [ -n "$APP_RULE_ID" ] && [ -n "$PROFILE_ID" ]; then
                # Update filter mode if it doesn't match
                CURRENT_MODE=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT filterMode FROM app_rules WHERE id = $APP_RULE_ID" 2>/dev/null || true)
                if [ "$CURRENT_MODE" != "$FS_ONDEMAND_MODE" ]; then
                    /usr/bin/sqlite3 "$DB_PATH" "UPDATE app_rules SET filterMode = '$FS_ONDEMAND_MODE' WHERE id = $APP_RULE_ID" 2>/dev/null || true
                    FILTER_MODE="$FS_ONDEMAND_MODE"
                    echo "focusshield: switched '$TOOL_NAME' to $FS_ONDEMAND_MODE mode." >&2
                fi

                # Add each hostname (skip duplicates)
                printf '%s\n' "$FS_HOSTS" | while IFS= read -r fs_host; do
                    [ -n "$fs_host" ] || continue
                    EXISTS=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM domain_rules WHERE appRuleID = $APP_RULE_ID AND domain = '$fs_host'" 2>/dev/null || echo "0")
                    if [ "$EXISTS" = "0" ]; then
                        /usr/bin/sqlite3 "$DB_PATH" "INSERT INTO domain_rules (profileID, appRuleID, domain, isEnabled) VALUES ($PROFILE_ID, $APP_RULE_ID, '$fs_host', 1)" 2>/dev/null || true
                        echo "focusshield: added '$fs_host' to $FS_ONDEMAND_MODE for '$TOOL_NAME'." >&2
                    fi
                done

                # Re-read updated domain list from DB so current execution uses it
                UPDATED_DOMAINS=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT domain FROM domain_rules WHERE appRuleID = $APP_RULE_ID AND isEnabled = 1" 2>/dev/null || true)
                if [ -n "$UPDATED_DOMAINS" ]; then
                    DOMAIN_RULES_B64=$(printf '%s' "$UPDATED_DOMAINS" | /usr/bin/base64)
                fi
                FILTER_MODE=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT filterMode FROM app_rules WHERE id = $APP_RULE_ID" 2>/dev/null || echo "$FILTER_MODE")
            else
                echo "focusshield: no CLI rule found for '$TOOL_NAME' ($REAL_EXEC). Add it in the app first." >&2
            fi
        fi
    fi
fi

SCAN_FILE=$(mktemp -t focusshield_scan.XXXXXX)
STDIN_FILE=""

cleanup() {
    rm -f "$SCAN_FILE"
    if [ -n "$STDIN_FILE" ] && [ -f "$STDIN_FILE" ]; then
        rm -f "$STDIN_FILE"
    fi
}
trap cleanup EXIT INT TERM HUP

printf 'tool=%s\n' "$TOOL_NAME" > "$SCAN_FILE"
printf 'argv=' >> "$SCAN_FILE"
printf '%s ' "$@" >> "$SCAN_FILE"
printf '\n' >> "$SCAN_FILE"

if [ ! -t 0 ]; then
    STDIN_FILE=$(mktemp -t focusshield_stdin.XXXXXX)
    cat > "$STDIN_FILE"
    printf '\nstdin:\n' >> "$SCAN_FILE"
    head -c 4194304 "$STDIN_FILE" >> "$SCAN_FILE" 2>/dev/null || true
    printf '\n' >> "$SCAN_FILE"
fi

for arg in "$@"; do
    candidate="$arg"
    case "$candidate" in
        @*)
            candidate="${candidate#@}"
            ;;
    esac
    if [ -f "$candidate" ]; then
        printf '\nfile:%s\n' "$candidate" >> "$SCAN_FILE"
        head -c 131072 "$candidate" >> "$SCAN_FILE" 2>/dev/null || true
        printf '\n' >> "$SCAN_FILE"
    fi
done

decode_domain_rules() {
    if [ -z "$DOMAIN_RULES_B64" ]; then
        return 0
    fi
    printf '%s' "$DOMAIN_RULES_B64" | /usr/bin/base64 -D 2>/dev/null || true
}

extract_hosts() {
    /usr/bin/perl -ne 'while (/(?:https?:\/\/)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?(?:[\/\s"<>]|$)/g) { print lc($1), "\n"; }' "$SCAN_FILE" | sort -u
}

host_matches_rule() {
    local host="$1"
    local rule="$2"
    case "$rule" in
        [*].*) rule="${rule#*.}" ;;
    esac
    case "$host" in
        "$rule"|*."$rule") return 0 ;;
    esac
    return 1
}

check_domain_policy() {
    local rules hosts violation matched
    violation=0
    rules="$(decode_domain_rules)"
    [ -n "$rules" ] || return 0

    hosts="$(extract_hosts)"
    [ -n "$hosts" ] || return 0

    # Write hosts to a temp file for POSIX-safe iteration
    FS_HOSTS_TMP=$(mktemp -t fs_hosts.XXXXXX)
    FS_RULES_TMP=$(mktemp -t fs_rules.XXXXXX)
    printf '%s\n' "$hosts" > "$FS_HOSTS_TMP"
    printf '%s\n' "$rules" > "$FS_RULES_TMP"

    while IFS= read -r host; do
        [ -n "$host" ] || continue
        matched=1
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            if host_matches_rule "$host" "$rule"; then
                matched=0
                break
            fi
        done < "$FS_RULES_TMP"

        if [ "$FILTER_MODE" = "whitelist" ] && [ "$matched" -ne 0 ]; then
            echo "focusshield: blocked '$TOOL_NAME' because '$host' is outside the allowed domain list." >&2
            violation=1
        fi
        if [ "$FILTER_MODE" = "blacklist" ] && [ "$matched" -eq 0 ]; then
            echo "focusshield: blocked '$TOOL_NAME' because '$host' matches a blocked domain rule." >&2
            violation=1
        fi
    done < "$FS_HOSTS_TMP"

    rm -f "$FS_HOSTS_TMP" "$FS_RULES_TMP"
    return "$violation"
}

contains_allow_fingerprint() {
    local fingerprint="$1"
    local file="$2"
    [ -f "$file" ] || return 1
    grep -Fxq "$fingerprint" "$file"
}

record_allow_fingerprint() {
    local fingerprint="$1"
    local file="$2"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if ! contains_allow_fingerprint "$fingerprint" "$file"; then
        echo "$fingerprint" >> "$file"
    fi
}

escape_applescript() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

check_payload_patterns() {
    [ "$PAYLOAD_PROTECTION" = "1" ] || return 0
    [ -n "$PATTERNS_FILE" ] || return 0
    [ -f "$PATTERNS_FILE" ] || return 0

    local matched_names=""
    local name regex

    while IFS=$'\t' read -r name regex; do
        [ -n "$name" ] || continue
        [ -n "$regex" ] || continue
        if /usr/bin/perl -0e 'use strict; use warnings; my $pattern = shift @ARGV; local $/; my $data = <STDIN>; exit(($data =~ /$pattern/im) ? 0 : 1);' "$regex" < "$SCAN_FILE"; then
            matched_names="${matched_names}${name}\n"
        fi
    done < "$PATTERNS_FILE"

    [ -n "$matched_names" ] || return 0

    local fingerprint
    fingerprint=$(/usr/bin/shasum -a 256 "$SCAN_FILE" | awk '{print $1}')
    [ -n "$ALLOWLIST_FILE" ] || ALLOWLIST_FILE="/tmp/focusshield-payload-allowlist.txt"
    [ -n "$SESSION_ALLOWLIST_FILE" ] || SESSION_ALLOWLIST_FILE="/tmp/focusshield-payload-session-allowlist.txt"
    touch "$ALLOWLIST_FILE" "$SESSION_ALLOWLIST_FILE"

    if contains_allow_fingerprint "$fingerprint" "$ALLOWLIST_FILE" || contains_allow_fingerprint "$fingerprint" "$SESSION_ALLOWLIST_FILE"; then
        return 0
    fi

    local clean_names message button
    clean_names=$(printf "%b" "$matched_names" | sed '/^$/d')
    message=$(printf "FocusShield detected sensitive payload patterns for %s:\n\n%s\n\nAllow this request?" "$TOOL_NAME" "$clean_names")
    button=$(/usr/bin/osascript -e "button returned of (display dialog \"$(escape_applescript "$message")\" buttons {\"Deny\", \"Allow Session\", \"Always Allow\"} default button \"Deny\" with icon caution)" 2>/dev/null || true)

    case "$button" in
        "Allow Session")
            record_allow_fingerprint "$fingerprint" "$SESSION_ALLOWLIST_FILE"
            ;;
        "Always Allow")
            record_allow_fingerprint "$fingerprint" "$ALLOWLIST_FILE"
            ;;
        *)
            echo "focusshield: request denied because sensitive payload patterns were detected." >&2
            return 1
            ;;
    esac

    return 0
}

check_invisible_chars() {
    CHARSCAN_ENABLED="${FOCUSSHIELD_CHARSCAN_ENABLED:-0}"
    [ "$CHARSCAN_ENABLED" = "1" ] || return 0

    CHARSCAN_ZWSP="${FOCUSSHIELD_CHARSCAN_ZWSP:-0}"
    CHARSCAN_RTL="${FOCUSSHIELD_CHARSCAN_RTL:-0}"
    CHARSCAN_TAGS="${FOCUSSHIELD_CHARSCAN_TAGS:-0}"
    CHARSCAN_INVIS="${FOCUSSHIELD_CHARSCAN_INVIS:-0}"
    CHARSCAN_HOMOGLYPH="${FOCUSSHIELD_CHARSCAN_HOMOGLYPH:-0}"

    local checks=""
    [ "$CHARSCAN_ZWSP"      = "1" ] && checks="${checks}zwsp,"
    [ "$CHARSCAN_RTL"       = "1" ] && checks="${checks}rtl,"
    [ "$CHARSCAN_TAGS"      = "1" ] && checks="${checks}tags,"
    [ "$CHARSCAN_INVIS"     = "1" ] && checks="${checks}invis,"
    [ "$CHARSCAN_HOMOGLYPH" = "1" ] && checks="${checks}homoglyph,"
    [ -n "$checks" ] || return 0

    local hit_names
    hit_names=$(/usr/bin/perl -e '
use strict; use warnings;
binmode(STDIN, ":utf8");
my @checks = split(/,/, $ARGV[0] // "");
local $/; my $data = <STDIN> // "";
my %found;
for my $c (@checks) {
    if    ($c eq "zwsp")      { $found{$c}++ if $data =~ /[\x{200B}\x{200C}\x{200D}\x{FEFF}\x{2060}\x{FFFC}\x{FFF9}\x{FFFA}\x{FFFB}]/ }
    elsif ($c eq "rtl")       { $found{$c}++ if $data =~ /[\x{202A}-\x{202E}\x{2066}-\x{2069}]/ }
    elsif ($c eq "tags")      { $found{$c}++ if $data =~ /[\x{E0001}-\x{E007F}]/ }
    elsif ($c eq "invis")     { $found{$c}++ if $data =~ /[\x{00AD}\x{115F}\x{1160}\x{3164}\x{17B4}\x{17B5}\x{180B}-\x{180D}\x{FE00}-\x{FE0F}]/ }
    elsif ($c eq "homoglyph") { $found{$c}++ if $data =~ /[\x{0430}-\x{0435}\x{043E}\x{0440}\x{0441}\x{0445}\x{03BF}\x{03B1}]/ }
}
print join("\n", keys %found), "\n" if %found;
' "$checks" < "$SCAN_FILE" 2>/dev/null || true)

    [ -n "$hit_names" ] || return 0

    local fingerprint
    fingerprint=$(printf '%s%s' "$hit_names" "$(wc -c < "$SCAN_FILE")" \
        | /usr/bin/shasum -a 256 | awk '{print $1}')
    [ -n "$ALLOWLIST_FILE" ]         || ALLOWLIST_FILE="/tmp/focusshield-payload-allowlist.txt"
    [ -n "$SESSION_ALLOWLIST_FILE" ] || SESSION_ALLOWLIST_FILE="/tmp/focusshield-payload-session-allowlist.txt"
    touch "$ALLOWLIST_FILE" "$SESSION_ALLOWLIST_FILE"

    if contains_allow_fingerprint "$fingerprint" "$ALLOWLIST_FILE" \
        || contains_allow_fingerprint "$fingerprint" "$SESSION_ALLOWLIST_FILE"; then
        return 0
    fi

    local labels
    labels=$(printf '%s\n' "$hit_names" | sed \
        -e 's/zwsp/Zero-Width Characters/g' \
        -e 's/rtl/RTL Override\/Embedding/g' \
        -e 's/tags/Invisible Tag Characters (prompt-injection risk)/g' \
        -e 's/invis/Invisible Format Characters/g' \
        -e 's/homoglyph/Unicode Homoglyphs (lookalike letters)/g')
    local message button
    message=$(printf "FocusShield detected suspicious Unicode in the %s payload:\n\n%s\n\nAllow this request?" \
        "$TOOL_NAME" "$labels")
    button=$(/usr/bin/osascript \
        -e "button returned of (display dialog \"$(escape_applescript "$message")\" \
            buttons {\"Deny\", \"Allow Session\", \"Always Allow\"} \
            default button \"Deny\" with icon caution)" 2>/dev/null || true)

    case "$button" in
        "Allow Session") record_allow_fingerprint "$fingerprint" "$SESSION_ALLOWLIST_FILE" ;;
        "Always Allow")  record_allow_fingerprint "$fingerprint" "$ALLOWLIST_FILE" ;;
        *)
            echo "focusshield: request denied — invisible/bad Unicode characters detected in payload." >&2
            return 1 ;;
    esac
}

check_domain_policy
check_payload_patterns
check_invisible_chars

# Restore full PATH so the real tool runs in the user's environment
export PATH="$_FS_SAVED_PATH"

seatbelt_exec() {
    if [ -n "$SEATBELT_PROFILE" ] && [ -f "$SEATBELT_PROFILE" ] && [ -x /usr/bin/sandbox-exec ]; then
        exec /usr/bin/sandbox-exec -f "$SEATBELT_PROFILE" -D _HOME="$HOME" -D _CWD="$PWD" "$@"
    fi
    exec "$@"
}

if [ -n "$STDIN_FILE" ]; then
    seatbelt_exec "$REAL_EXEC" "$@" < "$STDIN_FILE"
fi

seatbelt_exec "$REAL_EXEC" "$@"
