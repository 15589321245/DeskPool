import socket
import time
import unittest

from lan import BALLS, PROTOCOL, Guest, Snapshots, decode, encode


def state(sequence, value, sent_at, game_state="rolling"):
    return {
        "kind": "state", "sequence": sequence, "sentAt": sent_at, "turn": 1,
        "snapshot": {"positions": [[value, .5, 0] for _ in range(BALLS)],
                     "sunk": [], "state": game_state},
        "room": {"mode": "called", "phase": "playing", "targetBall": 8},
    }


class TestGuest(unittest.TestCase):
    def test_snapshot_interpolation_and_sequence(self):
        snapshots = Snapshots()
        snapshots.add(state(1, .2, 5), 10)
        snapshots.add(state(2, .6, 5.10), 10.10)
        snapshots.add(state(1, 9, 5), 10.11)
        latest, positions = snapshots.sample(10.13)
        self.assertEqual(latest["sequence"], 2)
        self.assertAlmostEqual(positions[0][0], .4)
        self.assertEqual(latest["room"]["targetBall"], 8)

    def test_protocol_over_tcp_and_udp(self):
        with socket.socket() as tcp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            tcp.bind(("127.0.0.1", 0))
            address = tcp.getsockname()
            udp.bind(address)
            tcp.listen()
            tcp.settimeout(4)
            udp.settimeout(4)
            guest = Guest(address[0], "client-id", "Windows PC", port=address[1])
            try:
                connection, _ = tcp.accept()
                with connection, connection.makefile("rb") as reader:
                    connection.settimeout(4)
                    hello = decode(reader.readline())
                    register = decode(reader.readline())
                    self.assertEqual(hello, {"kind": "hello", "identity": "client-id", "name": "Windows PC",
                                             "protocolVersion": PROTOCOL})
                    self.assertEqual(register["kind"], "udp-register")
                    packet, guest_udp = udp.recvfrom(65536)
                    self.assertEqual(decode(packet)["identity"], register["identity"])
                    connection.sendall(encode({"kind": "identity", "player": 1, "protocolVersion": PROTOCOL}) + b"\n")
                    self.assertEqual(guest.events.get(timeout=4), ("connecting", None))
                    self.assertEqual(guest.events.get(timeout=4), ("identity", 1))
                    stamp = time.monotonic()
                    udp.sendto(encode(state(2, .4, stamp)), guest_udp)
                    self.wait_for_state(guest, 2)
                    connection.sendall(encode(state(3, .5, stamp + .03, "ballInHand")) + b"\n")
                    self.assertEqual(self.wait_for_state(guest, 3)["snapshot"]["state"], "ballInHand")
                    guest.send("place", point=[.2, .3])
                    self.assertEqual(decode(reader.readline()), {"kind": "place", "point": [.2, .3]})
                    guest.send("shoot", direction=[1, 0], power=.6)
                    self.assertEqual(decode(reader.readline()), {"kind": "shoot", "direction": [1, 0], "power": .6})
            finally:
                guest.close()
                guest.thread.join(timeout=4)

    def wait_for_state(self, guest, expected):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            packet, _ = guest.snapshots.sample(time.monotonic())
            if packet and packet["sequence"] == expected:
                return packet
            time.sleep(.01)
        self.fail(f"Did not receive state {expected}")


if __name__ == "__main__":
    unittest.main()
