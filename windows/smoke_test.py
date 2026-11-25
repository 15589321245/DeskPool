"""Exercise the canvas and actual Windows Shell icon conversion on the build runner."""

import os
from pathlib import Path
import tkinter as tk

from deskpool import App
from icons import ShellIcons
from lan import BALLS

root = tk.Tk()
try:
    app = App(root, None, "zh", demo=True)
    root.update()
    app.player = 1
    app.packet = {
        "turn": 1,
        "room": {"mode": "called", "phase": "playing", "targetBall": 2, "turnSerial": 1},
        "snapshot": {"state": "ready", "sunk": [], "aim": [1, 0]},
        "names": {"0": "Mac host", "1": "Windows guest"},
        "scores": {"0": 0, "1": 2},
    }
    app.positions = [[.15 + .03 * i, .5 + (i % 3) * .08, 0] for i in range(BALLS)]
    app.draw()
    assert "目标" in [app.canvas.itemcget(item, "text") for item in app.canvas.find_all()
                   if app.canvas.type(item) == "text"]
    app.packet["room"] = {"mode": "sixPockets", "phase": "playing", "litPockets": {"0": [0], "1": [2, 4]}}
    app.draw()
    assert "六袋挑战 · 我的袋口 2/4" in [
        app.canvas.itemcget(item, "text") for item in app.canvas.find_all() if app.canvas.type(item) == "text"
    ]
    pockets = [item for item in app.canvas.find_all() if app.canvas.type(item) == "oval"][:6]
    assert [index for index, item in enumerate(pockets) if not app.canvas.itemcget(item, "dash")] == [2, 4]
    app.packet["room"] = {"mode": "sixPockets", "phase": "playing", "litPockets": {"1": [2, 3, 4]}}
    app.draw()
    assert "六袋挑战 · 我的袋口 3/4" in [
        app.canvas.itemcget(item, "text") for item in app.canvas.find_all() if app.canvas.type(item) == "text"
    ]
    if os.name == "nt":
        system_exe = Path(os.environ["WINDIR"]) / "explorer.exe"
        data = ShellIcons().image(system_exe, 48)
        assert data, "Windows Shell icon extraction failed"
        icon = tk.PhotoImage(master=root, data=data, format="png")
        assert icon.width() == icon.height() == 48
        assert any(not icon.transparency_get(x, y) for x in range(48) for y in range(48)), "Empty icon"
finally:
    root.destroy()
