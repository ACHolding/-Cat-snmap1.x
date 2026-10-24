#!/usr/bin/env bash
#===============================================================================
#  cat's nmap v0.1.1.sh
#  A small, opinionated wrapper around nmap.
#  bash 3.2-safe: no associative arrays, no set -u array pitfalls.
#===============================================================================

# If we were launched by sh/dash/zsh, hand ourselves to bash and start over.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -o pipefail

VERSION="0.1.1"
PROG="$(basename "$0")"

#-------------------------------------------------------------------------------
# Colors
#-------------------------------------------------------------------------------
if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'
  BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=; G=; Y=; B=; C=; BOLD=; N=
fi

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
TARGET=""
PROFILE="quick"
PORTS=""
OUTDIR="./catnmap-out"
SHOW_ALL=0
NO_DNS=0
DRY_RUN=0
NMAP_EXTRA=()

PROFILE_LIST="quick fast version full stealth udp vuln aggressive ping"

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
die()  { printf '%s[!]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
warn() { printf '%s[~]%s %s\n' "$Y" "$N" "$*" >&2; }
info() { printf '%s[*]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }

profile_desc() {
  case "$1" in
    quick)      echo "Top 100 ports, fast timing" ;;
    fast)       echo "Top 1000 ports" ;;
    version)    echo "Service + default script detection" ;;
    full)       echo "All 65535 TCP ports" ;;
    stealth)    echo "SYN half-open, slow (needs root)" ;;
    udp)        echo "Top 100 UDP ports (needs root)" ;;
    vuln)       echo "Version detection + vuln NSE scripts" ;;
    aggressive) echo "OS, version, scripts, traceroute" ;;
    ping)       echo "Host discovery only" ;;
    *)          echo "?" ;;
  esac
}

profile_flags() {
  case "$1" in
    quick)      echo "-T4 -F" ;;
    fast)       echo "-T4 --top-ports 1000" ;;
    version)    echo "-sV -sC -T4" ;;
    full)       echo "-T4 -p-" ;;
    stealth)    if [ "$IS_ROOT" -eq 1 ]; then echo "-sS -T2 -Pn"; else echo "-sT -T2 -Pn"; fi ;;
    udp)        echo "-sU --top-ports 100 -T4" ;;
    vuln)       echo "-sV --script vuln" ;;
    aggressive) echo "-A -T4" ;;
    ping)       echo "-sn" ;;
    *)          die "Unknown profile: $1" ;;
  esac
}

list_profiles() {
  printf '%sAvailable profiles:%s\n' "$BOLD" "$N"
  local p
  for p in $PROFILE_LIST; do
    printf '  %s%s%-10s%s %s\n' "$C" "$BOLD" "$p" "$N" "$(profile_desc "$p")"
  done
}

usage() {
  cat <<EOF
${BOLD}${PROG}${N} v${VERSION} — friendly nmap wrapper

${BOLD}USAGE${N}
  bash "${PROG}" -t <target> [-p <profile>] [options] [-- <extra nmap args>]

${BOLD}OPTIONS${N}
  -t <target>   Target host, IP, CIDR or range        (required)
  -p <profile>  Scan profile                          (default: quick)
  -P <ports>    Override port spec, e.g. 22,80,443 or 1-1024
  -o <dir>      Output directory                      (default: ./catnmap-out)
  -a            Show all ports, not just open ones
  -n            Skip DNS resolution
  -d            Dry run — print the command, don't execute
  -l            List available profiles
  -h            Show this help
  -v            Show version

${BOLD}EXAMPLES${N}
  bash "${PROG}" -t 192.168.1.0/24 -p ping
  bash "${PROG}" -t scanme.nmap.org -p version
  bash "${PROG}" -t 10.0.0.5 -p full -P 1-10000 -o ~/scans
  bash "${PROG}" -t 10.0.0.5 -p quick -- -sV --script http-title

$(list_profiles)
EOF
}

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--target)  [ -n "${2:-}" ] || die "-t needs a target"; TARGET="$2"; shift 2 ;;
    -p|--profile) [ -n "${2:-}" ] || die "-p needs a profile"; PROFILE="$2"; shift 2 ;;
    -P|--ports)   [ -n "${2:-}" ] || die "-P needs a port spec"; PORTS="$2"; shift 2 ;;
    -o|--out)     [ -n "${2:-}" ] || die "-o needs a directory"; OUTDIR="$2"; shift 2 ;;
    -a|--all)     SHOW_ALL=1; shift ;;
    -n|--no-dns)  NO_DNS=1; shift ;;
    -d|--dry-run) DRY_RUN=1; shift ;;
    -l|--list)    list_profiles; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    -v|--version) echo "$PROG v$VERSION"; exit 0 ;;
    --)           shift; NMAP_EXTRA=("$@"); break ;;
    -*)           die "Unknown option: $1  (try -h)" ;;
    *)            TARGET="$1"; shift ;;
  esac
