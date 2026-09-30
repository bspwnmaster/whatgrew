#!/bin/bash
#
# whatgrew-v1.sh — Disk monitor that tells you WHAT grew, not just THAT it's full.
#
# Two-layer alerting:
#   Layer 1 (every tick) — duf checks mount thresholds (space AND inodes) via
#     JSON → jq.  Fast, kernel-level query, milliseconds.  Exits immediately
#     if nothing is over the configured threshold.
#   Layer 2 (forensics, once per 24h) — ncdu deep-scans configured directories
#     and diffs against the most recent earlier scan.  The alert email shows a
#     drive overview (usage bars, filesystem types) PLUS which directories grew
#     (by total size of their contents) and what large files appeared.
#     On-call knows where to look before SSH'ing in.
#
# Failure behaviour:
#   - If duf/jq fail, the script exits 1 with a message on stderr (cron mails
#     it) instead of silently treating the error as "below threshold".
#   - If a scan or diff fails, the alert is still sent with a note in the
#     affected section, and the 24h rate limit still applies.
#
# Dependencies (Fedora):
#   sudo dnf install duf ncdu jq util-linux     # + s-nail if ALERT_EMAIL is set
#
# Setup:
#   1. Edit the Configuration block below (threshold, email, scan paths)
#   2. sudo cp whatgrew-v1.sh /usr/local/bin/whatgrew.sh
#   3. sudo chown root:root /usr/local/bin/whatgrew.sh
#   4. sudo chmod 750        /usr/local/bin/whatgrew.sh
#   5. Add both cron entries to root crontab:
#
#        # Daily: build ncdu cache so diffs always have yesterday's data
#        0 3 * * * /usr/local/bin/whatgrew.sh --scan
#
#        # Hourly: check thresholds, diff against cache, alert if needed
#        0 * * * * /usr/local/bin/whatgrew.sh
#
#      Both runs take a lock (flock), so they never scan at the same time.
#
# Security notes:
#   - chmod 750 the script (blocks non-root read, prevents tampering)
#   - CACHE_DIR is created 0700 and every file in it 0600 (umask 077):
#     ncdu exports map your full filesystem, including other users' files.
#   - PATH is pinned below so a root cron job never runs a planted binary.
#   - CACHE_DIR's parent directory must remain root-only-writable:
#     prepare_cache_dir() checks CACHE_DIR itself is a non-symlink,
#     self-owned directory once at startup, but does not re-verify before
#     every later open. If CACHE_DIR is ever pointed at a path whose
#     parent a non-root user can write to, that single check-then-use gap
#     becomes exploitable (symlink swap between check and use).
#   - ALERT_EMAIL delivery pipes the report into mail(1)/s-nail via stdin,
#     which can embed local-user-controlled filenames (from ncdu). This
#     assumes the mail client has '~' tilde-escape command processing
#     disabled for non-interactive/piped input (the default) — do not
#     re-enable "set escape" for the account this script mails.
#
set -euo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# ─── Configuration ───────────────────────────────────────────────────
# Edit these to match your environment.

