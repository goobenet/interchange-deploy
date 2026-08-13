#!/usr/bin/env bash
# =============================================================================
#  Interchange — one-line LXC/CT deployer for Proxmox VE  (Optimized Media Group)
# =============================================================================
#  Deploys an Interchange product into an unprivileged Debian 13 container from
#  our self-contained template: creates the CT, wires the dual-NIC AoIP +
#  management topology, and prints the control-UI URL and Install ID.
#
#  Usage (on the PROXMOX HOST, as root):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/goobenet/interchange-deploy/main/interchange-ct.sh)"
#
#  ── CONTAINERS vs VMs ───────────────────────────────────────────────────────
#  A container SHARES THE HOST'S KERNEL, and therefore the host's system clock.
#  That is the whole reason to prefer a CT for AoIP: discipline the clock once
#  on the host and every container inherits a studio-locked clock. A VM has its
#  own kernel and must run its own ptp4l against a virtual NIC that has no PTP
#  hardware clock, which will not lock properly.
#
#  The consequence is that PTP for containers is a HOST concern, so this script
#  has to touch the host's clock configuration — and it will not do that behind
#  your back. See the "PTP" step: if the host already runs PTP, you are asked
#  what to do, and the default is always to leave your setup alone.
#
#  If you would rather deploy a VM, use interchange-vm.sh instead. The two are
#  deliberately separate scripts.
# =============================================================================
set -euo pipefail

# ─── DISTRIBUTION ENDPOINTS ─────────────────────────────────────────────────
# Change this one line to move the distribution (e.g. to another host or org).
ARTIFACT_BASE="${ARTIFACT_BASE:-https://github.com/goobenet/interchange-deploy/releases/download/v2026.08.191}"

# Compiled into every shipped binary; a build without it rejects every license.
readonly ISSUER_PUBKEY="02e412906f2a575d25f431899f970d6bb153224a4f0031e5ef9938f9f4ce7277"

# host-PTP kit (only fetched when you choose --ptp install). Pinned like every
# other artifact: this one runs as root on the hypervisor itself.
readonly HOSTPTP_SHA="76f2ab4f38de6c2469f4fa1029b018d2465f594db2f52fe637253cc11ece1e50"

# ─── PRODUCT MANIFEST ───────────────────────────────────────────────────────
# key|template|template sha256|deb|deb sha256|binary sha256|service|port|ctid|hostname|aoip ip
readonly PRODUCTS=(
"gateway|interchange-gateway-2026.08.187-trixie-amd64.tar.zst|258ecd149cdcbe812981964ca7aaac7c3b35eca9775aa9a01267a8d3480782f0|hls2aes67_2026.08.187_amd64.deb|f2983a61fdc425e5c39cac7b7930646fe9f66e6758a70e6c49c2380549169274|396f8a6adc70f3fbba1cd128d297cf06475df9c39f5e5ea221414f79689ee41e|hls2aes67|8088|960|gateway|192.168.24.220/24"
"onramp|interchange-onramp-2026.08.191-trixie-amd64.tar.zst|7f0e783ebbf2d1b19d48c7d4e5a5455e263085732c936db52a4d6bffe70dfd34|aes672hls_2026.08.191_amd64.deb|bb4d04f7d188eafe3e93d351c3fcdf37c339c8e008dad8e5b18c3088a21dd987|24f2d82f6fd7ea0ae90c64afd69696385caed33cef38bcbf387cca2f62d3a56e|aes672hls|8080|950|onramp|192.168.24.230/24"
)
readonly PRODUCT_LABELS="gateway = Interchange Gateway (HLS/Icecast -> AES67/Livewire)
onramp  = Interchange Onramp  (AES67/Livewire -> HLS)"

PRODUCT="" CTID="" HOSTNAME="" STORAGE="local-lvm"
CORES=2 MEMORY=1024 DISK=8
AOIP_BRIDGE="vmbr1" AOIP_IP=""
MGMT_BRIDGE="vmbr0" MGMT_IP="dhcp" MGMT_GW=""
NAMESERVER="8.8.8.8" SSHKEYFILE="" CTPASS=""
PTP_NIC="" PTP_CHOICE="" ASSUME_YES=0 START_CT=1

