#!/bin/bash
# ingest.sh -- one-pass extraction of the vendor report bundle into flat TSV
# indexes. Everything downstream reads only the indexes, never the raw bundle,
# except for log file bodies which are streamed on demand.
#
# Produces, under $IDX:
#   facts.tsv       key <TAB> value          -- cluster-level scalars
#   pods.tsv        ns pod ready status restarts age ip node
#   containers.tsv  ns pod container image state reason exit ready restarts
#                   req_cpu req_mem lim_cpu lim_mem
#   logs.tsv        ns pod container kind bytes lines errors warns path
#   events.tsv      ts type reason kind ns name count message
#   usage.tsv       ns pod container cpu mem
#   files.tsv       category name bytes
#   nodes.tsv       node ready problems scheduling
#   volumes.tsv     ns pod volume claim mounted phase ready
#   workloads.tsv   kind ns name desired ready note
#   tls.tsv         ns pod container tls_error_lines
#
# All parsing is awk-only. No jq, no yq, no python.

# ------------------------------------------------------------------ constants

# Bump whenever the set or shape of the indexes changes, so cached work dirs
# built by an older version are rebuilt instead of half-read.
INDEX_VERSION=2

# TLS / certificate failures as they surface in Go, Java, Python and openssl
# logs. Case-insensitive; matched against current logs only.
TLS_RE='x509: |certificate has expired|signed by unknown authority|certificate verify failed|certificate_verify_failed|tls: (bad certificate|handshake failure|failed to verify)|PKIX path (building|validation) failed|SSLHandshakeException'

# Log severity detection.
#
# Matching the bare word "error" is useless here: these are structured logs
# and the token appears constantly inside field names and payloads of INFO
# lines. A naive /error/i scan reports ~338 "errors" in the worker log that
# actually contains 2.
#
# This bundle uses exactly three logging styles, so match the level field
# itself rather than the vocabulary:
#   zap JSON     {"level":"ERROR: "}   -- note the trailing colon+space
#   logfmt       level=error
#   bracketed    [ERROR] / [WARNING]
# Plus unprefixed Go runtime panics.
ERR_RE='"level":"(ERROR|FATAL|PANIC)|level=(error|fatal|panic)|\[(ERROR|FATAL)\]|(^|[^A-Za-z])(panic:|goroutine [0-9]+ \[running\])'
WARN_RE='"level":"WARN|level=warn|\[WARN(ING)?\]'

# ------------------------------------------------------------------- unpacking

ingest_prepare() {
  # ingest_prepare <tarball-or-dir> <workdir>
  _src=$1
  _work=$2
  SRC="$_work/extract"

  if [ -d "$_src" ]; then
    # Already-extracted bundle: use in place, don't copy 16MB around.
    SRC="$_src"
    return 0
  fi

  [ -f "$_src" ] || die "no such file or directory: $_src"

  # Re-extract only when the tarball is newer than our marker.
  if [ -f "$_work/.extracted" ] && [ "$_work/.extracted" -nt "$_src" ]; then
    info "using cached extract at $SRC"
    return 0
  fi

  rm -rf "$SRC"
  mkdir -p "$SRC" || die "cannot create $SRC"

  case "$_src" in
    *.tar.gz|*.tgz|*_tar.gz) tar -xzf "$_src" -C "$SRC" ;;
    *.tar)                   tar -xf  "$_src" -C "$SRC" ;;
    *) die "unrecognized archive: $_src (expected .tar.gz/.tgz/.tar)" ;;
  esac || die "extraction failed"

  # The bundle is flat, but tolerate a single wrapping directory in case a
  # future report version adds one.
  _n=$(ls -1 "$SRC" | wc -l | tr -d ' ')
  if [ "$_n" = "1" ]; then
    _only="$SRC/$(ls -1 "$SRC")"
    if [ -d "$_only" ]; then SRC="$_only"; fi
  fi

  [ -f "$SRC/k8s-podlist" ] || \
    die "this does not look like a supported report bundle (no k8s-podlist)"

  : > "$_work/.extracted"
}

# --------------------------------------------------------------------- facts

