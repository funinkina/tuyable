# /// script
# dependencies = ["aiohttp", "tinytuya"]
# ///
"""Phone web app (PWA) + JSON API for the bulb, controlled over the home WiFi (Tuya LAN protocol).

usage: uv run server.py [PORT]        (default 8080)

GET  /api/state[?fresh=1]   current state; fresh=1 first waits for a connection attempt if the lamp is down
GET  /api/events            server-sent events: the state, pushed on every change
POST /api/set               {"on": bool} | {"mode": "white", "b": 0-100, "t": 0-100}
                            | {"mode": "color", "h": 0-359, "s": 0-100, "v": 0-100}
GET  /api/diag              connection stats
POST /api/scan              look the bulb up on the network again

This process is the single source of truth for the lamp's state. One thread owns one TCP session
to the bulb: it sends every write and reads everything the bulb says (its echo of each write, and
changes made elsewhere, e.g. Smart Life). Nothing ever polls the bulb or pairs a reply with a
request, so clients can't get in each other's way. Writes that arrive while the bulb is still
answering the previous one are merged, latest value wins, and sent as one. A written value stands
until the bulb confirms it, so the bulb's late echoes of older writes can't roll the state back. Web pages and the `lamp` CLI all read this
process's copy of the state; pages get it pushed over /api/events.

The bulb is found by device id from its LAN broadcasts, so a new IP from the router is fine.
"""

import asyncio
import json
import queue
import select
import socket
import sys
import threading
import time
from pathlib import Path

import tinytuya
from aiohttp import web

WEB = Path(__file__).parent / "web"
CONFIG = Path.home() / ".config/tuyable/devices.json"
HEARTBEAT = 10  # seconds of silence before pinging the bulb; 3 unanswered = session dead
PACE = 0.15  # seconds to wait for the bulb to answer one write before sending the next
SETTLE = 2  # seconds a written value outranks what the bulb reports, unless it reports that value
RETRY = 15  # seconds between reconnect attempts while the bulb is unreachable
UNREACHABLE = "Can't reach the lamp on WiFi. Is it switched on at the wall?"


class LampError(Exception):
    pass


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def pct(n, lo=0, hi=1000):
    return lo + round(max(0, min(100, int(n))) * (hi - lo) / 100)