done

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
command -v nmap >/dev/null 2>&1 || die "nmap not found in PATH. Install it first."
[ -n "$TARGET" ] || { usage; echo; die "No target given. Use -t <target>."; }

FOUND=0
for p in $PROFILE_LIST; do [ "$p" = "$PROFILE" ] && FOUND=1; done
[ "$FOUND" -eq 1 ] || die "Unknown profile '$PROFILE'. Use -l to list them."

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

if [ "$PROFILE" = "stealth" ] && [ "$IS_ROOT" -eq 0 ]; then
  warn "Not root — falling back to a TCP connect scan (-sT)."
fi
if [ "$PROFILE" = "udp" ] && [ "$IS_ROOT" -eq 0 ]; then
  warn "Not root — UDP scan will be slow or partly restricted."
fi

FLAGS=()
read -ra FLAGS <<< "$(profile_flags "$PROFILE")"
[ -n "$PORTS" ] && FLAGS+=(-p "$PORTS")
[ "$NO_DNS" -eq 1 ] && FLAGS+=(-n)

#-------------------------------------------------------------------------------
# Output paths
#-------------------------------------------------------------------------------
SAFE_TARGET=$(printf '%s' "$TARGET" | tr -c 'a-zA-Z0-9._-' '_')
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR" || die "Cannot create output directory: $OUTDIR"
BASE="${OUTDIR%/}/${SAFE_TARGET}_${PROFILE}_${STAMP}"

CMD=(nmap)
CMD+=("${FLAGS[@]}")
if [ "$PROFILE" != "ping" ] && [ "$SHOW_ALL" -eq 0 ]; then CMD+=(--open); fi
CMD+=(-oA "$BASE" "$TARGET")
if [ "${#NMAP_EXTRA[@]}" -gt 0 ]; then CMD+=("${NMAP_EXTRA[@]}"); fi

#-------------------------------------------------------------------------------
# Run
#-------------------------------------------------------------------------------
echo
info "Target  : $TARGET"
info "Profile : $PROFILE  ($(profile_desc "$PROFILE"))"
info "Output  : ${BASE}.{nmap,gnmap,xml}"
echo
info "Command : ${CMD[*]}"
echo

if [ "$DRY_RUN" -eq 1 ]; then
  ok "Dry run — nothing executed."
  exit 0
fi

START=$(date +%s)
"${CMD[@]}"
RC=$?
ELAPSED=$(( $(date +%s) - START ))

echo
if [ "$RC" -eq 0 ]; then
  OPEN_COUNT=0
  if [ -f "${BASE}.gnmap" ]; then
    OPEN_COUNT=$(grep -o '/open/' "${BASE}.gnmap" 2>/dev/null | wc -l | tr -d ' ')
  fi
  ok "Scan finished in ${ELAPSED}s. Open ports found: ${OPEN_COUNT}"
  info "Results: ${BASE}.nmap (text)  ${BASE}.gnmap (grep)  ${BASE}.xml (parse)"
else
  warn "nmap exited with code ${RC} after ${ELAPSED}s."
  warn "Partial results (if any) are at ${BASE}.*"
fi

exit $RC