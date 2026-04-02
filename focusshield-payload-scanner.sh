#!/bin/sh
# focusshield-payload-scanner — Lightweight payload scanner for file-reader tools.
# Wraps: cat, head, tail, grep, awk, sed, strings
#
# CRITICAL: This script MUST NOT call: cat head grep awk sed wc sort basename
# Those tools may be wrapped (their wrappers point back to this script).
# All I/O uses /usr/bin/perl exclusively. No recursion possible.
#
# Safe external programs: /usr/bin/perl  /usr/bin/mktemp  /usr/bin/osascript
#                         /usr/bin/shasum  /bin/rm  /bin/mkdir  /usr/bin/touch
set -eu

REAL_EXEC="$1"
shift

TOOL_NAME="${FOCUSSHIELD_TOOL_NAME:-tool}"
PAYLOAD_PROTECTION="${FOCUSSHIELD_PAYLOAD_PROTECTION:-0}"
PATTERNS_FILE="${FOCUSSHIELD_PAYLOAD_PATTERNS_FILE:-}"
ALLOWLIST_FILE="${FOCUSSHIELD_PAYLOAD_ALLOWLIST_FILE:-/tmp/focusshield-payload-allowlist.txt}"
SESSION_ALLOWLIST_FILE="${FOCUSSHIELD_PAYLOAD_SESSION_ALLOWLIST_FILE:-/tmp/focusshield-payload-session-allowlist.txt}"
CHARSCAN_ENABLED="${FOCUSSHIELD_CHARSCAN_ENABLED:-0}"
CHARSCAN_ZWSP="${FOCUSSHIELD_CHARSCAN_ZWSP:-0}"
CHARSCAN_RTL="${FOCUSSHIELD_CHARSCAN_RTL:-0}"
CHARSCAN_TAGS="${FOCUSSHIELD_CHARSCAN_TAGS:-0}"
CHARSCAN_INVIS="${FOCUSSHIELD_CHARSCAN_INVIS:-0}"
CHARSCAN_HOMOGLYPH="${FOCUSSHIELD_CHARSCAN_HOMOGLYPH:-0}"
SEATBELT_PROFILE="${FOCUSSHIELD_SEATBELT_PROFILE:-}"

# ── Fast path ────────────────────────────────────────────────────────────────
if [ "$PAYLOAD_PROTECTION" != "1" ] && [ "$CHARSCAN_ENABLED" != "1" ]; then
    if [ -n "$SEATBELT_PROFILE" ] && [ -f "$SEATBELT_PROFILE" ] && [ -x /usr/bin/sandbox-exec ]; then
        exec /usr/bin/sandbox-exec -f "$SEATBELT_PROFILE" -D _HOME="$HOME" -D _CWD="$PWD" "$REAL_EXEC" "$@"
    fi
    exec "$REAL_EXEC" "$@"
fi

# ── Temp files ───────────────────────────────────────────────────────────────
SCAN_FILE=$(/usr/bin/mktemp -t focusshield_scan.XXXXXX)
STDIN_FILE=""

cleanup() {
    /bin/rm -f "$SCAN_FILE"
    [ -n "$STDIN_FILE" ] && [ -f "$STDIN_FILE" ] && /bin/rm -f "$STDIN_FILE"
}
trap cleanup EXIT INT TERM HUP

printf 'tool=%s\nargv=' "$TOOL_NAME" > "$SCAN_FILE"
printf '%s ' "$@"                   >> "$SCAN_FILE"
printf '\n'                         >> "$SCAN_FILE"

# ── Buffer stdin (pure perl — never calls cat) ────────────────────────────────
if [ ! -t 0 ]; then
    STDIN_FILE=$(/usr/bin/mktemp -t focusshield_stdin.XXXXXX)
    /usr/bin/perl -0777 -e 'local $/; my $d = <STDIN>; print $d if defined $d' > "$STDIN_FILE"
    printf '\nstdin:\n' >> "$SCAN_FILE"
    /usr/bin/perl -e '
        open(my $fh, "<", $ARGV[0]) or exit;
        my $buf; read($fh, $buf, 4194304);
        print defined $buf ? $buf : "";
    ' "$STDIN_FILE" >> "$SCAN_FILE"
    printf '\n' >> "$SCAN_FILE"
fi

