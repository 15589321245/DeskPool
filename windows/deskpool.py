"""Windows guest for DeskPool. The Mac host owns the physics and rules."""

import argparse
from functools import lru_cache
from ipaddress import IPv4Address
import locale
import math
import os
from pathlib import Path
import queue
import socket
import time
import tkinter as tk
from tkinter import ttk
import uuid

from icons import ShellIcons, desktop_files
from lan import Guest

ASPECT = 16 / 9
CHARGE_SECONDS = 0.9
MIN_CHARGE = 0.18
POCKET_WIN_SCORE = 4


def identity():
    directory = Path(os.environ.get("LOCALAPPDATA", Path.home() / ".deskpool")) / "DeskPool"
    path = directory / "player-id"
    try:
        if path.is_file():
            return str(uuid.UUID(path.read_text(encoding="ascii").strip()))
    except (OSError, ValueError):
        pass
    value = str(uuid.uuid4())
    try:
        directory.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="ascii")
    except OSError:
        pass
    return value


def first_contact(origin, direction, width, height, radius, obstacles):
    """Find the first rail or circular obstacle along the aiming ray."""
    x, y = origin
    dx, dy = direction
    edges = [(x, dx, width), (y, dy, height)]
    distance = min(
        ((limit - radius if speed > 0 else radius) - coord) / speed
        if abs(speed) > 1e-9 else math.inf
        for coord, speed, limit in edges
    )
    for cx, cy, r in obstacles:
        ox, oy = cx - x, cy - y
        ahead = ox * dx + oy * dy
        clearance = r * r - (ox * dy - oy * dx) ** 2
        if ahead > 0 and clearance > 0:
            distance = min(distance, max(0, ahead - math.sqrt(clearance)))
    return max(0, distance)


