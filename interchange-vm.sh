#!/usr/bin/env bash
# =============================================================================
#  Interchange — one-line VM deployer for Proxmox VE  (Optimized Media Group)
# =============================================================================
#  Deploys an Interchange product into a fresh Debian 13 cloud-init VM on a
#  Proxmox host: creates the VM, wires the dual-NIC AoIP + management topology,
#  installs the product .deb with its dependencies, verifies the artifact, and
#  prints the control-UI URL and licensing Install ID.
#
#  Usage (on the PROXMOX HOST, as root):
#     bash -c "$(curl -fsSL https://<host>/packaging/vm/interchange-vm.sh)"
#
#  Non-interactive / scripted:
#     ./interchange-vm.sh --product gateway --vmid 970 --aoip-ip 192.168.24.222/24 --yes
#
#  Lab use, before the artifacts are published anywhere public:
#     ./interchange-vm.sh --product gateway --local-deb /root/gate-artifacts/hls2aes67_2026.08.187_amd64.deb
#
#  Run  --help  for every option.
# =============================================================================
set -euo pipefail

# ─── DISTRIBUTION ENDPOINTS ─────────────────────────────────────────────────
# Change these two lines to move the whole distribution. Everything else keys
# off them. Moving to GitHub is exactly this and nothing more, e.g.
#   ARTIFACT_BASE="https://github.com/<org>/interchange/releases/download/v2026.08"
#
# ⚠️  SECURITY: prefer an HTTPS endpoint. This script is piped into a root shell
#     on a hypervisor; over plain HTTP anyone able to MITM the connection gets
#     root on the customer's virtualisation host. The sha256 pins below limit
#     the blast radius for the *artifacts*, but they cannot protect the fetch of
#     this script itself — only TLS can. Publish over HTTPS before shipping.
ARTIFACT_BASE="${ARTIFACT_BASE:-https://github.com/goobenet/interchange-deploy/releases/download/v2026.08.191}"
DEBIAN_IMAGE_URL="${DEBIAN_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"

# The Ed25519 issuer public key compiled into every shipped binary. A build
# without it rejects every license, so we verify it is present post-install.
readonly ISSUER_PUBKEY="02e412906f2a575d25f431899f970d6bb153224a4f0031e5ef9938f9f4ce7277"

# ─── PRODUCT MANIFEST ───────────────────────────────────────────────────────
# key|deb filename|deb sha256|installed binary sha256|service|web port|dflt vmid|dflt hostname|dflt AoIP ip
# VM AoIP addresses deliberately avoid the LXC block (.210/.220/.230).
readonly PRODUCTS=(
"gateway|hls2aes67_2026.08.187_amd64.deb|f2983a61fdc425e5c39cac7b7930646fe9f66e6758a70e6c49c2380549169274|396f8a6adc70f3fbba1cd128d297cf06475df9c39f5e5ea221414f79689ee41e|hls2aes67|8088|970|gateway-vm|192.168.24.222/24"
"onramp|aes672hls_2026.08.191_amd64.deb|bb4d04f7d188eafe3e93d351c3fcdf37c339c8e008dad8e5b18c3088a21dd987|24f2d82f6fd7ea0ae90c64afd69696385caed33cef38bcbf387cca2f62d3a56e|aes672hls|8080|971|onramp-vm|192.168.24.232/24"
)
readonly PRODUCT_LABELS="gateway = Interchange Gateway (HLS/Icecast -> AES67/Livewire)
onramp  = Interchange Onramp  (AES67/Livewire -> HLS)"

# ─── defaults (overridable by flag or prompt) ───────────────────────────────
PRODUCT="" VMID="" HOSTNAME="" STORAGE="local-lvm"
CORES=2 MEMORY=2048 DISK=8
AOIP_BRIDGE="vmbr1" AOIP_IP=""
MGMT_BRIDGE="vmbr0" MGMT_IP="dhcp" MGMT_GW=""
NAMESERVER="8.8.8.8" CIUSER="root" CIPASS="" SSHKEYFILE=""
LOCAL_DEB="" DEB_URL="" ASSUME_YES=0 START_VM=1

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