ingest_facts() {
  _f="$IDX/facts.tsv"
  _nd="$SRC/k8s-nodes-describe"

  {
    printf 'bundle\t%s\n' "$(basename "$BUNDLE")"
    printf 'source_dir\t%s\n' "$SRC"

    if [ -f "$_nd" ]; then
      awk -F'\t' '
        BEGIN { OFS = "\t" }
        # Capacity / Allocatable use a literal tab after the key.
        /^Capacity:/     { sect = "cap";   next }
        /^Allocatable:/  { sect = "alloc"; next }
        /^System Info:/  { sect = "sys";   next }
        /^[A-Z]/         { if ($0 !~ /^(Capacity|Allocatable|System Info):/) sect = "" }

        sect == "cap" && /^  cpu:/    { gsub(/^[ ]+|[ ]+$/, "", $2); print "node_cpu",    $2 }
        sect == "cap" && /^  memory:/ { gsub(/^[ ]+|[ ]+$/, "", $2); print "node_memory", $2 }
        sect == "cap" && /^  pods:/   { gsub(/^[ ]+|[ ]+$/, "", $2); print "node_maxpods",$2 }
      ' "$_nd"

      # System Info is space-aligned, not tab-separated.
      awk '
        BEGIN { OFS = "\t" }
        /^System Info:/ { s = 1; next }
        /^[A-Za-z]/     { s = 0 }
        s && /Kernel Version:/           { sub(/^[^:]*:[ ]+/, ""); print "kernel",  $0 }
        s && /OS Image:/                 { sub(/^[^:]*:[ ]+/, ""); print "os",      $0 }
        s && /Container Runtime Version:/{ sub(/^[^:]*:[ ]+/, ""); print "runtime", $0 }
        s && /Kubelet Version:/          { sub(/^[^:]*:[ ]+/, ""); print "kubelet", $0 }
      ' "$_nd"

      awk '
        BEGIN { OFS = "\t" }
        /^Name:/  { sub(/^Name:[ ]+/,  ""); print "node_name", $0 }
        /^Roles:/ { sub(/^Roles:[ ]+/, ""); print "node_roles", $0 }
        # Conditions block: flag any pressure that is not False.
        /^Conditions:/ { c = 1; next }
        /^Addresses:/  { c = 0 }
        c && $1 ~ /Pressure$/ && $2 != "False" { print "pressure_" $1, $2 }
        c && $1 == "Ready" { print "node_ready", $2 }
      ' "$_nd"
    fi

    # Capture window and reboot marker come from the event stream, which is
    # the only place with trustworthy absolute timestamps.
    if [ -f "$IDX/events.tsv" ]; then
      awk -F'\t' '
        BEGIN { OFS = "\t" }
        $1 != "" && ($1 < first || first == "") { first = $1 }
        $1 > last { last = $1 }
        $3 == "Rebooted" { reboot = $1 }
        END {
          if (first)  print "events_from", first
          if (last)   print "events_to",   last
          if (reboot) print "node_reboot", reboot
        }
      ' "$IDX/events.tsv"
    fi

    printf 'pod_count\t%s\n'       "$(flines "$IDX/pods.tsv")"
    printf 'container_count\t%s\n' "$(flines "$IDX/containers.tsv")"
    printf 'log_count\t%s\n'       "$(flines "$IDX/logs.tsv")"
    printf 'event_count\t%s\n'     "$(flines "$IDX/events.tsv")"
    printf 'index_version\t%s\n'   "$INDEX_VERSION"

    _health_facts
  } | atomic_write "$_f"
}

