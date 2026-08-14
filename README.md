# Interchange — Deployment

Audio-over-IP broadcast products from **Optimized Media Group**.

| Product | Role | Web UI |
|---|---|---|
| **Interchange Gateway** (`hls2aes67`) | HLS / Icecast → AES67 / Livewire | `:8088` |
| **Interchange Onramp** (`aes672hls`) | AES67 / Livewire → HLS | `:8080` |

This repository contains **deployment tooling, documentation and release
artifacts**. The product source is not public.

> **This repository is a publish endpoint.** The deployer scripts and the
> documents under `docs/` are copies, maintained in the private source
> repository alongside the code they describe and synced here at release time.
> Edits made directly here will be overwritten. Please send corrections to
> info@optimizedmedia.net rather than opening a pull request against a mirror.

## Documentation

- **[User Guide](docs/INTERCHANGE-USER-GUIDE.md)** — what each product does,
  configuration, timing, licensing, and the MQTT interface in depth.
- **[HTTP API Reference](docs/INTERCHANGE-API-REFERENCE.md)** — every endpoint on
  both appliances. The web UI uses nothing private, so anything it can do, an
  automation system can do.

Each appliance also serves its own manual at `/manual.html`.

---

## Before you start — requirements

Both paths need root on the Proxmox host, a bridge on your AoIP network, a
bridge with internet access, outbound HTTPS, and roughly 8 GB of storage per
product.

| | Container (LXC) | Virtual machine |
|---|---|---|
| **Proxmox VE** | **8.4 or newer** (9.x recommended) | 8.x or 9.x |
| **RAM** | 1 GB | 2 GB |
| **Also needs** | — | a storage with the **`snippets`** content type |

**Containers are recommended for audio-over-IP**, because a container inherits
the host's disciplined system clock and a VM cannot. See [Which one?](#which-one)
and [Clocking and PTP](#clocking-and-ptp).

Two things that catch people out, both checked up front by the deployers so you
find out immediately rather than part-way through:

- **Proxmox older than 8.4 cannot create our containers.** Proxmox validates a
  container's distro release against a table in its own libraries; our templates
  are Debian 13 (trixie) and an older Proxmox refuses them with
  `Unsupported debian version '13.6'`. That is a limit in Proxmox, not the
  template, and nothing in the template avoids it. **On an older host, deploy a
  VM instead** — Proxmox does not inspect a VM's guest OS, so Debian 13 runs
  fine there. If you specifically need containers on an older host, contact us
  about a Debian 12 template.
- **The `snippets` content type is not enabled by default**, and the VM path
  needs it to install the product into the guest. The VM deployer offers to
  enable it for you — a one-line, reversible change to a directory storage. The
  container path does not need it at all.

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

### Your grandmaster — use dedicated hardware

**An AoIP network should have a purpose-built PTP grandmaster.** What audio needs
from it is a **metronome**: one stable frequency reference every device locks to,
so nobody slips a sample. Dedicated hardware gives you what software on a
general-purpose server cannot:

- **A stable oscillator** — a purpose-built clock, not a server crystal
  competing with scheduler jitter and power management.
- **Holdover** — it rides out a reference outage instead of drifting.
- **A clock that isn't also doing something else** — no other workload can
  preempt it.

Most AoIP-capable switches, and every serious broadcast clock product, will do
this. It is worth the rack unit.

**An ARB (arbitrary) timescale is fine — expected, even.** Audio needs rate lock,
not absolute time, and ARB grandmasters are normal in Livewire and Axia plants.
You do not need a TAI-locked grandmaster to run audio correctly, and this
software does not ask for one.

TAI only matters if you need RTP timestamps to correspond to real wall-clock
time across systems — ST 2110 video/audio alignment, or correlating streams
between facilities. For audio transport on its own, it buys you nothing.

### Interchange never competes for the clock

Our products advertise **`priority1` = 130**. The IEEE 1588 default is 128 and
**lower wins**, so an Interchange appliance always yields BMCA to any properly
configured master. It is the **clock of last resort** by design: deploying one
onto your network cannot take the clock away from your studio grandmaster.

It only becomes grandmaster when it is genuinely alone on the segment. That
works — the audio stays rate-locked to it — but a general-purpose server is a
mediocre metronome, so treat an Interchange box acting as grandmaster as a
signal that the network wants a proper clock, not as a failure.

The same applies to any device that elects itself because nothing better exists:
a console, a node, an interface unit. It will keep the plant running; it just
won't hold as well as dedicated hardware. Check what is actually mastering your
segment:

```bash
pmc -u -b 0 'GET PARENT_DATA_SET' | grep grandmasterIdentity
pmc -u -b 0 'GET TIME_PROPERTIES_DATA_SET' | grep ptpTimescale
```

`ptpTimescale 0` simply means ARB, which is normal for audio — see below for
what that implies for the system calendar.

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

### Why the system clock stays on NTP under an ARB grandmaster

This is the two-clock model working as intended, not a fault.

An ARB grandmaster counts from an arbitrary origin. It is a perfectly good
metronome — which is all audio wants — but its numbers are not UTC. Slaving
`CLOCK_REALTIME` to one would step the host's wall clock to something like 1970
and take TLS, HTTPS, log timestamps and HLS `PROGRAM-DATE-TIME` down with it.

So the kit deliberately splits them:

- **Media clock — PTP**, following the AoIP grandmaster. Rate lock, sample
  alignment, no slips. ARB is fine here.
- **Calendar — NTP**, always. Real UTC for timestamps, certificates and
  `PROGRAM-DATE-TIME`, which is what makes HLS output correlate with everything
  else.

While the selected grandmaster is ARB, PTP discipline of `CLOCK_REALTIME` is
withheld and the calendar stays on NTP. **That is the correct outcome** — you get
the metronome without letting it wreck the calendar. If you see PTP declining to
discipline the system clock, this is almost certainly why, and nothing is wrong.

### Already running PTP?

The container deployer detects that and **defaults to leaving it alone**. The
Interchange kit installs its own `ptp4l@.service` and `phc2sys@.service` unit
templates, so letting it take over would replace yours and start a second
`ptp4l` on the same interface — two instances fighting over one clock. Choose
`keep` unless you specifically want us to manage it.

---

## Support

**info@optimizedmedia.net**

Include your Install ID and the output of `systemctl status hls2aes67` (or
`aes672hls`) from inside the VM or container.

To request a license, send us the **Install ID** from the Configuration page.