C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_INF=$'\e[1;36m'; C_OFF=$'\e[0m'
ok(){   echo "${C_OK}  ✔${C_OFF} $*"; }
info(){ echo "${C_INF}  →${C_OFF} $*"; }
warn(){ echo "${C_WARN}  !${C_OFF} $*" >&2; }
die(){  echo "${C_ERR}  ✖ $*${C_OFF}" >&2; exit 1; }
step(){ echo; echo "${C_INF}══ $* ${C_OFF}"; }

# `set -e` kills the script with no output at all, which is the worst possible
# failure for something a customer runs once. Anything that exits without going
# through die() is a bug in this script — say so, and say where.
trap 'rc=$?; [[ $rc -ne 0 ]] && printf "\n%s  ✖ unexpected failure (exit %s) at line %s of %s%s\n%s    This is a bug in the deployer, not your host. Please report it to info@optimizedmedia.net%s\n" "$C_ERR" "$rc" "$LINENO" "${BASH_SOURCE[0]##*/}" "$C_OFF" "$C_ERR" "$C_OFF" >&2; exit $rc' ERR

usage(){ cat <<EOF
Interchange LXC/CT deployer — run on the Proxmox host as root.

  --product <gateway|onramp>   which product to deploy
  --ctid <id>                  container id            (default: next free)
  --hostname <name>            container hostname
  --storage <name>             rootfs storage          (default: $STORAGE)
  --cores <n> --memory <MB> --disk <GB>
  --aoip-bridge <vmbrX>        AoIP bridge             (default: auto-detected)
  --aoip-ip <cidr>             AoIP static address, gateway-less
  --mgmt-bridge <vmbrX>        management bridge       (default: auto-detected)
  --mgmt-ip <cidr|dhcp>        management address      (default: dhcp)
  --mgmt-gw <ip>               management gateway      (static only)
  --nameserver <ip>            DNS for the container
  --password <pw>              root password in the CT
  --sshkey <file>              public key to inject
  --ptp <keep|install|skip>    what to do about host PTP (default: ask)
       keep    = leave the host's existing PTP setup untouched
       install = install/refresh the Interchange host-PTP kit
       skip    = do not configure PTP at all
  --ptp-nic <iface>            AoIP NIC for PTP (only with --ptp install)
  --no-start                   create the CT but leave it stopped
  --yes                        accept defaults, no prompts (implies --ptp keep)
  --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product) PRODUCT=$2; shift 2;;      --ctid) CTID=$2; shift 2;;
    --hostname) HOSTNAME=$2; shift 2;;    --storage) STORAGE=$2; shift 2;;
    --cores) CORES=$2; shift 2;;          --memory) MEMORY=$2; shift 2;;
    --disk) DISK=$2; shift 2;;            --aoip-bridge) AOIP_BRIDGE=$2; shift 2;;
    --aoip-ip) AOIP_IP=$2; shift 2;;      --mgmt-bridge) MGMT_BRIDGE=$2; shift 2;;
    --mgmt-ip) MGMT_IP=$2; shift 2;;      --mgmt-gw) MGMT_GW=$2; shift 2;;
    --nameserver) NAMESERVER=$2; shift 2;;--password) CTPASS=$2; shift 2;;
    --sshkey) SSHKEYFILE=$2; shift 2;;    --ptp) PTP_CHOICE=$2; shift 2;;
    --ptp-nic) PTP_NIC=$2; shift 2;;      --no-start) START_CT=0; shift;;
    --yes|-y) ASSUME_YES=1; shift;;       --help|-h) usage; exit 0;;
    *) die "unknown option: $1  (try --help)";;
  esac
done

ask(){ local p=$1 d=$2 v=$3 a
  if [[ $ASSUME_YES -eq 1 ]]; then printf -v "$v" '%s' "$d"; return; fi
  read -r -p "  $p [$d]: " a </dev/tty || a=""; printf -v "$v" '%s' "${a:-$d}"; }

next_free_ctid(){ local want=$1 used id
  used=" $( { pct list 2>/dev/null | awk 'NR>1{print $1}'; qm list 2>/dev/null | awk 'NR>1{print $1}'; } | tr '\n' ' ' ) "
  [[ "$used" != *" $want "* ]] && { echo "$want"; return; }
  for (( id=want; id<=999999; id++ )); do [[ "$used" != *" $id "* ]] && { echo "$id"; return; }; done
  echo "$want"; }
list_storages(){ pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}'; }
list_tmpl_store(){ pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}' | head -1; }
list_bridges(){ ip -br link show type bridge 2>/dev/null | awk '{print $1}' | grep -v '^fwbr'; }
guess_mgmt_bridge(){ ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1; }
guess_aoip_bridge(){ local d b; d=$(guess_mgmt_bridge)
  for b in $(list_bridges); do [[ "$b" != "$d" ]] && { echo "$b"; return; }; done; }

