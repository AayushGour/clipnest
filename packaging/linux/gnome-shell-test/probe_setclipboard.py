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

read_fd, write_fd = os.pipe()
payload = b"set-via-devops-probe"


def writer():
    os.write(write_fd, payload)
    os.close(write_fd)


import threading
threading.Thread(target=writer, daemon=True).start()

fdlist = Gio.UnixFDList.new()
idx = fdlist.append(read_fd)
os.close(read_fd)

r, out_fdlist = bus.call_with_unix_fd_list_sync(
    "app.clipnest.ShellHelper", "/app/clipnest/ShellHelper",
    "app.clipnest.ShellHelper1", "SetClipboard",
    GLib.Variant("(sh)", ("text/plain;charset=utf-8", idx)), None,
    Gio.DBusCallFlags.NONE, 2000, fdlist, None,
)
print("SetClipboard -> OK:", r.print_(True))