# Scalars feeding the health table that have no natural home in another index.
_health_facts() {
  # Node utilisation. Take the worst node so a multi-node bundle still flags.
  if [ -f "$SRC/k8s-top-nodes" ]; then
    awk '
      NR == 1 || !NF { next }
      {
        c = $3; m = $5; sub(/%$/, "", c); sub(/%$/, "", m)
        if (c + 0 > mc) mc = c + 0
        if (m + 0 > mm) { mm = m + 0; mu = $4 }
        n++
      }
      END { if (n) printf "node_cpu_pct\t%d\nnode_mem_pct\t%d\nnode_mem_used\t%s\n", mc, mm, mu }
    ' "$SRC/k8s-top-nodes"
  fi

  # k3s checks its own node + CA certificates and reports the outcome as a
  # node event (CertificateExpirationOK / ...Warning). Latest one wins.
  awk -F'\t' '
    $3 ~ /^CertificateExpiration/ { r = $3; t = $1; m = $8 }
    END {
      if (r != "") {
        gsub(/^\047|\047$/, "", m)
        printf "cert_k3s_reason\t%s\ncert_k3s_ts\t%s\ncert_k3s_msg\t%s\n", r, t, m
      }
    }
  ' "$IDX/events.tsv"

  # The appliance cert-merger controller validates the CA bundle mounted
  # into every workload and logs how many certs it accepted/skipped.
  _cm_row=$(awk -F'\t' '$3 ~ /cert-merger/ && $4 == "current" { print; exit }' "$IDX/logs.tsv")
  if [ -n "$_cm_row" ]; then
    _cm_path=$(printf '%s' "$_cm_row" | cut -f9)
    printf 'cert_merger_errors\t%s\n' "$(printf '%s' "$_cm_row" | cut -f7)"
    awk '
      /total_valid_certs/ { line = $0 }
      END {
        if (line == "") exit
        v = line; s = line
        if (match(v, /"total_valid_certs":[0-9]+/))  { v = substr(v, RSTART, RLENGTH); sub(/.*:/, "", v) } else v = ""
        if (match(s, /"custom_certs_skipped":[0-9]+/)) { s = substr(s, RSTART, RLENGTH); sub(/.*:/, "", s) } else s = ""
        if (v != "") print "cert_merger_valid\t" v
        if (s != "") print "cert_merger_skipped\t" s
      }
    ' "$_cm_path"
  fi

  if [ -f "$SRC/k8s-redis-info-persistence" ]; then
    awk -F: '
      { gsub(/\r/, "") }
      $1 == "rdb_last_bgsave_status" { print "redis_bgsave_status\t" $2 }
      $1 == "aof_enabled"            { print "redis_aof_enabled\t"   $2 }
      $1 == "aof_last_write_status"  { print "redis_aof_status\t"    $2 }
    ' "$SRC/k8s-redis-info-persistence"
  fi
}

# ----------------------------------------------------------------------- pods

ingest_pods() {
  awk '
    BEGIN { OFS = "\t" }
    NR == 1 { next }                       # header
    !NF     { next }                       # trailing blanks
    {
      ns = $1; pod = $2; ready = $3; status = $4; restarts = $5

      # kubectl sometimes renders restarts as "3 (2d ago)". This vendor does
      # not, but locate AGE positionally rather than assuming field 6 so a
      # format change degrades instead of silently shifting every column.
      age = ""; ip = ""; node = ""
      for (i = 6; i <= NF; i++) {
        if ($i ~ /^[0-9]+[dhms]/) { age = $i; ip = $(i+1); node = $(i+2); break }
      }
      print ns, pod, ready, status, restarts, age, ip, node
    }
  ' "$SRC/k8s-podlist" | sort -t"$TAB" -k1,1 -k2,2 | atomic_write "$IDX/pods.tsv"
}

# ----------------------------------------------------------------- containers

