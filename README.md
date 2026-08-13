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

Run on the **Proxmox host**, as root. Two deployers, deliberately separate —
pick the one that matches how you want the clock handled.

### Container (LXC) — recommended for AoIP

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/goobenet/interchange-deploy/main/interchange-ct.sh)"
```

### Virtual machine

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/goobenet/interchange-deploy/main/interchange-vm.sh)"
```

Either asks which product to deploy, then for the id, hostname, resources and
network. Every prompt has a default discovered from *your* host — free id, real
storage, actual bridges — so pressing Enter throughout gives a working
deployment.

### Which one?

**A container shares the host's kernel, and therefore the host's system clock.**
Discipline the clock once on the host and every container inherits it. That is
the single biggest reason to prefer a container for audio-over-IP.

**A virtual machine has its own kernel and its own clock.** It must run its own
`ptp4l` against a virtual NIC, and virtual NICs have no PTP hardware clock — so
a VM will not achieve a tight media-clock lock, no matter how the host is
configured. VMs are the right choice when you want hard isolation, a different
kernel, or snapshot/migration behaviour, and are perfectly usable where the
audio path tolerates a softer clock.

The container deployer additionally asks before touching PTP on your host, and
defaults to leaving whatever you already run alone. See **Clocking and PTP**.

### Non-interactive

```bash
curl -fsSLO https://raw.githubusercontent.com/goobenet/interchange-deploy/main/interchange-ct.sh
chmod +x interchange-ct.sh
./interchange-ct.sh --product gateway --ctid 960 --aoip-ip 192.168.24.220/24 --ptp keep --yes
```

`--help` lists every option on both scripts.

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

## Clocking and PTP

PTP is **host-managed**. You do not run `ptp4l` inside a container — an
unprivileged container cannot set the clock anyway, and it doesn't need to: it
inherits the host's.

Two clocks are kept deliberately separate:

- **Calendar — always NTP.** Timestamps, TLS certificate validity and HLS
  `PROGRAM-DATE-TIME` depend on real UTC.
- **Media clock — AoIP PTP.** Follows the grandmaster and never steps the
  system wall clock.

### Choosing a topology

This is the part people get wrong, so here are the real options.

**1. Dedicated, non-bridged NIC — best accuracy.**
A second physical NIC on the AoIP network, not enslaved to any bridge, used only
for PTP. Hardware timestamping, tight lock.

```bash
./host-ptp/install.sh enp1s0
```

The catch: dedicating a physical port to PTP is often impractical on a
hypervisor — consolidating hardware is usually the reason you're running one.
If that's your situation, use option 2.

**2. Bind PTP to the bridge — the practical default.**
Point PTP at the **bridge** (`vmbr1`), not at the physical port beneath it.

```bash
./host-ptp/install.sh vmbr1
```

The bridge is a real L3 interface and does receive the grandmaster's
Announce/Sync multicast, so PTP participates in BMCA and genuinely locks.
A bridge has no PTP hardware clock, so this is software timestamping — looser
than option 1, and completely serviceable for a receive-side or
stream-conversion box. No NIC sacrificed.

**3. ⚠ The trap: binding PTP to a bridge *slave*.**
Pointing PTP at the physical port when that port is enslaved to a bridge
(`nic1` inside `vmbr1`) **looks** right and silently never works. A bridge slave
does not deliver the multicast to a socket bound to it, so `ptp4l` sits in
`LISTENING` forever, `phc2sys` waits for a lock that never arrives, and the host
quietly stays on NTP.

You get neither hardware timestamping nor a lock — the worst of both. Check for
it with:

```bash
pmc -u -b 0 'GET PORT_DATA_SET' | grep portState
```

`LISTENING` that never becomes `SLAVE` means you have hit this. Re-run the
installer against the **bridge** instead.

**4. No PTP at all.** Perfectly valid. The host stays on NTP and the products
still run; you simply don't get media-clock lock to a studio grandmaster.
Choose `--ptp skip` (or `keep`) in the container deployer.

### If your grandmaster runs an ARB timescale

Some Livewire/Axia devices announce an **arbitrary (non-TAI)** timescale. Slaving
the system clock to one of those can step your host's wall clock to ~1970, which
takes TLS, HTTPS and every container's timestamps down with it.

The kit guards against this: while the selected grandmaster is ARB, the system
clock is **held on NTP** and PTP discipline is deliberately withheld — media
stays rate-synced, the calendar stays correct. If PTP appears not to be
disciplining the clock, check the grandmaster's timescale before assuming a
fault. A TAI-timescale grandmaster is preferable where you have the choice.

### Already running PTP?

The container deployer detects that and **defaults to leaving it alone**. The
Interchange kit installs its own `ptp4l@.service` and `phc2sys@.service` unit
templates, so letting it take over would replace yours and start a second
`ptp4l` on the same interface — two instances fighting over one clock. Choose
`keep` unless you specifically want us to manage it.

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
