# Interchange — HTTP API Reference

**Optimized Media Group · Interchange Gateway & Interchange Onramp**

Every function of both appliances is reachable over HTTP. The web UI is itself a client of these
endpoints and uses nothing private — anything the UI can do, an automation system can do.

Companion document: the [Interchange User Guide](INTERCHANGE-USER-GUIDE.md), which covers what
the products do and the MQTT interface in depth.

---

## Contents

1. [Conventions](#1-conventions)
2. [Gateway API](#2-gateway-api)
3. [Onramp API](#3-onramp-api)
4. [Shared data types](#4-shared-data-types)
5. [Worked examples](#5-worked-examples)

---

## 1. Conventions

### Base URL and mounting

| | Gateway | Onramp |
|---|---|---|
| Default listen | `0.0.0.0:8088` | `127.0.0.1:8080` |
| API prefix | **`/api`** — e.g. `/api/streams/0` | **none** — routes sit at the root, e.g. `/channels/foo` |
| Also served here | Web UI, `/ws` | Web UI **and the public HLS output** |

Onramp mounts its control API, its web UI and every channel's playlist and segments on **one
port at the root**. Gateway keeps its control plane under `/api` and serves only the UI
elsewhere.

### Authentication

**Neither control API is authenticated.** There are no API keys, tokens or sessions; any client
that can reach the port has full control, including licence changes and service restarts.

The only HTTP auth in either product runs the other way round: Onramp's *served HLS streams* can
require Basic credentials from a player (§3.10), and Gateway *sends* Basic credentials to a
protected source. Neither protects the control API.

> **Deploy accordingly.** Bind the control plane to a management interface (Gateway's
> `mgmt_iface`) or to localhost, and put a reverse proxy in front if it must be reachable more
> widely. This matters most on Onramp, where the control API shares a port with output you may
> want to publish.

### Request and response format

- Request bodies are JSON and require `Content-Type: application/json`. The one exception is
  Onramp's `PUT /config/import`, which takes the raw body as text.
- **Successful** responses are JSON, except where noted (`204`, `202`, and Gateway's SDP
  endpoint, which returns `application/sdp`).
- **Error** responses are **plain text**, not JSON. Don't parse an error body as JSON — read the
  status code and treat the body as a human-readable message.

```
HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8

output 239.69.1.1:5004 is already used by stream 1 ('station-2') — each enabled stream needs a unique multicast address:port
```

### Status codes

| Code | Meaning |
|---|---|
| `200` | Success, JSON body. |
| `202` | Accepted — the restart endpoints, which respond before acting. |
| `204` | Success, no body (Gateway's loudness reset). |
| `400` | Validation failure, or malformed JSON. Body is the reason. |
| `403` | Blocked by the unlicensed-mode cap. Body names the limit and your Install ID. |
| `404` | No such stream / channel / SDP. |
| `409` | Conflict — an audio device already claimed by another Onramp channel. |
| `415` | Missing or wrong `Content-Type` on a JSON endpoint. |
| `422` | Well-formed JSON that doesn't match the expected schema. |
| `500` | Failed to persist configuration, or an operation failed internally. Body is the error chain. |

`400`, `415` and `422` for body problems are produced by the web framework before the handler
runs; the rest come from the handlers and always carry an actionable message.

### Patch semantics

Several endpoints accept partial updates, and **the rule is not uniform** — check the endpoint:

| Pattern | Where | Behaviour |
|---|---|---|
| **Merge patch** | Gateway `POST /api/ptp`; Onramp `PUT /ptp`, `PUT /channels/{id}`, `PUT /mqtt-options` | Omitted fields keep their current value. |
| **Full replace** | Gateway `PUT /api/streams/{id}`, `PUT /api/net`, `PUT /api/mqtt` | The body is the new object. Omitted optional fields fall back to their *defaults*, not their current values. |
| **Empty string clears** | Onramp `mqtt_topic`, `stream_username`, `stream_password` | Omitted = leave alone; `""` = clear the setting. |

> The distinction bites on Gateway's `PUT /api/streams/{id}`: it is a **replace**, so a request
> that omits `multicast_addr` gets an empty string and fails validation, and one that omits
> `enabled` gets `true`. Read the current object from `GET /api/config` and send it back
> modified. One field is exempt — `gain_db` is deliberately preserved from the existing config
> rather than taken from the body, so the setup form can't reset a live trim.

### Persistence and when changes take effect

Both products persist to their JSON config file on every accepted write, so changes survive a
restart. What differs is how quickly they take hold:

| Change | Effect |
|---|---|
| Gain, mute, loudness reset, now-playing, events | Immediate; no interruption. |
| PTP settings, MQTT broker | Applied live. |
| One Gateway stream | Only that stream's audio path rebuilds (~1–2 s gap on that output). |
| Onramp codec / bitrate / station / topic | Applied live to that encoder; a codec change restarts only its ffmpeg. |
| Gateway `base_topic` | Live, but every stream is re-applied so topics re-resolve — expect a brief per-stream blip. |
| Network binding, listen address, web port | Requires `POST /api/restart` (Gateway) or `POST /restart` (Onramp). |

---

## 2. Gateway API

All paths are prefixed `/api` unless stated. Stream ids are integers **0 – 7**; a non-numeric id
is rejected by the router with `400`.

### 2.1 `GET /api/state` — running snapshot

Returns the same object the WebSocket streams (§2.2). **Only running streams appear** — a
configured-but-stopped slot is absent. Use `GET /api/config` to enumerate configured streams.

```json
{ "streams": [ { … } ] }
```

Each entry:

| Field | Type | Meaning |
|---|---|---|
| `id` | int | Slot number, 0-based. |
| `name` | string | Display name. |
| `connected` | bool | Source is connected. |
| `error` | string? | Last source error. |
| `hls_url` | string | Configured source URL. |
| `playlist` | object? | `media_sequence`, `target_duration`, `segment_count`, `is_live`, `version`. HLS only. |
| `window_depth_s` | float | Depth of the source's live window. |
| `live_edge_latency_s` | float? | How far behind the live edge we are. |
| `container` | string? | Source container (HLS). |
| `input_codec` | string? | Decoded codec (Icecast/SHOUTcast). |
| `bitrate_kbps` | int? | Source bitrate when known. |
| `buffer_ms` | float | Playout buffer depth. |
| `drift_corrections` | int | Cumulative drift corrections applied. |
| `gain_db` | float | Live output trim. |
| `station` | object? | `name`, `id`, `uuid`, `call_sign`, `genre`, `website`, `logo`, `image`. |
| `now_playing` | object? | Track: `title`, `artist`, `album`, `genre`, `type`, `image`, `isrc`, `duration`. |
| `upcoming` | array | Same shape, upcoming tracks. |
| `psd` | object? | Latest in-band program-service data: `segment`, `title`, `artist`, `album`, `genre`, `isrc`, `encoder`, `extra` (array of `[key, value]`). |
| `events` | array | Declared events on the current track: `role`, `kind`, `mode`, `action`, `text`. |
| `active_events` | array | Roles asserted **right now**: `role`, `mode`, `remaining_s`. This is what drives the indicator lamps. |
| `aes67` | object | See below. |
| `new_logs` | array | Log entries **since your last poll** — see the cursor note. |

`aes67`: `running`, `error`, `multicast`, `port`, `iface`, `channels`, `payload_type`,
`ptime_ms`, `source` (`"hls"`/`"icecast"`), `livewire_channel`, `rms_db[]`, `peak_db[]`,
`sdp_available`, `lufs_m`, `lufs_s`, `lufs_i`, `lra`, `true_peak_dbtp`.

> **`new_logs` is cursor-based per connection.** A WebSocket client receives the retained history
> on its first frame and only new entries thereafter. `GET /api/state` opens a fresh cursor every
> call, so each request returns the **full** log history. Poll `/api/state` for state and you'll
> re-read the whole log each time; use the WebSocket if you want the incremental stream.

`active_events` merges two sources and keeps the longer countdown: contact-closure events
evaluated against the track's elapsed clock, and a content-type signal (a track whose `type` is
`eas` asserts the `eas` role for the track's whole duration).

### 2.2 `GET /ws` — live snapshot stream

WebSocket at `/ws` (**no** `/api` prefix). Pushes the §2.1 snapshot as a JSON text frame at
**20 Hz**; the UI interpolates to 60 fps meters locally. The server ignores anything you send
except a close frame. There is no subscribe/filter protocol — every client gets everything.

At 20 Hz with 8 streams this is a substantial feed. For monitoring, prefer MQTT (change-gated) or
a slow `/api/state` poll.

### 2.3 `PUT /api/streams/{id}` — create or update a stream

**Full replace** (see [patch semantics](#patch-semantics)). Restarts only this stream.

| Field | Type | Default | Notes |
|---|---|---|---|
| `hls_url` | string | *required* | Non-empty. |
| `name` | string | `station-<N>` | Blank falls back to the generated name. |
| `source_type` | enum | `auto` | `auto` / `hls` / `icecast`. |
| `enabled` | bool | `true` | |
| `multicast_addr` | string | `""` | Required unless `livewire_channel` is set; must be a valid IPv4 multicast address. |
| `port` | int | `5004` | |
| `channels` | int | `2` | |
| `livewire_channel` | int? | `null` | 1 – max. Pins the address and RTP port, overriding the two fields above. |
| `mqtt_topic` | string? | `null` | Resolved under `base_topic`. Blank is stored as unset. |
| `username` / `password` | string? | `null` | Basic auth sent to the source. |
| `tls_insecure` | bool | `false` | Accept an invalid certificate on an `https://` source. |

**Success:** `200` with the full config object (identical to `GET /api/config`).

**Errors:** `400` id out of range · `400` no URL · `400` invalid multicast address · `400`
Livewire channel out of range · `400` the output endpoint collides with another **enabled**
stream · `403` unlicensed cap · `500` config save failed.

The collision check compares *effective* endpoints, so a Livewire channel that resolves onto
another stream's manual address is caught too. Disabled streams may overlap freely.

### 2.4 `DELETE /api/streams/{id}`

Removes the stream and stops that slot. `200` with the full config object; `400` for an id
outside 0–7. Deleting an id that isn't configured succeeds silently.

### 2.5 `POST /api/streams/{id}/gain`

```json
{ "gain_db": -3.5 }
```

Clamped to ±12 dB; a non-finite value becomes `0`. Applies live and persists. Returns the
**clamped** value — read it back rather than assuming your input was accepted verbatim:

```json
{ "gain_db": -3.5 }
```

### 2.6 `POST /api/streams/{id}/loudness/reset`

Restarts the EBU R128 integration (integrated LUFS, LRA, max true peak). Momentary and short-term
are windowed and unaffected. **`204 No Content`** on success, `404` if the stream doesn't exist.

### 2.7 `GET /api/streams/{id}/sdp`

Returns the stream's announced SDP as `application/sdp`. `404` if the stream isn't running or
hasn't produced one. The `ts-refclk` line tracks the live PTP grandmaster.

### 2.8 `GET` / `POST /api/ptp`

`GET` returns [`PtpStatus`](#41-ptpstatus). `POST` is a **merge patch**:

```json
{ "mode": "follower", "domain": 0, "priority1": 130, "priority2": 130,
  "ntp_servers": "10.0.0.1 10.0.0.2" }
```

All fields optional. `mode` is `auto` / `follower` / `grandmaster`. `ntp_servers` is
space- or comma-separated and reconfigures the system time source live.

Returns the updated `PtpStatus`. It responds **without waiting for the clock election** — a
newly-enabled leader reports its old role until `ptp4l` reaches master, typically within a couple
of seconds. Poll if you need to observe the transition. `500` if PTP could not be applied
(usually: not running as root).

### 2.9 `GET /api/nics`

Lists network interfaces with names and addresses, for interface pickers.

### 2.10 `GET` / `PUT /api/net`

`GET` returns:

```json
{ "configured": { "aoip_iface": "ens19", "mgmt_iface": null, "web_port": 8088 },
  "running_aoip_iface": "ens19", "running_web_bind": "0.0.0.0:8088",
  "restart_required": false }
```

`PUT` takes the `configured` object. Interface names are validated against the live NIC list;
`web_port` must be non-zero; an empty `mgmt_iface` string is normalised to `null` (all
interfaces). Persists but **does not rebind** — `restart_required` goes `true` until you
`POST /api/restart`.

Errors: `400` unknown AoIP interface · `400` unknown management interface · `400` port 0 ·
`500` save failed.

### 2.11 `GET` / `PUT /api/mqtt`

`GET` returns live connection state only:

```json
{ "enabled": true, "connected": true, "host": "10.0.0.5", "port": 1883 }
```

`PUT` takes the **full** MQTT config — `enabled`, `host`, `port`, `username`, `password`,
`base_topic`, `ha_discovery`, `ha_discovery_prefix` — persists it, and reconnects live. Returns
the same status object as `GET`; note the response tells you the *new* configuration's state,
which may still be `connected: false` for a moment while the connection establishes.

Changing `base_topic` re-applies every configured stream so topics re-resolve under the new base.

Full topic semantics are in the [User Guide](INTERCHANGE-USER-GUIDE.md#42-gateway-mqtt).

### 2.12 `GET /api/system`

```json
{ "version": "2026.08.191", "build_ts": "2026-08-13T…Z",
  "uptime_secs": 84213, "hostname": "gateway-1" }
```

`version` is a calendar version stamped at build time. `hostname` also determines the Home
Assistant device id.

### 2.13 `GET` / `PUT` / `DELETE /api/license`

All three return [`LicenseView`](#43-licenseview). `PUT` takes `{"token": "…"}` — an empty or
whitespace-only token is equivalent to `DELETE`, which removes the installed token. `500` if the
token can't be written to disk.

Quote `install_id` from the response when requesting a licence. Installing a licence takes effect
immediately; it does not start streams that were blocked earlier, so enable them afterwards.

### 2.14 `GET /api/config` — full configuration

The System Configuration page's backing object, and the backup payload:

```json
{ "config": { "net": {…}, "mqtt": {…}, "ptp": {…}, "streams": […] },
  "running_aoip_iface": "ens19", "running_web_bind": "0.0.0.0:8088",
  "restart_required": false, "mqtt": {…}, "nics": […], "max_streams": 8 }
```

The MQTT **password is included** in `config.mqtt`, as are per-stream source passwords. Treat a
downloaded backup as a secret.

### 2.15 `PUT /api/config/import` — restore

Body is the **inner `config` object**, not the whole `GET /api/config` envelope. Validated as a
set before anything is applied:

- at most 8 streams,
- every stream valid individually (id in range, URL present, multicast/Livewire valid),
- no duplicate stream ids,
- no two **enabled** streams sharing an output endpoint.

Any failure returns `400` with the offending stream named and **nothing is applied** — the
restore is all-or-nothing. On success every stream is re-applied per slot and MQTT and PTP
reconnect; network bindings still need a restart. Returns the full config object.

### 2.16 `POST /api/restart`

Re-execs the service so apply-on-restart settings take effect. Responds `202 Accepted` with
`restarting` immediately; teardown takes about a second, then the process replaces itself.
Debounced — a second call while one is in flight returns `202` with `restart already in
progress`. The web listener stays up until the exec, so the response always reaches you.

---

## 3. Onramp API

Routes are at the **root** — no prefix. Channel ids are strings of 1–32 characters from
`A–Z a–z 0–9 - _`.

### 3.1 `GET /channels` — list

```json
[ { "id": "default", "station_name": "KXYZ",
    "playlist_url": "http://host:8080/channels/default/media.m3u8",
    "capture_source": "station-1 · 239.192.83.253:5004",
    "capture_ok": true, "mqtt_topic": "station/np", "stream_auth": false } ]
```

`playlist_url` is built from the request's `Host` header (honouring `X-Forwarded-Host` /
`-Proto`), so the URL is correct from wherever you called it — not the bind address.
`capture_source` includes the discovered source name when one is advertised.

### 3.2 `POST /channels` — create

```json
{ "id": "hd2", "station_name": "KXYZ-HD2", "station_id": "kxyz",
  "station_uuid": "…", "playlist_name": "media.m3u8",
  "source": { "kind": "livewire", "channel": 1234 },
  "codec": "he_aac", "bitrate_kbps": 64,
  "mqtt_topic": "kxyz/hd2/np",
  "stream_username": "listener", "stream_password": "…",
  "mismatch_uuid": false }
```

Only `id` is required. `source` defaults to the system default input; `playlist_name` to
`media.m3u8`; `codec` to `aac_lc`. See [`CaptureSource`](#44-capturesource) for source shapes.

**Errors:** `400` invalid playlist name · `400` bitrate not one of the presets for a lossy codec ·
`400` invalid channel id · `400` duplicate id · `400` channel limit reached · `400` the requested
audio device is already claimed · `403` unlicensed cap.

A playlist name is rejected if it is empty, contains `/` or `\`, or collides with a route name
already mounted under the channel: **`status`**, **`devices`**, **`now-playing`**,
**`master.m3u8`**.

`bitrate_kbps` must be one of **64, 96, 128, 160, 192, 224, 256, 320**. It is stored as `null`
for FLAC regardless of what you send.

Returns `{"ok": true}`.

### 3.3 `PUT /channels/{id}` — update

**Merge patch.** Fields: `station_id`, `station_name`, `station_uuid`, `playlist_name`,
`mismatch_uuid`, `mqtt_topic`, `codec`, `bitrate_kbps`, `stream_username`, `stream_password`.

Omitted = unchanged. For `mqtt_topic`, `stream_username` and `stream_password`, an explicit `""`
**clears** the setting. There is no way to clear `bitrate_kbps` back to "let the encoder choose"
— switch to a codec without a bitrate, which drops it.

Codec and bitrate are validated **together** against the resulting combination, so you can change
either alone. Touching `mqtt_topic` restarts that channel's MQTT client. Everything applies live.

Returns `{"ok": true}`; `404` unknown channel; `400` validation.

To change the **source**, use `POST /channels/{id}/capture/source` (§3.6) — it is not part of this
patch.

### 3.4 `DELETE /channels/{id}`

Stops the encoder, releases its device claim and removes its configuration. `{"ok": true}`, or
`404`.

### 3.5 `GET /channels/{id}/status` — full channel state

The dashboard's polling endpoint.

| Field | Meaning |
|---|---|
| `id` | Channel id. |
| `track` | Current now-playing object (all metadata fields). |
| `station` | `id`, `name`, `uuid`. |
| `elapsed_s` | Seconds since the current track went on air. |
| `closures` | One entry per role — see below. |
| `segment_sequence` | Sequence number of the most recent segment. |
| `capture_ok` | Input is producing audio. `false` is the `NO INPUT` state. |
| `last_encode_error` | Most recent encoder error, if any. |
| `uptime_s` | Seconds since this encoder started. |
| `capture_source` | Human-readable source label with discovered name. |
| `gain_db`, `muted`, `peak_dbfs` | Live input controls and level. |
| `playlist_name`, `playlist_url`, `master_playlist_url` | Output locations, host-derived. |
| `mismatch_uuid` | Diagnostic UUID-mismatch mode. |
| `mqtt_topic`, `mqtt_connected` | See the caveat below. |
| `codec`, `bitrate_kbps` | Current encode settings. |
| `stream_username`, `stream_auth` | Basic-auth username (not secret) and whether auth is in force. The password is never returned. |
| `meter` | [`MeterSnapshot`](#42-metersnapshot). |
| `log` | Up to the **last 80** log entries: `id`, `at`, `level` (`info`/`event`/`warn`/`error`), `msg`. |

`closures` has one entry for **every** role, always 13 entries:

```json
{ "role": "eas", "mode": "maintained", "active": true, "remaining_s": 47.2 }
```

`mode: null` means this role has never reported an event — distinct from `active: false`, which
means reported and currently inactive.

> **`mqtt_connected: false` is ambiguous by design.** It covers "MQTT globally disabled", "no
> topic on this channel", "still connecting", and "the broker is rejecting us". A channel that
> shows a `mqtt_topic` but stays disconnected for more than a few seconds is failing — check the
> encoder log, which records the reason.

Unlike Gateway's `/api/state`, `log` is **not** cursor-based: every call returns the same recent
window. Track `id` values yourself to detect new entries.

### 3.6 `POST /channels/{id}/capture/source` — repoint live

Body is a [`CaptureSource`](#44-capturesource). Switches the input **without dropping the output
stream**. Returns `{"ok": true}`.

**Errors:** `409` the named audio device is held by another channel (body names the holder) ·
`400` the source could not be opened · `404` unknown channel.

### 3.7 `PUT /channels/{id}/capture/gain` · `POST /channels/{id}/capture/mute`

```json
{ "gain_db": -3.0 }
{ "muted": true }
```

Both apply immediately and persist. `{"ok": true}`. Unlike Gateway's gain, **the value is not
clamped** — send a sane range.

### 3.8 `POST /channels/{id}/loudness/reset`

Restarts the input loudness integration. `{"ok": true}`.

### 3.9 Metadata and events

**`PUT /channels/{id}/now-playing`** — merge patch over the current track. Fields: `title`,
`artist`, `artist_id`, `album`, `album_id`, `genre`, `image`, `isrc`, `type`, `duration`.
Omitted fields keep their value. Unknown fields are ignored. Triggers an MQTT republish.
Changing the track identity resets `elapsed_s`.

**`POST /channels/{id}/event`** — fire a contact closure:

```json
{ "role": "eas", "mode": "maintained", "action": "activate", "duration_s": 120 }
```

| Field | Required | Values |
|---|---|---|
| `role` | yes | `eas`, `local_avail`, `program_cue`, `join_point`, `exit_point`, `gpio1`…`gpio8`. |
| `mode` | yes | `momentary` or `maintained`. |
| `action` | one of the two | `activate` / `deactivate`. |
| `state` | one of the two | Boolean shorthand: `true` = activate. |
| `duration_s` | no | Maintained activate only — schedules an automatic deactivate. |

Returns `{"ok": true, "offset": 12.34}` — the event's offset in seconds from the current track's
start, which is how it is encoded into the stream. A new event for a role cancels any pending
auto-deactivate for that role, so re-triggering extends rather than truncates.

`400` with a specific message for an unknown role, a bad mode or action, or neither `action` nor
`state`.

**`POST /channels/{id}/note`** — `{"text": "Top of hour ID"}`. Returns `{"ok": true, "offset": …}`.
`400` if the text is empty or whitespace. Notes do **not** trigger an MQTT republish.

All three are also reachable over MQTT with identical validation — see the
[User Guide](INTERCHANGE-USER-GUIDE.md#43-onramp-mqtt).

### 3.10 HLS output

Not part of the control API, but served from the same port:

```
GET /channels/{id}/master.m3u8        ← point players here
GET /channels/{id}/{playlist_name}
GET /channels/{id}/segments/{file}
```

If the channel has a `stream_username` set, all three require HTTP Basic auth. Credentials are
compared in constant time. Content types are set per codec (`audio/aac`, `audio/mpeg`,
`audio/flac`).

### 3.11 `GET /devices` · `GET /channels/{id}/devices`

Local audio inputs with their claim state:

```json
{ "devices": [ { "name": "Line In (Audio Interface)", "in_use_by": "default" } ] }
```

The channel-scoped form excludes the calling channel's own claim, so it can list its current
device as available. The unscoped form shows every holder — it's for the "add channel" form,
which has no id yet. `500` if enumeration fails.

### 3.12 `GET /discovery`

Live table of AES67/Livewire sources heard on the AoIP network — the source browser's backing
data. Entries age out on a TTL, so the result is current, not cumulative. See
[`DiscoveredSource`](#45-discoveredsource).

Empty is normal if no AoIP interface was resolvable at startup or nothing is advertising.

### 3.13 `GET` / `PUT /ptp`

`GET`:

```json
{ "status": { …PtpStatus… }, "ntp_servers": "10.0.0.1" }
```

`PUT` is a **merge patch** over `mode`, `domain`, `priority1`, `priority2`, `ntp_servers`;
persists and applies live. Returns `{"ok": true}`, or `500` with `PTP apply failed (needs root?)`
— the usual cause when running unprivileged.

Note the asymmetry with Gateway: Gateway's PTP write returns the updated status, Onramp's returns
only `ok`. Follow with `GET /ptp` if you need the new state.

### 3.14 `GET /net`

```json
{ "aoip_iface": "ens19", "nics": [ … ] }
```

`aoip_iface` is the **auto-detected** gateway-less interface and may be `null`. Onramp has no
`PUT /net`; the AoIP interface is detected, not configured. Use `/server-options` for the listen
address.

### 3.15 `GET` / `PUT /server-options`

```json
{ "listen_addr": "0.0.0.0:8080", "configured_listen_addr": "0.0.0.0:8080",
  "restart_required": false }
```

`PUT` takes `{"listen_addr": "host:port"}`, validated as a socket address. Persisted only —
there is no live rebind, so `restart_required` goes `true` until `POST /restart`. `400` on an
unparseable address.

### 3.16 `GET` / `PUT /mqtt-options`

`GET` returns the shared broker settings, **password omitted**:

```json
{ "enabled": true, "broker_url": "10.0.0.5:1883", "username": "onramp" }
```

`PUT` is a **merge patch** over `enabled`, `broker_url`, `username`, `password`. Because omitted
means unchanged, sending no `password` keeps the stored one — which is exactly how the UI
implements "leave blank to keep". An empty `username` clears it.

`400` if `enabled` is true with a blank `broker_url`. Returns `{"ok": true}`.

`broker_url` accepts `host:port`, or a bare host (port 1883), with an optional `mqtt://` or
`tcp://` prefix. Topics are set per channel, not here.

### 3.17 `GET` / `PUT` / `DELETE /license`

Identical semantics to Gateway (§2.13); the view uses `demo_channel_limit` in place of
`demo_stream_limit`.

### 3.18 `GET /system`

```json
{ "version": "2026.08.191", "build_ts": "…", "uptime_secs": 3600, "hostname": "onramp-1" }
```

### 3.19 `GET /config` · `PUT /config/import`

`GET` returns the whole persisted configuration as JSON — the backup payload. It contains the
**MQTT password and every channel's stream password**; treat it as a secret.

`PUT /config/import` takes that JSON as the **raw request body** (a plain string, not a typed
JSON extractor — so it is tolerant about `Content-Type`). The export is exactly the import
payload; no unwrapping is needed, unlike Gateway.

Pre-flight validation covers the channel count and every channel id. Past that point the restore
**replaces the channel set in place**: all current channels are stopped and deleted, then the
imported ones are created one at a time. A channel that fails to create — a device now claimed
elsewhere, a source that won't open — is **logged and skipped**, and the restore still reports
success.

> **Onramp's restore is not all-or-nothing** (Gateway's is). A partial failure leaves you with
> fewer encoders than the backup contained, and a `200`. Compare `GET /channels` against the
> backup afterwards, and check the service log for skipped channels.

`400` with the reason if pre-flight validation fails; `{"ok": true}` on success.

### 3.20 `POST /restart`

Stops every encoder (so no ffmpeg child is orphaned), shuts down PTP, then re-execs after a short
delay. Returns `{"ok": true, "restarting": true}` immediately. On Windows it spawns a replacement
and exits, so the listen socket can be rebound.

---

## 4. Shared data types

Both products build on the same library crates, so these shapes are identical across them.

### 4.1 `PtpStatus`

| Field | Meaning |
|---|---|
| `running` | PTP is active. |
| `mode` | Configured preference: `auto` / `follower` / `grandmaster`. |
| `iface` | Bound interface. |
| `domain`, `priority1`, `priority2` | Current settings. |
| `role` | Live role from a **canonical vocabulary**: `leader`, `follower`, `electing`, `stopped`, `host-managed`. Raw `ptp4l` port states never leak through. |
| `gm_identity` | Active grandmaster's clock identity — ours when leading. |
| `clock_source` | Discipline source of the **system calendar**: `NTP` while running, `host` under host-managed PTP, else `stopped`. It never reads `PTP` — PTP does not discipline the wall clock. |
| `ntp_synced` | System calendar is NTP-synchronised. Independent of PTP. |
| `error` | Last PTP error. |
| `log` | Rolling `ptp4l` log lines. Present in the API; deliberately **excluded** from MQTT. |

`role: "host-managed"` means the appliance is in a container and the host owns the clock — PTP
settings are inert there.

### 4.2 `MeterSnapshot`

`channels`, `peak_db[]`, `rms_db[]` (per channel, dBFS, floored at −100), `lufs_m` (400 ms),
`lufs_s` (3 s), `lufs_i` (integrated, gated), `lra` (LU), `true_peak_dbtp` (max across channels).

### 4.3 `LicenseView`

| Field | Meaning |
|---|---|
| `licensed` | Entitled. |
| `status` | `licensed` / `unlicensed` / `invalid`. |
| `install_id` | This machine's binding id — quote it when requesting a licence. |
| `reason` | Why a present token failed, when `invalid`. |
| `company`, `order_number`, `tier` | From the token. |
| `products`, `features` | Entitlement arrays. |
| `expires_at` | Unix seconds, or `null` for perpetual. |
| `demo_stream_limit` / `demo_channel_limit` | The unlicensed cap (Gateway / Onramp). |
| `has_token` | A token is installed — true even when it is invalid. |

`status: "invalid"` with `has_token: true` is the case to surface loudly: a licence *is*
installed but isn't being honoured, and `reason` says why.

### 4.4 `CaptureSource` (Onramp)

Tagged by `kind`:

```json
{ "kind": "aes67", "group": "239.69.1.1", "port": 5004, "channels": 2,
  "payload_type": null, "jitter_ms": 40 }

{ "kind": "livewire", "channel": 1234, "jitter_ms": 40 }

{ "kind": "device", "name": "Line In (Audio Interface)" }

{ "kind": "default" }
{ "kind": "silence" }
```

`payload_type: null` (the default, and what the UI sends) auto-detects from the packets; a number
pins it for an unusual source. `jitter_ms` defaults to 40.

### 4.5 `DiscoveredSource`

`kind` (`aes67` / `livewire`), `name`, `group`, `port`, `channels`, `payload_type`,
`sample_rate`, `livewire_channel`, `node` (Livewire node name or SAP origin), `age_s` (seconds
since last announcement).

### 4.6 Event roles

Both products use the same 13: `eas`, `local_avail`, `program_cue`, `join_point`, `exit_point`,
`gpio1`, `gpio2`, `gpio3`, `gpio4`, `gpio5`, `gpio6`, `gpio7`, `gpio8`.

`note` is a separate annotation kind, not a closure role — it never appears in a closure list.

---

## 5. Worked examples

### Point a Gateway stream at a new source

Read, modify, write — remember `PUT` is a full replace.

```bash
curl -s http://gateway:8088/api/config | jq '.config.streams[0]'
```

```bash
curl -X PUT http://gateway:8088/api/streams/0 -H 'Content-Type: application/json' -d '{"name":"Network Feed","hls_url":"https://example.com/live/master.m3u8","source_type":"auto","enabled":true,"multicast_addr":"239.69.1.1","port":5004,"channels":2,"mqtt_topic":"network/np"}'
```

### Trim a Gateway output and confirm the clamp

```bash
curl -X POST http://gateway:8088/api/streams/0/gain -H 'Content-Type: application/json' -d '{"gain_db":-20}'
```

Returns `{"gain_db":-12}` — clamped to the ±12 dB limit.

### Push now-playing to an Onramp encoder

```bash
curl -X PUT http://onramp:8080/channels/default/now-playing -H 'Content-Type: application/json' -d '{"title":"Cinnamon Girl","artist":"Neil Young","duration":178}'
```

### Fire a 2-minute EAS closure, then clear it early

```bash
curl -X POST http://onramp:8080/channels/default/event -H 'Content-Type: application/json' -d '{"role":"eas","mode":"maintained","action":"activate","duration_s":120}'
```

```bash
curl -X POST http://onramp:8080/channels/default/event -H 'Content-Type: application/json' -d '{"role":"eas","mode":"maintained","state":false}'
```

The second call cancels the pending auto-deactivate as well as clearing the closure.

### Repoint an Onramp encoder to a discovered Livewire source

```bash
curl -s http://onramp:8080/discovery | jq '.[] | select(.kind=="livewire") | {name, livewire_channel}'
```

```bash
curl -X POST http://onramp:8080/channels/default/capture/source -H 'Content-Type: application/json' -d '{"kind":"livewire","channel":1234,"jitter_ms":40}'
```

The output stream stays up across the switch.

### Back up and restore

Gateway — note the restore takes the inner `config` object:

```bash
curl -s http://gateway:8088/api/config | jq '.config' > gateway-backup.json
```

```bash
curl -X PUT http://gateway:8088/api/config/import -H 'Content-Type: application/json' -d @gateway-backup.json
```

Onramp — the export is already the restore payload:

```bash
curl -s http://onramp:8080/config > onramp-backup.json
```

```bash
curl -X PUT http://onramp:8080/config/import --data-binary @onramp-backup.json
```

### Watch a Gateway's live meters

```bash
websocat ws://gateway:8088/ws | jq -c '.streams[] | {name, lufs_s: .aes67.lufs_s, peak: .aes67.true_peak_dbtp}'
```

---

## Stability notes

These are the interfaces the shipped web UIs use, and they change with the products. Two habits
make an integration durable:

- **Ignore unknown fields.** Both products add fields to response objects between releases.
- **Read before you replace.** For Gateway's stream endpoint especially, fetch the current
  object, modify it, and send it back — don't hand-build a body from these tables and assume the
  omitted fields are inert.

Check `GET /api/system` (Gateway) or `GET /system` (Onramp) for the running version when
reporting a problem.