ingest_containers() {
  # Source: k8s-pods-describe. NOTE this vendor file covers the `default`
  # namespace only -- 39 of 43 pods. Downstream joins must tolerate misses.
  _d="$SRC/k8s-pods-describe"
  if [ ! -f "$_d" ]; then : | atomic_write "$IDX/containers.tsv"; return 0; fi

  awk '
    BEGIN { OFS = "\t" }

    function flushc() {
      if (cname != "") {
        print ns, pod, cname, image, state, reason, exitc, ready, rst,
              rcpu, rmem, lcpu, lmem
      }
      cname = image = state = reason = exitc = ready = rst = ""
      rcpu = rmem = lcpu = lmem = ""
    }

    /^---$/ { flushc(); inc = 0; next }

    /^Name:/      { flushc(); inc = 0; sub(/^Name:[ ]+/, "");      pod = $0; next }
    /^Namespace:/ {                    sub(/^Namespace:[ ]+/, ""); ns  = $0; next }

    /^Containers:/      { inc = 1; sect = ""; next }
    /^Conditions:/      { flushc(); inc = 0; next }
    /^Events:/          { flushc(); inc = 0; next }

    inc != 1 { next }

    # A container header is exactly two spaces of indent then "name:".
    /^  [A-Za-z0-9]/ && /:[ ]*$/ && !/^   / {
      flushc()
      cname = $0
      sub(/^[ ]+/, "", cname); sub(/:[ ]*$/, "", cname)
      sect = ""
      next
    }

    # Indent-4 keys. Track which block we are in so that indent-6 lines under
    # Environment: (which can legitimately contain a var called "memory")
    # are never mistaken for resource values.
    /^    State:/         { sect = "state"; v = $0; sub(/^[^:]*:[ ]+/, "", v); state  = v; next }
    /^    Last State:/    { sect = "last";                                              next }
    /^    Image:/         { sect = "";      v = $0; sub(/^[^:]*:[ ]+/, "", v); image  = v; next }
    /^    Ready:/         { sect = "";      v = $0; sub(/^[^:]*:[ ]+/, "", v); ready  = v; next }
    /^    Restart Count:/ { sect = "";      v = $0; sub(/^[^:]*:[ ]+/, "", v); rst    = v; next }
    /^    Requests:/      { sect = "req";   next }
    /^    Limits:/        { sect = "lim";   next }
    /^    Environment:/   { sect = "env";   next }
    /^    Mounts:/        { sect = "mnt";   next }
    /^    [A-Za-z]/       { sect = "";      next }

    # Indent-6 values, interpreted only within a known block.
    sect == "state" && /^      Reason:/    { v=$0; sub(/^[^:]*:[ ]+/,"",v); reason = v; next }
    sect == "state" && /^      Exit Code:/ { v=$0; sub(/^[^:]*:[ ]+/,"",v); exitc  = v; next }

    # The vendor writes requests as "cpu :   0.03" and limits as "cpu:  0.2".
    sect == "req" && /^      cpu[ ]*:/    { v=$0; sub(/^[^:]*:[ ]+/,"",v); rcpu = v; next }
    sect == "req" && /^      memory[ ]*:/ { v=$0; sub(/^[^:]*:[ ]+/,"",v); rmem = v; next }
    sect == "lim" && /^      cpu[ ]*:/    { v=$0; sub(/^[^:]*:[ ]+/,"",v); lcpu = v; next }
    sect == "lim" && /^      memory[ ]*:/ { v=$0; sub(/^[^:]*:[ ]+/,"",v); lmem = v; next }

    END { flushc() }
  ' "$_d" | sort -t"$TAB" -k1,1 -k2,2 -k3,3 | atomic_write "$IDX/containers.tsv"
}

# ----------------------------------------------------------------------- logs