usage(){ sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; cat <<EOF

Options:
  --product <gateway|onramp>   which product to deploy
  --vmid <id>                  Proxmox VM id            (default: per product)
  --hostname <name>            guest hostname           (default: per product)
  --storage <name>             VM disk storage          (default: $STORAGE)
  --cores <n> --memory <MB> --disk <GB>
  --aoip-bridge <vmbrX>        AoIP bridge              (default: $AOIP_BRIDGE)
  --aoip-ip <cidr>             AoIP static address, gateway-less
  --mgmt-bridge <vmbrX>        management bridge        (default: $MGMT_BRIDGE)
  --mgmt-ip <cidr|dhcp>        management address       (default: dhcp)
  --mgmt-gw <ip>               management gateway       (static only)
  --nameserver <ip>            DNS for the guest        (default: $NAMESERVER)
  --ciuser <name>              cloud-init user          (default: root)
  --cipassword <pw>            cloud-init password      (default: none, key-only)
  --sshkey <file>              public key to inject     (default: host's, if any)
  --local-deb <path>           install this .deb instead of downloading
  --deb-url <url>              explicit .deb URL (overrides ARTIFACT_BASE)
  --no-start                   create the VM but leave it stopped
  --yes                        accept defaults, no prompts
  --help
EOF
}

# ─── argument parsing ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --product) PRODUCT=$2; shift 2;;      --vmid) VMID=$2; shift 2;;
    --hostname) HOSTNAME=$2; shift 2;;    --storage) STORAGE=$2; shift 2;;
    --cores) CORES=$2; shift 2;;          --memory) MEMORY=$2; shift 2;;
    --disk) DISK=$2; shift 2;;            --aoip-bridge) AOIP_BRIDGE=$2; shift 2;;
    --aoip-ip) AOIP_IP=$2; shift 2;;      --mgmt-bridge) MGMT_BRIDGE=$2; shift 2;;
    --mgmt-ip) MGMT_IP=$2; shift 2;;      --mgmt-gw) MGMT_GW=$2; shift 2;;
    --nameserver) NAMESERVER=$2; shift 2;;--ciuser) CIUSER=$2; shift 2;;
    --cipassword) CIPASS=$2; shift 2;;    --sshkey) SSHKEYFILE=$2; shift 2;;
    --local-deb) LOCAL_DEB=$2; shift 2;;  --deb-url) DEB_URL=$2; shift 2;;
    --no-start) START_VM=0; shift;;       --yes|-y) ASSUME_YES=1; shift;;
    --help|-h) usage; exit 0;;
    *) die "unknown option: $1  (try --help)";;
  esac
done

# `qm guest exec` exits 0 whenever the *agent call* succeeded — the guest
# command's own status is inside the JSON. Checking $? therefore always says
# "success" and silently breaks any wait loop built on it.
guest_ok(){ # guest_ok <vmid> <cmd...>  → true only if the GUEST command exited 0
  local out
  out=$(qm guest exec "$1" --timeout 30 -- "${@:2}" 2>/dev/null) || return 1
  grep -qE '"exitcode"[[:space:]]*:[[:space:]]*0' <<<"$out"
}

# First non-loopback IPv4 that isn't the AoIP address. Must be IPv4-only: the
# agent also reports ::1 and fe80:: and they sort ahead of the useful address.
guest_mgmt_ip(){ # guest_mgmt_ip <vmid> <aoip-ip-without-cidr>
  qm guest cmd "$1" network-get-interfaces 2>/dev/null \
    | awk -F'"' '/"ip-address"/{print $4}' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    | grep -v '^127\.' | grep -vx "$2" | head -1
}