class Lamp:
    """State + the worker thread that owns the bulb session. Only the worker touches self.dev."""

    def __init__(self):
        self.dev, self.ip, self.version = None, None, None
        self.dps, self.error, self.ok = {}, None, False
        self.jobs, self.unacked = queue.SimpleQueue(), None  # unacked: (dps, sent_at) until the bulb says anything
        self.outbox, self.waiters = {}, []  # merged writes not sent yet, and the requests waiting on them
        self.want = {}  # dp -> (written value, deadline): outranks the bulb's reports until confirmed
        self.wake_r, self.wake_w = socket.socketpair()
        self.loop, self.changed = None, None  # set in start(); changed: asyncio.Event, replaced on each change
        self.started = time.monotonic()
        self.diag = {"ms": None, "heard_at": None, "found_at": None, "session_at": None, "error_at": None,
                     "last_error": None, "writes": 0, "sessions": 0, "failures": 0}

    # ---- asyncio side ----

    def start(self):
        self.loop, self.changed = asyncio.get_running_loop(), asyncio.Event()
        threading.Thread(target=self._worker, daemon=True).start()

    async def ask(self, kind, dps=None):
        """Queue a job for the worker: "set" (write dps), "ping" (make sure there's a session),
        "scan" (look the bulb up again). Returns once done; raises LampError if the bulb is unreachable."""
        fut = self.loop.create_future()
        self.jobs.put((kind, dps, fut))
        self.wake_w.send(b"x")
        await fut

    def _notify(self):  # runs on the loop
        ev, self.changed = self.changed, asyncio.Event()
        ev.set()

    # ---- worker thread ----

    def _finish(self, fut, err=None):
        def done():
            if not fut.done():
                fut.set_exception(LampError(err)) if err else fut.set_result(None)
        self.loop.call_soon_threadsafe(done)

    def _merge(self, dps):
        if dps and any(self.dps.get(k) != v for k, v in dps.items()):
            self.dps.update(dps)
            self.loop.call_soon_threadsafe(self._notify)

    def _heard(self, dps, now):
        """Merge what the bulb reported, minus late echoes of values we have since overwritten."""
        keep = {}
        for k, v in (dps or {}).items():
            value, deadline = self.want.get(k, (v, 0))
            if v == value or now > deadline:
                self.want.pop(k, None)
                keep[k] = v
        self._merge(keep)

    def _open(self, ip):
        cred = self.cred
        d = tinytuya.Device(cred["id"], ip, cred["local_key"], version=self.version, persist=True,
                            connection_timeout=3, connection_retry_limit=1, connection_retry_delay=0)
        d.set_retry(False)  # return on an empty ack instead of waiting out the timeout for more
        r = d.status()  # nothing else is on the wire yet, so this one reply can be paired
        if r and "Error" in r:
            d.close()
            raise LampError(r["Error"])
        self.dev = d
        self._merge((r or {}).get("dps"))

    def _connect(self, rediscover):
        devs = json.loads(CONFIG.read_text())
        self.cred = ([d for d in devs if d["category"] == "dj"] or devs)[0]
        if self.ip and not rediscover:
            try:
                return self._open(self.ip)
            except LampError as e:
                log("remembered address failed, looking the lamp up again:", e)
        found = tinytuya.find_device(self.cred["id"])  # waits for the bulb's next broadcast, up to ~18s
        if not found["ip"]:
            raise LampError(UNREACHABLE)
        self.ip, self.version = found["ip"], float(found["version"])
        self.diag["found_at"] = time.monotonic()
        log(f"found lamp at {self.ip}, protocol {self.version}")
        try:
            self._open(self.ip)
        except LampError as e:
            raise LampError(f"{UNREACHABLE} ({e})")

    def _flush(self, now):
        """Send the merged writes as one, with mode and power last (the bulb wants data before mode)."""
        dps = {k: v for k, v in self.outbox.items() if k not in ("21", "20")}
        dps.update({k: self.outbox[k] for k in ("21", "20") if k in self.outbox})
        r = self.dev.set_multiple_values(dps, nowait=True)
        if r and "Error" in r:
            raise LampError(r["Error"])  # outbox and waiters stay for the next session
        self.unacked = (dps, now)
        self.want.update({k: (v, now + SETTLE) for k, v in dps.items()})
        self.diag["writes"] += 1
        self._merge(dps)
        for fut in self.waiters:
            self._finish(fut)
        self.outbox, self.waiters = {}, []

    def _serve(self):
        """Run one session until it dies (raises) or a rescan is asked for (returns)."""
        d, heard = self.dev, time.monotonic()
        if self.unacked and heard - self.unacked[1] < 5:
            # the last write went into a session that then died: repeat it
            self.outbox = {**self.unacked[0], **self.outbox}
        self.unacked = None
        while True:
            if not d.socket:
                raise LampError("session closed")
            # the queue is checked every pass: a job's wake-up byte may have been used up elsewhere
            while not self.jobs.empty():
                kind, dps, fut = self.jobs.get()
                if kind == "scan":
                    self.jobs.put(("ping", None, fut))  # answered by the reconnect
                    return
                if kind == "set":
                    self.outbox.update(dps)
                    self.waiters.append(fut)
                else:
                    self._finish(fut)
            now = time.monotonic()
            if self.outbox and not (self.unacked and now - self.unacked[1] < PACE):
                self._flush(now)
            wait = self.unacked[1] + PACE - now if self.outbox else HEARTBEAT
            ready = select.select([d.socket, self.wake_r], [], [], max(wait, 0))[0]
            now = time.monotonic()
            if self.wake_r in ready:
                self.wake_r.recv(4096)
            if d.socket in ready:
                if not d.socket.recv(1, socket.MSG_PEEK):
                    raise LampError("session closed by the lamp")
                r = d.receive()
                if r and "Error" in r:
                    raise LampError(r["Error"])
                heard = self.diag["heard_at"] = now
                if self.unacked:
                    self.diag["ms"] = round((now - self.unacked[1]) * 1000)
                    self.unacked = None
                self._heard((r or {}).get("dps"), now)
            if not ready and not self.outbox:
                if now - heard > 3 * HEARTBEAT:
                    raise LampError("no answer to heartbeats")
                d.heartbeat(nowait=True)

    def _worker(self):
        rediscover = False
        while True:
            try:
                self._connect(rediscover)
                self.ok, self.error, rediscover = True, None, False
                self.diag["sessions"] += 1
                self.diag["session_at"] = time.monotonic()
                self.loop.call_soon_threadsafe(self._notify)
                self._serve()
                rediscover, self.ok = True, False  # _serve returned: a rescan was asked for
                log("looking the lamp up again (asked)")
                self.loop.call_soon_threadsafe(self._notify)
            except Exception as e:
                was_ok, self.ok = self.ok, False
                if was_ok and time.monotonic() - self.diag["session_at"] > 2:
                    # an established session died: reconnect straight away, quietly
                    log("session lost, reconnecting:", e)
                    self.loop.call_soon_threadsafe(self._notify)
                    continue
                self.error = str(e) if isinstance(e, LampError) else f"{UNREACHABLE} ({e})"
                self.diag["failures"] += 1
                self.diag.update(error_at=time.monotonic(), last_error=self.error)
                log("error:", self.error)
                if select.select([self.wake_r], [], [], 0)[0]:
                    self.wake_r.recv(4096)  # wake-ups for the jobs failed below; don't let them cut the wait
                while not self.jobs.empty():
                    self.waiters.append(self.jobs.get()[2])
                for fut in self.waiters:
                    self._finish(fut, self.error)
                self.outbox, self.waiters, self.unacked = {}, [], None  # those writes were refused; don't repeat them later
                self.loop.call_soon_threadsafe(self._notify)
                if select.select([self.wake_r], [], [], RETRY)[0]:  # a job cuts the wait short
                    self.wake_r.recv(4096)
            finally:
                if self.dev:
                    self.dev.close()
                self.dev = None