ingest_logs() {
  # Log files are named  k8s-logs-<ns>-<pod>-<container>[-prev]
  # Pod and container names both contain hyphens, so the split point is
  # ambiguous from the filename alone. Resolve it by longest-prefix match
  # against the known <ns>-<pod>- pairs from pods.tsv.
  _list="$IDX/.loglist"
  ( cd "$SRC" && ls -1 | grep '^k8s-logs-' ) > "$_list" 2>/dev/null || : > "$_list"

  awk -v src="$SRC" '
    BEGIN { OFS = "\t" }
    NR == FNR { ns[FNR] = $1; pod[FNR] = $2; n = FNR; next }
    {
      file = $0
      base = file
      sub(/^k8s-logs-/, "", base)
      kind = "current"
      if (base ~ /-prev$/) { kind = "prev"; sub(/-prev$/, "", base) }

      bestlen = -1; bns = ""; bpod = ""; bcon = ""
      for (i = 1; i <= n; i++) {
        pfx = ns[i] "-" pod[i] "-"
        if (substr(base, 1, length(pfx)) == pfx) {
          if (length(pfx) > bestlen) {
            bestlen = length(pfx)
            bns = ns[i]; bpod = pod[i]
            bcon = substr(base, length(pfx) + 1)
          }
        }
      }
      if (bestlen < 0) { bns = "?"; bpod = base; bcon = "?" }
      print bns, bpod, bcon, kind, src "/" file
    }
  ' "$IDX/pods.tsv" "$_list" > "$IDX/.logmap"

  # Second pass: size, line count, and error/warning density per file.
  : > "$IDX/.logstats"
  while IFS="$TAB" read -r lns lpod lcon lkind lpath; do
    [ -n "${lpath:-}" ] || continue
    _b=$(fsize "$lpath")
    if [ "${_b:-0}" -eq 0 ] 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\t%s\n' \
        "$lns" "$lpod" "$lcon" "$lkind" "$lpath" >> "$IDX/.logstats"
      continue
    fi
    _l=$(flines "$lpath")
    # NB: grep -c already prints 0 on no-match and exits 1. Adding a
    # `|| echo 0` fallback appends a SECOND zero, producing a value with an
    # embedded newline that splits the TSV row. Let the nonzero exit stand.
    _e=$(grep -a -c -E "$ERR_RE"  "$lpath" 2>/dev/null)
    _w=$(grep -a -c -E "$WARN_RE" "$lpath" 2>/dev/null)
    [ -n "${_e:-}" ] || _e=0
    [ -n "${_w:-}" ] || _w=0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$lns" "$lpod" "$lcon" "$lkind" "$_b" "$_l" "$_e" "$_w" "$lpath" \
      >> "$IDX/.logstats"
  done < "$IDX/.logmap"

  sort -t"$TAB" -k1,1 -k2,2 -k3,3 -k4,4 "$IDX/.logstats" \
    | atomic_write "$IDX/logs.tsv"
  rm -f "$IDX/.loglist" "$IDX/.logmap" "$IDX/.logstats"
}

# --------------------------------------------------------------------- events

ingest_events() {
  _e="$SRC/k8s-events"
  if [ ! -f "$_e" ]; then : | atomic_write "$IDX/events.tsv"; return 0; fi

  # A deliberately small YAML-subset reader for the exact shape `kubectl get
  # events -o yaml` emits. It is not a general YAML parser and does not try
  # to be: it tracks the current indent-2 block so that metadata.name is
  # never confused with involvedObject.name, and it rejoins the wrapped
  # continuation lines of long `message:` values.
  awk '
    BEGIN { OFS = "\t" }

    function clean(v) {
      sub(/^[ ]+/, "", v); sub(/[ ]+$/, "", v)
      gsub(/^"|"$/, "", v)
      if (v == "null") v = ""
      return v
    }
    function emit() {
      if (!seen) return
      ts = last_ts
      if (ts == "") ts = event_ts
      if (ts == "") ts = first_ts
      sub(/\.[0-9]+Z$/, "Z", ts)          # normalize so ts sorts lexically
      gsub(/\t/, " ", msg)
      print ts, type, reason, kind, ons, oname, (cnt == "" ? "1" : cnt), msg
    }
    function reset() {
      type = reason = kind = ons = oname = cnt = msg = ""
      last_ts = event_ts = first_ts = ""
      blk = ""; mode = ""
    }

    /^items:/ { next }

    # Record boundary: a list item at column 0.
    /^- / {
      emit(); reset(); seen = 1
      line = "  " substr($0, 3)           # re-indent to the common indent-2 form
    }
    !/^- / { line = $0 }

    {
      ind = match(line, /[^ ]/) - 1

      # Continuation of a wrapped message value.
      if (mode == "msg" && ind >= 4) { msg = msg " " clean(line); next }
      if (ind == 2) mode = ""

      if (ind == 2) {
        key = line; sub(/^[ ]+/, "", key); sub(/:.*$/, "", key)
        val = line
        if (val ~ /:/) { sub(/^[^:]*:[ ]*/, "", val) } else { val = "" }
        val = clean(val)

        if (val == "")                 { blk = key } else { blk = "" }

        if      (key == "type")           type     = val
        else if (key == "reason")         reason   = val
        else if (key == "count")          cnt      = val
        else if (key == "lastTimestamp")  last_ts  = val
        else if (key == "eventTime")      event_ts = val
        else if (key == "firstTimestamp") first_ts = val
        else if (key == "message")      { msg = val; mode = "msg" }
        next
      }

      if (ind == 4 && blk == "involvedObject") {
        key = line; sub(/^[ ]+/, "", key); sub(/:.*$/, "", key)
        val = line; sub(/^[^:]*:[ ]*/, "", val); val = clean(val)
        if      (key == "kind")      kind  = val
        else if (key == "name")      oname = val
        else if (key == "namespace") ons   = val
        next
      }
    }
    END { emit() }
  ' "$_e" | sort -t"$TAB" -k1,1 | atomic_write "$IDX/events.tsv"
}

