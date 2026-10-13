#!/bin/bash
# menu.sh -- interactive navigation.
#
# Navigation model is drill-down:  pod  ->  container  ->  log actions
#
# Every list uses the same picker, so the key bindings are identical
# everywhere:  a number selects, "/text" filters, "b" goes back, "q" quits.
#
# bash 3.2 has no associative arrays, so selection state is carried in
# index-aligned temp files rather than name->value maps.

MENU_TMP=""

menu_cleanup() { [ -n "$MENU_TMP" ] && rm -rf "$MENU_TMP"; }

menu_init() {
  MENU_TMP="${TMPDIR:-/tmp}/k8shelp.menu.$$"
  mkdir -p "$MENU_TMP" || die "cannot create $MENU_TMP"
  trap 'menu_cleanup; exit 130' INT TERM
  trap 'menu_cleanup' EXIT
}

cls() {
  [ -t 1 ] || return 0
  # tput is present on macOS, but fall back to raw ANSI so this still works
  # over a dumb TERM or inside a CI capture.
  if have tput && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
    tput clear 2>/dev/null && return 0
  fi
  printf '\033[2J\033[H'
}

bar() { printf '%s%s%s\n' "$C_DIM" \
  "--------------------------------------------------------------------------" \
  "$C_RST"; }

crumb() {
  printf '%s%s%s\n' "$C_CYN$C_B" "$*" "$C_RST"
  bar
}

pause() {
  [ -t 0 ] || return 0
  printf '\n%s[enter to continue]%s ' "$C_DIM" "$C_RST"
  read -r _ || true
}

# ---------------------------------------------------------------- the picker

# colw <file> <field> <header>
#
# Display width for one TSV column: the longest value, or the header if that
# is longer. Pickers bake these into their printf formats, because the
# dynamic "%-*s" width is not reliable in macOS awk (see tsv_table).
colw() {
  awk -F'\t' -v f="$2" -v h="$3" '
    BEGIN { w = length(h) }
    length($f) > w { w = length($f) }
    END { print w }
  ' "$1"
}

