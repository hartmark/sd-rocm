#!/usr/bin/env bash
# disk-report.sh - where's the space on a btrfs system, and how much is pinned by
# snapper snapshots (deleting a file frees nothing while a snapshot still refers
# to it). Read-only: nothing is deleted or changed.
#
#   sudo ./disk-report.sh [mountpoint ...]
#
# With no args it looks at every mounted btrfs. Per-snapshot "exclusive" space
# (what actually frees when you delete that one snapshot) needs btrfs quota
# (qgroups) enabled, or a slow extent walk (btrfs filesystem du) which the script
# offers; otherwise it points you at btdu.
set -u

[ "$(id -u)" -eq 0 ] || { echo "run me as root:  sudo $0 $*"; exit 1; }
command -v btrfs >/dev/null || { echo "btrfs-progs not installed"; exit 1; }
hr(){ printf '%s\n' "======================================================================"; }
human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

# snapper get-config value for one key. Output is "KEY <sep> VALUE" with <sep>
# either '|' or a box-drawing '│'; split on whitespace so the separator (and its
# multibyte encoding) never matters - field 1 key, field 2 sep, 3.. value.
getcfg(){ snapper -c "$1" get-config 2>/dev/null | awk -v k="$2" \
  '$1==k{v="";for(i=3;i<=NF;i++)v=v (i>3?" ":"") $i;print v;exit}'; }

# real btrfs mountpoints (skip the raw top-level and nested .snapshots subvols)
if [ "$#" -gt 0 ]; then
  MNTS=("$@")
else
  # one mountpoint per distinct subvolume; drop the raw top-level, .snapshots,
  # and re-export / container-storage binds that just re-walk another subvol
  mapfile -t MNTS < <(findmnt -rno TARGET,SOURCE,FSTYPE |
    awk '$3=="btrfs" && !seen[$2]++ &&
         $1!~/btrfs-root|\.snapshots|^\/srv\/|^\/var\/lib\/(incus|docker|containers|machines)\//{print $1}')
fi
# one mountpoint per underlying device, for the fs-usage summary
declare -A SEEN_DEV; SUMMARY_MNTS=()
for m in "${MNTS[@]}"; do
  d=$(findmnt -no SOURCE -T "$m" 2>/dev/null | sed 's/\[.*//')
  [ -n "$d" ] && [ -z "${SEEN_DEV[$d]:-}" ] && { SEEN_DEV[$d]=1; SUMMARY_MNTS+=("$m"); }
done
USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || true)}"

# ---- filesystem usage (once per device) -----------------------------------
for MNT in "${SUMMARY_MNTS[@]}"; do
  hr; echo "  FILESYSTEM: $MNT  ($(findmnt -no SOURCE -T "$MNT" | sed 's/\[.*//'))"; hr
  btrfs filesystem usage "$MNT"
  UNALLOC=$(btrfs filesystem usage -b "$MNT" | awk '/Device unallocated/{print $3; exit}')
  echo
  if [ "${UNALLOC:-1073741825}" -lt 1073741824 ]; then
    echo ">> Device fully allocated - new data can only use free space *inside* the"
    echo "   existing Data block group. 'btrfs balance start -dusage=15 $MNT' may"
    echo "   hand some back (needs a few GiB already free for scratch)."
    echo
  fi
done

# ---- snapper configs -----------------------------------------------------
hr; echo "  SNAPPER CONFIGS"; hr
CFGS=()
if command -v snapper >/dev/null; then
  mapfile -t CFGS < <(snapper list-configs 2>/dev/null | awk 'NR>2 && $1!=""{print $1}')
  for c in "${CFGS[@]}"; do
    sub=$(getcfg "$c" SUBVOLUME); numlim=$(getcfg "$c" NUMBER_LIMIT)
    n=$(snapper -c "$c" list --columns number 2>/dev/null | awk '$1~/^[0-9]+$/ && $1+0>0' | wc -l)
    tl=$(snapper -c "$c" get-config 2>/dev/null | awk \
      '$1~/^TIMELINE_LIMIT_/{v=$3; if(v!=""&&v!="0")printf "%s ", tolower($1)"="v}')
    printf "  %-8s subvol=%-8s snapshots=%-4s NUMBER_LIMIT=%-4s %s\n" \
           "$c" "${sub:-?}" "$n" "${numlim:-?}" "$tl"
  done
  echo
  for c in "${CFGS[@]}"; do
    echo "-- snapper -c $c list"
    snapper -c "$c" list --columns number,type,date,description 2>/dev/null
    echo
  done