# ---------------------------------------------------------------------- usage

ingest_usage() {
  _t="$SRC/k8s-top-pods"
  if [ ! -f "$_t" ]; then : | atomic_write "$IDX/usage.tsv"; return 0; fi

  # Rows are  NAMESPACE  POD/CONTAINER  CPU  MEMORY
  awk '
    BEGIN { OFS = "\t" }
    NR == 1 { next }
    !NF     { next }
    {
      split($2, p, "/")
      print $1, p[1], (p[2] == "" ? "-" : p[2]), $3, $4
    }
  ' "$_t" | sort -t"$TAB" -k1,1 -k2,2 | atomic_write "$IDX/usage.tsv"
}

# ---------------------------------------------------------------------- files

ingest_files() {
  ( cd "$SRC" && ls -1 ) | awk -v src="$SRC" '
    BEGIN { OFS = "\t" }
    {
      f = $0
      if      (f ~ /^k8s-logs-/)        c = "log"
      else if (f ~ /describe$/)         c = "describe"
      else if (f ~ /^k8s-redis-/)       c = "redis"
      else if (f ~ /^k8s-top-/)         c = "metrics"
      else if (f ~ /^k8s-podlist$/)     c = "table"
      else if (f ~ /^k8s-events$/)      c = "events"
      else if (f ~ /^k8s-cluster-info/) c = "clusterinfo"
      else                              c = "resource"
      print c, f
    }
  ' | while IFS="$TAB" read -r cat name; do
        printf '%s\t%s\t%s\n' "$cat" "$name" "$(fsize "$SRC/$name")"
      done | sort -t"$TAB" -k1,1 -k2,2 | atomic_write "$IDX/files.tsv"
}

# --------------------------------------------------------------------- health

# Shared prelude for reading `kubectl get -o yaml` list output.
#
# yline() normalizes one line so callers can reason purely in key indents:
# a list item "<sp>- key: v" is rewritten as "<sp>  key: v" with ITEM set to
# the dash's indent (-1 when the line is not a list item). It then sets
#   IND  indent of the key      KEY  the key      VAL  the scalar value
# Like ingest_events this is a reader for kubectl's exact output shape, not
# a general YAML parser.
_YAML_AWK='
  BEGIN { OFS = "\t" }
  function yline(s) {
    ITEM = -1
    if (match(s, /^ *- /)) {
      ITEM = RLENGTH - 2
      s = substr(s, 1, ITEM) "  " substr(s, RLENGTH + 1)
    }
    IND = match(s, /[^ ]/) - 1
    KEY = s; sub(/^ +/, "", KEY); sub(/:.*$/, "", KEY)
    VAL = s
    if (VAL ~ /:/) { sub(/^[^:]*:[ ]*/, "", VAL) } else { VAL = "" }
    sub(/[ \r]+$/, "", VAL); gsub(/^"|"$/, "", VAL)
  }
'

ingest_nodes() {
  # Prefer the structured node list; it covers every node, where the
  # describe file only feeds facts for the first.
  _n="$SRC/k8s-nodes"
  if [ ! -f "$_n" ]; then : | atomic_write "$IDX/nodes.tsv"; return 0; fi

  awk "$_YAML_AWK"'
    function flush() {
      if (name != "") print name, (ready == "" ? "Unknown" : ready), bad, (unsched == "true" ? "cordoned" : "schedulable")
      name = ready = bad = unsched = cst = cty = s2 = s4 = ""
    }
    { yline($0) }
    IND < 0     { next }
    ITEM == 0   { flush() }
    IND == 2    { s2 = KEY; s4 = ""; next }
    IND == 4 {
      s4 = KEY
      if (s2 == "metadata" && KEY == "name")          name    = VAL
      if (s2 == "spec"     && KEY == "unschedulable") unsched = VAL
      next
    }
    s2 == "status" && s4 == "conditions" && IND == 6 {
      if (ITEM == 4) cst = cty = ""
      if (KEY == "status") cst = VAL
      if (KEY == "type")   cty = VAL
      if (cst != "" && cty != "") {
        # Ready must be True; every other condition (the *Pressure family,
        # NetworkUnavailable) is a problem when it is anything but False.
        if (cty == "Ready") ready = cst
        else if (cst != "False") bad = bad (bad == "" ? "" : ",") cty
        cst = cty = ""
      }
    }
    END { flush() }
  ' "$_n" | atomic_write "$IDX/nodes.tsv"
}