THRESHOLD=90                        # Alert when disk (or inode) usage% >= this
ALERT_EMAIL=""                      # e.g. "ops@example.com" — leave empty to skip email
CACHE_DIR="/var/lib/whatgrew"     # Where ncdu exports and state files live
# ── SCAN_PATHS — directories ncdu will deep‑scan ──
#
#   Scans run in two situations:
#     1. Daily at 3 AM via --scan mode — silently builds the cache so
#        yesterday's data always exists when an alert fires later.
#     2. When a threshold alert fires + the 24 h rate limiter allows —
#        fresh scan + diff against the latest earlier scan to show what grew.
#
#   Syntax: bash array, space‑separated, each path quoted.
#     Single path:   SCAN_PATHS=( "/var" )
#     Multiple:      SCAN_PATHS=( "/var" "/home" "/opt" )
#     Empty (skip):  SCAN_PATHS=( )          ← ncdu scanning disabled
#
#   Paths must be absolute and use only letters, digits, and . _ - /
#   ("." and ".." components are not allowed).
#   Entries with other characters are skipped with a warning.
#
#   How to choose which paths to scan:
#
#     /var    – #1 offender on servers.  Logs, Docker images, databases,
#               package caches all live here.  Scan this on EVERY system.
#
#     /home   – User data: downloads, git repos, browser caches, core dumps.
#               Essential for multi‑user or desktop machines.
#
#     /opt    – Third‑party apps (monitoring agents, commercial tools)
#               that may log or cache locally without telling you.
#
#     /srv    – Self‑hosted services: web roots, file shares, CI runners.
#
#     /tmp    – Ephemeral, but some apps abuse it.  Scan if /tmp isn't a
#               tmpfs or if you suspect build‑artifact clutter.
#
#     /usr    – Usually stable (package installs don't change day‑to‑day).
#               Skip unless you have a specific reason.
#
#   Per‑machine examples:
#     Web server:     SCAN_PATHS=( "/var" "/srv" )
#     DB server:      SCAN_PATHS=( "/var/lib/postgresql" "/var/log" )
#     Desktop:        SCAN_PATHS=( "/var" "/home" )
#     Minimal VM:     SCAN_PATHS=( "/var" )
#
SCAN_PATHS=( "/var" "/home" )

ALERT_COOLDOWN_SECS=86400           # At most one alert per 24 hours
SCAN_RETENTION_DAYS=7               # Delete ncdu exports older than this
NEW_ENTRY_MIN_BYTES=10485760        # Report NEW files/dirs of at least 10 MiB
GROWTH_MIN_BYTES=1048576            # Report GROWTH of at least 1 MiB
TOP_CHANGES=15                      # Lines of growth shown per scan path
DUF_TIMEOUT_SECS=60                 # Kill duf if a stuck mount hangs the threshold check.
                                     #   duf is a fast statfs()-class sweep (milliseconds on a
                                     #   healthy box), so 60s is already generous headroom -- no
                                     #   benchmarking needed for this one.
NCDU_TIMEOUT_SECS=3600              # Kill ncdu if a stuck mount/oversized tree hangs the scan.
                                     #   Operator expectation for this deployment: a normal scan
                                     #   should finish in well under 10min. 1h is set as the kill
                                     #   ceiling rather than ~10min itself, so a merely-slow-but-
                                     #   healthy run (disk under load, a few more files than usual)
                                     #   isn't mistaken for a stuck mount -- the timeout only needs
                                     #   to catch genuine hangs, not police normal runtime. BEFORE
                                     #   trusting this default, benchmark your actual paths:
                                     #     time ncdu -0xo /dev/null /var
                                     #     time ncdu -0xo /dev/null /home
                                     #   (repeat for each entry in SCAN_PATHS below). If real scans
                                     #   consistently land near the ~10min expectation, 1h leaves
                                     #   ~6x headroom, which is reasonable; if any path is routinely
                                     #   taking a large fraction of an hour on its own, that's worth
                                     #   investigating on its own merits before relying on this
                                     #   timeout to mask it. Applies per path, to the daily --scan.
NCDU_ALERT_TIMEOUT_SECS=900         # Per-path limit for the fresh scan an alert runs before the
                                     #   email goes out. Shorter than NCDU_TIMEOUT_SECS so a slow
                                     #   scan can't hold back a disk-full alert for hours; if it
                                     #   runs out, the report falls back to today's 03:00 scan and
                                     #   says so.
KILL_AFTER_SECS=30                  # If a timed-out duf/ncdu ignores SIGTERM (e.g. blocked on a
                                     #   hung NFS mount), SIGKILL it this many seconds later.