else
  echo "(no snapper)"
fi

# ---- per-snapshot exclusive space --------------------------------------
hr; echo "  SPACE ONLY A SNAPSHOT IS HOLDING  (delete that snapshot -> that much frees)"; hr
qgroups_on(){ btrfs qgroup show -pcre --sync "$1" >/dev/null 2>&1; }

WALK=""
for c in "${CFGS[@]}"; do
  sv=$(getcfg "$c" SUBVOLUME); [ -d "$sv" ] || continue
  sd="$sv/.snapshots"; [ -d "$sd" ] || continue
  echo "-- config $c   ($sv)"
  if qgroups_on "$sv"; then
    SVMAP=$(btrfs subvolume list "$sv" | awk '{print $2"\t"$NF}')
    btrfs qgroup show -pcre --sync --raw "$sv" | awk -v svmap="$SVMAP" '
      BEGIN{n=split(svmap,L,"\n");for(i=1;i<=n;i++){split(L[i],a,"\t");p[a[1]]=a[2]}
            printf "   %-12s %10s %10s  %s\n","qgroup","EXCL","refer","subvolume"}
      NR>2 && $1~/^0\//{id=$1;sub(/^0\//,"",id)
        printf "   %-12s %8.2fG %8.2fG  %s\n",$1,$3/1073741824,$2/1073741824,(id in p?p[id]:"?")}' \
      | sort -k2 -rh | head -25
  else
    if [ -z "$WALK" ]; then
      read -rp "   qgroups off. walk extents with 'btrfs filesystem du'? slow (minutes). [y/N] " a </dev/tty || a=n
      [[ "$a" =~ ^[Yy] ]] && WALK=yes || WALK=no
    fi
    if [ "$WALK" = yes ]; then
      { for d in "$sd"/[0-9]*/snapshot; do
          [ -d "$d" ] || continue
          e=$(btrfs filesystem du -s --raw "$d" 2>/dev/null | awk 'NR==2{print $2}')
          [ -n "$e" ] && printf '%s\t%s\n' "$e" "$d"
        done; } | sort -rn | while IFS=$'\t' read -r bytes path; do
          printf '   %12s excl  %s\n' "$(human "$bytes")" "$path"
        done
    else
      echo "   -> 'btrfs quota enable $sv && btrfs quota rescan -w $sv' then rerun,"
      echo "      or 'btdu $sv' for a fast sampled view."
    fi
  fi
  echo
done
echo "  trim:  snapper -c <cfg> delete <N>[-<M>]     snapper -c <cfg> cleanup number"
echo "  retention: NUMBER_LIMIT / TIMELINE_LIMIT_* above  (snapper -c <cfg> set-config KEY=VAL)"
echo

# ---- biggest live dirs -------------------------------------------------
hr; echo "  BIGGEST LIVE DIRECTORIES (top 25 per mount)"; hr
for MNT in "${MNTS[@]}"; do
  echo "-- $MNT"
  du -xh -d4 "$MNT" 2>/dev/null | sort -rh | head -25
  echo
done

# ---- deleted-but-open -------------------------------------------------
hr; echo "  DELETED-BUT-OPEN FILES (>50 MB; space frees when the process restarts)"; hr
if command -v lsof >/dev/null; then
  lsof -nP +L1 2>/dev/null | awk '($NF=="(deleted)"||$NF~/\(deleted\)$/) && $7+0>52428800{
    seen[$2"\t"$1]+=$7} END{for(k in seen){split(k,a,"\t");
    printf "  %-16s pid=%-8s %8.1f MB\n",a[2],a[1],seen[k]/1048576}}' | sort -k4 -rn | head -20
else
  echo "  (lsof not installed)"
fi
echo

# ---- podman (as the invoking user, not root) -------------------------
hr; echo "  CONTAINER IMAGES / STORAGE"; hr
if command -v podman >/dev/null && [ -n "${USER_NAME:-}" ] && [ "$USER_NAME" != root ]; then
  echo "  (podman as $USER_NAME)"
  sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$(id -u "$USER_NAME")" \
       podman system df 2>/dev/null || echo "  (could not query rootless podman)"
  echo
  echo "  podman image prune -a       # images no container uses"
  echo "  podman system prune -a --volumes   # + build cache + unused volumes"
elif command -v podman >/dev/null; then
  podman system df
fi