ingest_volumes() {
  # One row per PVC-backed volume, joined with what the pod reports about
  # itself. The bundle has no PVC/PV objects, so "mounted" is inferred: a
  # container references the volume, and the pod got far enough to run.
  _p="$SRC/k8s-pod-yaml"
  if [ ! -f "$_p" ]; then : | atomic_write "$IDX/volumes.tsv"; return 0; fi

  awk "$_YAML_AWK"'
    function flush(   i) {
      if (pod != "")
        for (i = 1; i <= nv; i++)
          if (vclaim[i] != "")
            print ns, pod, vname[i], vclaim[i], (vname[i] in mnt ? "yes" : "no"),
                  (phase == "" ? "Unknown" : phase), crdy "/" ctot
      pod = ns = phase = s2 = s4 = s6 = ""
      nv = crdy = ctot = 0
      split("", vname); split("", vclaim); split("", mnt)
    }
    /^items:/   { next }
    { yline($0) }
    IND < 0     { next }
    ITEM == 0   { flush() }
    IND == 2    { s2 = KEY; s4 = s6 = ""; next }
    IND == 4 {
      s4 = KEY; s6 = ""
      if      (s2 == "metadata" && KEY == "name")      pod   = VAL
      else if (s2 == "metadata" && KEY == "namespace") ns    = VAL
      else if (s2 == "status"   && KEY == "phase")     phase = VAL
      next
    }
    s2 == "spec" && s4 == "volumes" {
      if (ITEM == 4) nv++
      if (IND == 6 && KEY == "name")      vname[nv]  = VAL
      if (IND == 8 && KEY == "claimName") vclaim[nv] = VAL
      next
    }
    s2 == "spec" && (s4 == "containers" || s4 == "initContainers") {
      # Track the indent-6 container key so env "- name:" entries are never
      # mistaken for volumeMount names.
      if (IND == 6) s6 = KEY
      if (s6 == "volumeMounts" && IND == 8 && KEY == "name") mnt[VAL] = 1
      next
    }
    s2 == "status" && s4 == "containerStatuses" {
      if (ITEM == 4) ctot++
      if (IND == 6 && KEY == "ready" && VAL == "true") crdy++
      next
    }
    END { flush() }
  ' "$_p" | sort -t"$TAB" -k1,1 -k4,4 | atomic_write "$IDX/volumes.tsv"
}

