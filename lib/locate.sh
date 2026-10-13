#!/bin/bash
# locate.sh -- find a report bundle by name anywhere on the machine.
#
# "Scan the filesystem" is the requirement, but a bare `find / -name X` on
# macOS is a bad implementation of it:
#
#   * TCC (privacy protection) makes find spew hundreds of "Operation not
#     permitted" lines for ~/Library/Mail, Photos, Messages and friends.
#   * The APFS firmlink layout means / and /System/Volumes/Data are the same
#     storage, so every hit is found twice under two different paths.
#   * Mounted Time Machine / network volumes under /Volumes turn a 2-second
#     search into a multi-minute one.
#   * /private/var/folders holds per-process temp dirs full of noise.
#
# So the search is tiered, cheapest first, and stops at the first tier that
# produces a hit:
#
#   0  the argument is already a usable path
#   1  obvious locations (cwd, Downloads, Desktop, Documents, /tmp)
#   2  Spotlight via mdfind -- effectively instant when the index is warm
#   3  find under $HOME, pruned
#   4  find under /, pruned
#
# Tier 4 is only reached when the file genuinely is somewhere unusual.

# Directories that are never worth descending into.
_prune_args() {
  printf '%s' \
    "-name .Spotlight-V100 -o -name .fseventsd -o -name .DocumentRevisions-V100 \
     -o -name .TemporaryItems -o -name .Trash -o -name node_modules \
     -o -name .git -o -name Caches"
}

# Absolute path without readlink -f, which BSD does not provide.
_abspath() {
  _ap_d=$(dirname "$1")
  _ap_b=$(basename "$1")
  _ap_p=$(cd "$_ap_d" 2>/dev/null && pwd) || return 1
  printf '%s/%s' "$_ap_p" "$_ap_b"
}

# Append a hit to the results file unless an equivalent path is already there.
# Normalizes the APFS firmlink alias so /X and /System/Volumes/Data/X are
# recognized as the same file rather than offered to the user twice.
_add_hit() {
  _ah_p=$1
  [ -f "$_ah_p" ] || return 0
  _ah_abs=$(_abspath "$_ah_p") || return 0
  _ah_norm=$_ah_abs
  case "$_ah_norm" in
    /System/Volumes/Data/*) _ah_norm="/${_ah_norm#/System/Volumes/Data/}" ;;
  esac
  grep -q -x -F "$_ah_norm" "$HITS" 2>/dev/null && return 0
  printf '%s\n' "$_ah_norm" >> "$HITS"
}

_tier_direct() {
  _add_hit "$1"
}

_tier_common() {
  _tc_base=$1
  for d in \
    "$PWD" \
    "$HOME/Downloads" \
    "$HOME/Desktop" \
    "$HOME/Documents" \
    "$HOME" \
    "/tmp" \
    "/var/tmp"
  do
    [ -d "$d" ] || continue
    _add_hit "$d/$_tc_base"
  done
}

_tier_spotlight() {
  _ts_base=$1
  have mdfind || return 0
  # -name does a filename substring match; filter to exact basename so
  # "report.tar.gz" does not also return "report.tar.gz.partial".
  mdfind -name "$_ts_base" 2>/dev/null | while IFS= read -r p; do
    [ "$(basename "$p")" = "$_ts_base" ] && printf '%s\n' "$p"
  done | while IFS= read -r p; do
    _add_hit "$p"
  done
}

_tier_find() {
  # _tier_find <root> <basename>
  _tf_root=$1
  _tf_base=$2
  [ -d "$_tf_root" ] || return 0

  # stderr is discarded wholesale: on macOS it is almost entirely TCC
  # "Operation not permitted" noise, which is expected and not actionable.
  find "$_tf_root" \
    \( $(_prune_args) \) -prune -o \
    -type f -name "$_tf_base" -print 2>/dev/null \
  | while IFS= read -r p; do
      _add_hit "$p"
    done
}

_tier_find_root() {
  _tr_base=$1
  find / \
    \( -path /System -o -path /Volumes -o -path /dev -o -path /net \
       -o -path /private/var/folders -o -path /private/var/db \
       -o $(_prune_args) \) -prune -o \
    -type f -name "$_tr_base" -print 2>/dev/null \
  | while IFS= read -r p; do
      _add_hit "$p"
    done
}

# ---------------------------------------------------------------------------

locate_report() {
  # locate_report <name-or-path>
  # Prints the chosen absolute path on stdout. Returns 1 if nothing matched.
  _lr_arg=$1
  _lr_base=$(basename "$_lr_arg")

  HITS="${TMPDIR:-/tmp}/k8shelp.hits.$$"
  : > "$HITS"
  # shellcheck disable=SC2064
  trap 'rm -f "$HITS"' EXIT INT TERM

  # Tier 0 -- already a path we can open.
  _tier_direct "$_lr_arg"
  _lr_n=$(wc -l < "$HITS" | tr -d ' ')

  # Tier 1 -- the handful of places a downloaded report actually lives.
  if [ "$_lr_n" -eq 0 ]; then
    _tier_common "$_lr_base"
    _lr_n=$(wc -l < "$HITS" | tr -d ' ')
  fi

  # Tier 2 -- Spotlight.
  if [ "$_lr_n" -eq 0 ] && have mdfind; then
    info "searching Spotlight index..."
    _tier_spotlight "$_lr_base"
    _lr_n=$(wc -l < "$HITS" | tr -d ' ')
  fi

  # Tier 3 -- walk the home directory.
  if [ "$_lr_n" -eq 0 ]; then
    info "searching $HOME (ctrl-c to stop)..."
    _tier_find "$HOME" "$_lr_base"
    _lr_n=$(wc -l < "$HITS" | tr -d ' ')
  fi

  # Tier 4 -- walk the whole volume.
  if [ "$_lr_n" -eq 0 ]; then
    info "searching / (this can take a while; ctrl-c to stop)..."
    _tier_find_root "$_lr_base"
    _lr_n=$(wc -l < "$HITS" | tr -d ' ')
  fi

  if [ "$_lr_n" -eq 0 ]; then
    rm -f "$HITS"
    return 1
  fi

  if [ "$_lr_n" -eq 1 ]; then
    cat "$HITS"
    rm -f "$HITS"
    return 0
  fi

  # More than one file with that name. Never silently guess -- picking the
  # wrong customer's report is worse than asking.
  if [ ! -t 0 ]; then
    warn "$_lr_n files named '$_lr_base' found; using the first (not a tty)"
    sed -n '1p' "$HITS"
    rm -f "$HITS"
    return 0
  fi

  printf '%sfound %s files named %s:%s\n' "$C_YEL" "$_lr_n" "$_lr_base" "$C_RST" >&2
  _lr_i=0
  while IFS= read -r p; do
    _lr_i=$((_lr_i + 1))
    printf '  %s%2d%s  %s  %s(%s bytes)%s\n' \
      "$C_B" "$_lr_i" "$C_RST" "$p" "$C_DIM" "$(fsize "$p")" "$C_RST" >&2
  done < "$HITS"

  printf '%s' "select [1-$_lr_n]: " >&2
  read -r _lr_sel
  case "$_lr_sel" in
    ''|*[!0-9]*) rm -f "$HITS"; die "not a number: $_lr_sel" ;;
  esac
  if [ "$_lr_sel" -lt 1 ] || [ "$_lr_sel" -gt "$_lr_n" ]; then
    rm -f "$HITS"; die "out of range: $_lr_sel"
  fi
  sed -n "${_lr_sel}p" "$HITS"
  rm -f "$HITS"
  return 0
}