# ── host enumeration ────────────────────────────────────────────────────────
# Defaults are *discovered*, not assumed. A hardcoded default that is already
# taken is worse than no default: it reads as a recommendation and then fails.
next_free_vmid(){ # next_free_vmid <preferred>
  local want=$1 used id
  used=" $( { qm list 2>/dev/null | awk 'NR>1{print $1}'; pct list 2>/dev/null | awk 'NR>1{print $1}'; } | tr '\n' ' ' ) "
  [[ "$used" != *" $want "* ]] && { echo "$want"; return; }
  for (( id=want; id<=999999; id++ )); do
    [[ "$used" != *" $id "* ]] && { echo "$id"; return; }
  done
  echo "$want"
}

list_storages(){ # storages that can hold VM disks
  pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}'
}

list_bridges(){ ip -br link show type bridge 2>/dev/null | awk '{print $1}' | grep -v '^fwbr'; }

# The AoIP bridge is the one WITHOUT a default route — audio networks are
# gateway-less. If exactly one such bridge exists it is almost certainly it.
guess_aoip_bridge(){
  local defbr b out=""
  defbr=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
  for b in $(list_bridges); do [[ "$b" != "$defbr" ]] && out="${out}${b} "; done
  echo "${out%% *}"
}
guess_mgmt_bridge(){ ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1; }