ingest_workloads() {
  # kind ns name desired ready note
  {
    for _f in "$SRC"/k8s-deployments "$SRC"/k8s-*-deployments; do
      [ -f "$_f" ] && printf 'Deployment\t%s\n' "$_f"
    done
    for _f in "$SRC"/k8s-*statefulset*; do
      [ -f "$_f" ] && printf 'StatefulSet\t%s\n' "$_f"
    done
    for _f in "$SRC"/k8s-*-daemonsets; do
      [ -f "$_f" ] && printf 'DaemonSet\t%s\n' "$_f"
    done
    for _f in "$SRC"/k8s-*-endpoints; do
      [ -f "$_f" ] && printf 'Endpoints\t%s\n' "$_f"
    done
  } > "$IDX/.wlfiles"

  {
    while IFS="$TAB" read -r _kind _file; do
      awk -v kind="$_kind" "$_YAML_AWK"'
        function flush(   d, r) {
          if (name != "") {
            if      (kind == "DaemonSet") { d = dns; r = nrd }
            else if (kind == "Endpoints") { d = ea + en; r = ea }
            else                          { d = (rep == "" ? 1 : rep); r = rrd }
            print kind, ns, name, d + 0, r + 0, ""
          }
          name = ns = rep = rrd = dns = nrd = s2 = s4 = ""
          ea = en = 0
        }
        { yline($0) }
        IND < 0     { next }
        ITEM == 0   { flush() }
        IND == 2    { s2 = KEY; s4 = ""; next }
        IND == 4 {
          s4 = KEY
          if      (s2 == "metadata" && KEY == "name")                   name = VAL
          else if (s2 == "metadata" && KEY == "namespace")              ns   = VAL
          else if (s2 == "spec"     && KEY == "replicas")               rep  = VAL
          else if (s2 == "status"   && KEY == "readyReplicas")          rrd  = VAL
          else if (s2 == "status"   && KEY == "desiredNumberScheduled") dns  = VAL
          else if (s2 == "status"   && KEY == "numberReady")            nrd  = VAL
          next
        }
        # Endpoints: subsets[].addresses[] are ready backends,
        # subsets[].notReadyAddresses[] are backends failing readiness.
        s2 == "subsets" && ITEM == 4 {
          if      (s4 == "addresses")         ea++
          else if (s4 == "notReadyAddresses") en++
        }
        END { flush() }
      ' "$_file"
    done < "$IDX/.wlfiles"

    # HPA status is a different shape: items at column 0 with their keys at
    # indent 2 and conditions[] beneath.
    if [ -f "$SRC/k8s-hpa-status" ]; then
      awk "$_YAML_AWK"'
        function flush() {
          if (name != "") print "HPA", ns, name, des + 0, cur + 0, "ScalingActive=" (act == "" ? "?" : act)
          name = ns = des = cur = act = cst = s2 = ""
        }
        /^hpas:/    { next }
        { yline($0) }
        IND < 0     { next }
        ITEM == 0   { flush() }
        IND == 2 {
          s2 = KEY
          if      (KEY == "name")            name = VAL
          else if (KEY == "namespace")       ns   = VAL
          else if (KEY == "desiredReplicas") des  = VAL
          else if (KEY == "currentReplicas") cur  = VAL
          next
        }
        s2 == "conditions" && IND == 4 {
          if (ITEM == 2) cst = ""
          if (KEY == "status") cst = VAL
          if (KEY == "type" && VAL == "ScalingActive") act = cst
        }
        END { flush() }
      ' "$SRC/k8s-hpa-status"
    fi
  } | sort -u -t"$TAB" -k1,1 -k2,2 -k3,3 | atomic_write "$IDX/workloads.tsv"
  rm -f "$IDX/.wlfiles"
}

ingest_tls() {
  # TLS / certificate failures per current container log.
  : > "$IDX/.tls"
  awk -F'\t' '$4 == "current" && $5 + 0 > 0 { print $1 "\t" $2 "\t" $3 "\t" $9 }' "$IDX/logs.tsv" \
  | while IFS="$TAB" read -r tns tpod tcon tpath; do
      _t=$(grep -a -c -i -E "$TLS_RE" "$tpath" 2>/dev/null)
      [ "${_t:-0}" -gt 0 ] 2>/dev/null && \
        printf '%s\t%s\t%s\t%s\n' "$tns" "$tpod" "$tcon" "$_t" >> "$IDX/.tls"
    done
  sort -t"$TAB" -k4,4nr "$IDX/.tls" | atomic_write "$IDX/tls.tsv"
  rm -f "$IDX/.tls"
}

ingest_health() {
  ingest_nodes
  ingest_volumes
  ingest_workloads
  ingest_tls
}

# --------------------------------------------------------------------- driver

ingest_all() {
  # ingest_all <bundle> <workdir>
  BUNDLE=$1
  WORK=$2
  IDX="$WORK/index"

  mkdir -p "$IDX" || die "cannot create index dir $IDX"
  ingest_prepare "$BUNDLE" "$WORK"

  info "indexing pods..."       ; ingest_pods
  info "indexing containers..." ; ingest_containers
  info "indexing events..."     ; ingest_events
  info "indexing logs..."       ; ingest_logs
  info "indexing usage..."      ; ingest_usage
  info "indexing files..."      ; ingest_files
  info "indexing health..."     ; ingest_health
  info "collecting facts..."    ; ingest_facts
}