ALERT_STAMP_FILE="$CACHE_DIR/last_alert"   # mtime = time of last alert
RUN_LOCK_FILE="$CACHE_DIR/.run.lock"       # flock: one run at a time
# How long a second invocation waits for the lock before giving up: long enough
# for a daily --scan that runs every path up to its NCDU_TIMEOUT_SECS limit, so a
# healthy-but-slow scan never makes the next cron tick fail with "another
# whatgrew run still holds $RUN_LOCK_FILE".
RUN_LOCK_WAIT_SECS=$(( ${#SCAN_PATHS[@]} * (NCDU_TIMEOUT_SECS + KILL_AFTER_SECS) + 300 ))

TODAY=""        # YYYYmmdd, set once in main so scan and diff always agree
WORK_DIR=""     # Private temp dir inside CACHE_DIR, removed on exit
declare -A SCAN_DURATIONS=()   # path -> most recent ncdu scan duration in whole seconds,
                                #   populated by scan_cache(); surfaced in both the --scan
                                #   mode's own output and the hourly alert report so a scan
                                #   trending toward NCDU_TIMEOUT_SECS is visible before it
                                #   actually times out.
declare -A SCAN_FAILED=()      # path -> "timed out" or "failed" when that path's most recent
                                #   ncdu run did not produce an export. The report checks this,
                                #   not whether today's export file exists, because the 03:00
                                #   --scan leaves one behind that would otherwise pass for fresh.

# ─── Helpers ─────────────────────────────────────────────────────────

die() {
    echo "whatgrew: $*" >&2
    exit 1
}

warn() {
    echo "whatgrew: $*" >&2
}

require_tools() {
    local tool missing=()
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} )); then
        die "required tool(s) not installed: ${missing[*]} (dnf install duf ncdu jq util-linux s-nail)"
    fi
}

# run_limited <secs> <command...> — run with a time limit; SIGKILL follows
# SIGTERM after KILL_AFTER_SECS in case the command ignores it.
run_limited() {
    local secs=$1
    shift
    timeout -k "$KILL_AFTER_SECS" "$secs" "$@"
}

# is_timeout <exit-code> <elapsed-secs> <limit-secs> — true if run_limited
# stopped the command: 124 = SIGTERM worked, 137 = it needed SIGKILL. 137 alone
# could also be the OOM killer, so it only counts once the limit had passed.
is_timeout() {
    (( $1 == 124 || ($1 == 137 && $2 >= $3) ))
}

# Create CACHE_DIR as a root-only directory and refuse to use it if it is a
# symlink, owned by someone else, or writable by group/other.
prepare_cache_dir() {
    install -d -m 700 "$CACHE_DIR"
    [[ -d "$CACHE_DIR" && ! -L "$CACHE_DIR" ]] || die "$CACHE_DIR is not a plain directory"
    [[ -O "$CACHE_DIR" ]] || die "$CACHE_DIR is not owned by $(id -un)"
    chmod 700 "$CACHE_DIR"
}

# Serialize runs: the 03:00 --scan job and the hourly alert job must never
# write the same ncdu export at the same time.
take_run_lock() {
    exec 9>"$RUN_LOCK_FILE"
    flock -w "$RUN_LOCK_WAIT_SECS" 9 || die "another whatgrew run still holds $RUN_LOCK_FILE"
}

make_work_dir() {
    WORK_DIR=$(mktemp -d -p "$CACHE_DIR" .work.XXXXXX)
    trap 'rm -rf -- "$WORK_DIR"' EXIT
}

# Return 0 (true) if we haven't alerted within ALERT_COOLDOWN_SECS.
# This avoids spamming every cron tick while someone fixes the disk.
can_alert() {
    [[ -f "$ALERT_STAMP_FILE" ]] || return 0      # Never alerted before
    local now last_alert_ts
    now=$(date +%s)
    last_alert_ts=$(stat -c %Y "$ALERT_STAMP_FILE" 2>/dev/null || echo 0)
    (( now - last_alert_ts >= ALERT_COOLDOWN_SECS ))
}

