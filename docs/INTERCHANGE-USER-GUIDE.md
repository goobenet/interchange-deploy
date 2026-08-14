# Interchange — Gateway & Onramp User Guide

**Optimized Media Group · Interchange family**

This guide covers the two shipping Interchange appliances and, in depth, how they interface
with MQTT.

| Product | Codename / binary | Direction | Default web port |
|---|---|---|---|
| **Interchange Gateway** | `hls2aes67` | Internet stream (HLS / Icecast) **→** AES67 / Livewire multicast | 8088 |
| **Interchange Onramp** | `aes672hls` | AES67 / Livewire multicast **→** live HLS | 8080 |

They are mirror images of each other and are designed to be deployed together: Onramp takes a
studio bus onto the internet, Gateway brings an internet feed back into the plant. Each runs as
a standalone appliance (Debian `.deb`, Proxmox LXC template, Proxmox VM, or a Windows service)
with its own web UI, its own PTP participation, and its own MQTT integration.

---

## Contents

1. [Concepts shared by both products](#1-concepts-shared-by-both-products)
2. [Interchange Gateway](#2-interchange-gateway)
3. [Interchange Onramp](#3-interchange-onramp)
4. [MQTT — the complete reference](#4-mqtt--the-complete-reference)
   - [4.1 Two different MQTT models](#41-two-different-mqtt-models)
   - [4.2 Gateway MQTT](#42-gateway-mqtt)
   - [4.3 Onramp MQTT](#43-onramp-mqtt)
   - [4.4 Home Assistant](#44-home-assistant-gateway-only)
   - [4.5 Integration patterns](#45-integration-patterns)
   - [4.6 MQTT troubleshooting](#46-mqtt-troubleshooting)
5. [Operations reference](#5-operations-reference)

---

## 1. Concepts shared by both products

### AES67 and Livewire

Both appliances speak **AES67** — 24-bit linear PCM in RTP over IP multicast, clocked by PTP —
and the **Livewire+** flavour of it used by Telos/Axia gear. A Livewire *channel number* is just
a shorthand for a multicast address: channel `ch` maps to `239.192.(ch>>8).(ch&0xFF)` on RTP
port 5004. You can address a stream either way in both products.

Sources advertise themselves with **SAP/SDP** (the AES67 standard announcement protocol) and,
for Axia gear, the Livewire advertisement. Gateway advertises everything it transmits; Onramp
discovers and lists everything it can hear, so you can pick a source from a browser instead of
typing addresses.

### PTP (timing)

Everything on an AoIP network must share one clock. Both appliances run PTP continuously — it
is not a feature you switch on.

| Mode | Behaviour |
|---|---|
| **Auto** (default) | The Best-Master-Clock Algorithm decides. Follows a better clock if one exists; takes over only if it disappears. |
| **Follower** | Locks to an existing grandmaster; never leads. |
| **Grandmaster** | Always leads the domain. |

Both ship with **priority1 = priority2 = 130** — deliberately *worse* than the PTP default of
128, so a software-timestamped appliance loses the election to properly-clocked hardware and
only ever leads as the clock of last resort. The **domain** must match the rest of your plant.

**Two clocks, deliberately kept apart.** PTP is the *media* clock — a metronome for sample
alignment. It never disciplines the system calendar, in any role:

| Clock | Disciplined by | Used for |
|---|---|---|
| **Media clock** | PTP (the AoIP grandmaster) | Sample alignment, RTP timing |
| **Calendar** (`CLOCK_REALTIME`) | **NTP, always** | Timestamps, TLS validity, HLS `PROGRAM-DATE-TIME` |

NTP is never suspended, so the configured **NTP source** always matters. This split is what makes
an **ARB** (arbitrary-epoch) grandmaster safe: an ARB clock counts from an arbitrary origin, so
slaving the calendar to one would step the system clock to something like 1970 and break TLS,
logs and `PROGRAM-DATE-TIME`. ARB is normal on Livewire/Axia plants and is perfectly good as a
metronome — audio needs rate lock, not absolute time — so the appliance follows it for media and
leaves the calendar to NTP.

`GET /api/ptp` reports both: `role` for the media clock, and `clock_source` / `ntp_synced` for
the calendar.

PTP needs raw sockets, so the service runs with root privileges. Inside an LXC container the
*host* owns the clock: both appliances detect the container automatically and switch to
host-managed PTP rather than starting their own `ptp4l`.

### Metadata and events

Both products carry **broadcaster-specific metadata** inside the HLS stream: a now-playing JSON
object in the `#EXTINF` title field, IBOC-style ID3 program-service data on segments, and
**contact-closure events** attached to a track.

An event has a **role**, a **mode**, and an **action**:

- **Roles** (13, identical in both products):
  `eas`, `local_avail`, `program_cue`, `join_point`, `exit_point`,
  `gpio1` … `gpio8`
- **Modes:** `momentary` (a pulse) or `maintained` (latches until deactivated)
- **Actions:** `activate` / `deactivate`

`note` is a separate, non-closure annotation carrying free text.

Because both products use the same encoder/decoder for this format, metadata and events survive
a full round trip: an Onramp-encoded stream fed to a Gateway arrives with its titles, artwork
references and EAS/GPIO closures intact — **without MQTT being involved at all**. MQTT is the
out-of-band path for automation systems that need to see or drive those same values.

### Licensing

Licences are Ed25519-signed and bound to the appliance's **Install ID**. Both products run
degraded rather than refusing to start:

- **Gateway unlicensed:** only **1 stream** runs.
- **Onramp unlicensed:** only **1 encoder** runs, **and the encoded audio carries test beeps**.

Install a licence on the Configuration page (or `PUT /api/license` on Gateway, `PUT /license` on
Onramp). The UI shows the licence card and the Install ID you need to quote when requesting one.

### Web UI, configuration and backup

Each appliance serves a dashboard, a configuration page, and its own built-in manual from the
same port. Configuration is persisted as JSON and can be downloaded and restored as a single
file from the Configuration page — the fastest way to clone a known-good setup onto another
unit. Restores are validated and applied live; only a change of network-interface binding needs
a full service restart.

---

## 2. Interchange Gateway

**A studio on-ramp from public streaming into professional audio-over-IP.** Gateway pulls
internet radio streams and re-transmits them as broadcast-grade AES67/Livewire multicast on your
facility network, PTP-disciplined, while forwarding now-playing metadata and station events to
MQTT and Home Assistant.

```
HLS / Icecast  ──►  decode  ──►  gain / metering  ──►  AES67 · Livewire multicast  ──►  receivers
      │                                                        │
      │                                                        └──►  SAP/SDP + Livewire advert
      └──►  now-playing + events  ──►  MQTT / Home Assistant
```

### 2.1 Inputs

Up to **8 simultaneous streams**. Per stream:

| Setting | Notes |
|---|---|
| **Name** | Free label; used in the UI, logs and Home Assistant entity names. |
| **URL** | The source. |
| **Source type** | `auto` (default), `hls`, or `icecast`. `auto` picks HLS when the URL path contains `.m3u8`, otherwise Icecast/SHOUTcast (continuous HTTP audio). |
| **Enabled** | Disabled slots keep their configuration but don't run. |
| **Username / password** | Optional HTTP Basic auth for a protected source. Sent as an `Authorization` header, so it never appears in logged URLs. |
| **Allow invalid TLS** | Off by default. Enable only for an internal `https://` source with a self-signed certificate. |

Codec support comes from GStreamer (`libav` + `bad` plugins) — AAC, MP3 and FLAC sources all
work; the detected codec and bitrate are reported on the dashboard and over MQTT.

### 2.2 Outputs

| Setting | Notes |
|---|---|
| **Multicast address** | Defaults to a contiguous block: `239.69.1.1`, `239.69.1.2`, … per slot. |
| **RTP port** | Default `5004`. |
| **Channels** | Default `2` (stereo). |
| **Livewire channel** | Optional. Setting it *pins* the output to the Axia-derived group and RTP 5004, overriding the manual address/port. |
| **Gain trim** | ±12 dB, applied live to the AES67 signal and persisted. |

Two enabled streams may not transmit to the same multicast group **and** port — the
configuration page validates this, so you cannot silently double up on one endpoint.

Each output is advertised three ways so receivers can find it: **SAP/SDP**, the **Livewire
advertisement**, and MQTT. The SDP's `ts-refclk` line is regenerated automatically whenever the
PTP grandmaster changes, so receivers always see the correct clock reference. The current SDP
for any stream is available at `GET /api/streams/{id}/sdp`.

### 2.3 Monitoring

The dashboard shows, per stream: connection state, detected codec/bitrate, playout buffer depth
and drift corrections, stereo meters, full **EBU R128 / ITU-R BS.1770** loudness (momentary,
short-term, integrated, loudness range) and **true peak in dBTP**, plus a row of event indicator
lamps with live countdowns. Topbar chips report PTP role, system clock and AoIP interface state.

### 2.4 Restart behaviour

| Change | Effect |
|---|---|
| One stream's settings | Only that stream's audio path rebuilds (~1–2 s gap on that output). Other streams, the PTP clock and the MQTT connection are untouched. |
| MQTT broker & topics, PTP settings | Applied live; no audio interruption. |
| Network-interface binding, web port | Requires a service restart (offered in the UI). |

### 2.5 Files and endpoints

- Config: `$HLS2AES67_CONFIG` if set; otherwise
  `%PROGRAMDATA%\Interchange Gateway\hls2aes67-config.json` on Windows, or
  `hls2aes67-config.json` in the working directory on Linux (the systemd unit runs from
  `/var/lib/hls2aes67`).
- Web UI: `/` (dashboard), `/config.html`, `/manual.html`, live updates over `/ws`.
- API: `/api/state`, `/api/streams/{id}` (PUT/DELETE), `/api/streams/{id}/sdp`,
  `/api/streams/{id}/gain`, `/api/streams/{id}/loudness/reset`, `/api/ptp`, `/api/nics`,
  `/api/net`, `/api/mqtt`, `/api/system`, `/api/license`, `/api/config`, `/api/config/import`,
  `/api/restart`.

---

## 3. Interchange Onramp

**The reverse path: studio audio out to the internet.** Onramp receives an AES67/Livewire
multicast (or a local sound device) and encodes it to live HLS with embedded broadcaster-specific
now-playing metadata and EAS/GPI event signalling — served directly from the appliance.

```
AES67 · Livewire  ──►  jitter buffer  ──►  gain / metering  ──►  ffmpeg  ──►  HLS playlist + segments
        ▲                                                                            │
        │                                                                            ▼
   SAP discovery                                     now-playing + events  ◄──►  MQTT (two-way)
```

### 3.1 Encoders (channels)

Onramp is organised into **encoders**, each with its own id, source, codec and output. The
default maximum is **4** (`--max-channels`). The channel id becomes a URL path segment and an
on-disk directory name, so it is restricted to 1–32 characters of `A-Z a-z 0-9 - _`.

### 3.2 Sources

| Source | Parameters |
|---|---|
| **AES67** | Multicast group, port (default 5004), channels (default 2), RTP payload type (auto-detected by default), jitter buffer (default 40 ms). |
| **Livewire** | Channel number — the address is derived automatically. Jitter buffer as above. |
| **Audio device** | Named local input (WASAPI on Windows, ALSA on Linux), or the system default. |
| **Silence** | Keeps a channel alive with digital silence. Seeded automatically on first run inside a container, where no audio hardware exists. |

The **source browser** lists everything discovered via SAP/Livewire advertisements, with a live
name where one is advertised (e.g. `station-1 · 239.192.83.253:5004`). Not everything
advertises; anything can be entered manually. An encoder can be **repointed to a different
source live**, without dropping the output stream.

If input stops arriving the encoder does not die — it shows `NO INPUT` and keeps the stream
alive with silence, so downstream players stay connected.

### 3.3 Codecs and output

| Codec | Notes |
|---|---|
| **AAC-LC** | Default. |
| **HE-AAC** | Requires an ffmpeg build with `libfdk_aac` — the `.deb` bundles one. |
| **MP3** | |
| **FLAC** | Lossless; bitrate selection does not apply. |

Bitrate presets for lossy codecs: **64, 96, 128, 160, 192, 224, 256, 320 kbps**. Segments
default to a 6-second target duration with a 10-segment rolling window (both service-wide).
Changing a codec restarts only that encoder's ffmpeg — the input is not dropped.

Output is served from the same port as the UI:

```
/channels/{id}/master.m3u8        ← point players here
/channels/{id}/{playlist_name}    ← the media playlist (default media.m3u8)
/channels/{id}/segments/{file}
```

Each channel can require **HTTP Basic auth** on its served stream (master playlist, media
playlist and segments). The password is write-only over the control API — accepted, never echoed
back. This is the inbound mirror of Gateway's outbound source auth.

### 3.4 Metadata, events and notes

Now-playing metadata can be set three ways, all landing in the same state:

1. the dashboard's manual form,
2. the control API (`PUT /channels/{id}/now-playing`),
3. **MQTT ingest** (see [§4.3](#43-onramp-mqtt)).

Events use the same three paths (`POST /channels/{id}/event`), with role, mode, action (or a
boolean `state`) and an optional duration for auto-release. Notes are text-only annotations
(`POST /channels/{id}/note`). Each encoder card carries its own console log, meters with EBU
R128 loudness and a resettable integration.

### 3.5 Files and endpoints

- Channel config: `aes672hls-channels.json` (`--config`). Segment output: `aes672hls-out/`
  (`--output-dir`).
- Listen address: `--listen` sets it and is then persisted; falls back to `127.0.0.1:8080` on a
  genuine first run. A changed port takes effect on the next restart — there is no live rebind.
- API: `/license`, `/discovery`, `/ptp`, `/net`, `/system`, `/config`, `/config/import`,
  `/restart`, `/devices`, `/mqtt-options`, `/server-options`, `/channels`, `/channels/{id}`,
  `/channels/{id}/now-playing`, `/channels/{id}/event`, `/channels/{id}/note`,
  `/channels/{id}/status`, `/channels/{id}/devices`, `/channels/{id}/capture/source`,
  `/channels/{id}/capture/gain`, `/channels/{id}/capture/mute`, `/channels/{id}/loudness/reset`.

> **Note on exposure.** Onramp's control API, web UI and public HLS output all share one port.
> If you publish the stream to the internet, put a reverse proxy in front and restrict the
> control paths — or bind Onramp to localhost and let the proxy handle everything.

---

## 4. MQTT — the complete reference

Both products integrate with MQTT, but they were designed for **different jobs**, and the
difference matters when you plan a deployment. Read §4.1 before wiring anything.

### 4.1 Two different MQTT models

| | **Gateway** | **Onramp** |
|---|---|---|
| **Role** | Telemetry publisher | Control surface + state mirror |
| **Direction** | **Publish only** — never subscribes | **Two-way** — subscribes and publishes on the same topic |
| **Connections** | **One** shared broker connection for the whole appliance | **One per encoder** (each channel runs its own client) |
| **Topic model** | Everything under one configurable **base topic** | One flat topic per channel; no base topic, no tree |
| **What it publishes** | Now-playing, event booleans, per-stream health, system PTP status, availability | Now-playing only |
| **What it accepts** | Nothing | Now-playing patches, contact-closure events, notes |
| **Availability (LWT)** | Yes — `<base>/system/status` | No |
| **Home Assistant discovery** | Yes | No |
| **Client ID** | `hls2aes67-<pid>` | `hls-encoder-<channel-id>` |
| **Keep-alive / reconnect** | 15 s / 3 s | 30 s / 5 s |
| **QoS** | Publish QoS 1, retained | Publish QoS 1 retained; subscribe QoS 0 |
| **Transport** | Plain TCP (default 1883) | Plain TCP (default 1883) |

> **No TLS.** Neither product currently connects to a broker over TLS, and MQTT usernames and
> passwords are therefore sent in clear text. Keep the broker on a trusted network segment, or
> front it with a local TLS-terminating bridge.

**Rule of thumb:** if you want to *watch* what a feed is doing, that's Gateway. If you want to
*drive* what a stream says, that's Onramp.

---

### 4.2 Gateway MQTT

#### Connecting

Configure the broker on the Configuration page (or `PUT /api/mqtt`): **enabled**, **host**,
**port** (default 1883), **username**, **password**, **base topic** (default `hls2aes67`), plus
the Home Assistant options. Changes apply **live** — the connection is torn down and rebuilt
without touching audio.

One connection serves the whole appliance, with client ID `hls2aes67-<pid>`, a 15-second
keep-alive, and a 3-second retry backoff on any connection error. The dashboard's MQTT chip and
`GET /api/mqtt` report the live connection state.

#### The base-topic rule

**Everything Gateway publishes lives under the base topic.** A per-stream topic is a *path under
the base*, never an absolute escape hatch:

| Per-stream topic setting | Resulting topic (base = `hls2aes67`) |
|---|---|
| *(blank)* | `hls2aes67/stream1/nowplaying` (slot number, 1-based) |
| `newsroom/np` | `hls2aes67/newsroom/np` |
| `/newsroom/np/` | `hls2aes67/newsroom/np` (surrounding slashes ignored) |
| `hls2aes67/custom/np` | `hls2aes67/custom/np` (already prefixed — no double prefix) |

If the base topic is left **empty**, system topics are not published at all and a stream only
publishes if it has an explicit topic of its own. The single deliberate exception to the
base-topic rule is Home Assistant *discovery configuration*, which must live in HA's own
namespace (see [§4.4](#44-home-assistant-gateway-only)).

#### The topic tree

```
<base>/
├─ system/
│  ├─ status                        "online" | "offline"        (retained, Last-Will)
│  └─ ptp                           { role, domain, gm_identity, … }
│     ├─ running | mode | iface | role | gm_identity
│     ├─ domain | priority1 | priority2
│     └─ clock_source | ntp_synced | error
└─ stream<N>/nowplaying             { title, artist, album, … }
   ├─ title | artist | artist_id | album | album_id
   ├─ genre | image | isrc | type | duration
   ├─ events                        { kind, eas, …, active: [ … ] }
   │  ├─ eas | local_avail | program_cue | join_point | exit_point
   │  └─ gpio1 … gpio8              "true" | "false"
   └─ status                        { connected, codec, bitrate_kbps, lufs_s, … }
```

**Every message is retained**, so a subscriber that connects late — or a broker that restarts —
sees current state immediately rather than waiting for the next change.

#### `<base>/system/status`

`online` while connected. Registered as the connection's **Last Will and Testament**, so if the
appliance loses power or its network the broker itself publishes `offline`. This is the topic to
use for "is the box alive" alarms; it is also the availability source for every Home Assistant
entity.

#### `<base>/system/ptp`

Published at 1 Hz but **change-gated** — nothing is sent while the clock state is steady. The
rolling `ptp4l` log is deliberately excluded, precisely so it can't defeat that gating.

JSON blob, and each field also as its own retained sub-topic:

| Field | Meaning |
|---|---|
| `kind` | Always `"ptp"`. |
| `running` | Whether PTP is active. |
| `mode` | Configured mode: `auto` / `follower` / `grandmaster`. |
| `iface` | Interface PTP is bound to. |
| `role` | Live **media-clock** role, from a fixed vocabulary: `leader`, `follower`, `electing`, `stopped`, `host-managed`. Raw `ptp4l` port states never appear here. |
| `gm_identity` | Identity of the active grandmaster (ours when leading, the external one when following). |
| `domain`, `priority1`, `priority2` | Current PTP settings. |
| `clock_source` | What disciplines the **calendar**: `NTP` while running, `host` when the host manages the clock, else `stopped`. Never `PTP` — see §1. |
| `ntp_synced` | Whether the system calendar is NTP-synchronised. Independent of PTP. |
| `error` | Last PTP error, empty when healthy. |

#### `<stream topic>` — now-playing

Published whenever new metadata is decoded from the source. Both a JSON blob **and** one
retained raw value per field, so a subscriber that can't parse JSON (a lamp, a display, a legacy
automation input) can subscribe to a single field.

JSON blob keys: `kind` (`"now_playing"`), `title`, `artist`, `album`, `genre`, `type`, `isrc`,
`image`, `duration`, `station`.

Raw sub-topics: `title`, `artist`, `artist_id`, `album`, `album_id`, `genre`, `image`, `isrc`,
`type`, `duration`.

> The two sets are deliberately close but not identical: the blob carries `station` (the
> station name from the source's metadata) which has no sub-topic, and the sub-topics carry
> `artist_id` / `album_id` which are not in the blob. A field with no value publishes an **empty
> string**, which also clears any stale retained value left behind.

#### `<stream topic>/events` — station events

Every one of the 13 roles is published as a retained `"true"` / `"false"` string under
`.../events/<role>`, plus an aggregate blob on `.../events`:

```json
{ "kind": "events", "eas": false, "local_avail": true, "program_cue": false,
  "join_point": false, "exit_point": false, "gpio1": false, "…": false,
  "active": ["local_avail"] }
```

Evaluated at 1 Hz but published **only when a role actually changes**, so a quiet stream
generates no broker traffic. The full set is re-emitted after any broker reconfiguration, since
a new broker starts with no retained state.

This is the topic to automate against: *"mute the network feed while `eas` is `true`"*, *"fire
the break sequence when `local_avail` goes `true`"*.

#### `<stream topic>/status` — stream health

One retained JSON blob, published at 1 Hz and change-gated (a settled stream stops publishing):

| Field | Meaning |
|---|---|
| `connected` | Source is connected. |
| `aes67_running` | AES67 transmit path is running. |
| `source` | Resolved source kind: `hls` or `icecast`. |
| `codec` | Detected input codec (or container). |
| `bitrate_kbps` | Detected input bitrate. |
| `buffer_ms` | Playout buffer depth. |
| `drift_corrections` | Cumulative drift corrections applied by the ingest. |
| `lufs_s`, `lufs_i` | Short-term and integrated loudness (LUFS). |
| `true_peak_dbtp` | True peak (dBTP). |

#### Delivery caveat

Gateway enqueues publishes without blocking the audio path. The request queue is sized for the
worst realistic burst (a full Home Assistant discovery pass — up to ~26 entities × 8 streams plus
system, on top of normal traffic), but if a broker stalls long enough to overflow it, **excess
messages are dropped silently** rather than backing up into the pipeline. In practice this means
a wedged broker costs you telemetry, never audio.

---

### 4.3 Onramp MQTT

Onramp's MQTT is a **control surface**. For stations whose automation system already knows what
is on the air, it replaces the manual now-playing form entirely.

#### Connecting

The broker is configured **once, globally** (Configuration page → MQTT Options, or
`PUT /mqtt-options`) — enabled, `broker_url`, username, password. The topic is set **per
encoder**, in the encoder dialog.

`broker_url` accepts `host:port`, with an optional `mqtt://` or `tcp://` prefix that is stripped
on use; a bare host defaults to port **1883**. MQTT cannot be enabled without a broker address.

An encoder connects only when **all three** conditions hold: MQTT is globally enabled, a broker
address is set, and *that encoder* has a topic. Otherwise its MQTT task simply doesn't run.

Each encoder runs its **own client**, with client ID `hls-encoder-<channel-id>`, a 30-second
keep-alive, and a 5-second reconnect backoff that retries forever.

> **Client-ID collision.** The client ID is derived from the channel id alone. Two Onramp units
> pointed at the same broker with a channel of the same name (`default`, say) will present the
> same client ID and repeatedly kick each other off. Give channels unique ids across the plant —
> `wxyz-hd2`, not `default` — whenever more than one unit shares a broker.

The dashboard shows per-encoder MQTT state, and `GET /channels/{id}/status` returns
`mqtt_topic` and `mqtt_connected`. A topic configured with `mqtt_connected: false` for more than
a few seconds means the connection is failing — usually a rejected credential.

#### One topic, both directions

Each encoder **subscribes to and publishes on the same topic** (QoS 0 in, QoS 1 retained out).
That single topic is simultaneously the command inbox and the retained state mirror.

Onramp publishes its current now-playing state:

- on every successful connect and reconnect,
- whenever the now-playing fields change, from **any** source — the manual form, the control API,
  or an incoming MQTT message,
- after an incoming **event** message (which republishes the current state).

An incoming **note** does not trigger a republish.

As with Gateway, publishes are a JSON blob plus one retained raw value per field:

Blob keys: `kind` (`"now_playing"`), `title`, `artist`, `artist_id`, `album`, `album_id`,
`genre`, `image`, `isrc`, `type`, `duration`.

Sub-topics: `title`, `artist`, `artist_id`, `album`, `album_id`, `genre`, `image`, `isrc`,
`type`, `duration`. Unset fields publish an empty string.

> **Echo handling.** Because Onramp is subscribed to the topic it publishes to, the broker
> delivers its own retained publishes straight back. Onramp remembers the last **8** payloads it
> published and ignores a byte-identical message, which is what stops an infinite
> apply→publish→apply loop. It does *not* deduplicate a message that merely looks similar — an
> external republish of the same content with different key ordering will be applied again
> (harmlessly, since the result is the same state).

#### Incoming payload shapes

All ingest is JSON, dispatched on an optional `"kind"` field. Every path runs through exactly the
same validation as the equivalent HTTP endpoint — one schema, several ways in. Invalid payloads
are logged and dropped; they never disturb the encoder.

**1. Now-playing** — `kind: "now_playing"`, or **no `kind` at all** (the plain shape, kept for
backward compatibility):

```json
{
  "kind": "now_playing",
  "title":  "Cinnamon Girl",
  "artist": "Neil Young",
  "album":  "Everybody Knows This Is Nowhere",
  "artist_id": "…", "album_id": "…",
  "genre": "Rock", "image": "https://…/cover.jpg",
  "isrc": "USRE10900123", "type": "song", "duration": 178.0
}
```

This is a **patch**: only the fields you send are overwritten, the rest keep their current
values. Send `title` alone to change just the title. Unknown keys are ignored. Setting a new
title/artist resets the encoder's on-air elapsed clock, which is what makes event offsets
meaningful.

**2. Contact-closure event** — `kind: "event"`:

```json
{ "kind": "event", "role": "eas", "mode": "maintained",
  "action": "activate", "duration_s": 120 }
```

| Field | Required | Values |
|---|---|---|
| `role` | yes | One of the 13 roles: `eas`, `local_avail`, `program_cue`, `join_point`, `exit_point`, `gpio1`…`gpio8`. |
| `mode` | yes | `momentary` or `maintained`. |
| `action` | one of these two | `activate` or `deactivate`. |
| `state` | one of these two | Boolean shorthand: `true` = activate, `false` = deactivate. |
| `duration_s` | no | Only meaningful with `mode: "maintained"` + `activate`. Schedules an automatic deactivate after that many seconds. |

Any new event for a role cancels a pending auto-deactivate from an earlier one, so a re-trigger
extends the closure rather than being cut short by the previous timer.

**3. Note** — `kind: "note"`:

```json
{ "kind": "note", "text": "Top of hour ID" }
```

Empty or whitespace-only text is rejected.

#### What Onramp does *not* publish

There is no `system/` tree, no availability/Last-Will topic, no health or loudness telemetry, and
no Home Assistant discovery. Encoder health lives on the HTTP API
(`GET /channels/{id}/status`) and the dashboard. If you need Onramp health in an automation
system today, poll that endpoint.

> **Don't put wildcards in a channel topic.** The topic string is used verbatim for both the
> subscribe *and* the publish. A `+` or `#` in it would subscribe broadly and then publish to a
> literal topic containing the wildcard character.

---

### 4.4 Home Assistant (Gateway only)

Enable **Home Assistant discovery** in Gateway's MQTT panel and the appliance appears in HA
automatically — no YAML. Gateway publishes retained discovery definitions to HA's own namespace
(the **discovery prefix**, default `homeassistant`):

```
<prefix>/<component>/hls2aes67_<device-id>/<object-id>/config
```

The device id is the appliance's hostname, lower-cased and sanitised (falling back to
`appliance`). Everything appears as one HA **device** — manufacturer *Optimized Media Group*,
model *Interchange Gateway* — with the running firmware version attached.

**Entities created:**

*System (5):* PTP Role, PTP Domain, PTP Grandmaster ID (sensors); PTP Grandmaster running, NTP
Synchronized (binary sensors). All tagged as diagnostic.

*Per running stream (26):*

| Group | Entities |
|---|---|
| Now-playing (5 sensors) | Title, Artist, Album, Genre, Content Type |
| Events (13 binary sensors) | `eas`, `local_avail`, `program_cue`, `join_point`, `exit_point`, `gpio1`…`gpio8` |
| Health (8) | Connected, AES67 Output (binary sensors); Source Kind, Codec, Bitrate, Playout Buffer, Loudness (S), True Peak (sensors, with units and `measurement` state class) |

Every entity's **availability** is tied to `<base>/system/status`, so the whole device shows
*unavailable* in HA the moment the appliance drops.

Discovery is **reconciled continuously**, not published once: entities are added when a stream
starts, and removed (by clearing the retained config topic) when a stream stops, is renamed or
retopiced, or when discovery is switched off. A reconnect forces one full republish in case the
broker lost its retained state.

> Enabling discovery writes into your live Home Assistant. Eight streams is 5 + 8×26 = **213
> entities**. Turn it on deliberately.

---

### 4.5 Integration patterns

**A. Watch a feed, act in the plant.** Subscribe to `<base>/stream1/nowplaying/events/eas`.
`"true"` means the source has asserted an EAS closure — mute the network return, fire a router
salvo, light a warning lamp. Because the value is retained, your automation sees the correct
state the instant it connects, not at the next transition.

**B. Drive a stream from playout.** Have automation publish a now-playing patch to the Onramp
encoder's topic on every song start, and an `event` message at each break. Nothing in the studio
has to touch the Onramp UI, and the metadata is embedded in the HLS output where a compatible
decoder — including a downstream Gateway — will read it.

**C. Relay metadata from Gateway to Onramp.** Gateway's now-playing blob is directly ingestible
by Onramp: it carries `kind: "now_playing"` and the field names line up, and Onramp ignores the
extra keys. Bridging the two lets a rebroadcast carry the origin station's metadata.

> Do this with a small broker-side rule or bridge that copies Gateway's blob to the Onramp
> encoder's own topic — **not** by pointing both products at one shared topic. If they share a
> topic, both write the same retained message and the retained payload flaps between two slightly
> different shapes (Gateway's includes `station`; Onramp's includes `artist_id`/`album_id`).
> There's no feedback loop — Gateway never subscribes — but the retained state becomes
> ambiguous.

**D. Skip MQTT entirely for a round trip.** Onramp embeds metadata and events in the HLS stream
itself, and Gateway decodes them natively. For a plain Onramp → internet → Gateway path, titles
and closures arrive intact with no broker in the chain. Use MQTT when a *third* system needs to
see or drive them.

**E. Home Assistant as the operator display.** Enable discovery on Gateway and you get a
ready-made status wall — per-stream connectivity, loudness, bitrate, and EAS/GPIO lamps —
without building a dashboard.

---

### 4.6 MQTT troubleshooting

| Symptom | Check |
|---|---|
| **Gateway** MQTT chip never goes green | Host/port/credentials; that the appliance can reach the broker (`system/status` will read `offline` or be absent). |
| Nothing under the base topic | Base topic is blank ⇒ system topics are suppressed. Streams only publish while they are **running**. |
| A stream publishes nowhere | With a blank base topic, a stream needs its own explicit topic or it publishes nothing. |
| Values look frozen | Expected. Events, health and PTP are **change-gated** — no change, no message. Confirm with the dashboard. |
| Stale values after re-pointing a topic | Retained messages persist on the old topic. Clear them at the broker (publish an empty retained payload). |
| HA entities missing / stuck unavailable | Availability rides `<base>/system/status`. Confirm the discovery prefix matches HA's `mqtt.discovery_prefix`, and that HA is on the same broker. |
| HA entities linger after a stream is removed | Reconciliation clears them on the next pass while connected; if the broker was down at the time, toggle discovery off and on. |
| **Onramp** encoder shows a topic but `mqtt_connected: false` | Broker is refusing the connection — most often bad or missing credentials. The reconnect loop retries every 5 s and only logs a warning. |
| Two Onramp units keep dropping | Client-ID collision from identically-named channels. Rename the channels. |
| Onramp ignores a published message | It must be valid JSON, and it must not be byte-identical to one of Onramp's own last 8 publishes. Check the encoder's console log — every rejection is logged with the reason. |
| An event message is rejected | `role` must be one of the 13; `mode` must be `momentary`/`maintained`; and you must supply either `action` or the boolean `state`. |
| A maintained closure never releases | `duration_s` only applies to `mode: "maintained"` with `action: "activate"`. Otherwise send an explicit deactivate. |

---

## 5. Operations reference

### Deployment

| Platform | Form |
|---|---|
| Debian / Ubuntu | `.deb` package with a systemd unit. Onramp bundles an ffmpeg with `libfdk_aac`; Gateway decodes via GStreamer and needs no ffmpeg. |
| Proxmox LXC | Per-product container template. PTP is host-managed automatically. |
| Proxmox VM | Debian cloud image + a one-line deployer. |
| Windows | Installer registering the appliance as a Windows service (Automatic, delayed start). |

The systemd units run **unsandboxed as root** by design: the PTP manager writes to `/etc` and
`/tmp` and drives `timedatectl` / `ptp4l`, and the AoIP path needs multicast plus
`CAP_SYS_TIME` / `CAP_NET_ADMIN`.

### Interfaces

Both products expect a **dual-NIC** layout: a management interface for the web UI and control
plane, and a gateway-less **AoIP interface** for multicast, PTP and SAP. The AoIP interface is
auto-detected (the one without a default gateway) and can be pinned on the Configuration page.

### Network fabric

Multicast audio requires **IGMP snooping with an active querier** on the switch. Give PTP and
RTP appropriate QoS. Control-plane traffic — PTP, SAP/SDP and MQTT combined — stays well under
100 kbps even while leading the clock; it is never the constraint.

### Ports

| Port | Product | Purpose |
|---|---|---|
| 8088/tcp | Gateway | Web UI + control API (configurable) |
| 8080/tcp | Onramp | Web UI + control API + HLS output (configurable) |
| 5004/udp | Both | RTP audio (per-stream configurable; pinned for Livewire) |
| 9875/udp | Both | SAP announcements |
| 319, 320/udp | Both | PTP |
| 1883/tcp | Both | MQTT to the broker (outbound; configurable) |

### Sizing

Gateway at its 8-stream maximum with all-lossless sources draws roughly 9–10 Mbps inbound; an
all-AAC deployment is under ~1 Mbps. Measured steady-state consumption for an 8×8 lab
deployment was approximately 0.45 cores / 172 MB for Onramp and 0.30 cores / 221 MB for Gateway —
the documented 2 cores / 1 GB per appliance is deliberately generous.

---

## Glossary

**AES67** — Interoperability standard for professional audio-over-IP: L24 PCM over RTP
multicast, PTP-clocked. · **Livewire+** — Telos/Axia's AoIP system; AES67-compatible, with its
own discovery and channel numbering. · **AoIP NIC** — the interface carrying audio-over-IP,
typically dedicated and gateway-less. · **HLS** — HTTP Live Streaming: a rolling media playlist
(`.m3u8`) of short segments, plus a master playlist listing renditions. · **HE-AAC** — AAC with
Spectral Band Replication; high efficiency at low bitrates. · **LUFS / LKFS** — loudness units
(EBU R128 / ITU-R BS.1770); **dBTP** is true peak in dB. · **PTP** — Precision Time Protocol
(IEEE 1588), the shared timebase of an AoIP plant. · **BMCA** — Best Master Clock Algorithm, the
election that decides which device leads PTP. · **SAP / SDP** — Session Announcement /
Description Protocol; how AES67 sources advertise themselves. · **EAS / GPI** — Emergency Alert
System / General-Purpose Input; contact-closure events carried alongside the audio. ·
**Retained message** — an MQTT message the broker stores and delivers immediately to any new
subscriber. · **LWT** — Last Will and Testament; a message the broker publishes on your behalf
if you disconnect unexpectedly.
