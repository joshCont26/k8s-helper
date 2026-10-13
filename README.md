# k8s-help

Interactive triage for Securiti appliance Kubernetes report bundles
(`report-##########.tar.gz`). Open a bundle and get a health verdict for the
cluster, then drill from pods to containers to logs without extracting
anything by hand.

## Index

1. [Requirements](#requirements)
2. [How to use the tool](#how-to-use-the-tool)
   - [Running it directly](#running-it-directly)
   - [Commands and options](#commands-and-options)
   - [Where the report is looked for](#where-the-report-is-looked-for)
   - [Cache and re-indexing](#cache-and-re-indexing)
3. [Shortcut: run `k8s` from anywhere](#shortcut-run-k8s-from-anywhere)
4. [Menu reference](#menu-reference)
   - [Navigation keys](#navigation-keys)
   - [1 health summary](#1-health-summary)
   - [2 pods](#2-pods)
   - [3 warning events](#3-warning-events)
   - [4 resources (used vs requested vs limit)](#4-resources-used-vs-requested-vs-limit)
   - [5 bundle files](#5-bundle-files)
5. [Directory structure](#directory-structure)
   - [Tool folder](#tool-folder)
   - [Shortcut link](#shortcut-link)
   - [Cache folder](#cache-folder)
   - [Report bundle contents](#report-bundle-contents)

---

## Requirements

- macOS with the stock `/bin/bash` (3.2) and BSD tools. Nothing to install:
  no `jq`, `yq`, Python or Homebrew packages.
- A Securiti report bundle (`.tar.gz`, `.tgz`, `.tar`, or an already
  extracted folder) that contains a `k8s-podlist` file.

## How to use the tool

### Running it directly

From the `k8s-helper` folder:

```bash
./k8s-help --file=report-1787683060.tar.gz
```

On a terminal this opens the interactive menu. The first run on a bundle
extracts and indexes it (a few seconds). Later runs on the same bundle open
straight away.

### Commands and options

```
./k8s-help --file=<report> [menu | summary | reindex]
```

| Argument | What it does |
|---|---|
| `--file=NAME`, `--file NAME`, `-f NAME` | The report bundle. Can be a bare file name, a relative or absolute path, `~/...`, or an extracted folder. Required. |
| `menu` | Interactive browser. The default on a terminal. |
| `summary` | Prints the health summary and exits. The default when output is piped or redirected. |
| `reindex` | Throws away the cached index for this bundle, rebuilds it, then opens the menu. |
| `--no-color` | Plain output with no ANSI colours. |
| `-h`, `--help` | Usage. |

Examples:

```bash
./k8s-help --file=report-1787683060.tar.gz                 # menu
./k8s-help --file=~/Downloads/report.tar.gz summary        # print the summary
./k8s-help --file=report.tar.gz summary > health.txt       # save it to a file
./k8s-help --file=report.tar.gz reindex                    # force a rebuild
```

### Where the report is looked for

If `--file` is not a path that exists, the tool searches for that file name,
cheapest place first, and stops at the first place that has a match:

1. The current folder, `~/Downloads`, `~/Desktop`, `~/Documents`, `~`,
   `/tmp`, `/var/tmp`
2. Spotlight
3. Everything under your home folder
4. The whole disk (slow; Ctrl-C to stop)

If it finds more than one file with that name, it lists them and asks you to
pick. It never guesses, because opening the wrong customer's report is worse
than asking. To skip the question, pass the full path.

### Cache and re-indexing

Each bundle is extracted and indexed once into
`~/.k8sdiag/<file-name>-<size-in-bytes>/`. The size is part of the key, so two
different reports with the same file name never share a cache.

The cache is rebuilt automatically when the tool is updated and its index
format changes. Run `reindex` if you want a rebuild anyway. To use a
different cache location, set `K8SDIAG_HOME`.

---

## Shortcut: run `k8s` from anywhere

The `k8s` launcher in this folder asks for the report file name and then runs
`k8s-help --file=<name>` for you:

```
$ k8s
report file [report-##########.tar.gz]: report-1787683060.tar.gz
```

The text in brackets is a format hint only. Pressing Enter without typing
anything asks again. Tab completes paths.

### Setting it up

1. Make sure the scripts are executable (run in the `k8s-helper` folder):

   ```bash
   chmod +x k8s k8s-help
   ```

2. Make sure `~/bin` exists and is on your PATH. Check with:

   ```bash
   echo "$PATH" | tr ':' '\n' | grep "$HOME/bin"
   ```

   If nothing is printed, add it to your shell profile and open a new
   terminal:

   ```bash
   mkdir -p ~/bin
   echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
   ```

3. Link the launcher into `~/bin` (run in the `k8s-helper` folder):

   ```bash
   ln -s "$PWD/k8s" ~/bin/k8s
   ```

   Use a link, not a copy: the launcher finds `k8s-help` and `lib/` through
   the link, and later updates to the folder take effect without
   reinstalling.

4. Check it, from any folder:

   ```bash
   type k8s        # should print: k8s is /Users/<you>/bin/k8s
   ```

If you move the `k8s-helper` folder, re-create the link:
`ln -sf "$PWD/k8s" ~/bin/k8s`.

### Using it

| You type | What runs |
|---|---|
| `k8s` | Asks for the file, opens the menu |
| `k8s summary` | Asks for the file, prints the health summary |
| `k8s reindex` | Asks for the file, rebuilds the cache, opens the menu |
| `k8s report-1787683060.tar.gz` | No prompt, opens the menu |
| `k8s ~/Downloads/report-1787683060.tar.gz summary` | No prompt, prints the summary |

Tip: if the same report exists in more than one place on your Mac, type the
full path at the prompt (Tab helps) so you aren't asked which copy to use.

---

## Menu reference

```
k8s-help   report-1787683060.tar.gz
--------------------------------------------------------------------------
  node ip-172-31-23-246...   43 pods   55 containers   118 logs

   1  health summary
   2  pods
   3  warning events
   4  resources (used vs requested vs limit)
   5  bundle files
   q  quit
```

### Navigation keys

Every list (pods, containers, events, files) uses the same keys:

| Key | Action |
|---|---|
| a number | Select that row |
| `/text` | Show only rows containing `text` (case-insensitive). The column header stays visible. |
| `/` | Clear the filter |
| `b` | Back one level |
| `q` | Quit the tool |

Long output opens in `less`: arrow keys or Space to scroll, `/` to search,
`q` to go back to the menu.

### 1 health summary

A full health report for the cluster. It starts with a **HEALTH CHECKS**
table: one row per component, with a status, a result, and a short detail.

| Status | Meaning |
|---|---|
| `OK` | Healthy |
| `WARN` | Worth a look, not necessarily broken |
| `FAIL` | Broken or unhealthy |
| `N/A` | The bundle has no data for this check |
| `INFO` | Describes the bundle, not the cluster |

The checks:

| Check | What is validated |
|---|---|
| Nodes ready | Every node reports `Ready=True` |
| Node conditions | No MemoryPressure, DiskPressure, PIDPressure or NetworkUnavailable |
| Node scheduling | No node is cordoned |
| Node CPU usage / Node Memory usage | Live usage. WARN at 80%, FAIL at 90% |
| Pods active | Count of Running and Completed pods. FAIL if any pod is Pending, Failed or Unknown |
| Pods ready | Every Running pod has all its containers ready (for example `2/2`) |
| Containers | No container stuck waiting (CrashLoopBackOff, ImagePullBackOff, ...) or exited with an error. Covers the `default` namespace, which is what the bundle describes |
| Pod restarts | Pods restarting more than a node reboot explains. After a reboot every pod restarts the same number of times, so the most common count is treated as the baseline |
| Deployments / StatefulSets / DaemonSets | Ready replicas reach the desired count |
| Autoscalers (HPA) | Every autoscaler can read its metrics (`ScalingActive=True`) |
| Service endpoints | Every service has at least one ready backend pod |
| PVC mounts | Every persistent volume claim is used by a container's volume mount, its pod is Running and Ready, and there are no FailedMount, FailedAttachVolume or binding events |
| Certificates (k3s) | k3s's own check of the node and CA certificates (`CertificateExpirationOK`) |
| CA trust bundle | `cert-merger-controller` built the CA bundle with no skipped certificates and no errors |
| TLS errors in logs | No `x509:`, expired-certificate, unknown-authority or handshake failures in any current container log |
| Redis persistence | Redis's last disk snapshot and AOF write both succeeded |
| Warning events | Number of Kubernetes warning events, with the most frequent reasons |
| Container log errors | Current container logs that contain error-level lines |
| Bundle coverage | How many pods the bundle has full describe data for |

The bundle contains no PVC objects and no certificate files, so the PVC and
certificate checks rely on indirect evidence: the pod specs and events for
PVCs, and what k3s and `cert-merger-controller` report for certificates.

Below the table:

- **OVERALL** verdict. HEALTHY if every check is OK, DEGRADED if any check
  is WARN, UNHEALTHY if any check is FAIL.
- **ATTENTION**: for every check that is not OK, a table of the specific
  pods, claims, nodes or containers behind it.
- The detailed sections:

  | Section | Contents |
  |---|---|
  | CLUSTER | Node name, roles, kubelet, container runtime, OS, capacity, and the time window the events cover |
  | PODS | Pod counts by status; pods not healthy; pods Running but not ready |
  | RESTARTS | Restarting pods ranked by restarts per day, not by total, separating restarts caused by a node reboot from the rest |
  | EVENTS (warnings) | Warning events grouped by reason, with an example message |
  | TOP MEMORY CONSUMERS | The 8 containers using the most memory, plus node CPU and memory |
  | LOGS BY SEVERITY | Container logs with the most error and warning lines |
  | BUNDLE COVERAGE | Pods that are missing describe data |

The same report is printed by `k8s summary` or `./k8s-help --file=... summary`.

### 2 pods

Drill down from a pod, to one of its containers, to that container's log.

**Pods list.** Only pods that have log files are listed. They are sorted by
log errors, then by restarts, so the likely problems are at the top.

| Column | Meaning |
|---|---|
| NAMESPACE, POD | The pod |
| STATUS | Running, Succeeded, Pending, ... |
| READY | Ready containers / total containers |
| RESTARTS | Total restarts |
| AGE | Pod age when the report was taken |
| LOGS | Number of log files (current and previous instances) |
| ERRORS | Error-level lines across all of the pod's logs |

**Containers list** (after you pick a pod):

| Column | Meaning |
|---|---|
| CONTAINER | Container name |
| STATE | Running, Terminated, Waiting (`?` if the bundle has no describe data for it) |
| RESTARTS | Container restart count |
| BYTES | Size of the current log |
| ERRORS / WARNS | Error and warning lines in the current log |
| PREV-LOG | `yes` if the log from before the last restart is in the bundle |

**Log actions** (after you pick a container). The header shows which log
instance you are on, its size, its error and warning counts, and its path.

| Option | What it does |
|---|---|
| 1 view whole log | The whole log in `less`, with error and warning lines highlighted |
| 2 last 100 lines | The end of the log, usually where a crash is |
| 3 first 100 lines | Startup output |
| 4 errors only | Error-level lines only, with line numbers |
| 5 errors + warnings | Error and warning lines, with line numbers |
| 6 search | Asks for text, then shows each match with 3 lines of context. Not case-sensitive; the text is matched literally, so no escaping is needed |
| 7 switch to 'prev' / 'current' instance | Toggles between the current log and the log from before the last restart. The "why did it crash" evidence is usually in `prev` |
| 8 events for this pod | Kubernetes events for this pod |
| b / q | Back to the containers list / quit |

Errors and warnings are detected from each log line's level field
(`"level":"ERROR"`, `level=error`, `[ERROR]`, plus Go panics), not from the
word "error" appearing anywhere. Structured logs mention "error" constantly
in normal INFO lines, so a plain word search would overcount badly.

### 3 warning events

All Kubernetes `Warning` events, newest first, with columns TIME, REASON,
OBJECT (`namespace/name`) and MESSAGE (shortened). Pick a row to see the
full event, one field per line.

### 4 resources (used vs requested vs limit)

For each container: live memory use against its configured request and
limit, sorted by percentage of the limit used, highest first. Use it to find
containers close to their memory limit (out-of-memory kill risk) and
containers with far more memory reserved than they use.

| Column | Meaning |
|---|---|
| PCT | Memory used as a percentage of the limit (`-` if there is no limit) |
| POD/CONTAINER | The container |
| USED | Live memory use |
| REQ / LIMIT | Configured memory request and limit |

### 5 bundle files

Every file in the report bundle, with columns CATEGORY (log, describe,
events, metrics, redis, resource, ...), FILE and BYTES. Pick one to open it
in `less`. Use this for raw data the other views don't cover, such as
`k8s-hpa-status`, the `k8s-redis-*` output, or `k8s-cluster-info-dump`.

---

## Directory structure

The tool touches three places: the tool folder (which you copy or clone),
one link in `~/bin` for the shortcut, and a cache folder that the tool
creates and manages itself.

### Tool folder

Keep these files together. `k8s-help` loads `lib/` from the folder it lives
in, so the folder can be anywhere, but its contents must keep this layout.

```
k8s-helper/
├── README.md          this file
├── k8s                launcher: asks for the report file, runs k8s-help   (executable)
├── k8s-help           main entry point: options, caching, health summary  (executable)
└── lib/
    ├── common.sh      shared helpers: colours, pager, table rendering
    ├── locate.sh      finds the report file on disk
    ├── ingest.sh      extracts the bundle and builds the indexes
    └── menu.sh        interactive menu and lists
```

`k8s` and `k8s-help` must be executable (`chmod +x k8s k8s-help`). The files
in `lib/` are loaded by `k8s-help`, not run on their own, so they don't need
to be.

### Shortcut link

Created during [shortcut setup](#setting-it-up). It is a link, not a copy:

```
~/bin/
└── k8s -> <path-to>/k8s-helper/k8s
```

### Cache folder

Created on the first run of each bundle. There is one subfolder per bundle,
named `<file-name>-<size-in-bytes>`. Delete a subfolder, or run `reindex`,
to rebuild it. To put it somewhere else, set `K8SDIAG_HOME`.

```
~/.k8sdiag/
└── report-1787683060.tar.gz-1177486/
    ├── .extracted          marker: the extract is newer than the tarball
    ├── extract/            the bundle, unpacked (see Report bundle contents)
    └── index/              flat tab-separated indexes the menu reads
        ├── facts.tsv       cluster-level values: node, versions, certs, Redis, ...
        ├── pods.tsv        one row per pod: status, ready, restarts, age
        ├── containers.tsv  one row per container: state, restarts, requests, limits
        ├── logs.tsv        one row per log file: size, lines, error and warning counts
        ├── events.tsv      one row per Kubernetes event
        ├── usage.tsv       live CPU and memory per container
        ├── files.tsv       every file in the bundle, by category
        ├── nodes.tsv       node readiness, pressure conditions, cordoned
        ├── volumes.tsv     PVC-backed volumes and whether they are mounted
        ├── workloads.tsv   deployments, statefulsets, daemonsets, HPAs, endpoints
        └── tls.tsv         containers with TLS / certificate errors in their logs
```

If you open an already-extracted folder instead of a `.tar.gz`, there is no
`extract/` or `.extracted`: the tool reads that folder in place.

### Report bundle contents

What a Securiti report bundle contains once unpacked. The files are flat,
with no subfolders. If the archive wraps them in a single top-level folder,
that is handled too. `k8s-podlist` is the only file that must be present.
Every other file is optional: if one is missing, the checks and views that
depend on it show `N/A` or have nothing to list.

```
extract/
├── k8s-podlist                   pod table (kubectl get pods)           REQUIRED
├── k8s-pods-describe             pod describe, default namespace
├── k8s-pod-yaml                  full pod specs and status, all namespaces
├── k8s-nodes                     node objects (YAML)
├── k8s-nodes-describe            node describe
├── k8s-events                    Kubernetes events (YAML)
├── k8s-top-nodes                 live node CPU and memory
├── k8s-top-pods                  live container CPU and memory
├── k8s-deployments               deployments (YAML)
├── k8s-<namespace>-deployments   per namespace: default, kube-system, securiti-cluster-upgrade
├── k8s-<namespace>-daemonsets
├── k8s-<namespace>-endpoints
├── k8s-<namespace>-pods
├── k8s-<namespace>-replicasets
├── k8s-<namespace>-services
├── k8s-redis-statefulset         Redis statefulset (YAML)
├── k8s-redis-info-persistence    Redis INFO persistence output
├── k8s-redis-big-keys
├── k8s-redis-mem-keys
├── k8s-hpa                       autoscaler specs
├── k8s-hpa-status                autoscaler status and conditions
├── k8s-active-job-list
├── k8s-config-overrides
├── k8s-cluster-info-dump
└── k8s-logs-<namespace>-<pod>-<container>[-prev]
                                  one file per container log; -prev is the
                                  instance from before the last restart
```

Which files feed which feature:

| Feature | Reads |
|---|---|
| Pods list, Pods checks | `k8s-podlist` |
| Containers list and checks, resources view | `k8s-pods-describe`, `k8s-top-pods` |
| Node checks | `k8s-nodes`, `k8s-nodes-describe`, `k8s-top-nodes` |
| PVC mounts | `k8s-pod-yaml`, `k8s-events` |
| Workload, HPA and endpoint checks | `k8s-deployments`, `k8s-<namespace>-*`, `k8s-redis-statefulset`, `k8s-hpa-status` |
| Certificate checks | `k8s-events`, cert-merger-controller log, all container logs |
| Redis persistence | `k8s-redis-info-persistence` |
| Logs, log errors, TLS errors | `k8s-logs-*` |
| Warning events | `k8s-events` |