lamp = Lamp()


def unit(n, lo):
    return max(0, min(100, round((n - lo) * 100 / (1000 - lo))))


def view():
    d = lamp.dps
    c = d.get("24", "")
    h, s, v = (
        (int(c[i : i + 4], 16) for i in (0, 4, 8)) if len(c) == 12 else (30, 1000, 1000)
    )
    return {
        "on": d.get("20", False),
        "color": d.get("21") == "colour",
        "white": unit(d.get("22", 1000), 10),
        "temp": unit(d.get("23", 500), 0),
        "h": h % 360,
        "s": round(min(s, 1000) / 10),
        "v": unit(v, 10),
        "known": bool(d),
        "connected": lamp.ok,
        "error": lamp.error,
    }


def command(q):
    """Validate a request body into DP writes. Raises on anything malformed. Order matters: data before mode."""
    if set(q) == {"on"}:
        return {"20": bool(q["on"])}
    if q["mode"] == "white":
        return {"22": pct(q["b"], 10), "23": pct(q["t"]), "21": "white", "20": True}
    if q["mode"] == "color":
        hsv = f"{int(q['h']) % 360:04x}{pct(q['s']):04x}{pct(q['v'], 10):04x}"
        return {"24": hsv, "21": "colour", "20": True}
    raise ValueError(q["mode"])


async def quiet(coro):
    try:
        await coro
    except LampError:
        pass  # already on lamp.error


async def get_state(req):
    if req.query.get("fresh") and not lamp.ok:
        await quiet(lamp.ask("ping"))
    return web.json_response(view())


async def get_events(req):
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
    await resp.prepare(req)
    try:
        while True:
            changed = lamp.changed  # taken before the write, so a change during it isn't missed
            await resp.write(f"data: {json.dumps(view())}\n\n".encode())
            try:
                await asyncio.wait_for(changed.wait(), 20)  # resend as a keepalive
            except TimeoutError:
                pass
    except ConnectionError:
        pass
    return resp


