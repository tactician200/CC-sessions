#!/usr/bin/env bash
# Personal-data gate for the public export. Fails (exit 1) on any hit.
#
#   scripts/pii-gate.sh <dir> [--images]      source tree: denylist + patterns (+ image metadata/OCR)
#   scripts/pii-gate.sh --binary <App.app>    built app: denylist + /Users/ + self-tests in strings/Info.plist
#   --patterns-only                           no denylist (CI): print hit COUNTS only, never matches
#
# The denylist is private and never lives in this repo: pass it as PII_DENYLIST=<file>
# (one term per line, '#' comments, case-insensitive whole-word match). Private ids such as
# an old bundle-id prefix belong in the denylist too, not in this public script.
# A line containing "pii-gate:allow" is exempt from the id/date patterns (not from the denylist).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: $0 <dir> [--images] [--patterns-only] | --binary <App.app> [--patterns-only]" >&2; exit 2; }

target="" binary="" images=0 patterns_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --binary) binary="${2:-}"; shift 2 ;;
        --images) images=1; shift ;;
        --patterns-only) patterns_only=1; shift ;;
        -h|--help) usage ;;
        *) [ -z "$target" ] || usage; target="$1"; shift ;;
    esac
done
[ -n "$target" ] || [ -n "$binary" ] || usage

terms=""
if [ "$patterns_only" -eq 0 ]; then
    [ -n "${PII_DENYLIST:-}" ] && [ -f "$PII_DENYLIST" ] || { echo "pii-gate: set PII_DENYLIST=<file> (or --patterns-only)" >&2; exit 2; }
    terms="$(mktemp)"
    grep -v '^[[:space:]]*#' "$PII_DENYLIST" | sed '/^[[:space:]]*$/d' > "$terms"
    trap 'rm -f "$terms"' EXIT
fi

hits=0
# report <check> <output>: counts lines; prints them only when not in --patterns-only mode.
report() {
    local name="$1" out="$2" n
    n=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
        hits=$((hits + n))
        echo "FAIL $name: $n hit(s)"
        [ "$patterns_only" -eq 1 ] || printf '%s\n' "$out" | sed '/^$/d' | head -50 | sed 's/^/    /'
    else
        echo "ok   $name"
    fi
}

if [ -n "$binary" ]; then
    exe="$binary/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$binary/Contents/Info.plist" 2>/dev/null)"
    [ -f "$exe" ] || { echo "pii-gate: no executable in $binary" >&2; exit 2; }
    strs="$(mktemp)"; strings -a "$exe" > "$strs"; plutil -convert xml1 -o - "$binary/Contents/Info.plist" >> "$strs"
    find "$binary" -type f \( -name '*.strings' -o -name '*.plist' -o -name '*.json' \) -exec cat {} + >> "$strs" 2>/dev/null
    [ "$patterns_only" -eq 1 ] || report "binary: denylist" "$(grep -niwI -f "$terms" "$strs")"
    report "binary: /Users/ paths" "$(grep -n '/Users/' "$strs")"
    report "binary: self-tests compiled in" "$(grep -n -- '-selftest' "$strs")"
    rm -f "$strs"
fi

