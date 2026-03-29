#!/bin/sh
set -eu

# FocusShield Domain Add Helper
# Called by fsw/fsb/whitelist/blacklist wrapper commands.
# Usage: focusshield-domain-add <w|b> <tool_name> <original_args...>
#
# Extracts hostnames from the command arguments, adds them to the tool's
# domain list in the FocusShield database, then executes the command
# through the normal CLI guard flow.

MODE="$1"   # "w" or "b"
shift
TOOL_NAME="$1"
shift

# Resolve the real executable path (skip our own wrappers in /usr/local/bin)
resolve_real_exec() {
    local name="$1"
    # Check common system paths first
    for dir in /usr/bin /usr/sbin /sbin /bin /opt/homebrew/bin; do
        if [ -x "$dir/$name" ]; then
            echo "$dir/$name"
            return
        fi
    done
    # Fallback: use which but skip /usr/local/bin entries
    local candidate
    candidate=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/usr/local/bin' | tr '\n' ':') which "$name" 2>/dev/null || true)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        echo "$candidate"
        return
    fi
    echo ""
}

REAL_EXEC=$(resolve_real_exec "$TOOL_NAME")
if [ -z "$REAL_EXEC" ]; then
    echo "focusshield: cannot find real executable for '$TOOL_NAME'" >&2
    exit 127
fi

# Database location
DB_PATH="$HOME/Library/Application Support/FocusShield/focusshield.sqlite"
if [ ! -f "$DB_PATH" ]; then
    echo "focusshield: database not found at '$DB_PATH'" >&2
    echo "focusshield: falling through to direct execution." >&2
    exec "$REAL_EXEC" "$@"
fi

# Extract hostnames from the remaining arguments
extract_hosts_from_args() {
    printf '%s\n' "$@" | /usr/bin/perl -ne 'while (/(?:https?:\/\/)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?(?:[\/\s"<>]|$)/g) { print lc($1), "\n"; }' | sort -u
}

HOSTS=$(extract_hosts_from_args "$@")

if [ -z "$HOSTS" ]; then
    echo "focusshield: no hostnames detected in command arguments." >&2
    echo "focusshield: executing '$TOOL_NAME' directly." >&2
    exec "$REAL_EXEC" "$@"
fi

# Find the app_rule for this CLI tool
APP_RULE_ID=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT id FROM app_rules WHERE executablePath = '$REAL_EXEC' AND ruleType = 'cliTool' LIMIT 1" 2>/dev/null || true)
PROFILE_ID=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT profileID FROM app_rules WHERE id = '$APP_RULE_ID' LIMIT 1" 2>/dev/null || true)

if [ -z "$APP_RULE_ID" ] || [ -z "$PROFILE_ID" ]; then
    echo "focusshield: no CLI rule found for '$TOOL_NAME' ($REAL_EXEC)." >&2
    echo "focusshield: add it in the Focus Shield app first, then use fsw/fsb." >&2
    exec "$REAL_EXEC" "$@"
fi

# Determine the desired filter mode
DESIRED_MODE="blacklist"
case "$MODE" in
    w|whitelist) DESIRED_MODE="whitelist" ;;
    b|blacklist) DESIRED_MODE="blacklist" ;;
esac

# Update the filter mode if it doesn't match
CURRENT_MODE=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT filterMode FROM app_rules WHERE id = $APP_RULE_ID" 2>/dev/null || true)
if [ "$CURRENT_MODE" != "$DESIRED_MODE" ]; then
    /usr/bin/sqlite3 "$DB_PATH" "UPDATE app_rules SET filterMode = '$DESIRED_MODE' WHERE id = $APP_RULE_ID" 2>/dev/null || true
    echo "focusshield: switched '$TOOL_NAME' to $DESIRED_MODE mode." >&2
fi

# Add each hostname to the domain_rules table (skip duplicates)
ADDED=0
printf '%s\n' "$HOSTS" | while IFS= read -r host; do
    [ -n "$host" ] || continue
    EXISTS=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM domain_rules WHERE appRuleID = $APP_RULE_ID AND domain = '$host'" 2>/dev/null || echo "0")
    if [ "$EXISTS" = "0" ]; then
        /usr/bin/sqlite3 "$DB_PATH" "INSERT INTO domain_rules (profileID, appRuleID, domain, isEnabled) VALUES ($PROFILE_ID, $APP_RULE_ID, '$host', 1)" 2>/dev/null || true
        echo "focusshield: added '$host' to $DESIRED_MODE for '$TOOL_NAME'." >&2
        ADDED=$((ADDED + 1))
    else
        echo "focusshield: '$host' already in domain list for '$TOOL_NAME'." >&2
    fi
done

# Now execute the command through the normal flow.
# The CLI guard wrapper will pick up the updated domain list from its env vars,
# but those are baked at apply-time. For immediate effect, we re-read the DB
# and construct the updated domain rules ourselves.
UPDATED_DOMAINS=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT domain FROM domain_rules WHERE appRuleID = $APP_RULE_ID AND isEnabled = 1" 2>/dev/null || true)
UPDATED_MODE=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT filterMode FROM app_rules WHERE id = $APP_RULE_ID" 2>/dev/null || true)

if [ -n "$UPDATED_DOMAINS" ]; then
    export FOCUSSHIELD_DOMAIN_RULES_B64=$(printf '%s' "$UPDATED_DOMAINS" | /usr/bin/base64)
fi
export FOCUSSHIELD_FILTER_MODE="${UPDATED_MODE:-blacklist}"
export FOCUSSHIELD_TOOL_NAME="$TOOL_NAME"

# Execute through the CLI guard if available
CLI_GUARD="/usr/local/lib/focusshield/focusshield-cli-guard"
if [ -x "$CLI_GUARD" ]; then
    exec "$CLI_GUARD" "$REAL_EXEC" "$@"
fi

# Fallback: direct execution
exec "$REAL_EXEC" "$@"