step "Preflight"
[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "'pct' not found — this must run on a Proxmox VE host"
for t in curl sha256sum awk; do command -v $t >/dev/null || die "missing tool: $t"; done
PVEVER=$(pveversion 2>/dev/null | sed 's/pve-manager\///;s/\/.*//' || echo '?')
ok "Proxmox VE $PVEVER, running as root"

# Our container templates are Debian 13 (trixie). Proxmox validates a container's
# distro release against a table in its own perl libs and REFUSES to create one
# it does not recognise ("Unsupported debian version '13.6'"). PVE releases older
# than trixie itself cannot create these containers at all — nothing about the
# template can work around it. Detect it here rather than after a 247 MB
# download and a failed create.
readonly TEMPLATE_DEBIAN_MAJOR=13
DEBPM=/usr/share/perl5/PVE/LXC/Setup/Debian.pm
if [[ -r "$DEBPM" ]]; then
  PVE_MAXDEB=$(grep -oE 'DEBIAN_MAXIMUM_RELEASE[^0-9]*[0-9]+' "$DEBPM" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
  KNOWS_TRIXIE=$(grep -c 'trixie' "$DEBPM" 2>/dev/null || true)
  if [[ -n "$PVE_MAXDEB" ]] && (( PVE_MAXDEB < TEMPLATE_DEBIAN_MAJOR )) && (( KNOWS_TRIXIE == 0 )); then
    echo >&2
    die "this Proxmox version cannot create Debian ${TEMPLATE_DEBIAN_MAJOR} containers.

  Proxmox VE $PVEVER validates a container's distro release and refuses anything
  newer than Debian $PVE_MAXDEB. Our container templates are Debian ${TEMPLATE_DEBIAN_MAJOR} (trixie), so
  'pct create' would fail with: Unsupported debian version '13.6'.

  This is a limit in Proxmox itself — no template setting avoids it.

  Two ways forward, both fine:

    1. Deploy a VM instead. Proxmox does not inspect a VM's guest OS, so the
       Debian 13 image works on this host today:
         bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/goobenet/interchange-deploy/main/interchange-vm.sh)\"

    2. Upgrade Proxmox to a release that knows trixie (PVE 8.4+ / 9.x), then
       re-run this script.

  If neither is possible, contact info@optimizedmedia.net — we can look at
  building a Debian 12 container template for older hosts."
  fi
fi

if [[ -z "$PRODUCT" ]]; then echo; echo "$PRODUCT_LABELS"; echo; ask "Product to deploy" "gateway" PRODUCT; fi
ROW=""; for r in "${PRODUCTS[@]}"; do [[ "${r%%|*}" == "$PRODUCT" ]] && ROW="$r"; done
[[ -n "$ROW" ]] || die "unknown product '$PRODUCT' (expected: gateway, onramp)"
IFS='|' read -r _ TMPL TMPL_SHA DEB_NAME DEB_SHA BIN_SHA SERVICE WEB_PORT D_CTID D_HOST D_AOIP <<<"$ROW"
ok "product: $PRODUCT"

# ═══ PTP ════════════════════════════════════════════════════════════════════
# The step most likely to cause harm, so it is explicit, conservative, and
# never silently supersedes an existing setup. Containers inherit the HOST's
# clock, so this is a host-level decision that outlives the container.
step "PTP / clock discipline (host-level)"
PTP_STATE="none"; PTP_DETAIL=""
HAVE_BIN=0; command -v ptp4l >/dev/null && HAVE_BIN=1
# `systemctl list-unit-files` exits 1 when the pattern matches NOTHING (unlike
# list-units, which exits 0). Under `set -e` + `pipefail` that killed the script
# silently on any host with no PTP installed — i.e. exactly the hosts that most
# need this step. Both are guarded; "no match" is a normal answer here.
ACTIVE_UNITS=$(systemctl list-units --type=service --state=running --no-legend 'ptp4l*' 'phc2sys*' 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)
ENABLED_UNITS=$(systemctl list-unit-files --no-legend 'ptp4l*' 'phc2sys*' 2>/dev/null | awk '$2=="enabled"{print $1}' | tr '\n' ' ' || true)
RUNNING_PROCS=$(pgrep -a 'ptp4l|phc2sys' 2>/dev/null | head -3 || true)
OURS=0; [[ -d /etc/interchange/host-ptp ]] && compgen -G "/etc/interchange/host-ptp/*.mode" >/dev/null 2>&1 && OURS=1

if [[ $OURS -eq 1 ]]; then
  PTP_STATE="ours"
  PTP_DETAIL="Interchange host-PTP kit already installed (NIC(s): $(basename -s .mode /etc/interchange/host-ptp/*.mode 2>/dev/null | tr '\n' ' '))"
elif [[ -n "$ACTIVE_UNITS$ENABLED_UNITS$RUNNING_PROCS" ]]; then
  PTP_STATE="theirs"
  PTP_DETAIL="existing PTP on this host — units: ${ACTIVE_UNITS:-none running} ${ENABLED_UNITS:+(enabled: $ENABLED_UNITS)}"
elif [[ $HAVE_BIN -eq 1 ]]; then
  PTP_STATE="installed-idle"; PTP_DETAIL="linuxptp is installed but no ptp4l/phc2sys is running or enabled"
fi

case "$PTP_STATE" in
  ours)  ok "$PTP_DETAIL" ;;
  theirs)
    warn "$PTP_DETAIL"
    [[ -n "$RUNNING_PROCS" ]] && echo "$RUNNING_PROCS" | sed 's/^/      /'
    echo
    echo "  You are ALREADY running PTP on this host. Installing the Interchange kit"
    echo "  would overwrite /etc/systemd/system/ptp4l@.service and phc2sys@.service and"
    echo "  start another ptp4l — two instances on one NIC fight over the clock."
    echo
    echo "    keep    (recommended) leave your PTP exactly as it is. The container"
    echo "            inherits the host clock either way, so your setup still works."
    echo "    install replace the unit templates with ours and manage PTP here."
    echo "    skip    same as keep; just don't ask again."
    ;;
  installed-idle) info "$PTP_DETAIL" ;;
  none) info "no PTP configured on this host" ;;