# ── Buffer file arguments (pure perl — never calls head) ──────────────────────
for arg in "$@"; do
    candidate="$arg"
    case "$candidate" in @*) candidate="${candidate#@}" ;; esac
    if [ -f "$candidate" ]; then
        printf '\nfile:%s\n' "$candidate" >> "$SCAN_FILE"
        /usr/bin/perl -e '
            open(my $fh, "<", $ARGV[0]) or exit;
            my $buf; read($fh, $buf, 131072);
            print defined $buf ? $buf : "";
        ' "$candidate" >> "$SCAN_FILE" 2>/dev/null || true
        printf '\n' >> "$SCAN_FILE"
    fi
done

# ── Helpers (no grep / sed / awk) ────────────────────────────────────────────
fp_in_file() {
    /usr/bin/perl -e '
        my ($fp, $file) = @ARGV;
        open(my $fh, "<", $file) or exit 1;
        while (my $line = <$fh>) { chomp $line; exit 0 if $line eq $fp; }
        exit 1;
    ' "$1" "$2" 2>/dev/null
}

record_fp() {
    local fp="$1" file="$2"
    local dir
    dir=$(/usr/bin/perl -e 'use File::Basename qw(dirname); print dirname($ARGV[0])' "$file")
    /bin/mkdir -p "$dir" 2>/dev/null || true
    /usr/bin/touch "$file" 2>/dev/null || true
    fp_in_file "$fp" "$file" 2>/dev/null || printf '%s\n' "$fp" >> "$file"
}

show_dialog() {
    local msg
    msg=$(/usr/bin/perl -e '
        my $v = $ARGV[0];
        $v =~ s/\\/\\\\/g; $v =~ s/"/\\"/g; $v =~ s/\n/\\n/g;
        print $v;
    ' "$1")
    /usr/bin/osascript \
        -e "button returned of (display dialog \"$msg\" buttons {\"Deny\", \"Allow Session\", \"Always Allow\"} default button \"Deny\" with icon caution)" \
        2>/dev/null || true
}

# ── Payload pattern scan ──────────────────────────────────────────────────────
check_payload_patterns() {
    [ "$PAYLOAD_PROTECTION" = "1" ] || return 0
    [ -n "$PATTERNS_FILE" ] && [ -f "$PATTERNS_FILE" ] || return 0

    local matched
    matched=$(/usr/bin/perl -e '
use strict; use warnings;
my ($scan_f, $pat_f) = @ARGV;
open(my $sf, "<", $scan_f) or exit 0;
local $/; my $data = <$sf>; close($sf);
open(my $pf, "<", $pat_f) or exit 0;
my @lines = <$pf>; close($pf);
my @hit;
for my $line (@lines) {
    chomp $line;
    my ($name, $regex) = split(/\t/, $line, 2);
    next unless defined $name && length($name) && defined $regex && length($regex);
    eval { push @hit, $name if $data =~ /$regex/im };
}
print join("\n", @hit), "\n" if @hit;
' "$SCAN_FILE" "$PATTERNS_FILE" 2>/dev/null || true)

    [ -n "$matched" ] || return 0

    local fp
    fp=$(/usr/bin/shasum -a 256 "$SCAN_FILE" | /usr/bin/perl -lane 'print $F[0]')
    /usr/bin/touch "$ALLOWLIST_FILE" "$SESSION_ALLOWLIST_FILE" 2>/dev/null || true
    fp_in_file "$fp" "$ALLOWLIST_FILE" && return 0
    fp_in_file "$fp" "$SESSION_ALLOWLIST_FILE" && return 0

    local msg button
    msg=$(printf 'FocusShield detected sensitive patterns in data accessed by %s:\n\n%s\n\nAllow this request?' \
        "$TOOL_NAME" "$matched")
    button=$(show_dialog "$msg")
    case "$button" in
        "Allow Session") record_fp "$fp" "$SESSION_ALLOWLIST_FILE" ;;
        "Always Allow")  record_fp "$fp" "$ALLOWLIST_FILE" ;;
        *)
            echo "focusshield: request denied — sensitive payload patterns detected in $TOOL_NAME." >&2
            return 1 ;;
    esac
}

