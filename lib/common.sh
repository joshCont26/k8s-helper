#!/bin/bash
# common.sh -- portability layer and shared helpers.
#
# TARGET: macOS /bin/bash 3.2.57 + BSD userland.
# Hard rules enforced throughout this codebase:
#   - no `declare -A`            (bash 4+)
#   - no `mapfile` / `readarray` (bash 4+)
#   - no `${var^^}` / `${var,,}` (bash 4+)
#   - no `grep -P`               (GNU only)
#   - no `\s` `\d` `\w` in sed/awk regex (GNU only; use [[:space:]] etc.)
#   - no `sed -r`                (use -E, portable on both)
#   - no `sed -i` without arg    (BSD requires a suffix)
#   - no `stat -c`               (BSD is -f; we use `wc -c` instead)
#   - no `date -d`               (GNU only; we compare RFC3339 lexically)
#   - no `readlink -f`           (BSD lacks it pre-12)
#   - no `sort -V`               (unreliable)

set -u

# ---------------------------------------------------------------- environment

K8SDIAG_VERSION="0.1.0"

# Force byte-wise collation. On macOS the default UTF-8 locale makes
# ranges like [a-z] behave unexpectedly and makes grep choke on the
# ANSI escape sequences embedded in several container logs.
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------- tty / color

if [ -t 1 ] && [ "${K8SDIAG_NO_COLOR:-0}" != "1" ]; then
  C_RST=$'\033[0m'
  C_DIM=$'\033[2m'
  C_B=$'\033[1m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'
  C_CYN=$'\033[36m'
else
  C_RST=''; C_DIM=''; C_B=''
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''
fi

# ---------------------------------------------------------------- diagnostics

die()  { printf '%s\n' "${C_RED}error:${C_RST} $*" >&2; exit 1; }
warn() { printf '%s\n' "${C_YEL}warn:${C_RST} $*" >&2; }
info() { printf '%s\n' "${C_DIM}$*${C_RST}" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- portability

# Byte size of a file without stat(1). BSD stat is -f, GNU is -c; wc is both.
fsize() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# Line count without the filename column that BSD wc prints.
flines() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

# A pager that degrades to cat. macOS always has `less`, but a tool that
# assumes it will break the moment someone runs this in a stripped container.
page() {
  if [ -t 1 ] && have less; then
    less -R -X -F
  elif [ -t 1 ] && have more; then
    more
  else
    cat
  fi
}

# Like page(), but never auto-exits. For viewers inside a redraw loop: with
# -F, output that fits on one screen makes less quit immediately, and the
# caller's next cls wipes it before it can be read.
page_hold() {
  if [ -t 1 ] && have less; then
    less -R -X
  elif [ -t 1 ] && have more; then
    more
  else
    cat
  fi
}

# Portable in-place edit is avoided entirely; we always write to a temp
# file and mv. This helper exists so callers never reach for `sed -i`.
atomic_write() {
  # atomic_write <dest>   -- content on stdin
  _aw_dest=$1
  _aw_tmp="${_aw_dest}.tmp.$$"
  cat > "$_aw_tmp" || return 1
  mv -f "$_aw_tmp" "$_aw_dest"
}

# ---------------------------------------------------------------- tsv helpers

TAB=$'\t'

# Print a TSV file as aligned columns. `column -t -s` is not reliable on
# macOS for tab-separated input with empty fields, so we do it in awk.
tsv_table() {
  # tsv_table [file]   -- reads stdin if no file
  # NOTE: built with manual padding rather than sprintf("%-*s"). The dynamic
  # field-width `*` is a GNU awk extension; the one-true-awk shipped as
  # /usr/bin/awk on macOS does not reliably honour it.
  awk -F'\t' '
    function pad(s, n,   r) {
      r = s
      while (length(r) < n) r = r " "
      return r
    }
    { for (i = 1; i <= NF; i++) {
        row[NR, i] = $i
        if (length($i) > w[i]) w[i] = length($i)
      }
      if (NF > maxf) maxf = NF
      n = NR
    }
    END {
      for (r = 1; r <= n; r++) {
        line = ""
        for (i = 1; i <= maxf; i++) {
          cell = row[r, i]
          if (i < maxf) line = line pad(cell, w[i]) "  "
          else          line = line cell
        }
        sub(/[ ]+$/, "", line)
        print line
      }
    }
  ' "$@"
}

# Print TSV as a bordered table; the first line is the header row.
# Borders are plain ASCII on purpose: with LC_ALL=C exported, less(1)
# renders UTF-8 box-drawing bytes as <E2><94><80> escapes.
tsv_box() {
  # tsv_box [file]   -- reads stdin if no file
  awk -F'\t' '
    function pad(s, n,   r) {
      r = s
      while (length(r) < n) r = r " "
      return r
    }
    function rep(n,   s) {
      s = ""
      while (n-- > 0) s = s "-"
      return s
    }
    function rule(l, m, r,   i, s) {
      s = l
      for (i = 1; i <= maxf; i++) s = s rep(w[i] + 2) (i < maxf ? m : r)
      return s
    }
    { for (i = 1; i <= NF; i++) {
        row[NR, i] = $i
        if (length($i) > w[i]) w[i] = length($i)
      }
      if (NF > maxf) maxf = NF
      n = NR
    }
    END {
      if (n == 0) exit
      print rule("+", "+", "+")
      for (r = 1; r <= n; r++) {
        line = "|"
        for (i = 1; i <= maxf; i++) line = line " " pad(row[r, i], w[i]) " |"
        print line
        if (r == 1 && n > 1) print rule("+", "+", "+")
      }
      print rule("+", "+", "+")
    }
  ' "$@"
}

# Look up a single value from a key<TAB>value file.
fact() {
  # fact <facts.tsv> <key>
  awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null
}
