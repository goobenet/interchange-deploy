# Interchange — Deployment

Audio-over-IP broadcast products from **Optimized Media Group**.

| Product | Role | Web UI |
|---|---|---|
| **Interchange Gateway** (`hls2aes67`) | HLS / Icecast → AES67 / Livewire | `:8088` |
| **Interchange Onramp** (`aes672hls`) | AES67 / Livewire → HLS | `:8080` |

This repository contains **deployment tooling and release artifacts only**. The
product source is not public.

---

## Deploy on Proxmox VE — one line

Run on the **Proxmox host**, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/goobenet/interchange-deploy/main/interchange-vm.sh)"
```

It asks which product to deploy, then for the VM id, hostname, resources, and
network — every prompt has a sensible default, so pressing Enter throughout
gives a working deployment.

It creates a Debian 13 cloud-init VM, installs the product and its dependencies,
and prints the control-UI URL when it's done.

### Non-interactive

```bash
curl -fsSLO https://raw.githubusercontent.com/goobenet/interchange-deploy/main/interchange-vm.sh
chmod +x interchange-vm.sh
./interchange-vm.sh --product gateway --vmid 970 --aoip-ip 192.168.24.222/24 --yes
```

`--help` lists every option.

---

## Networking

Interchange VMs are **dual-homed**, and this matters:

- **`net0` — AoIP.** The audio network, on its own bridge, with **no gateway**.
  AES67 is multicast; a default route here would black-hole management traffic.
- **`net1` — management.** Web UI, MQTT, NTP, updates. DHCP by default.

The deployer configures both and leaves exactly one default route, via
management. Give `--aoip-ip` an address on your AoIP VLAN.

---

## Licensing

Each install generates an **Install ID**, shown on the Configuration page of the
web UI. Send it to your supplier to receive a license token, then paste the
token on that same page.

Unlicensed operation is deliberately capability-limited rather than blocked —
the software runs so you can commission and test it.

Licensing is verified offline — nothing phones home, and no network access is
needed to validate a token.

**The deployer checks that the build it is about to install is licensable, and
aborts if it is not.** That property is compiled into the binary, so a build
that fails the check cannot be repaired after deployment — better to stop
before creating the VM than to hand you an install that silently rejects every
license.

---

## Verifying a download

Every release ships `SHA256SUMS`:

```bash
sha256sum -c SHA256SUMS
```

The deployer also pins each artifact's sha256 internally and refuses to install
anything that doesn't match. Because of that pinning, **the deploy script and
the release artifacts are versioned together** — use the script from `main`
alongside the release it points at.

---

## PTP / clocking

PTP is **host-managed**, not configured inside the VM. If your Proxmox host
isn't already a PTP node on the AoIP segment, set it up there.

The media clock (AoIP PTP) and the system calendar (NTP) are deliberately
separate: the calendar always follows NTP so timestamps, TLS and HLS
`PROGRAM-DATE-TIME` stay correct, while the media clock follows the AoIP
grandmaster and never touches the system wall clock.

---

## Requirements

- Proxmox VE 8 or 9, with `qm` available and root access
- A bridge on your AoIP network and one with internet access
- ~8 GB storage and 2 GB RAM per product VM
- Outbound HTTPS on the host, to fetch the Debian cloud image

## Support

**info@optimizedmedia.net**

Include your Install ID and the output of `systemctl status hls2aes67` (or
`aes672hls`) from inside the VM or container.

To request a license, send us the **Install ID** from the Configuration page.