if [ -n "$target" ]; then
    cd "$target" || exit 2
    if git rev-parse --git-dir >/dev/null 2>&1; then files="$(git ls-files)"; else files="$(find . -type f ! -path './.git/*' | sed 's|^\./||')"; fi
    filelist="$(mktemp)"; printf '%s\n' "$files" > "$filelist"

    [ "$patterns_only" -eq 1 ] || report "text: denylist" "$(tr '\n' '\0' < "$filelist" | xargs -0 grep -niwI -f "$terms" 2>/dev/null)"
    [ "$patterns_only" -eq 1 ] || report "file names: denylist" "$(grep -niw -f "$terms" "$filelist")"

    # Patterns, source text only (this script and fixtures marked pii-gate:allow are exempt).
    scan() { tr '\n' '\0' < "$filelist" | xargs -0 grep -nIE "$@" 2>/dev/null | grep -v 'pii-gate:allow' | grep -v '^scripts/pii-gate.sh:'; }
    nontest() { grep -vE '^(tests/|plugin/tests/|docs/demo-sessions/)|SelfTest[^:]*\.swift:'; }
    report "operator wording" "$(scan -i '\boperador\b|\boperator\b')"
    report "home paths" "$(tr '\n' '\0' < "$filelist" | xargs -0 perl -ne 'print "$ARGV:$.: $_" if m{/Users/(?!alex\b|runner\b|x/|you\b|<)}; close ARGV if eof' 2>/dev/null | grep -v 'pii-gate:allow' | grep -v '^scripts/pii-gate.sh:')"
    report "emails" "$(scan '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | grep -vE 'noreply@(github\.com|anthropic\.com)|users\.noreply\.github\.com|@example\.(com|org)')"
    report "session-id-like UUIDs outside fixtures" "$(scan '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | nontest)"
    report "short session ids outside fixtures" "$(scan '(^|[^0-9A-Za-z-])[0-9a-f]{8}([^0-9A-Za-z-]|$)' | grep -E '[0-9]' | grep -E '[a-f]' | nontest)"
    report "dated comments" "$(scan '(^|[[:space:]])(//|#|/\*|\*)([[:space:]]|$).*20[0-9]{2}-[01][0-9]-[0-3][0-9]' | grep -v '^LICENSE')"

    if [ "$images" -eq 1 ]; then
        imgs="$(grep -iE '\.(png|jpe?g|gif|webp|heic|tiff?)$' "$filelist")"
        if [ -n "$imgs" ]; then
            # Metadata: any text/EXIF/XMP chunk in PNG, comment/XMP in GIF, EXIF/XMP in JPEG.
            meta="$(printf '%s\n' "$imgs" | /usr/bin/env python3 -c '
import sys
for p in sys.stdin.read().split("\n"):
    if not p: continue
    b = open(p, "rb").read()
    found = []
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        i = 8
        while i + 8 <= len(b):
            n = int.from_bytes(b[i:i+4], "big"); t = b[i+4:i+8]
            if t in (b"tEXt", b"iTXt", b"zTXt", b"eXIf", b"iCCP", b"tIME"): found.append(t.decode())
            i += 12 + n
    elif b[:3] == b"GIF":
        if b"\x21\xfe" in b: found.append("comment")
        if b"XMP DataXMP" in b: found.append("XMP")
    elif b[:2] == b"\xff\xd8":
        if b"Exif\x00\x00" in b: found.append("EXIF")
        if b"http://ns.adobe.com/xap" in b: found.append("XMP")
    if found: print(p + ": " + ",".join(sorted(set(found))))
')"
            report "images: metadata" "$meta"
            if [ "$patterns_only" -eq 0 ]; then
                ocr_script="${OCR_SCRIPT:-$here/ocr.swift}"
                ocr="$(printf '%s\n' "$imgs" | tr '\n' '\0' | xargs -0 swift "$ocr_script" 2>&1)" || { echo "FAIL images: OCR could not run"; hits=$((hits + 1)); }
                report "images: denylist in OCR text" "$(printf '%s\n' "$ocr" | grep -iw -f "$terms")"
                report "images: paths/emails in OCR text" "$(printf '%s\n' "$ocr" | grep -E '/Users/[A-Za-z]|@[A-Za-z0-9-]+\.[A-Za-z]{2,}' | grep -vE '/Users/alex\b')"
            fi
        else
            echo "ok   images: none"
        fi
    fi

    if command -v gitleaks >/dev/null 2>&1; then
        gitleaks dir --no-banner --redact . >/dev/null 2>&1 && echo "ok   gitleaks" || { echo "FAIL gitleaks (run: gitleaks dir --redact $target)"; hits=$((hits + 1)); }
    else
        echo "skip gitleaks (not installed)"
    fi
    rm -f "$filelist"
fi

echo "pii-gate: $hits hit(s)"
[ "$hits" -eq 0 ]