# ── Invisible character scan ──────────────────────────────────────────────────
check_invisible_chars() {
    [ "$CHARSCAN_ENABLED" = "1" ] || return 0
    local checks=""
    [ "$CHARSCAN_ZWSP"      = "1" ] && checks="${checks}zwsp,"
    [ "$CHARSCAN_RTL"       = "1" ] && checks="${checks}rtl,"
    [ "$CHARSCAN_TAGS"      = "1" ] && checks="${checks}tags,"
    [ "$CHARSCAN_INVIS"     = "1" ] && checks="${checks}invis,"
    [ "$CHARSCAN_HOMOGLYPH" = "1" ] && checks="${checks}homoglyph,"
    [ -n "$checks" ] || return 0

    local hits
    hits=$(/usr/bin/perl -e '
use strict; use warnings;
my @checks = split(/,/, $ARGV[0] // "");
open(my $fh, "<:utf8", $ARGV[1]) or exit 0;
local $/; my $data = <$fh> // ""; close($fh);
my %found;
for my $c (@checks) {
    if    ($c eq "zwsp")      { $found{$c}++ if $data =~ /[\x{200B}\x{200C}\x{200D}\x{FEFF}\x{2060}\x{FFFC}]/ }
    elsif ($c eq "rtl")       { $found{$c}++ if $data =~ /[\x{202A}-\x{202E}\x{2066}-\x{2069}]/ }
    elsif ($c eq "tags")      { $found{$c}++ if $data =~ /[\x{E0001}-\x{E007F}]/ }
    elsif ($c eq "invis")     { $found{$c}++ if $data =~ /[\x{00AD}\x{115F}\x{1160}\x{3164}\x{17B4}\x{17B5}\x{FE00}-\x{FE0F}]/ }
    elsif ($c eq "homoglyph") { $found{$c}++ if $data =~ /[\x{0430}-\x{0435}\x{043E}\x{0440}\x{0441}\x{0445}\x{03BF}\x{03B1}]/ }
}
print join("\n", keys %found), "\n" if %found;
' "$checks" "$SCAN_FILE" 2>/dev/null || true)

    [ -n "$hits" ] || return 0

    local fp
    fp=$(printf 'charscan\n'; /usr/bin/shasum -a 256 "$SCAN_FILE")
    fp=$(printf '%s' "$fp" | /usr/bin/shasum -a 256 | /usr/bin/perl -lane 'print $F[0]')
    /usr/bin/touch "$ALLOWLIST_FILE" "$SESSION_ALLOWLIST_FILE" 2>/dev/null || true
    fp_in_file "$fp" "$ALLOWLIST_FILE" && return 0
    fp_in_file "$fp" "$SESSION_ALLOWLIST_FILE" && return 0

    local labels
    labels=$(/usr/bin/perl -e '
my %map = (
    zwsp=>"Zero-Width Characters", rtl=>"RTL Override/Embedding",
    tags=>"Invisible Tag Characters (prompt-injection risk)",
    invis=>"Invisible Format Characters", homoglyph=>"Unicode Homoglyphs",
);
my @out; for my $k (split /\n/, $ARGV[0]) { push @out, $map{$k} if $map{$k}; }
print join("\n", @out), "\n";
' "$hits")

    local msg button
    msg=$(printf 'FocusShield detected suspicious Unicode in data accessed by %s:\n\n%s\n\nAllow this request?' \
        "$TOOL_NAME" "$labels")
    button=$(show_dialog "$msg")
    case "$button" in
        "Allow Session") record_fp "$fp" "$SESSION_ALLOWLIST_FILE" ;;
        "Always Allow")  record_fp "$fp" "$ALLOWLIST_FILE" ;;
        *)
            echo "focusshield: request denied — invisible/bad Unicode detected in $TOOL_NAME." >&2
            return 1 ;;
    esac
}

# ── Run checks ────────────────────────────────────────────────────────────────
check_payload_patterns
check_invisible_chars

# ── Exec real tool (replay buffered stdin if captured) ───────────────────────
seatbelt_exec() {
    if [ -n "$SEATBELT_PROFILE" ] && [ -f "$SEATBELT_PROFILE" ] && [ -x /usr/bin/sandbox-exec ]; then
        exec /usr/bin/sandbox-exec -f "$SEATBELT_PROFILE" -D _HOME="$HOME" -D _CWD="$PWD" "$@"
    fi
    exec "$@"
}

if [ -n "$STDIN_FILE" ] && [ -f "$STDIN_FILE" ]; then
    seatbelt_exec "$REAL_EXEC" "$@" < "$STDIN_FILE"
fi
seatbelt_exec "$REAL_EXEC" "$@"
