"""DeskPool protocol 5: reliable TCP commands, UDP snapshots with TCP fallback."""

import collections
import json
import queue
import select
import socket
import threading
import time
import uuid

PORT = 7777
PROTOCOL = 5
BALLS = 22  # Cue ball plus 21 icon balls.
PLAYBACK_DELAY = 0.080


def encode(packet):
    return json.dumps(packet, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def decode(data):
    try:
        packet = json.loads(data)
        return packet if isinstance(packet, dict) else {}
    except (ValueError, UnicodeError):
        return {}


class Snapshots:
    def __init__(self):
        self.frames = collections.deque(maxlen=10)
        self.lock = threading.Lock()
        self.sequence = 0

    def clear(self):
        with self.lock:
            self.frames.clear()
            self.sequence = 0

    def add(self, packet, arrived):
        sequence = packet.get("sequence")
        snapshot = packet.get("snapshot")
        if not isinstance(sequence, int) or not isinstance(snapshot, dict):
            return
        positions = snapshot.get("positions")
        if not isinstance(positions, list) or len(positions) != BALLS or any(
            not isinstance(pos, list) or len(pos) != 3 or
            any(not isinstance(value, (float, int)) or not -1e6 < value < 1e6 for value in pos)
            for pos in positions
        ):
            return
        sunk = snapshot.get("sunk")
        if not isinstance(sunk, list) or any(not isinstance(index, int) or not 0 <= index < BALLS for index in sunk):
            return
        if snapshot.get("state") not in ("ready", "stroke", "rolling", "returnWhite", "ballInHand", "finished"):
            return
        stamp = packet.get("sentAt", arrived)
        if not isinstance(stamp, (float, int)) or not 0 <= stamp < 1e12:
            return
        with self.lock:
            if sequence <= self.sequence:
                return
            if self.frames and not 0 < stamp - self.frames[-1][0] <= 0.6:
                self.frames.clear()
            self.sequence = sequence
            self.frames.append((stamp, arrived, packet))

    def sample(self, now):
        with self.lock:
            frames = list(self.frames)
        if not frames:
            return None, []
        latest = frames[-1][2]
        offset = min(arrived - stamp for stamp, arrived, _ in frames)
        play_at = now - offset - PLAYBACK_DELAY
        for (first, _, before), (second, _, after) in zip(frames, frames[1:]):
            if play_at <= second:
                t = max(0, (play_at - first) / (second - first))
                a, b = before["snapshot"], after["snapshot"]
                if a["sunk"] != b["sunk"] or a["state"] != b["state"]:
                    break
                return latest, [
                    [x + (y - x) * t for x, y in zip(left, right)]
                    for left, right in zip(a["positions"], b["positions"])
                ]
        return latest, latest["snapshot"]["positions"]


class Guest:
    def __init__(self, ip, identity, name, port=PORT):
        self.address = (ip, port)
        self.identity = identity
        self.name = name
        self.events = queue.SimpleQueue()
        self.commands = queue.Queue(maxsize=32)
        self.snapshots = Snapshots()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def send(self, kind, **data):
        try:
            self.commands.put_nowait({"kind": kind, **data})
        except queue.Full:
            pass

    def close(self):
        self.stop.set()

    def run(self):
        while not self.stop.is_set():
            self.events.put(("connecting", None))
            try:
                with socket.create_connection(self.address, timeout=3) as tcp:
                    tcp.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    tcp.settimeout(0.25)
                    if self.connected(tcp):
                        return
            except OSError as error:
                self.events.put(("disconnected", str(error)))
            finally:
                self.snapshots.clear()
                try:
                    while True:
                        self.commands.get_nowait()
                except queue.Empty:
                    pass
            self.stop.wait(1.5)

    def connected(self, tcp):
        token = uuid.uuid4().hex
        hello = {"kind": "hello", "identity": self.identity, "name": self.name,
                 "protocolVersion": PROTOCOL}
        register = {"kind": "udp-register", "identity": token}
        tcp.sendall(encode(hello) + b"\n" + encode(register) + b"\n")
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.connect(self.address)
            udp.setblocking(False)
            return self.exchange(tcp, udp, register)

    def exchange(self, tcp, udp, register):
        pending = bytearray()
        last_udp = 0
        heartbeat = 0.0
        while not self.stop.is_set():
            while True:
                try:
                    command = self.commands.get_nowait()
                except queue.Empty:
                    break
                tcp.sendall(encode(command) + b"\n")
            now = time.monotonic()
            if now >= heartbeat:
                try:
                    udp.send(encode({**register, "sequence": last_udp}))
                except OSError:
                    pass  # TCP carries the full stream when UDP is unavailable.
                heartbeat = now + 1
            ready, _, _ = select.select([tcp, udp], [], [], 0.016)
            for channel in ready:
                if channel is udp:
                    try:
                        packet = decode(udp.recv(65536))
                    except OSError:
                        continue
                    if packet.get("kind") == "state":
                        sequence = packet.get("sequence")
                        if isinstance(sequence, int):
                            last_udp = max(last_udp, sequence)
                        self.snapshots.add(packet, time.monotonic())
                    continue
                data = tcp.recv(65536)
                if not data:
                    raise ConnectionError("Host disconnected")
                pending.extend(data)
                while b"\n" in pending:
                    end = pending.index(10)
                    packet = decode(pending[:end])
                    del pending[:end + 1]
                    kind = packet.get("kind")
                    if kind == "state":
                        self.snapshots.add(packet, time.monotonic())
                    elif kind == "identity":
                        if packet.get("protocolVersion") != PROTOCOL:
                            self.events.put(("rejected", "Incompatible host version"))
                            return True
                        if isinstance(packet.get("player"), int):
                            self.events.put(("identity", packet["player"]))
                    elif kind == "rejected":
                        self.events.put(("rejected", packet.get("name")))
                        return True
                if len(pending) > 262144:
                    raise ConnectionError("Invalid frame")
        return True