esac

if [[ -z "$PTP_CHOICE" ]]; then
  if [[ $ASSUME_YES -eq 1 ]]; then
    PTP_CHOICE=keep
  else
    case "$PTP_STATE" in
      theirs) ask "PTP: keep / install / skip" "keep" PTP_CHOICE ;;
      ours)   ask "PTP: keep (already ours) / install (refresh) / skip" "keep" PTP_CHOICE ;;
      *)      echo "  The Interchange kit disciplines the host clock from the AoIP grandmaster and"
              echo "  guards against an ARB-timescale master stepping your system clock."
              ask "PTP: install / skip" "install" PTP_CHOICE ;;
    esac
  fi
fi
case "$PTP_CHOICE" in
  keep|skip) ok "PTP: leaving the host's clock configuration untouched" ;;
  install)
    if [[ -z "$PTP_NIC" ]]; then
      CAND=$(ip -br link show 2>/dev/null | awk '$2=="UP"{print $1}' | grep -vE '^(lo|vmbr|fwbr|veth|tap)' | tr '\n' ' ')
      echo "    candidate AoIP NICs: ${CAND:-none found}"
      warn "a NIC enslaved to a bridge will NOT receive PTP multicast — prefer a dedicated NIC"
      ask "AoIP NIC for PTP" "${CAND%% *}" PTP_NIC
    fi
    [[ -n "$PTP_NIC" ]] && ip link show "$PTP_NIC" &>/dev/null || die "no such interface: '$PTP_NIC'"
    ok "PTP: will install the Interchange kit on $PTP_NIC (after the container is created)"
    ;;
  *) die "invalid --ptp value '$PTP_CHOICE' (expected keep, install or skip)" ;;
esac

step "Settings"
SUGGEST=$(next_free_ctid "$D_CTID")
[[ "$SUGGEST" != "$D_CTID" ]] && info "CT $D_CTID is taken — suggesting $SUGGEST"
AVAIL_STOR=$(list_storages | tr '\n' ' '); AVAIL_BR=$(list_bridges | tr '\n' ' ')
grep -qw "$STORAGE" <<<"$AVAIL_STOR" || STORAGE=$(list_storages | head -1)
G_A=$(guess_aoip_bridge); G_M=$(guess_mgmt_bridge)
[[ -n "$G_A" ]] && AOIP_BRIDGE="$G_A"; [[ -n "$G_M" ]] && MGMT_BRIDGE="$G_M"