# pick <datafile> <awk-display-program> <title> [header]
#
# Renders one numbered row per line of <datafile> using the awk program,
# then returns the chosen RAW line in PICK. The awk program is given the
# raw TSV fields and must print the display text. [header] is printed
# above the rows, aligned past the number gutter; build it with the same
# format string as the display program so the columns line up.
#
# returns 0 = selected (PICK set), 1 = back, 2 = quit
PICK=""
pick() {
  _pk_data=$1
  _pk_disp=$2
  _pk_title=$3
  _pk_hdr=${4:-}
  _pk_filter=""

  while :; do
    _pk_view="$MENU_TMP/view"
    if [ -n "$_pk_filter" ]; then
      grep -i -- "$_pk_filter" "$_pk_data" > "$_pk_view" 2>/dev/null || : > "$_pk_view"
    else
      cp "$_pk_data" "$_pk_view"
    fi
    _pk_n=$(flines "$_pk_view")

    cls
    crumb "$_pk_title"
    if [ -n "$_pk_filter" ]; then
      printf '%sfilter: %s%s  (%s match)%s\n\n' \
        "$C_YEL" "$_pk_filter" "$C_RST" "$_pk_n" ""
    fi

    if [ "$_pk_n" -eq 0 ]; then
      printf '  %sno matches%s\n' "$C_DIM" "$C_RST"
    else
      # Same gutter as the rows below: "  %3d  ".
      [ -n "$_pk_hdr" ] && printf '  %s%3s  %s%s\n' "$C_B" "#" "$_pk_hdr" "$C_RST"
      awk -F'\t' -v prog=1 "$_pk_disp" "$_pk_view" \
        | awk -v b="$C_B" -v x="$C_RST" \
            '{ printf "  %s%3d%s  %s\n", b, NR, x, $0 }'
    fi

    printf '\n%s[number] select   /text filter   b back   q quit%s\n' \
      "$C_DIM" "$C_RST"
    printf '> '
    read -r _pk_in || { PICK=""; return 2; }

    case "$_pk_in" in
      q|Q)  PICK=""; return 2 ;;
      b|B)  PICK=""; return 1 ;;
      "")   continue ;;
      /)    _pk_filter="" ; continue ;;
      /*)   _pk_filter=${_pk_in#/} ; continue ;;
      *[!0-9]*) continue ;;
      *)
        if [ "$_pk_in" -ge 1 ] 2>/dev/null && [ "$_pk_in" -le "$_pk_n" ]; then
          PICK=$(sed -n "${_pk_in}p" "$_pk_view")
          return 0
        fi
        ;;
    esac
  done
}

# ------------------------------------------------------------------ log view

# Severity-highlighting pager. grep --color exists on BSD grep but is not
# universal, so probe once rather than assume.
_color_grep() {
  if [ -n "$C_RED" ] && printf 'x\n' | grep --color=always x >/dev/null 2>&1; then
    grep -a -E --color=always -e "$ERR_RE" -e "$WARN_RE" -e '^' 
  else
    cat
  fi
}

# Page a result set, or say plainly that there was nothing.
#
# Writing to a temp file first is deliberate: `grep ... | page || msg` binds
# the || to page, which succeeds on empty input, so the "no match" branch is
# unreachable. Checking grep's own status is also not enough, because the
# exit code has to survive the pipe.
page_result() {
  # page_result <file> <message-when-empty>
  if [ -s "$1" ]; then
    page_hold < "$1"
  else
    printf '%s%s%s\n' "$C_YEL" "$2" "$C_RST"
    pause
  fi
}

log_actions() {
  # log_actions <ns> <pod> <container>
  _la_ns=$1; _la_pod=$2; _la_con=$3
  _la_kind="current"

  while :; do
    _la_row=$(awk -F'\t' -v n="$_la_ns" -v p="$_la_pod" -v c="$_la_con" \
                  -v k="$_la_kind" \
      '$1==n && $2==p && $3==c && $4==k' "$IDX/logs.tsv")

    if [ -z "$_la_row" ]; then
      warn "no $_la_kind log for $_la_con"
      _la_kind="current"
      pause
      return 0
    fi

    _la_bytes=$(printf '%s' "$_la_row" | cut -f5)
    _la_lines=$(printf '%s' "$_la_row" | cut -f6)
    _la_err=$(printf '%s'   "$_la_row" | cut -f7)
    _la_warn=$(printf '%s'  "$_la_row" | cut -f8)
    _la_path=$(printf '%s'  "$_la_row" | cut -f9)

    _la_other="prev"; [ "$_la_kind" = "prev" ] && _la_other="current"
    _la_has_other=$(awk -F'\t' -v n="$_la_ns" -v p="$_la_pod" -v c="$_la_con" \
                        -v k="$_la_other" '$1==n && $2==p && $3==c && $4==k' \
                        "$IDX/logs.tsv")

    cls
    crumb "$_la_pod / $_la_con"
    printf '  instance : %s%s%s\n' "$C_B" "$_la_kind" "$C_RST"
    printf '  size     : %s bytes, %s lines\n' "$_la_bytes" "$_la_lines"
    if [ "${_la_err:-0}" -gt 0 ] 2>/dev/null; then
      printf '  severity : %s%s error%s / %s warn\n' "$C_RED" "$_la_err" "$C_RST" "$_la_warn"
    else
      printf '  severity : %s error / %s warn\n' "${_la_err:-0}" "${_la_warn:-0}"
    fi
    printf '  path     : %s%s%s\n' "$C_DIM" "$_la_path" "$C_RST"
    bar

    if [ "${_la_bytes:-0}" -eq 0 ] 2>/dev/null; then
      printf '  %s(this log is empty)%s\n' "$C_DIM" "$C_RST"
    fi

    cat <<EOF
   1  view whole log
   2  last 100 lines
   3  first 100 lines
   4  errors only
   5  errors + warnings
   6  search (case-insensitive, with context)
   7  switch to '$_la_other' instance
   8  events for this pod
   b  back        q  quit
EOF
    printf '> '
    read -r _la_in || return 2

    case "$_la_in" in
      1) _color_grep < "$_la_path" | page_hold ;;
      2) tail -n 100 "$_la_path" | _color_grep | page_hold ;;
      3) head -n 100 "$_la_path" | _color_grep | page_hold ;;
      4) grep -a -n -E "$ERR_RE" "$_la_path" > "$MENU_TMP/res" 2>/dev/null
         page_result "$MENU_TMP/res" "no error lines in this log" ;;
      5) grep -a -n -E -e "$ERR_RE" -e "$WARN_RE" "$_la_path" \
           > "$MENU_TMP/res" 2>/dev/null
         page_result "$MENU_TMP/res" "no error or warning lines in this log" ;;
      6) printf 'pattern: '
         read -r _la_pat || continue
         [ -n "$_la_pat" ] || continue
         # -F so the pattern is a literal string the user does not have to
         # escape. Context lines make a hit in a 20k-line log actionable.
         grep -a -n -i -F -C 3 -- "$_la_pat" "$_la_path" \
           > "$MENU_TMP/res" 2>/dev/null
         page_result "$MENU_TMP/res" "no match for: $_la_pat" ;;
      7) if [ -n "$_la_has_other" ]; then _la_kind=$_la_other
         else warn "no '$_la_other' instance for this container"; pause; fi ;;
      8) show_pod_events "$_la_ns" "$_la_pod"; pause ;;
      b|B) return 0 ;;
      q|Q) return 2 ;;
    esac
  done
}

# ------------------------------------------------------------- pod drill-down

show_pod_events() {
  _spe_ns=$1; _spe_pod=$2
  printf '\n%sEVENTS for %s%s\n' "$C_CYN$C_B" "$_spe_pod" "$C_RST"
  _spe_rows=$(awk -F'\t' -v n="$_spe_ns" -v p="$_spe_pod" \
    'BEGIN{OFS="\t"} $5==n && $6==p { print $1, $2, $3, substr($8,1,90) }' \
    "$IDX/events.tsv")
  if [ -z "$_spe_rows" ]; then
    printf '  %snone%s\n' "$C_DIM" "$C_RST"
    return 0
  fi
  printf '%s\n' "$_spe_rows" | tsv_table | sed 's/^/  /'
}

container_menu() {
  # container_menu <ns> <pod>
  _cm_ns=$1; _cm_pod=$2

  while :; do
    # Containers that actually have a log file. The describe file only
    # covers the default namespace, so logs.tsv is the authoritative list
    # of what is browsable -- driving this off containers.tsv would hide
    # every kube-system container.
    _cm_f="$MENU_TMP/containers"
    awk -F'\t' -v n="$_cm_ns" -v p="$_cm_pod" '
      BEGIN { OFS = "\t" }
      $1==n && $2==p {
        key = $3
        if (!(key in seen)) { seen[key] = 1; order[++k] = key }
        if ($4 == "current") { cur[key] = $5; cerr[key] = $7; cwarn[key] = $8 }
        else                 { prv[key] = $5 }
      }
      END {
        for (i = 1; i <= k; i++) {
          c = order[i]
          print c, cur[c] + 0, cerr[c] + 0, cwarn[c] + 0, (c in prv ? "yes" : "-")
        }
      }
    ' "$IDX/logs.tsv" > "$_cm_f"

    if [ "$(flines "$_cm_f")" -eq 0 ]; then
      warn "no log files for $_cm_pod"
      pause
      return 0
    fi

    # Enrich with state and restart count from describe where available.
    _cm_f2="$MENU_TMP/containers2"
    awk -F'\t' -v n="$_cm_ns" -v p="$_cm_pod" '
      BEGIN { OFS = "\t" }
      NR == FNR { if ($1==n && $2==p) { st[$3] = $5; rs[$3] = $9 } ; next }
      { print $1, ($1 in st ? st[$1] : "?"), ($1 in rs ? rs[$1] : "?"), $2, $3, $4, $5 }
    ' "$IDX/containers.tsv" "$_cm_f" > "$_cm_f2"

    # Fields: container state restarts bytes errors warns prev
    _cm_fmt="%-$(colw "$_cm_f2" 1 CONTAINER)s  %-$(colw "$_cm_f2" 2 STATE)s  %$(colw "$_cm_f2" 3 RESTARTS)s  %$(colw "$_cm_f2" 4 BYTES)s  %$(colw "$_cm_f2" 5 ERRORS)s  %$(colw "$_cm_f2" 6 WARNS)s  %s"
    pick "$_cm_f2" "
      { printf \"$_cm_fmt\\n\", \$1, \$2, \$3, \$4, \$5, \$6, \$7 }
    " "pod: $_cm_pod   -- choose a container" \
      "$(printf "$_cm_fmt" CONTAINER STATE RESTARTS BYTES ERRORS WARNS PREV-LOG)"
    _cm_rc=$?
    [ $_cm_rc -eq 1 ] && return 0
    [ $_cm_rc -eq 2 ] && return 2

    _cm_con=$(printf '%s' "$PICK" | cut -f1)
    log_actions "$_cm_ns" "$_cm_pod" "$_cm_con"
    [ $? -eq 2 ] && return 2
  done
}

pod_menu() {
  while :; do
    # Only pods that have at least one log file are worth entering.
    _pm_f="$MENU_TMP/pods"
    awk -F'\t' '
      BEGIN { OFS = "\t" }
      NR == FNR { nlog[$1 "\t" $2]++ ; err[$1 "\t" $2] += $7 ; next }
      {
        k = $1 "\t" $2
        if (k in nlog) print $1, $2, $4, $3, $5, $6, nlog[k], err[k] + 0
      }
    ' "$IDX/logs.tsv" "$IDX/pods.tsv" > "$_pm_f"

    # Surface the pods most likely to be the problem: errors first, then
    # restarts. A flat alphabetical list buries the interesting ones.
    sort -t"$TAB" -k8,8nr -k5,5nr "$_pm_f" > "$MENU_TMP/pods.sorted"
    mv "$MENU_TMP/pods.sorted" "$_pm_f"

    # Fields: ns pod status ready restarts age logs errors. Text columns are
    # left-aligned, counts right-aligned, widths sized to the longest value.
    _pm_fmt="%-$(colw "$_pm_f" 1 NAMESPACE)s  %-$(colw "$_pm_f" 2 POD)s  %-$(colw "$_pm_f" 3 STATUS)s  %-$(colw "$_pm_f" 4 READY)s  %$(colw "$_pm_f" 5 RESTARTS)s  %-$(colw "$_pm_f" 6 AGE)s  %$(colw "$_pm_f" 7 LOGS)s  %$(colw "$_pm_f" 8 ERRORS)s"
    pick "$_pm_f" "
      { printf \"$_pm_fmt\\n\", \$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8 }
    " "PODS  -- choose one  (sorted by log errors, then restarts)" \
      "$(printf "$_pm_fmt" NAMESPACE POD STATUS READY RESTARTS AGE LOGS ERRORS)"
    _pm_rc=$?
    [ $_pm_rc -eq 1 ] && return 0
    [ $_pm_rc -eq 2 ] && return 2

    _pm_ns=$(printf '%s'  "$PICK" | cut -f1)
    _pm_pod=$(printf '%s' "$PICK" | cut -f2)
    container_menu "$_pm_ns" "$_pm_pod"
    [ $? -eq 2 ] && return 2
  done
}

# ------------------------------------------------------------- other sections

events_menu() {
  _ev_f="$MENU_TMP/events"
  awk -F'\t' 'BEGIN{OFS="\t"} $2=="Warning" { print $1, $3, $5 "/" $6, substr($8,1,100) }' \
    "$IDX/events.tsv" | sort -t"$TAB" -k1,1r > "$_ev_f"

  if [ "$(flines "$_ev_f")" -eq 0 ]; then
    printf 'no warning events\n'; pause; return 0
  fi
  _ev_fmt="%-$(colw "$_ev_f" 1 TIME)s  %-$(colw "$_ev_f" 2 REASON)s  %-$(colw "$_ev_f" 3 OBJECT)s  %s"
  pick "$_ev_f" "{ printf \"$_ev_fmt\\n\", \$1, \$2, \$3, \$4 }" \
    "WARNING EVENTS  (newest first)" \
    "$(printf "$_ev_fmt" TIME REASON OBJECT MESSAGE)"
  _ev_rc=$?
  [ $_ev_rc -eq 2 ] && return 2
  if [ $_ev_rc -eq 0 ]; then
    cls
    printf '%s\n' "$PICK" | tr '\t' '\n' | page
    pause
  fi
  return 0
}

resources_menu() {
  cls
  crumb "RESOURCES  -- requested vs limit vs actual"
  # Join live usage against the configured limits so over-provisioning and
  # near-limit containers are visible in one place.
  # The percentage is emitted twice: once as a bare number in column 1 for
  # sort -n, and once formatted for display. Sorting the formatted "97%"
  # lexically puts 8% above 72%, which is exactly backwards for the thing
  # this view exists to surface.
  {
    printf 'PCT\tPOD/CONTAINER\tUSED\tREQ\tLIMIT\n'
    awk -F'\t' '
      NR == FNR { use[$2 "\t" $3] = $5; next }
      {
        k = $2 "\t" $3
        if (!(k in use)) next
        u = use[k]; sub(/Mi$/, "", u)
        lim = $13 / 1048576
        req = $11 / 1048576
        pct = (lim > 0 ? u * 100 / lim : -1)
        printf "%.2f\t%s\t%s/%s\t%sMi\t%.0fMi\t%.0fMi\n",
               pct, (pct < 0 ? "-" : sprintf("%.0f%%", pct)), $2, $3, u, req, lim
      }
    ' "$IDX/usage.tsv" "$IDX/containers.tsv" \
      | sort -t"$TAB" -k1,1nr | cut -f2-
  } | tsv_table | sed 's/^/  /' | page
  pause
}

files_menu() {
  _fm_f="$MENU_TMP/files"
  cp "$IDX/files.tsv" "$_fm_f"
  _fm_fmt="%-$(colw "$_fm_f" 1 CATEGORY)s  %-$(colw "$_fm_f" 2 FILE)s  %$(colw "$_fm_f" 3 BYTES)s"
  pick "$_fm_f" "{ printf \"$_fm_fmt\\n\", \$1, \$2, \$3 }" \
    "BUNDLE FILES  -- $(flines "$IDX/files.tsv") files" \
    "$(printf "$_fm_fmt" CATEGORY FILE BYTES)"
  _fm_rc=$?
  [ $_fm_rc -eq 2 ] && return 2
  if [ $_fm_rc -eq 0 ]; then
    _fm_name=$(printf '%s' "$PICK" | cut -f2)
    page_hold < "$SRC/$_fm_name"
  fi
  return 0
}

# ------------------------------------------------------------------ main loop

cmd_menu() {
  menu_init
  while :; do
    cls
    crumb "k8s-help   $(fact "$IDX/facts.tsv" bundle)"
    printf '  node %s   %s pods   %s containers   %s logs\n\n' \
      "$(fact "$IDX/facts.tsv" node_name)" \
      "$(fact "$IDX/facts.tsv" pod_count)" \
      "$(fact "$IDX/facts.tsv" container_count)" \
      "$(fact "$IDX/facts.tsv" log_count)"
    cat <<'EOF'
   1  health summary
   2  pods
   3  warning events
   4  resources (used vs requested vs limit)
   5  bundle files
   q  quit
EOF
    printf '\n> '
    read -r _mm_in || break

    case "$_mm_in" in
      1) cls; cmd_summary | page; pause ;;
      2) pod_menu;       [ $? -eq 2 ] && break ;;
      3) events_menu;    [ $? -eq 2 ] && break ;;
      4) resources_menu ;;
      5) files_menu;     [ $? -eq 2 ] && break ;;
      q|Q) break ;;
    esac
  done
  cls
  menu_cleanup
}