mark_alerted() {
    touch "$ALERT_STAMP_FILE"
}

# ─── duf: thresholds and drive report ────────────────────────────────
#
# duf -json outputs a JSON array of all mount points:
#   {
#     "device":       "/dev/nvme0n1p3",
#     "device_type":  "local",           <-- real disk vs pseudo (tmpfs/proc)
#     "mount_point":  "/",
#     "fs_type":      "ext4",
#     "opts":         "rw,relatime,errors=remount-ro",
#     "total":        73456943104,       <-- bytes
#     "used":         10228842496,
#     "free":         61904977920,       <-- available to non-root users
#     "inodes":       4587520,           <-- 0 on btrfs, important on ext4/xfs!
#     "inodes_used":  312042,
#     "inodes_free":  4275478
#   }
#
# Shared jq definitions used by both the threshold check and the report:
#   real_mounts — local, non-zero-size, not mounted read-only, not overlay.
#                 Mount options are compared whole, so "errors=remount-ro" does
#                 not count as read-only. Overlay mounts (Docker/Podman container
#                 filesystems) are skipped: their files live on another
#                 filesystem, which is checked itself, and their names change
#                 with every container.
#   pct         — used / (used + free), which matches df's Use% (ext4 reserves
#                 ~5% for root, so used/total would under-report).
#   ipct        — inode usage %, 0 when the filesystem has no inode limit.
#
# JQ_CLEAN is shared by every jq program that prints text a local user can
# influence (filenames, mount points). Control characters (tab, newline, ANSI
# escapes) become "?" so a crafted name can't forge report lines. Unicode
# format characters (Cf: bidi overrides/isolates/marks, zero-width chars, tag
# chars) and line/paragraph separators (U+2028/U+2029) become "?" too, so a
# crafted name can't visually spoof what on-call reads in the alert or break a
# line in a mail client.
readonly JQ_CLEAN='
    def clean: gsub("[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]"; "?");