[[ -n "$CTID"     ]] || ask "Container ID" "$SUGGEST" CTID
[[ -n "$HOSTNAME" ]] || ask "Hostname"     "$D_HOST"  HOSTNAME
[[ $ASSUME_YES -eq 1 ]] || {
  ask "Cores" "$CORES" CORES; ask "Memory (MB)" "$MEMORY" MEMORY; ask "Disk (GB)" "$DISK" DISK
  echo "    available storage: ${AVAIL_STOR:-none}"; ask "Rootfs storage" "$STORAGE" STORAGE
  echo "    bridges: ${AVAIL_BR:-none}   (AoIP = the gateway-less one)"
  ask "AoIP bridge" "$AOIP_BRIDGE" AOIP_BRIDGE
}
[[ -n "$AOIP_IP" ]] || ask "AoIP address (CIDR, no gateway)" "$D_AOIP" AOIP_IP
[[ $ASSUME_YES -eq 1 ]] || {
  ask "Management bridge" "$MGMT_BRIDGE" MGMT_BRIDGE
  ask "Management address (dhcp or CIDR)" "$MGMT_IP" MGMT_IP
  [[ "$MGMT_IP" != "dhcp" ]] && ask "Management gateway" "$MGMT_GW" MGMT_GW
}

pct status "$CTID" &>/dev/null && die "CT $CTID already exists — next free id is $(next_free_ctid "$CTID")"
pvesm status --storage "$STORAGE" &>/dev/null || die "storage '$STORAGE' not found"
for b in "$AOIP_BRIDGE" "$MGMT_BRIDGE"; do ip link show "$b" &>/dev/null || die "bridge '$b' does not exist"; done
[[ "$AOIP_IP" == */* ]] || die "AoIP address must be CIDR (e.g. 192.168.24.220/24)"
ok "CT $CTID '$HOSTNAME' — ${CORES}c/${MEMORY}MB/${DISK}G on $STORAGE"
ok "AoIP $AOIP_IP on $AOIP_BRIDGE (gateway-less) · mgmt $MGMT_IP on $MGMT_BRIDGE"
if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "  Proceed? [Y/n]: " c </dev/tty || c=""; [[ "${c:-Y}" =~ ^[Yy]$|^$ ]] || { echo "aborted"; exit 0; }
fi

step "Template"
TSTORE=$(list_tmpl_store); [[ -n "$TSTORE" ]] || die "no storage on this host accepts container templates (vztmpl)"
TDIR="/var/lib/vz/template/cache"; mkdir -p "$TDIR"; TPATH="$TDIR/$TMPL"
if [[ -f "$TPATH" ]] && [[ "$(sha256sum "$TPATH" | awk '{print $1}')" == "$TMPL_SHA" ]]; then
  ok "template already present and verified"
else
  info "downloading $TMPL (this is the whole product + its dependencies)"
  curl -fSL --retry 3 --connect-timeout 20 --progress-bar -o "$TPATH" "$ARTIFACT_BASE/$TMPL" \
    || die "template download failed from $ARTIFACT_BASE"
  GOT=$(sha256sum "$TPATH" | awk '{print $1}')
  [[ "$GOT" == "$TMPL_SHA" ]] || { rm -f "$TPATH"; die "sha256 MISMATCH
    expected $TMPL_SHA
    got      $GOT
  Refusing to deploy an artifact that is not the published release."; }
  ok "sha256 verified: ${GOT:0:16}…"
fi

step "Creating CT $CTID"
NET0="name=eth0,bridge=$AOIP_BRIDGE,ip=$AOIP_IP"     # AoIP: never a gateway
NET1="name=eth1,bridge=$MGMT_BRIDGE,ip=$MGMT_IP"
[[ "$MGMT_IP" != "dhcp" && -n "$MGMT_GW" ]] && NET1="$NET1,gw=$MGMT_GW"
CREATE=(pct create "$CTID" "$TSTORE:vztmpl/$TMPL" --unprivileged 1 --hostname "$HOSTNAME"
        --cores "$CORES" --memory "$MEMORY" --swap 512 --rootfs "$STORAGE:$DISK"
        --net0 "$NET0" --net1 "$NET1" --nameserver "$NAMESERVER"
        --features nesting=1 --onboot 1)
[[ -n "$CTPASS" ]] && CREATE+=(--password "$CTPASS")
[[ -n "$SSHKEYFILE" && -f "$SSHKEYFILE" ]] && CREATE+=(--ssh-public-keys "$SSHKEYFILE")
"${CREATE[@]}" >/dev/null || die "pct create failed"
ok "container created (unprivileged, nesting=1, onboot)"

if [[ $START_CT -eq 1 ]]; then
  pct start "$CTID" >/dev/null; ok "container started"
  for _ in $(seq 1 30); do pct exec "$CTID" -- true 2>/dev/null && break; sleep 1; done
  if pct exec "$CTID" -- systemctl is-active --quiet "$SERVICE" 2>/dev/null; then ok "service '$SERVICE' is active"
  else
    pct exec "$CTID" -- systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
    sleep 2
    pct exec "$CTID" -- systemctl is-active --quiet "$SERVICE" 2>/dev/null \
      && ok "service '$SERVICE' is active" \
      || warn "service '$SERVICE' not active — check: pct exec $CTID -- systemctl status $SERVICE"
  fi
  if pct exec "$CTID" -- test -x "/usr/bin/$SERVICE" 2>/dev/null; then
    if pct exec "$CTID" -- grep -a -q "$ISSUER_PUBKEY" "/usr/bin/$SERVICE" 2>/dev/null
      then ok "issuer key present in the installed binary (licensable)"
      else warn "installed binary has NO issuer key — it will reject every license"; fi
  fi
fi

if [[ "$PTP_CHOICE" == "install" ]]; then
  step "Installing the Interchange host-PTP kit on $PTP_NIC"
  warn "this replaces /etc/systemd/system/ptp4l@.service and phc2sys@.service on the HOST"
  KIT=$(mktemp -d)
  if curl -fsSL --retry 2 -o "$KIT/host-ptp.tar.gz" "$ARTIFACT_BASE/host-ptp.tar.gz" 2>/dev/null; then
    GOT=$(sha256sum "$KIT/host-ptp.tar.gz" | awk '{print $1}')
    if [[ "$GOT" != "$HOSTPTP_SHA" ]]; then
      warn "host-ptp kit sha256 mismatch — refusing to run it"
      warn "  expected $HOSTPTP_SHA"
      warn "  got      $GOT"
    else
      tar -xzf "$KIT/host-ptp.tar.gz" -C "$KIT" \
        && bash "$KIT"/host-ptp/install.sh "$PTP_NIC" \
        || warn "host-PTP install reported an error"
    fi
  else
    warn "host-ptp kit not available at $ARTIFACT_BASE — install it from the source repo:"
    warn "  packaging/host-ptp/install.sh $PTP_NIC"
  fi
  rm -rf "$KIT"
fi

MGMT_ADDR=$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show eth1 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | tr -d '\r' || true)
[[ -n "$MGMT_ADDR" ]] || MGMT_ADDR="<container-ip>"
# Ask from the HOST, not from inside the container: the product template is a
# minimal rootfs and does not ship curl. The host is guaranteed to have it —
# preflight requires it.
INSTALL_ID=""
if [[ "$MGMT_ADDR" != "<container-ip>" ]]; then
  INSTALL_ID=$(curl -s --max-time 6 "http://$MGMT_ADDR:$WEB_PORT/api/license" 2>/dev/null \
               | sed -nE 's/.*"install_id":"([^"]+)".*/\1/p' | head -1 || true)
fi

cat <<EOF

${C_OK}══════════════════════════════════════════════════════════════${C_OFF}
 ${C_OK}Interchange ${PRODUCT} deployed — CT $CTID ($HOSTNAME)${C_OFF}
${C_OK}══════════════════════════════════════════════════════════════${C_OFF}

  Control UI     http://${MGMT_ADDR}:${WEB_PORT}/
  AoIP interface ${AOIP_IP} on ${AOIP_BRIDGE}  (no gateway — correct for AoIP)
  Service        pct exec ${CTID} -- systemctl status ${SERVICE}
  Shell          pct enter ${CTID}
${INSTALL_ID:+
  Install ID     ${INSTALL_ID}
                 Send this to info@optimizedmedia.net to obtain a license token.}

  Clock          $(case "$PTP_CHOICE" in
                    install) echo "Interchange host-PTP kit installed on $PTP_NIC";;
                    *) echo "left as you had it — this container inherits the HOST clock,";;
                  esac)
$([[ "$PTP_CHOICE" != "install" ]] && echo "                 so discipline the host clock however you prefer.")

EOF
exit 0