# ── snippets storage ────────────────────────────────────────────────────────
# Cloud-init user-data is delivered via a "snippet", which needs a storage with
# the `snippets` content type. That is NOT enabled by default: a stock Proxmox
# `local` is `iso,vztmpl,backup`. Rather than fail, we offer to add it — it is a
# one-line, reversible change to a directory storage and costs nothing.
snippet_store(){ pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}'; }
storage_content(){ awk -v s="$1" '
    /^[a-z]+:[[:space:]]/{cur=$2}
    cur==s && /^[[:space:]]*content[[:space:]]/{ $1=""; gsub(/^[[:space:]]+/,""); print; exit }
  ' /etc/pve/storage.cfg; }
dir_storages(){ awk '/^dir:[[:space:]]/{print $2}' /etc/pve/storage.cfg; }

enable_snippets(){ # prints the storage name on success, nothing on failure
  local s cur
  for s in $(dir_storages); do
    pvesm status --storage "$s" &>/dev/null || continue
    cur=$(storage_content "$s"); [[ -n "$cur" ]] || continue
    [[ "$cur" == *snippets* ]] && { echo "$s"; return 0; }
    if pvesm set "$s" --content "${cur},snippets" >/dev/null 2>&1; then echo "$s"; return 0; fi
  done
  return 1
}

ask(){ # ask <prompt> <default> <varname>
  local p=$1 d=$2 v=$3 a
  if [[ $ASSUME_YES -eq 1 ]]; then printf -v "$v" '%s' "$d"; return; fi
  read -r -p "  $p [$d]: " a </dev/tty || a=""
  printf -v "$v" '%s' "${a:-$d}"
}

# ─── preflight ──────────────────────────────────────────────────────────────
step "Preflight"
[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v qm    >/dev/null || die "'qm' not found — this must run on a Proxmox VE host"
command -v pvesm >/dev/null || die "'pvesm' not found — not a Proxmox VE host"
for t in curl sha256sum awk; do command -v $t >/dev/null || die "missing required tool: $t"; done
ok "Proxmox VE $(pveversion 2>/dev/null | sed 's/pve-manager\///;s/ .*//' || echo '?'), running as root"

# ─── product selection ──────────────────────────────────────────────────────
if [[ -z "$PRODUCT" ]]; then
  echo; echo "$PRODUCT_LABELS"; echo
  ask "Product to deploy" "gateway" PRODUCT
fi
ROW=""; for r in "${PRODUCTS[@]}"; do [[ "${r%%|*}" == "$PRODUCT" ]] && ROW="$r"; done
[[ -n "$ROW" ]] || die "unknown product '$PRODUCT' (expected: gateway, onramp)"
IFS='|' read -r _ DEB_NAME DEB_SHA BIN_SHA SERVICE WEB_PORT D_VMID D_HOST D_AOIP <<<"$ROW"
ok "product: $PRODUCT  ($DEB_NAME)"

# ─── gather settings ────────────────────────────────────────────────────────
step "Settings"
# Discover sane defaults from THIS host before offering any of them.
SUGGEST_VMID=$(next_free_vmid "$D_VMID")
[[ "$SUGGEST_VMID" != "$D_VMID" ]] && info "VM $D_VMID is taken — suggesting $SUGGEST_VMID"
AVAIL_STOR=$(list_storages | tr '\n' ' ')
AVAIL_BR=$(list_bridges | tr '\n' ' ')
grep -qw "$STORAGE" <<<"$AVAIL_STOR" || STORAGE=$(list_storages | head -1)
G_AOIP=$(guess_aoip_bridge); G_MGMT=$(guess_mgmt_bridge)
[[ -n "$G_AOIP" ]] && AOIP_BRIDGE="$G_AOIP"
[[ -n "$G_MGMT" ]] && MGMT_BRIDGE="$G_MGMT"

[[ -n "$VMID"     ]] || ask "VM ID"                     "$SUGGEST_VMID" VMID
[[ -n "$HOSTNAME" ]] || ask "Hostname"                  "$D_HOST" HOSTNAME
[[ $ASSUME_YES -eq 1 ]] || {
  ask "Cores"                                           "$CORES"   CORES
  ask "Memory (MB)"                                     "$MEMORY"  MEMORY
  ask "Disk (GB)"                                       "$DISK"    DISK
  echo "    available storage: ${AVAIL_STOR:-none found}"
  ask "VM disk storage"                                 "$STORAGE" STORAGE
  echo "    bridges on this host: ${AVAIL_BR:-none found}   (AoIP = the gateway-less one)"
  ask "AoIP bridge (audio network)"                     "$AOIP_BRIDGE" AOIP_BRIDGE
}
[[ -n "$AOIP_IP" ]] || ask "AoIP address (CIDR, no gateway — AoIP is multicast)" "$D_AOIP" AOIP_IP
[[ $ASSUME_YES -eq 1 ]] || {
  ask "Management bridge"                               "$MGMT_BRIDGE" MGMT_BRIDGE
  ask "Management address (dhcp or CIDR)"               "$MGMT_IP"     MGMT_IP
  [[ "$MGMT_IP" != "dhcp" ]] && ask "Management gateway" "$MGMT_GW"    MGMT_GW
}

qm status "$VMID" &>/dev/null && die "VM $VMID already exists — next free id is $(next_free_vmid "$VMID")"
pvesm status --storage "$STORAGE" &>/dev/null || die "storage '$STORAGE' not found"
for b in "$AOIP_BRIDGE" "$MGMT_BRIDGE"; do
  ip link show "$b" &>/dev/null || die "bridge '$b' does not exist on this host"
done
[[ "$AOIP_IP" == */* ]] || die "AoIP address must be CIDR (e.g. 192.168.24.222/24)"
ok "VM $VMID '$HOSTNAME' — ${CORES}c/${MEMORY}MB/${DISK}G on $STORAGE"
ok "AoIP $AOIP_IP on $AOIP_BRIDGE (gateway-less) · mgmt $MGMT_IP on $MGMT_BRIDGE"

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "  Proceed? [Y/n]: " c </dev/tty || c=""
  [[ "${c:-Y}" =~ ^[Yy]$|^$ ]] || { echo "aborted"; exit 0; }
fi

# ─── obtain the product .deb (host side, so we can verify before install) ───
step "Artifact"
WORK=$(mktemp -d /tmp/interchange-vm.XXXXXX); trap 'rm -rf "$WORK"' EXIT
DEB_LOCAL="$WORK/$DEB_NAME"
if [[ -n "$LOCAL_DEB" ]]; then
  [[ -f "$LOCAL_DEB" ]] || die "--local-deb not found: $LOCAL_DEB"
  cp "$LOCAL_DEB" "$DEB_LOCAL"; info "using local artifact: $LOCAL_DEB"
else
  URL="${DEB_URL:-$ARTIFACT_BASE/$DEB_NAME}"
  info "downloading $URL"
  curl -fSL --retry 3 --connect-timeout 20 -o "$DEB_LOCAL" "$URL" \
    || die "download failed. If the repository is private or offline, pass --local-deb <path>."
fi
GOT=$(sha256sum "$DEB_LOCAL" | awk '{print $1}')
[[ "$GOT" == "$DEB_SHA" ]] || die "sha256 MISMATCH
    expected $DEB_SHA
    got      $GOT
  Refusing to deploy an artifact that is not the published release."
ok "sha256 verified: ${GOT:0:16}…"

# Licensability gate: a build without the issuer key rejects every license, and
# the key is compile-time — there is no fix after deployment. Catch it here.
command -v dpkg-deb >/dev/null && {
  dpkg-deb -x "$DEB_LOCAL" "$WORK/x" 2>/dev/null || true
  BIN="$WORK/x/usr/bin/$SERVICE"
  if [[ -f "$BIN" ]]; then
    [[ "$(sha256sum "$BIN" | awk '{print $1}')" == "$BIN_SHA" ]] \
      || die "the binary inside the .deb is not the published build"
    [[ "$(grep -a -c "$ISSUER_PUBKEY" "$BIN" || true)" -ge 1 ]] \
      || die "this build has NO issuer public key — it would reject every license. Refusing."
    ok "binary verified + issuer key present (licensable)"
  fi
}

# ─── base image ─────────────────────────────────────────────────────────────
step "Base image"
IMG_CACHE="/var/lib/vz/template/cache/debian-13-genericcloud-amd64.qcow2"
[[ -f /root/debian13-genericcloud.qcow2 && ! -f "$IMG_CACHE" ]] && IMG_CACHE=/root/debian13-genericcloud.qcow2
if [[ -f "$IMG_CACHE" ]]; then
  ok "using cached image: $IMG_CACHE"
else
  info "fetching $DEBIAN_IMAGE_URL"
  curl -fSL --retry 3 -o "$IMG_CACHE" "$DEBIAN_IMAGE_URL" || die "could not fetch the Debian cloud image"
  ok "downloaded base image"
fi

# ─── create the VM ──────────────────────────────────────────────────────────
step "Creating VM $VMID"
qm create "$VMID" --name "$HOSTNAME" --ostype l26 --cpu host \
  --cores "$CORES" --memory "$MEMORY" \
  --scsihw virtio-scsi-single --agent 1 \
  --serial0 socket --vga serial0 \
  --net0 "virtio,bridge=$AOIP_BRIDGE" --net1 "virtio,bridge=$MGMT_BRIDGE" >/dev/null
ok "VM shell created"

qm importdisk "$VMID" "$IMG_CACHE" "$STORAGE" >/dev/null 2>&1 || die "importdisk failed"
DISKREF=$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2}')
[[ -n "$DISKREF" ]] || die "imported disk not found"
qm set "$VMID" --scsi0 "$DISKREF" --boot order=scsi0 >/dev/null
qm resize "$VMID" scsi0 "${DISK}G" >/dev/null 2>&1 || warn "resize to ${DISK}G skipped (image already larger?)"
qm set "$VMID" --ide2 "$STORAGE:cloudinit" >/dev/null
ok "disk imported and attached (${DISK}G)"

# cloud-init: net0 = AoIP, deliberately NO gateway (AoIP is multicast and a
# second default route would black-hole management traffic). net1 = management.
IPCFG1="ip=$MGMT_IP"
[[ "$MGMT_IP" != "dhcp" && -n "$MGMT_GW" ]] && IPCFG1="ip=$MGMT_IP,gw=$MGMT_GW"
qm set "$VMID" --ipconfig0 "ip=$AOIP_IP" --ipconfig1 "$IPCFG1" \
               --nameserver "$NAMESERVER" --ciuser "$CIUSER" >/dev/null
[[ -n "$CIPASS" ]] && qm set "$VMID" --cipassword "$CIPASS" >/dev/null
KEY="${SSHKEYFILE:-}"
[[ -z "$KEY" && -f /root/.ssh/id_ed25519.pub ]] && KEY=/root/.ssh/id_ed25519.pub
[[ -z "$KEY" && -f /root/.ssh/id_rsa.pub    ]] && KEY=/root/.ssh/id_rsa.pub
if [[ -n "$KEY" && -f "$KEY" ]]; then qm set "$VMID" --sshkeys "$KEY" >/dev/null; ok "ssh key injected: $KEY"
else warn "no ssh key injected — set --cipassword or --sshkey or you cannot log in"; fi
ok "cloud-init configured"

# ─── first boot: install the product ────────────────────────────────────────
# The .deb is served to the guest from this host over a short-lived HTTP server
# on the management bridge, so the guest never needs access to our repository.
step "Provisioning"
SNIPPET_STORE=$(snippet_store)
if [[ -z "$SNIPPET_STORE" ]]; then
  warn "no storage on this host has the 'snippets' content type enabled."
  echo  "    Cloud-init needs it to install the product into the VM. This is a stock"
  echo  "    Proxmox default, not a fault — 'local' normally ships as iso,vztmpl,backup."
  echo  "    Fix: add 'snippets' to a directory storage's content types. Reversible,"
  echo  "    affects nothing else, and is what the Proxmox UI does under"
  echo  "    Datacenter > Storage > Edit > Content."
  DO_IT=y
  [[ $ASSUME_YES -eq 1 ]] || { read -r -p "  Enable snippets now? [Y/n]: " DO_IT </dev/tty || DO_IT=y; }
  if [[ "${DO_IT:-y}" =~ ^[Yy]$|^$ ]]; then
    SNIPPET_STORE=$(enable_snippets || true)
    [[ -n "$SNIPPET_STORE" ]] && ok "enabled snippets on storage '$SNIPPET_STORE'" \
                              || warn "could not enable snippets automatically"
  fi
fi
HOSTIP=$(ip -4 -o addr show "$MGMT_BRIDGE" | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOSTIP" ]] || die "could not determine this host's IP on $MGMT_BRIDGE"

if [[ -n "$SNIPPET_STORE" ]]; then
  SNIPDIR="/var/lib/vz/snippets"; mkdir -p "$SNIPDIR"
  PORT_HTTP=$(shuf -i 20000-29999 -n1)
  cat > "$SNIPDIR/interchange-$VMID.yaml" <<EOF
#cloud-config
package_update: true
packages: [qemu-guest-agent, curl, ca-certificates]
runcmd:
  - systemctl enable --now qemu-guest-agent
  - curl -fsS --retry 20 --retry-delay 3 -o /tmp/product.deb http://$HOSTIP:$PORT_HTTP/$DEB_NAME
  - echo "$DEB_SHA  /tmp/product.deb" | sha256sum -c - || (echo "ARTIFACT SHA MISMATCH" && exit 1)
  - DEBIAN_FRONTEND=noninteractive apt-get update -qq
  - DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/product.deb || apt-get -f install -y
  - rm -f /tmp/product.deb
  - systemctl enable --now $SERVICE || true
  - touch /var/lib/interchange-provisioned
EOF
  qm set "$VMID" --cicustom "user=${SNIPPET_STORE}:snippets/interchange-$VMID.yaml" >/dev/null
  ok "cloud-init provisioning snippet installed"

  ( cd "$WORK" && timeout 900 python3 -m http.server "$PORT_HTTP" --bind "$HOSTIP" >/dev/null 2>&1 ) &
  HTTP_PID=$!
  trap 'kill $HTTP_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT
  info "serving $DEB_NAME to the guest on $HOSTIP:$PORT_HTTP (temporary, 15 min max)"
else
  # Keep the verified artifact somewhere durable — $WORK is removed on exit, so
  # telling the operator to scp a file that no longer exists helps nobody.
  KEEP="/var/lib/vz/template/cache/$DEB_NAME"
  cp -f "$DEB_LOCAL" "$KEEP" 2>/dev/null && MANUAL_DEB="$KEEP" || MANUAL_DEB=""
  warn "the VM will be created WITHOUT the product installed."
  if [[ -n "$MANUAL_DEB" ]]; then
    echo "    The verified package is kept at:"
    echo "      $MANUAL_DEB"
    echo "    Once the VM has booted and you know its management IP:"
    echo "      scp $MANUAL_DEB root@<vm-ip>:/tmp/"
    echo "      ssh root@<vm-ip> 'apt-get update && apt-get install -y /tmp/$DEB_NAME && systemctl enable --now $SERVICE'"
  fi
fi

if [[ $START_VM -eq 1 ]]; then
  qm start "$VMID" >/dev/null; ok "VM started — cloud-init is installing the product"
  info "waiting for the guest agent (up to 5 min)…"
  for _ in $(seq 1 60); do qm agent "$VMID" ping &>/dev/null && break; sleep 5; done
  if qm agent "$VMID" ping &>/dev/null; then
    ok "guest agent responding"
    # Installing the product pulls its whole GStreamer dependency tree — that is
    # a ~330-package apt transaction and takes minutes. The temporary artifact
    # server above lives only as long as this script, so we must genuinely wait
    # for the completion marker rather than racing ahead and killing it.
    info "installing product + dependencies in the guest (several minutes)…"
    PROVISIONED=0
    for i in $(seq 1 180); do
      if guest_ok "$VMID" test -f /var/lib/interchange-provisioned; then PROVISIONED=1; break; fi
      (( i % 12 == 0 )) && info "  … still installing ($((i*5))s elapsed)"
      sleep 5
    done
    if [[ $PROVISIONED -eq 1 ]]; then
      ok "product installed"
      if guest_ok "$VMID" systemctl is-active --quiet "$SERVICE"; then ok "service '$SERVICE' is active"
      else warn "service '$SERVICE' is not active yet — check: qm guest exec $VMID -- systemctl status $SERVICE"; fi
    else
      warn "provisioning did not finish within 15 min — inspect the guest:"
      warn "  qm guest exec $VMID -- tail -40 /var/log/cloud-init-output.log"
    fi
  else
    warn "guest agent did not respond — check the console: qm terminal $VMID"
  fi
fi

# ─── report ─────────────────────────────────────────────────────────────────
MGMT_ADDR="<vm-ip>"
if qm agent "$VMID" ping &>/dev/null; then
  FOUND=$(guest_mgmt_ip "$VMID" "${AOIP_IP%%/*}" || true)
  [[ -n "$FOUND" ]] && MGMT_ADDR="$FOUND"
fi
cat <<EOF

${C_OK}══════════════════════════════════════════════════════════════${C_OFF}
 ${C_OK}Interchange ${PRODUCT} deployed — VM $VMID ($HOSTNAME)${C_OFF}
${C_OK}══════════════════════════════════════════════════════════════${C_OFF}

  Control UI     http://${MGMT_ADDR}:${WEB_PORT}/
  AoIP interface ${AOIP_IP} on ${AOIP_BRIDGE}  (no gateway — correct for AoIP)
  Service        systemctl status ${SERVICE}
  Console        qm terminal ${VMID}

  Next steps
   1. Open the Control UI and copy the Install ID from the Configuration page.
   2. Send it to your supplier to obtain a license token, then paste the token
      on the same page. Unlicensed operation is capability-limited by design.
   3. PTP is host-managed. If this host is not already a PTP node, run
      packaging/host-ptp/install.sh <aoip-nic> on the PROXMOX HOST (not the VM).

EOF
if [[ -z "${SNIPPET_STORE:-}" ]]; then
  warn "PRODUCT NOT INSTALLED — this VM is a bare Debian 13 until you install it."
  [[ -n "${MANUAL_DEB:-}" ]] && warn "  package ready at: $MANUAL_DEB"
  warn "  or destroy it (qm destroy $VMID --purge), enable snippets, and re-run."
  warn "  Deploying as an LXC container instead avoids this entirely — see interchange-ct.sh"
fi
exit 0
