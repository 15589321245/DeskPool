"""Read local Windows Desktop icon images through the Shell; never open the files."""

import ctypes as ct
from ctypes import wintypes as win
import os
from pathlib import Path
import struct
import zlib


class ShellInfo(ct.Structure):
    _fields_ = [("icon", win.HANDLE), ("index", ct.c_int), ("attributes", win.DWORD),
                ("name", win.WCHAR * 260), ("type_name", win.WCHAR * 80)]


class BitmapInfo(ct.Structure):
    _fields_ = [("size", win.DWORD), ("width", win.LONG), ("height", win.LONG),
                ("planes", win.WORD), ("bits", win.WORD), ("compression", win.DWORD),
                ("image_size", win.DWORD), ("x_ppm", win.LONG), ("y_ppm", win.LONG),
                ("colors", win.DWORD), ("important", win.DWORD)]


def desktop_files():
    if os.name != "nt":
        return []
    folder_path = ct.windll.shell32.SHGetFolderPathW
    folder_path.argtypes = [win.HWND, ct.c_int, win.HANDLE, win.DWORD, win.LPWSTR]
    folder_path.restype = win.LONG
    files = {}
    for folder_id in (0x10, 0x19):  # User Desktop and Public Desktop (including redirected folders).
        path = ct.create_unicode_buffer(260)
        if folder_path(None, folder_id, None, 0, path) != 0:
            continue
        try:
            for entry in Path(path.value).iterdir():
                if entry.name.lower() != "desktop.ini" and not entry.name.startswith("."):
                    files.setdefault(entry.name.casefold(), entry)
        except OSError:
            pass
    return [files[key] for key in sorted(files)[:21]]


def png(rgba, size):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + rgba[i:i + size * 4] for i in range(0, len(rgba), size * 4))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class ShellIcons:
    def __init__(self):
        gdi, user, shell = ct.windll.gdi32, ct.windll.user32, ct.windll.shell32
        handle = win.HANDLE
        self.get = self.bind(shell.SHGetFileInfoW, ct.c_size_t, win.LPCWSTR, win.DWORD,
                             ct.POINTER(ShellInfo), win.UINT, win.UINT)
        self.draw = self.bind(user.DrawIconEx, win.BOOL, handle, ct.c_int, ct.c_int, handle,
                              ct.c_int, ct.c_int, win.UINT, handle, win.UINT)
        self.destroy = self.bind(user.DestroyIcon, win.BOOL, handle)
        self.create_dc = self.bind(gdi.CreateCompatibleDC, handle, handle)
        self.delete_dc = self.bind(gdi.DeleteDC, win.BOOL, handle)
        self.select = self.bind(gdi.SelectObject, handle, handle, handle)
        self.delete = self.bind(gdi.DeleteObject, win.BOOL, handle)
        self.flush = self.bind(gdi.GdiFlush, win.BOOL)
        self.create_bitmap = self.bind(gdi.CreateDIBSection, handle, handle, ct.POINTER(BitmapInfo),
                                       win.UINT, ct.POINTER(ct.c_void_p), handle, win.DWORD)

    @staticmethod
    def bind(function, result, *args):
        function.argtypes = args
        function.restype = result
        return function

    def image(self, path, size):
        info = ShellInfo()
        if not self.get(str(path), 0, ct.byref(info), ct.sizeof(info), 0x100) or not info.icon:
            return None
        try:
            return self.raster(info.icon, size)
        finally:
            self.destroy(info.icon)

    def raster(self, icon, size):
        dc = self.create_dc(None)
        if not dc:
            return None
        bits = ct.c_void_p()
        header = BitmapInfo(ct.sizeof(BitmapInfo), size, -size, 1, 32)
        bitmap = self.create_bitmap(dc, ct.byref(header), 0, ct.byref(bits), None, 0)
        if not bitmap:
            self.delete_dc(dc)
            return None
        previous = self.select(dc, bitmap)
        try:
            count = size * size * 4
            ct.memset(bits, 0, count)
            if not self.draw(dc, 0, 0, icon, size, size, 0, None, 3):
                return None
            self.flush()
            dark = ct.string_at(bits, count)
            ct.memset(bits, 255, count)
            if not self.draw(dc, 0, 0, icon, size, size, 0, None, 3):
                return None
            self.flush()
            light = ct.string_at(bits, count)
            rgba = bytearray(count)
            for i in range(0, count, 4):
                alpha = 255 - max(0, *(light[i + j] - dark[i + j] for j in range(3)))
                if alpha:
                    rgba[i:i + 4] = bytes([
                        min(255, dark[i + 2] * 255 // alpha),
                        min(255, dark[i + 1] * 255 // alpha),
                        min(255, dark[i] * 255 // alpha), alpha,
                    ])
            return png(rgba, size)
        finally:
            self.select(dc, previous)
            self.delete(bitmap)
            self.delete_dc(dc)