async def post_set(req):
    try:
        dps = command(await req.json())
    except Exception:
        raise web.HTTPBadRequest(text="bad command")
    try:
        await lamp.ask("set", dps)
    except LampError:
        return web.json_response(view(), status=503)
    return web.json_response(view())


def ago(t):
    return None if t is None else round(time.monotonic() - t)


async def get_diag(req):
    d = lamp.diag
    return web.json_response(
        {
            "connected": lamp.ok,
            "ip": lamp.ip,
            "version": lamp.version,
            "ms": d["ms"],
            "heard_age": ago(d["heard_at"]),
            "found_age": ago(d["found_at"]),
            "session_age": ago(d["session_at"]) if lamp.ok else None,
            "last_error": d["last_error"],
            "error_age": ago(d["error_at"]),
            "writes": d["writes"],
            "sessions": d["sessions"],
            "failures": d["failures"],
            "uptime": ago(lamp.started),
        }
    )


async def post_scan(req):
    """Look the bulb up on the network again."""
    await quiet(lamp.ask("scan"))
    return await get_diag(req)


async def lifecycle(app):
    lamp.start()
    yield


async def static(req):
    name = req.match_info.get("name") or "index.html"
    if name not in FILES:
        raise web.HTTPNotFound()
    if name == "index.html":
        log("page opened by", req.remote)
    return web.FileResponse(WEB / name, headers={"Cache-Control": "no-cache"})


FILES = {p.name for p in WEB.iterdir()}
app = web.Application()
app.add_routes(
    [
        web.get("/api/state", get_state),
        web.get("/api/events", get_events),
        web.post("/api/set", post_set),
        web.get("/api/diag", get_diag),
        web.post("/api/scan", post_scan),
        web.get("/", static),
        web.get("/{name}", static),
    ]
)
app.cleanup_ctx.append(lifecycle)


def selftest():
    assert command({"on": False}) == {"20": False}
    w = command({"mode": "white", "b": 150, "t": -5})
    assert w == {"22": 1000, "23": 0, "21": "white", "20": True} and list(w)[-2:] == ["21", "20"]
    assert command({"mode": "color", "h": 360, "s": 50, "v": 0}) == {"24": "000001f4000a", "21": "colour", "20": True}
    for bad in (
        {},
        {"mode": "disco"},
        {"mode": "white", "b": "x", "t": 1},
        [],
        {"on": 1, "mode": "white"},
    ):
        try:
            command(bad)
        except Exception:
            continue
        raise AssertionError(bad)
    lamp.dps.update({"20": True, "21": "colour", "22": 505, "23": 1000, "24": "00b401f403e8"})
    v = view()
    assert (v["on"], v["color"], v["white"], v["temp"], v["h"], v["s"], v["v"]) == (True, True, 50, 100, 180, 50, 100)
    lamp.loop = type("L", (), {"call_soon_threadsafe": lambda *a: None})
    lamp.want = {"22": (700, 10)}  # we wrote 700; it outranks the bulb until t=10
    lamp._heard({"22": 500, "23": 60}, 1)  # late echo of an older write: 22 ignored, 23 taken
    assert (lamp.dps["22"], lamp.dps["23"]) == (505, 60) and "22" in lamp.want
    lamp._heard({"22": 700}, 2)  # confirmed
    assert lamp.dps["22"] == 700 and not lamp.want
    lamp.want = {"22": (700, 10)}
    lamp._heard({"22": 300}, 11)  # never confirmed and settle time is over: the bulb is right
    assert lamp.dps["22"] == 300 and not lamp.want
    lamp.dps.clear()
    assert unit(10, 10) == 0 and unit(1000, 10) == 100
    assert ago(None) is None and ago(time.monotonic() - 5) == 5
    print("selftest ok")


if __name__ == "__main__" and sys.argv[1:] == ["selftest"]:
    selftest()
elif __name__ == "__main__":
    port = int(sys.argv[1]) if sys.argv[1:] else 8080
    log(f"serving on :{port}")
    web.run_app(app, port=port, access_log=None, print=None, shutdown_timeout=1)  # don't wait on open event streams
