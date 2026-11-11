# tuyable

App-free, cloud-free control of a Tuya bulb (Glamax TW+RGB). The bulb is reachable two
ways: over the home WiFi (Tuya LAN protocol 3.5, needs only `local_key`) and over
Bluetooth (service `0xFD50`, protocol 4.8, needs `local_key` + `sec_key`). Three clients
share the same credentials:

- **Tuyable.app**: a macOS menu-bar app (Swift, CoreBluetooth). It handles power, white
  temperature, colour wheel, brightness and presets.
- **Phone web app**: an installable web app served by the Pi (`server.py` + `web/`), so anyone on
  the home WiFi can control the lamp. It controls the bulb over WiFi.
- **`bulb.py`**: a Bluetooth CLI for scripts and cron.

See [HANDOVER.md](HANDOVER.md) for how the protocol was reverse-engineered.

## Mac app

```sh
./build.sh install        # build, copy to ~/Applications, launch
./build.sh                # build only -> build/Tuyable.app
build/Tuyable.app/Contents/MacOS/Tuyable --selftest   # offline protocol checks
build/Tuyable.app/Contents/MacOS/Tuyable --status     # live: connect, print state
```

- **Space** toggles power, **⌘Q** quits.
- Opening the panel connects. The link stays up while the panel is open and drops 30s
  after it closes, so the Pi bridge and phone can reach the bulb again (BLE allows
  one central at a time).
- Slider drags are latest-wins: at most one write is in flight, so the bulb follows
  your finger without building a backlog.
- It builds with Command Line Tools only (no Xcode), against `MacOSX26.sdk`, because the
  macOS 27 SDK turned SwiftUI's `@State` into a macro whose plugin ships only with
  Xcode.

## Phone web app (on the Pi)

Open **http://192.168.1.20:8080** on any phone on the home WiFi, then use the browser menu's
**Add to Home screen**. It has power, white/colour modes, brightness and temperature
sliders, presets, colour swatches and a custom colour picker.

```sh
# deploy / update from this repo
rsync -a server.py lamp tuyable.service web hermes:tuyable/
ssh hermes 'cp ~/tuyable/tuyable.service ~/.config/systemd/user/ && systemctl --user daemon-reload \
            && systemctl --user enable --now tuyable && systemctl --user restart tuyable'
ssh hermes 'tail -f ~/tuyable/server.log'   # lamp found at <ip>, errors
uv run server.py selftest                    # request validation checks
```

- The server talks to the bulb over the LAN with `tinytuya` and is the single source of truth
  for the lamp's state. One thread owns one session to the bulb: it sends every write and
  listens to everything the bulb reports, including changes made in Smart Life. Web pages
  and the `lamp` command read the server's copy; pages get changes pushed (`/api/events`).
- Writes from several clients are merged, latest value wins, and paced to the bulb's speed.
  A written value stands until the bulb confirms it.
- It finds the bulb by device id from its broadcasts, so a new IP from the router is fine,
  and it reconnects by itself (every 15 s while the bulb is unreachable).
- The Connection panel shows the bulb's address, response time and last error; **Find lamp
  again** repeats the lookup.
- The bulb must be on the home WiFi. If it drops off, the Bluetooth clients still work.
- The API is open to anyone on the LAN, by design: anyone in the house can use it.
- Over plain `http://`, Android adds a home-screen shortcut rather than a full standalone
  app. A true PWA install, with no browser bar and offline shell, needs HTTPS.

### Shell command on the Pi

`~/tuyable/lamp` drives the same server from a shell, for scripts, cron and the Hermes
agent. It prints the resulting state on one line and exits 1 with the reason on failure.

```sh
~/tuyable/lamp status
~/tuyable/lamp on | off | toggle
~/tuyable/lamp white 60 20      # brightness %, temp % (0=warm 100=cool)
~/tuyable/lamp color ff8800 80  # hex RGB, brightness %
~/tuyable/lamp bright 30        # keeps the current mode and colour
```

## Bluetooth CLI


```sh
uv run bulb.py on
uv run bulb.py off
uv run bulb.py white 60 20     # brightness %, temp % (0=warm 100=cool)
uv run bulb.py color ff8800 80 # hex RGB, brightness %
uv run bulb.py status
```

Credentials live in `~/.config/tuyable/devices.json` (chmod 600, **never** in this
repo). Each device entry needs `local_key` + `sec_key` (16 chars each), `uuid`, `id`.

## Protocol (what bulb.py implements)

- GATT: write `…0001-…07d0`, notify `…0002-…07d0`. 20-byte fragments, varint-indexed.
- App frame: `serial:u32 ack:u32 opcode:u16 len:u16 payload crc16/modbus`, AES-CBC,
  `mode:u8 + iv:16 + ciphertext`.
- Handshake: device-info (opcode 0) under **mode 14** = `md5(localKey+secKey)`.
  Reply carries a 6-byte nonce at `payload[6:12]`.
- Session: **mode 15** = `md5(localKey+secKey+nonce)` for all DP writes/reports.
  This firmware needs **no PAIR** (opcode 1 drops the link).
- DP writes: opcode `0x27`, payload `00 seq:u32 {id:u8 type:u8 len:u16 data}…`.
  DPs: 20 power(bool) 21 mode(enum 0=white 1=color) 22 bright(10..1000)
  23 temp(0..1000) 24 colour(HSV ascii-hex).

`uv run bulb.py selftest` checks CRC, framing round-trip, colour + report parsing.

## Key recovery (when the local_key rotates, i.e. after any re-pair)

`local_key` + `sec_key` only exist on the Tuya cloud / in the Smart Life app.
This firmware pairs with ECDH, so the keys are **not** sniffable from BLE.

**Cloud fetch (gets local_key + uuid, NOT sec_key):**
```sh
uv run fetch_keys.py <smartlife-user-code>   # scan QR in Smart Life
```

**sec_key** requires reading it out of the Smart Life app on a **rooted** phone
(see `recovery/`): run frida-server as root, open the device-list MMKV store, read
the device bean. The keys sit in `s_home_data_devlist…` →
`{localKey, secKey, uuid}`. Steps:
1. `adb push frida-server /data/local/tmp/ && su -c /data/local/tmp/frida-server -D`
2. `frida -U -p $(pidof com.tuya.smartlife) -l recovery/dump2.js` — but point it at
   store `preferences_global_key<uid>` key `s_home_data_devlist<uid>` and read the
   bean's `localKey`/`secKey` fields. (`recovery/hook.js` dumps MMKV reads live.)
3. Write both into `~/.config/tuyable/devices.json`.

`recovery/snoop.py` decodes an Android btsnoop HCI log — only useful on older
non-ECDH firmware that pairs with `md5(zeros+nonce)`; kept for reference.
