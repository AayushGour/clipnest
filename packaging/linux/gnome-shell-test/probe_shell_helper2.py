#!/usr/bin/env python3
# Part 2: the remaining ShellHelper1 methods not covered by
# probe_shell_helper.py (clipboard read/write/watch + mime types +
# SendKeyChord/FocusAndSendKeyChord), for full 11/11 method coverage.
import sys
import time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
reply = bus.call_sync(
    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "RequestName", GLib.Variant("(su)", ("app.clipnest.Clipnest", 0)),
    GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 2000, None,
)
print("RequestName ->", reply.print_(True))
time.sleep(1.5)


def call(method, args_variant, hint=""):
    try:
        r = bus.call_sync(
            "app.clipnest.ShellHelper", "/app/clipnest/ShellHelper",
            "app.clipnest.ShellHelper1", method, args_variant, None,
            Gio.DBusCallFlags.NONE, 2000, None,
        )
        print(f"{method}{hint} -> OK: {r.print_(True)}")
    except GLib.Error as e:
        print(f"{method}{hint} -> ERROR: {e.message}")


call("SetClipboardWatch", GLib.Variant("(bb)", (True, False)))
call("GetClipboardMimeTypes", GLib.Variant("(u)", (1,)), " (selection=1/CLIPBOARD)")
call("SendKeyChord", GLib.Variant("(uu)", (0x76, 0)), " (keyval=Clutter 'v', no mods)")
call(
    "FocusAndSendKeyChord",
    GLib.Variant("(tuu)", (0, 0x76, 0)),
    " (window_serial=0, keyval=v)",
)

# ReadClipboard needs the fd-list call variant.
try:
    r, fdlist = bus.call_with_unix_fd_list_sync(
        "app.clipnest.ShellHelper", "/app/clipnest/ShellHelper",
        "app.clipnest.ShellHelper1", "ReadClipboard",
        GLib.Variant("(us)", (1, "text/plain;charset=utf-8")), None,
        Gio.DBusCallFlags.NONE, 2000, None, None,
    )
    print("ReadClipboard -> OK:", r.print_(True), "nfds=", fdlist.get_length() if fdlist else 0)
except GLib.Error as e:
    print("ReadClipboard -> ERROR:", e.message)