'
readonly JQ_MOUNT_DEFS="$JQ_CLEAN"'
    def real_mounts:
        .[]
        | select(.device_type == "local")
        | select(.fs_type != "overlay")
        | select((.total // 0) > 0)
        | select((.opts // "") | split(",") | any(. == "ro") | not)
        | if [.total, .used, .free] | all(type == "number") then .
          else error("unexpected duf field types on \(.mount_point)") end;
    # Every real machine has at least one local mount; none means duf output
    # changed format, which must be an error, not "nothing over threshold".
    def checked_mounts:
        [real_mounts]
        | if length == 0 then error("no local mounts in duf output") else . end;
    def pct:
        ((.used // 0) + (.free // 0)) as $cap
        | if $cap > 0 then (.used // 0) / $cap * 100 else 0 end;
    def ipct:
        if (.inodes // 0) > 0 then (.inodes_used // 0) / .inodes * 100 else 0 end;
'

# Returns 0 if any mount is over THRESHOLD, 1 if none are, 2 on error.
check_thresholds() {
    local json rc=0 duf_rc t0=$SECONDS
    duf_rc=0
    json=$(run_limited "$DUF_TIMEOUT_SECS" duf -json) || duf_rc=$?
    if (( duf_rc != 0 )); then
        if is_timeout "$duf_rc" $(( SECONDS - t0 )) "$DUF_TIMEOUT_SECS"; then
            warn "duf -json timed out after ${DUF_TIMEOUT_SECS}s (stuck mount?)"
        else
            warn "duf -json failed"
        fi
        return 2
    fi
    jq -e --argjson threshold "$THRESHOLD" "$JQ_MOUNT_DEFS"'
        checked_mounts
        | map(select(pct >= $threshold or ipct >= $threshold))
        | length > 0
    ' <<<"$json" >/dev/null || rc=$?
    case $rc in
        0) return 0 ;;
        1) return 1 ;;
        *) warn "jq could not evaluate duf output (exit $rc)"; return 2 ;;
    esac
}

# One line per mount, fullest first: "/ [#########|] 95%  inodes 12%  ext4  /dev/sda2"
# Prints its own failure message into the report.
drive_report() {
    local json duf_rc t0=$SECONDS
    duf_rc=0
    json=$(run_limited "$DUF_TIMEOUT_SECS" duf -json) || duf_rc=$?
    if (( duf_rc != 0 )); then
        if is_timeout "$duf_rc" $(( SECONDS - t0 )) "$DUF_TIMEOUT_SECS"; then
            warn "duf -json timed out after ${DUF_TIMEOUT_SECS}s (stuck mount?)"
            echo "  (drive report failed: duf timed out after ${DUF_TIMEOUT_SECS}s — see cron stderr)"
        else
            warn "duf -json failed"
            echo "  (drive report failed — see cron stderr)"
        fi
        return 1
    fi
    if ! jq -r "$JQ_MOUNT_DEFS"'
        def bar($pct):  # 10-char usage bar
            ([($pct / 10 | floor), 10] | min) as $n
            | ([range(0; $n)  | "#"] | join(""))
            + ([range($n; 10) | " "] | join(""));

        checked_mounts
        | sort_by(- pct)
        | .[]
        | "\(.mount_point | clean) [\(bar(pct))] \(pct | floor)%"
          + (if (.inodes // 0) > 0 then "  inodes \(ipct | floor)%" else "" end)
          + "  \(.fs_type | clean)  \(.device | clean)"
    ' <<<"$json"; then
        echo "  (drive report failed: could not parse duf output — see cron stderr)"
        return 1
    fi
}

# ─── ncdu: scan and diff ────────────────────────────────────────────
#
# ncdu scans a directory tree and exports it as JSON:
#   ncdu -0xo /path/to/export.json /target/dir
#
#   -0   = no progress output while scanning (errors still go to stderr)
#   -x   = stay on one filesystem (don't cross mount points)
#   -o   = export to file instead of opening UI
#
# The exported JSON format:
#   [major, minor, metadata, [ {root info}, entry, entry... ]]
#   Each entry is either:
#     {name, asize, dsize}              — a file
#     [{name, asize, dsize}, child...]   — a directory + its children
#   The root's name is the absolute scan path ("/var"); children's names
#   are relative. dsize = disk blocks used by that entry itself — for a
#   directory that's just the directory inode, NOT its contents.
#

# Exports are named ncdu_<readable>-<hash>_<YYYYmmdd>.json. The short hash
# keeps "/var/log" and "/var_log" apart; the trailing "_<digit>" in the
# cleanup glob keeps "/var" from matching "/var/log" files.
scan_label() {
    local hash
    hash=$(printf '%s' "$1" | sha256sum)
    printf '%s-%s' "${1//\//_}" "${hash:0:8}"
}

ncdu_export_path() {    # ncdu_export_path <scan-path> <YYYYmmdd>
    printf '%s/ncdu_%s_%s.json' "$CACHE_DIR" "$(scan_label "$1")" "$2"
}

# Returns 0 if the SCAN_PATHS entry should be scanned. Missing directories are
# skipped silently (same config works on machines without /srv, etc.).
usable_scan_path() {
    if [[ ! "$1" =~ ^/[A-Za-z0-9._/-]*$ || "$1/" == */../* || "$1/" == */./* ]]; then
        warn "skipping SCAN_PATHS entry with unsupported characters or ./.. components: $1"
        return 1
    fi
    [[ -d "$1" ]]
}

# Newest export for <scan-path> dated before TODAY, or nothing.
previous_export() {
    local f d best="" best_date=""
    for f in "$CACHE_DIR"/ncdu_"$(scan_label "$1")"_[0-9]*.json; do
        [[ -f "$f" ]] || continue
        d=${f##*_}
        d=${d%.json}
        [[ "$d" =~ ^[0-9]{8}$ && "$d" < "$TODAY" && "$d" > "$best_date" ]] || continue
        best=$f
        best_date=$d
    done
    [[ -n "$best" ]] && printf '%s\n' "$best"
    return 0
}

# scan_cache — runs ncdu across all SCAN_PATHS, storing dated JSON exports.
#   Each scan is written to a temp file and only moved into place when ncdu
#   succeeds, so an interrupted scan never leaves a truncated export behind.
#   Returns 1 if any scan failed (the others still run).
scan_cache() {   # scan_cache <per-path limit in seconds>
    local limit=$1 path file tmp ncdu_rc rc=0 t0
    tmp="$WORK_DIR/scan.partial"
    for path in "${SCAN_PATHS[@]}"; do
        usable_scan_path "$path" || continue
        file=$(ncdu_export_path "$path" "$TODAY")

        ncdu_rc=0
        t0=$SECONDS
        run_limited "$limit" ncdu -0xo "$tmp" "$path" || ncdu_rc=$?
        SCAN_DURATIONS["$path"]=$(( SECONDS - t0 ))
        if (( ncdu_rc == 0 )); then
            mv -f -- "$tmp" "$file"
            unset 'SCAN_FAILED[$path]'
        else
            rm -f -- "$tmp"
            if is_timeout "$ncdu_rc" "${SCAN_DURATIONS[$path]}" "$limit"; then
                warn "ncdu scan of $path timed out after ${SCAN_DURATIONS[$path]}s (limit ${limit}s; stuck mount or oversized tree?)"
                SCAN_FAILED["$path"]="timed out"
            else
                warn "ncdu scan of $path failed (exit $ncdu_rc)"
                SCAN_FAILED["$path"]="failed"
            fi
            rc=1
        fi
    done

    # Sweep ALL old exports, not just labels for paths still in SCAN_PATHS --
    # otherwise removing a SCAN_PATHS entry orphans its old exports forever.
    find "$CACHE_DIR" -maxdepth 1 -type f -name 'ncdu_*_[0-9]*.json' \
        -mtime +"$SCAN_RETENTION_DAYS" -delete || rc=1

    return $rc
}

# jq program: flatten an ncdu export to one line per entry:
#   F<TAB>dsize<TAB>/full/path/file
#   D<TAB>dsize<TAB>/full/path/dir        (the directory inode itself)
# The root directory comes first. Names go through "clean" (see JQ_CLEAN).
readonly NCDU_FLATTEN="$JQ_CLEAN"'
    def walk($p):
        if type == "array" then
            .[0] as $m
            | (if $p == null then ($m.name | clean | rtrimstr("/"))
               else $p + "/" + ($m.name | clean) end) as $d
            | "D\t\($m.dsize // 0)\t\($d)",
              (.[1:][] | walk($d))
        elif type == "object" then
            "F\t\(.dsize // 0)\t\($p)/\(.name | clean)"
        else empty end;
    .[3] | walk(null)
'

# flatten_ncdu <export.json> — prints "bytes<TAB>path" for every file, and
# "bytes<TAB>path/" for every directory where bytes is the TOTAL size of
# everything under it, so a directory filling with many small files shows up.
flatten_ncdu() {
    jq -r "$NCDU_FLATTEN" "$1" | awk -F'\t' '
        NR == 1 { root = $3 }
        {
            size = $2 + 0
            if ($1 == "F") {
                printf "%.0f\t%s\n", size, $3
                dir = $3
                sub(/\/[^\/]*$/, "", dir)
            } else {
                dir = $3
            }
            # Add this entry to its directory and every ancestor up to root.
            while (length(dir) >= length(root)) {
                total[dir] += size
                if (dir == root) break
                sub(/\/[^\/]*$/, "", dir)
            }
        }
        END { for (d in total) printf "%.0f\t%s/\n", total[d], d }
    '
}

# diff_flattened <old> <new> — prints "delta<TAB>KIND<TAB>path" for entries
# that grew (GROWTH) or newly appeared (NEW).
diff_flattened() {
    awk -F'\t' -v min_new="$NEW_ENTRY_MIN_BYTES" -v min_growth="$GROWTH_MIN_BYTES" '
        NR == FNR { old[$2] = $1 + 0; next }
        {
            path = $2; now = $1 + 0
            if (path in old) {
                if (now - old[path] >= min_growth)
                    printf "%.0f\tGROWTH\t%s\n", now - old[path], path
            } else if (now >= min_new) {
                printf "%.0f\tNEW\t%s\n", now, path
            }
        }
    ' "$1" "$2"
}

# Biggest changes first, human-readable sizes. awk reads all input (rather
# than exiting after TOP_CHANGES lines) so sort never gets SIGPIPE.
format_top_changes() {
    sort -t$'\t' -k1,1nr | awk -F'\t' -v top="$TOP_CHANGES" '
        function human(n) {
            if (n >= 1073741824) return sprintf("%5.1f GiB", n / 1073741824)
            if (n >= 1048576)    return sprintf("%5.1f MiB", n / 1048576)
            return sprintf("%5.1f KiB", n / 1024)
        }
        NR <= top { printf "    %-9s %-6s  %s\n", human($1), $2, $3 }
    '
}

# scan_and_diff — runs a fresh ncdu scan, then diffs each path against its
# most recent earlier export. Returns 1 if anything failed; the report text
# says which path was affected.
scan_and_diff() {
    local path cur prev prev_date changes scanned rc=0
    local old="$WORK_DIR/old.tsv" new="$WORK_DIR/new.tsv"

    # Always do a fresh scan for the diff (so we have "right now" data), with
    # the shorter alert limit so a slow scan can't hold the email back for hours.
    scan_cache "$NCDU_ALERT_TIMEOUT_SECS" || rc=1

    for path in "${SCAN_PATHS[@]}"; do
        usable_scan_path "$path" 2>/dev/null || continue

        cur=$(ncdu_export_path "$path" "$TODAY")
        scanned="scan took ${SCAN_DURATIONS[$path]:-?}s"
        if [[ -n "${SCAN_FAILED[$path]:-}" ]]; then
            echo "  (fresh scan of $path ${SCAN_FAILED[$path]} after ${SCAN_DURATIONS[$path]:-?}s — see cron stderr)"
            rc=1
            if [[ ! -s "$cur" ]]; then
                echo "  (no scan of $path from earlier today either — no current data)"
                echo ""
                continue
            fi
            # Most likely the 03:00 --scan. Better than nothing, but say so.
            scanned="NOT fresh: using today's $(date -r "$cur" +%H:%M) scan instead"
        fi

        prev=$(previous_export "$path")
        if [[ -z "$prev" ]]; then
            echo "  (no previous scan for $path — diff will be available after the next daily scan)"
            continue
        fi
        prev_date=${prev##*_}
        prev_date=${prev_date%.json}

        echo "  Changes in $path since ${prev_date:0:4}-${prev_date:4:2}-${prev_date:6:2} (top $TOP_CHANGES by disk usage, $scanned):"
        if ! flatten_ncdu "$prev" >"$old" || ! flatten_ncdu "$cur" >"$new"; then
            echo "    (could not read ncdu export for $path)"
            rc=1
            continue
        fi
        if ! changes=$(diff_flattened "$old" "$new" | format_top_changes); then
            echo "    (diff failed for $path)"
            rc=1
            continue
        fi
        if [[ -n "$changes" ]]; then
            printf '%s\n' "$changes"
        else
            echo "    (no significant growth)"
        fi
        echo ""
    done
    rm -f -- "$old" "$new"
    return $rc
}

# ─── Send alert ─────────────────────────────────────────────────────
#
# If ALERT_EMAIL is set, send the report through mail(1). If that fails, or
# no email is set, print it to stdout (cron delivers it to root's mailbox).
#
send_alert() {
    local report=$1
    if [[ -n "$ALERT_EMAIL" ]]; then
        if printf '%s\n' "$report" | mail -s "[WHATGREW] Disk threshold exceeded (>= ${THRESHOLD}%)" "$ALERT_EMAIL"; then
            echo "Alert emailed to $ALERT_EMAIL"
            return 0
        fi
        warn "mail to $ALERT_EMAIL failed; printing report instead"
        printf '%s\n' "$report"
        return 1
    fi
    printf '%s\n' "$report"
}

build_report() {
    # Each section may fail on its own; the rest of the report still goes out.
    set +e
    echo "══════════════════════════════════════════════════════════════"
    echo "  STORAGE ALERT — $(date)"
    echo "  Threshold: >= ${THRESHOLD}% (disk space or inodes)"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
    echo "─── Drive Overview (duf) ─────────────────────────────────────"
    echo ""
    drive_report    # prints its own failure message
    echo ""
    echo "─── Directory Growth Since Last Scan (ncdu) ──────────────────"
    echo ""
    if (( ${#SCAN_PATHS[@]} )); then
        scan_and_diff || echo "  (one or more scans or diffs failed — see cron stderr)"
    else
        echo "  (SCAN_PATHS is empty — directory scanning disabled)"
    fi
    echo "══════════════════════════════════════════════════════════════"
}

# ─── Main ───────────────────────────────────────────────────────────

main() {
    TODAY=$(date +%Y%m%d)

    # ── Mode: --scan (daily cache builder, 3 AM cron) ──
    # Only runs ncdu scans and exits.  No threshold check, no email.
    if [[ "${1:-}" == "--scan" ]]; then
        (( ${#SCAN_PATHS[@]} )) || exit 0
        require_tools ncdu jq flock
        prepare_cache_dir
        take_run_lock
        make_work_dir
        local scan_rc=0 path
        scan_cache "$NCDU_TIMEOUT_SECS" || scan_rc=1
        # Print durations even on failure -- cron mails this stdout, and how
        # long a scan ran before failing is exactly what distinguishes "hit
        # the NCDU_TIMEOUT_SECS ceiling" from "failed instantly, real error".
        for path in "${SCAN_PATHS[@]}"; do
            [[ -n "${SCAN_DURATIONS[$path]:-}" ]] || continue
            if [[ -n "${SCAN_FAILED[$path]:-}" ]]; then
                echo "whatgrew: scan of $path ${SCAN_FAILED[$path]} after ${SCAN_DURATIONS[$path]}s"
            else
                echo "whatgrew: scanned $path in ${SCAN_DURATIONS[$path]}s"
            fi
        done
        exit $scan_rc
    fi

    # ── Mode: alert (every-hour cron, default) ──
    local -a tools=(duf jq flock)
    (( ${#SCAN_PATHS[@]} )) && tools+=(ncdu)
    [[ -n "$ALERT_EMAIL" ]] && tools+=(mail)
    require_tools "${tools[@]}"

    # Step 1 — Check thresholds (fast). Nothing over → exit quietly.
    #          An error is NOT "nothing over": exit 1 so cron mails stderr.
    local rc=0
    check_thresholds || rc=$?
    (( rc == 1 )) && exit 0
    (( rc == 2 )) && die "threshold check failed — disk usage is NOT being monitored"

    # Step 2 — Rate limiting, checked under the lock so two runs can't both alert.
    prepare_cache_dir
    take_run_lock
    can_alert || exit 0
    make_work_dir

    # Step 3 — Build and send the report, then start the cooldown even if a
    #          section failed, so a broken scan can't cause hourly re-alerts.
    local report
    report=$(build_report)
    rc=0
    send_alert "$report" || rc=1
    mark_alerted
    exit $rc
}

main "$@"
