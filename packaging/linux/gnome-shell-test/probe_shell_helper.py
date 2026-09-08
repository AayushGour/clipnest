#!/usr/bin/env python3
# Ad-hoc trusted-sender probe of app.clipnest.ShellHelper1, for devops
# investigation only -- claims app.clipnest.Clipnest itself (the extension's
# _checkSender only allows the current owner of that name to call it) so we
# can call the real methods and see real replies, independent of whether the
# actual clipnest binary is running.
import sys
import time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

# Plain synchronous RequestName -- no main loop needed, unlike
# Gio.bus_own_name_on_connection's async callback API.
reply = bus.call_sync(
    "org.freedesktop.DBus",
    "/org/freedesktop/DBus",
    "org.freedesktop.DBus",
    "RequestName",
    GLib.Variant("(su)", ("app.clipnest.Clipnest", 0)),
    GLib.VariantType("(u)"),
    Gio.DBusCallFlags.NONE,
    2000,
    None,
)
print("RequestName(app.clipnest.Clipnest) ->", reply.print_(True), "(1 = DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER)")

# Give the bus daemon + the extension's Gio.bus_watch_name callback plenty
# of time to observe the new ownership -- deliberately generous, to test
# whether the race clipnest hits (near-zero delay between RequestName and
# the live probe) is the actual cause of the gsettingsFloor fallback we
# observed from the real app.
delay = float(sys.argv[1]) if len(sys.argv) > 1 else 1.5
print(f"sleeping {delay}s before probing, to rule out the ownership-propagation race...")
time.sleep(delay)


def call(method, args_variant, arg_types_hint=""):
    try:
        reply = bus.call_sync(
            "app.clipnest.ShellHelper",
            "/app/clipnest/ShellHelper",
            "app.clipnest.ShellHelper1",
            method,
            args_variant,
            None,
            Gio.DBusCallFlags.NONE,
            2000,
            None,
        )
        print(f"{method}{arg_types_hint} -> OK: {reply.print_(True)}")
    except GLib.Error as e:
        print(f"{method}{arg_types_hint} -> ERROR: {e.message}")


call("GetPointer", None)
call("GetFocusedApp", None)
call("GetMonitorWorkArea", GLib.Variant("(i)", (0,)))
call("PlaceWindow", GLib.Variant("(siiu)", ("bogus-token-devops-probe", 10, 20, 1)), " (bogus token)")
call("UnplaceWindow", GLib.Variant("(s)", ("bogus-token-devops-probe",)))