class App:
    def __init__(self, root, address, language, demo):
        self.root = root
        self.language = language
        self.files = [] if demo else desktop_files()
        self.shell = ShellIcons() if self.files else None
        self.guest = None
        self.player = None
        self.packet = None
        self.positions = []
        self.held = None
        self.aim = None
        self.aim_sent = 0
        self.wait_for_shot_until = 0
        self.last_turn = None
        self.last_draw = None
        self.device = socket.gethostname()
        self.identifier = identity()
        root.title("DeskPool")
        if os.name == "nt":
            script_dir = Path(__file__).resolve().parent
            for directory in (script_dir, script_dir.parent):
                icon = directory / "assets" / "deskpool.png"
                if icon.is_file():
                    root.iconphoto(True, tk.PhotoImage(master=root, file=str(icon)).subsample(16))
                    break
        root.geometry("1040x680")
        root.minsize(660, 420)
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.bind("<Escape>", lambda _: self.close())
        root.bind("<F11>", lambda _: root.attributes("-fullscreen", not root.attributes("-fullscreen")))
        root.bind("<g>", self.toggle_guide)
        self.guide = True

        bar = ttk.Frame(root, padding=10)
        bar.pack(fill="x")
        ttk.Label(bar, text=self.tr("Mac 房主 IP", "Mac host IP")).pack(side="left")
        self.address = tk.StringVar(value=address or "")
        entry = ttk.Entry(bar, width=17, textvariable=self.address)
        entry.pack(side="left", padx=8)
        entry.bind("<Return>", lambda _: self.join())
        ttk.Button(bar, text=self.tr("加入", "Join"), command=self.join).pack(side="left")
        self.status = tk.StringVar(value=self.tr("输入 Mac 房主的局域网 IP", "Enter the Mac host's LAN IP"))
        ttk.Label(bar, textvariable=self.status).pack(side="left", padx=12)

        self.canvas = tk.Canvas(root, background="#111b20", highlightthickness=0, cursor="crosshair")
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<Motion>", self.move)
        self.canvas.bind("<ButtonPress-1>", self.press)
        self.canvas.bind("<ButtonRelease-1>", self.release)
        self.canvas.bind("<Configure>", lambda _: self.draw())
        self.info = tk.StringVar(value=self.tr(
            "移动鼠标瞄准 · 按住左键蓄力 · 松开击球 · G 辅助线 · F11 全屏",
            "Move to aim · Hold left mouse to charge · Release to shoot · G Guide · F11 Full screen",
        ))
        ttk.Label(root, padding=(10, 7), textvariable=self.info).pack(anchor="w")
        if address:
            self.join()
        else:
            entry.focus_set()
        root.after(16, self.tick)

    def tr(self, zh, en):
        return zh if self.language == "zh" else en

    def close(self):
        if self.guest:
            self.guest.close()
        self.root.destroy()

    def toggle_guide(self, _):
        self.guide = not self.guide

    def join(self):
        try:
            ip = str(IPv4Address(self.address.get().strip()))
        except ValueError:
            self.status.set(self.tr("请输入 IPv4 地址，例如 192.168.0.75", "Enter an IPv4 address, e.g. 192.168.0.75"))
            return
        if self.guest:
            self.guest.close()
        self.reset()
        self.guest = Guest(ip, self.identifier, self.device)

    def reset(self):
        self.player = self.packet = self.held = self.aim = self.last_turn = None
        self.wait_for_shot_until = 0
        self.positions = []

    def tick(self):
        if self.guest:
            self.read_events()
            packet, positions = self.guest.snapshots.sample(time.monotonic())
            if self.player is not None and packet:
                self.packet, self.positions = packet, positions
                self.update_room()
        self.draw()
        self.root.after(16, self.tick)

    def read_events(self):
        while True:
            try:
                event, details = self.guest.events.get_nowait()
            except queue.Empty:
                return
            if event == "identity":
                self.player = details
                self.status.set(self.tr("已加入，正在同步", "Joined, syncing"))
            else:
                self.reset()
                message = {
                    "connecting": self.tr("正在连接房主…", "Connecting to host…"),
                    "disconnected": self.tr("连接中断，正在重试", "Disconnected, retrying"),
                    "rejected": details or self.tr("房主拒绝加入", "Host refused the connection"),
                }
                self.status.set(message[event])

    @property
    def snapshot(self):
        return self.packet["snapshot"] if self.packet else {}

    @property
    def room(self):
        return (self.packet.get("room") or {}) if self.packet else {}

    @property
    def my_turn(self):
        return self.player is not None and self.packet and self.room.get("phase") == "playing" and (
            not self.room.get("paused") and self.packet.get("turn") == self.player
        )

    def player_name(self, player):
        return self.packet.get("names", {}).get(str(player), self.tr("玩家", "Player") + f" {player}")

    def update_room(self):
        phase = self.room.get("phase")
        state = self.snapshot.get("state")
        if state in ("stroke", "rolling", "returnWhite"):
            self.wait_for_shot_until = 0
        if not self.my_turn or state != "ready":
            self.held = None
        if not self.my_turn:
            self.aim = None
        if phase == "lobby":
            self.last_turn = None
            message = self.tr("已加入，等待 Mac 房主开始", "Joined. Waiting for the Mac host to start")
        elif phase == "finished":
            winner = self.room.get("winner")
            message = (self.tr("本局结束", "Round finished") if winner is None else
                       self.tr(f"{self.player_name(winner)} 获胜", f"{self.player_name(winner)} wins"))
        elif self.room.get("paused"):
            message = self.tr("暂停，等待玩家重连", "Paused. Waiting for players to reconnect")
        elif self.my_turn:
            serial = self.room.get("turnSerial")
            if serial != self.last_turn:
                self.last_turn = serial
                self.wait_for_shot_until = 0
                self.root.bell()
            message = self.tr("轮到你击球", "Your turn")
            if state == "ballInHand":
                message = self.tr("自由球：点击空处摆白球", "Ball in hand: click an open spot")
        else:
            name = self.player_name(self.packet.get("turn"))
            message = self.tr(f"轮到 {name}", f"{name}'s turn")
        clock = self.packet.get("remaining")
        if clock is not None:
            message += f"  ·  {clock}s"
        if message != self.status.get():
            self.status.set(message)

    def bounds(self):
        cw, ch = self.canvas.winfo_width(), self.canvas.winfo_height()
        width = min(max(1, cw - 76), max(1, ch - 104) * ASPECT)
        height = width / ASPECT
        return (cw - width) / 2, (ch - height) / 2 + 14, width, height

    def normalized(self, event):
        x, y, width, height = self.bounds()
        return (event.x - x) / width, (event.y - y) / height

    def move(self, event):
        if not self.my_turn or self.snapshot.get("state") != "ready" or not self.positions:
            return
        tx, ty = self.normalized(event)
        x, y, _ = self.positions[0]
        _, _, width, height = self.bounds()
        dx, dy = (tx - x) * width, (ty - y) * height
        length = math.hypot(dx, dy)
        if length < 2:
            return
        self.aim = (dx / length, dy / length)
        now = time.monotonic()
        if now - self.aim_sent >= 0.05:
            self.aim_sent = now
            self.guest.send("aim", direction=self.aim)

    def press(self, event):
        self.canvas.focus_set()
        tx, ty = self.normalized(event)
        if not self.my_turn or not (0 <= tx <= 1 and 0 <= ty <= 1):
            return
        state = self.snapshot.get("state")
        if state == "ballInHand":
            self.guest.send("place", point=[tx, ty])
        elif state == "ready" and time.monotonic() >= self.wait_for_shot_until:
            self.move(event)
            self.held = time.monotonic()

    def release(self, event):
        held, self.held = self.held, None
        if held is None or not self.my_turn or self.snapshot.get("state") != "ready":
            return
        tx, ty = self.normalized(event)
        if not (0 <= tx <= 1 and 0 <= ty <= 1):
            return
        self.move(event)
        now = time.monotonic()
        power = min(1, max(MIN_CHARGE, (now - held) / CHARGE_SECONDS))
        self.guest.send("shoot", direction=self.aim or self.snapshot.get("aim", [1, 0]), power=power)
        self.wait_for_shot_until = now + 0.6

    @lru_cache(maxsize=126)
    def photo(self, index, size):
        if self.shell:
            data = self.shell.image(self.files[(index - 1) % len(self.files)], size)
            if data:
                return tk.PhotoImage(master=self.root, data=data, format="png")
        return None

    def draw(self):
        x, y, width, height = self.bounds()
        charge = min(1, (time.monotonic() - self.held) / CHARGE_SECONDS) if self.held is not None else 0
        scores = self.packet.get("scores", {}) if self.packet else {}
        names = self.packet.get("names", {}) if self.packet else {}
        snapshot = self.snapshot
        playing = self.room.get("phase") == "playing"
        target = self.room.get("targetBall") if playing else None
        owners = self.room.get("owners", []) if playing else []
        mode = self.room.get("mode")
        lit_pockets = (self.room.get("litPockets") or {}).get(str(self.player), [])
        key = (x, y, width, height, self.positions, snapshot.get("sunk"), snapshot.get("state"),
               snapshot.get("visualScale"), snapshot.get("cueScale"), snapshot.get("pocketScale"),
               self.aim or snapshot.get("aim"), self.guide, charge, target, owners, self.player,
               mode, playing, lit_pockets, scores, names)
        if key == self.last_draw:
            return
        self.last_draw = key
        c = self.canvas
        c.delete("all")
        self.visible_images = []  # Keep references even if a resize evicts a cached image.
        c.create_rectangle(x, y, x + width, y + height, fill="#1c3735", outline="#70918a", width=2)
        modes = {"called": self.tr("点名球 · 5 分获胜", "Called Ball · First to 5"),
                 "free": self.tr("自由计分", "Free Scoring"),
                 "assigned": self.tr("分球竞速", "Assigned Balls"),
                 "sixPockets": self.tr("六袋挑战", "Six Pockets")}
        title = modes.get(mode, "DESKPOOL  /  LAN")
        if mode == "sixPockets" and self.player is not None:
            progress = f"{len(lit_pockets)}/{POCKET_WIN_SCORE}"
            title += self.tr(f" · 我的袋口 {progress}", f" · {progress} pockets lit")
        c.create_text(x + 34, y - 25, text=title, anchor="w",
                      fill="#c9e8e1", font=("TkDefaultFont", 12, "bold"))
        if not self.packet:
            c.create_text(x + width / 2, y + height / 2, text=self.tr("等待连接", "Waiting for connection"),
                          fill="#9ab7b5", font=("TkDefaultFont", 16))
            return
        pocket = height * (snapshot.get("pocketScale") or 0.047)
        pockets = [(u * width, v * height) for v in (0, 1) for u in (0, 0.5, 1)]
        for index, (px, py) in enumerate(pockets):
            outline = "#7da29d"
            dash = ()
            if mode == "sixPockets" and playing and self.player is not None:
                if index in lit_pockets:
                    outline = "#79c9a5"
                else:
                    outline = "#ceb47d"
                    dash = (4, 4)
            c.create_oval(x + px - pocket, y + py - pocket, x + px + pocket, y + py + pocket,
                          fill="#101e23", outline=outline, dash=dash, width=2)
        sunk = set(snapshot["sunk"])
        tile = (snapshot.get("visualScale") or [0.041])[0] * width
        cue = (snapshot.get("cueScale") or [0.031])[0] * width
        cue_x, cue_y = self.positions[0][0] * width, self.positions[0][1] * height
        pieces = [(u * width, v * height) for u, v, _ in self.positions]
        if self.guide and 0 not in sunk and snapshot["state"] == "ready":
            direction = self.aim or snapshot.get("aim", [1, 0])
            dx, dy = direction
            r = cue / 2
            obstacles = [(bx, by, r + tile * 0.45) for index, (bx, by) in enumerate(pieces)
                         if index and index not in sunk]
            obstacles.extend((px, py, pocket + r * 0.55) for px, py in pockets)
            distance = first_contact((cue_x, cue_y), direction, width, height, r, obstacles)
            if distance > r + 3:
                c.create_line(x + cue_x + dx * (r + 3), y + cue_y + dy * (r + 3),
                              x + cue_x + dx * distance, y + cue_y + dy * distance,
                              fill="#c9e5e0", dash=(5, 5))
        for index, (px, py) in enumerate(pieces):
            if index in sunk:
                continue
            size = max(10, round(tile if index else cue))
            bx, by, r = x + px, y + py, size / 2
            owned = 0 < index <= len(owners) and owners[index - 1] == self.player
            if owned or index == target:
                accent = "#f9cc72" if index == target else "#8af2b3"
                c.create_rectangle(bx - r, by - r, bx + r, by + r, outline=accent, width=2)
                label = self.tr("目标", "TARGET") if index == target else self.tr("我", "ME")
                c.create_text(bx + r + 3, by - r - 3, text=label, fill=accent, anchor="e",
                              font=("TkDefaultFont", 9, "bold"))
            photo = self.photo(index, size) if index else None
            if photo:
                self.visible_images.append(photo)
                c.create_image(bx, by, image=photo)
            else:
                c.create_oval(bx - r * .82, by - r * .82, bx + r * .82, by + r * .82,
                              fill="#e5f3ef" if not index else ("#547e92", "#597879", "#7e648b")[index % 3],
                              outline="#c5dad3", width=1)
                if index:
                    c.create_text(bx, by, text=str(index), fill="white")
        if charge > 0:
            c.create_rectangle(x, y + height + 14, x + width, y + height + 19, fill="#415f62", outline="")
            c.create_rectangle(x, y + height + 14, x + width * charge, y + height + 19,
                               fill="#8af2b3", outline="")
        else:
            leaders = sorted(scores, key=lambda player: (-scores[player], int(player)))[:5]
            ranking = "    ".join(f"{self.player_name(player)}  {scores[player]}" for player in leaders)
            c.create_text(x + 34, y + height + 24, text=ranking, fill="#b4d2cd", anchor="w",
                          width=width - 34)


def main():
    detected = locale.getlocale()[0] or ""
    parser = argparse.ArgumentParser(description="DeskPool: join a Mac-hosted LAN game.")
    parser.add_argument("--join", metavar="IP")
    parser.add_argument("--lang", choices=["zh", "en"], default="zh" if detected.startswith("zh") else "en")
    parser.add_argument("--demo", action="store_true", help="use numbered balls instead of desktop icons")
    args = parser.parse_args()
    root = tk.Tk()
    App(root, args.join, args.lang, args.demo)
    root.mainloop()


if __name__ == "__main__":
    main()
