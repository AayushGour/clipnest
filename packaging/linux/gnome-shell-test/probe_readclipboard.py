#!/usr/bin/env python3
import os
import time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
bus.call_sync(
    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "RequestName", GLib.Variant("(su)", ("app.clipnest.Clipnest", 0)),
    GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 2000, None,
)
time.sleep(1.5)

r, fdlist = bus.call_with_unix_fd_list_sync(
    "app.clipnest.ShellHelper", "/app/clipnest/ShellHelper",
    "app.clipnest.ShellHelper1", "ReadClipboard",
    GLib.Variant("(us)", (1, "text/plain;charset=utf-8")), None,
    Gio.DBusCallFlags.NONE, 2000, None, None,
)
import select

handle = r.get_child_value(0).get_handle()
fd = fdlist.get(handle)
chunks = []
deadline = time.time() + 3
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            continue
        if not chunk:
            break
        chunks.append(chunk)
os.close(fd)
print("ReadClipboard fd contents:", repr(b"".join(chunks)))
