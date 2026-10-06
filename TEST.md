# Testing Clipnest 1.0.0 on Linux

> **Status (1.0.0): the freeze this plan was written to chase is root-caused
> and fixed.** It reproduced on the reporter's own Ubuntu 24.04 machine
> whenever auto-paste wasn't set up. A gdb backtrace showed the GTK thread
> waiting on a clipboard read that only that same thread could answer:
> Clipnest's own write had not been recognised as its own, so it asked
> itself for the bytes. 1.0.0 marks its writes (`application/x-clipnest-owned`)
> and never reads them back. See `TESTING-LINUX.md` §3 for everything
> verified on that hardware. The diagnostics below are kept for any
> *different* hang.

This build exists to answer **one open question** — a freeze on picking an item,
reported on real hardware and never reproduced in the VM — and to carry three
fixes found while chasing it.

Read [What is actually proven](#what-is-actually-proven) before you start. Some
of what this build does is well measured; some is not, and it is worth knowing
which is which before you spend time on it.

---

## Install

```bash
tar xzf clipnest-1.0.0-linux-<arch>.tar.gz
cd clipnest-1.0.0-linux-<arch>
sha256sum -c SHA256SUMS      # every line should say OK
./install.sh                 # as your normal user, NOT with sudo
```

The installer refuses to run as root and refuses on an architecture mismatch.
Both are intentional.

```bash
clipnest --version           # should print 1.0.0
```

If you are testing on a machine that already had 0.9.2 or 0.9.3, say so when you
report back — whether a version ever worked on a given machine is the single
most useful fact for the freeze question below.

---

## Priority 1 — the freeze (the reason this build exists)

**Symptom:** pick an item from the picker, the window stops responding, and the
desktop offers "Force Quit / Wait".

Run the capture script below **before** reproducing. It removes the need to type
commands into a frozen session, and needs no root.

<details>
<summary><code>clipnest-hang-capture.sh</code> — copy this into a file</summary>

```bash
#!/usr/bin/env bash
OUT="$HOME/clipnest-hang-$(date +%H%M%S).txt"
exec > >(tee "$OUT") 2>&1
echo "Reproduce the hang now. Press Enter once frozen (auto-captures in 30s)."
read -r -t 30 _ || true
echo; echo "================ CAPTURE $(date -Is) ================"
PID="$(pgrep -x clipnest | head -1)"
echo "## pid: ${PID:-NOT RUNNING}"
[ -z "$PID" ] && { echo "clipnest not running"; exit 0; }
echo; echo "## 1. ping (separate thread — the key signal)"
timeout 5 clipnest-ctl ping; echo "   ping exit: $? (124 = wedged)"
echo; echo "## 2. what every thread is blocked in"
for t in /proc/$PID/task/*; do
  printf '%-8s %-22s %s\n' "$(basename "$t")" "$(cat "$t/comm" 2>/dev/null)" \
    "state=$(awk '{print $3}' "$t/stat" 2>/dev/null) wchan=$(cat "$t/wchan" 2>/dev/null)"
done
echo; echo "## 3. kernel stacks (often empty without root — fine)"
for t in /proc/$PID/task/*; do
  s="$(cat "$t/stack" 2>/dev/null)" && [ -n "$s" ] && { echo "--- $(basename "$t")"; echo "$s"; }
done
echo; echo "## 4. cpu — spinning or idle?"
top -b -n1 -H -p "$PID" 2>/dev/null | tail -n +7 | head -25
echo; echo "## 5. logs"
journalctl --user -n 80 --no-pager 2>/dev/null | grep -i clipnest | tail -40
echo; echo "## 6. environment"
echo "session:   $XDG_SESSION_TYPE"
echo "version:   $(clipnest --version 2>&1 | head -1)"
echo "groups:    $(id -nG)"
echo "uinput rw: $([ -w /dev/uinput ] && echo yes || echo no)"
echo "ibus:      $(pgrep -x ibus-daemon >/dev/null && echo running || echo 'NOT running')"
echo "ibus eng:  $(timeout 5 ibus engine 2>&1)"
echo "================ END ================"; echo "Saved to: $OUT"
```

</details>

```bash
chmod +x clipnest-hang-capture.sh && ./clipnest-hang-capture.sh
```

You get 30 seconds to switch to Clipnest and trigger the freeze. Then press
Enter (or wait). Send back the `.txt` it writes.

### The one line that decides everything

```
ping exit: 0     → only the UI thread is stuck
ping exit: 124   → the whole process is wedged
```

`ping` is answered by a **different thread** from the one drawing the window.
Those two outcomes are different bugs with different fixes. Until this is known,
any fix would be a guess.

### Also worth trying

- Does it freeze on **every** pick, or only sometimes?
- Only when pasting into certain apps?
- Does it recover on its own if you wait 30 seconds, or stay dead?
- Text items vs images — any difference?

---

## Priority 2 — the permissions flow

Open **Settings → Permissions**.

Fixed in this build: the same sentence used to appear twice (once normally, once
greyed out below), which made a *correct* state look broken.

Check:

- Each message appears **once**.
- The three states read sensibly: not yet set up / granted-but-needs-relogin /
  granted.
- **Grant Access…** raises a real polkit password prompt.

Then the part that needs a careful answer:

```bash
id -nG | tr ' ' '\n' | grep clipnest-input   # in the group?
[ -w /dev/uinput ] && echo writable || echo "not writable"
```

| In group | `/dev/uinput` | Logged out since granting? | Verdict |
|---|---|---|---|
| yes | writable | — | Working. Auto-paste should be live |
| yes | not writable | **no** | Correct — Linux only applies group membership at login |
| yes | not writable | **yes** | **Bug. Report it** |
| no | not writable | — | Grant did not take. Report it |

That third row is the one worth being careful about — please confirm whether you
actually logged out and back in, rather than just restarting the app.

---

## Priority 3 — snippet expansion (the new feature)

This is what 0.9.3 added and what most of the work went into.

**What it does:** type a keyword, select it, press the expand hotkey, and the
keyword is replaced in place by the snippet text.

**Why it was rebuilt:** on GNOME Wayland the old approach synthesised Ctrl+C.
The hotkey fires while you are still holding its modifiers, and the compositor
merged those held keys into the synthesised chord, so it silently did nothing —
it failed roughly 8 times out of 8 at a realistic key-hold. The new path sends
the text over D-Bus through the input-method system, so there is no keystroke to
corrupt.

### Setup

Settings → Snippets (tab 3). Add:

| Keyword | Body |
|---|---|
| `zzsig` | `Best regards, Clipnest` |
| `zzuni` | `café 👍 done` |

### 3a. The basic case

In **Text Editor** (`gnome-text-editor`): type `before zzsig after`, select just
`zzsig` (Shift+Left ×5), press the expand hotkey.

Expect exactly: `before Best regards, Clipnest after`

### 3b. The actual bug — hold the modifiers

Same thing, but **keep the hotkey's modifiers held down** while it fires, the way
you naturally would.

This is the case that was broken. It should now work identically to 3a. Try it
about ten times — the old failure was intermittent-looking but nearly total.

### 3c. Apps worth trying

| App | Note |
|---|---|
| Text Editor / gedit | Measured working |
| **A terminal** | **Please try this properly — see below** |
| Firefox — address bar and a text box on a page | Unverified |
| VS Code, Slack, Discord, any Electron app | Only tested with a hand-built Electron app |
| LibreOffice, Thunderbird | Never tested |

**The terminal case matters most.** It is the main reason this approach was
chosen — terminals cannot be served by the older accessibility path at all. It
was never confirmed end to end, because the test harness could not produce a
text selection the terminal reports. **A real mouse drag-selection may well
work where the automated harness could not.** If you try one thing here, try
selecting a keyword in a terminal with the mouse and expanding it.

### 3d. Non-ASCII

Use `zzuni`. The result must be exactly `café 👍 done` — no missing or extra
characters, and the text either side untouched. Off-by-one errors here would be
invisible in plain ASCII, which is why this case is listed separately.

### 3e. What must never happen

- Text appearing **twice** (`Best regards, ClipnestBest regards, Clipnest`)
- The keyword deleted but nothing inserted — **that is data loss, report it immediately**
- A corrupted or half-replaced line

If expansion simply does nothing, that is a fallback behaving correctly, not a
failure. Note which app it was.

---

## Priority 4 — nothing else broke

Quick pass over existing behaviour:

- Copy text and images → they appear in History
- Search; pin something (tab 2)
- `Alt+Super+V` opens the picker
- Picker Enter still copies (or pastes, if auto-paste is granted)
- Tray icon and menu work
- Quit and relaunch — settings survive

Then two specific checks for this build:

```bash
# 1. Startup should not stall, even after a force-quit
pkill -9 clipnest && clipnest &
# the tray icon should appear promptly, not after a multi-second freeze

# 2. Typing must still work if Clipnest is killed mid-expansion
pkill -9 clipnest
# now type in any app — it must work normally, immediately
```

The second one matters: expansion briefly makes Clipnest the system input
method. If it dies at the wrong moment without restoring, **you would be unable
to type**. That recovery was measured working, but it is worth confirming on
your hardware.

If typing ever does break, this restores it:

```bash
ibus engine xkb:us::eng
```

---

## What is actually proven

Being straight about this, because a previous build was described more
confidently than the evidence supported.

| Claim | Status |
|---|---|
| Expansion survives held modifiers | **Measured** — 8/8 with modifiers held, 3/3 control, 0/8 with the fix disabled |
| Expansion works in GTK4 apps | **Measured** — 5/5 exact |
| Non-ASCII is handled correctly | **Measured** — 2/2 exact |
| Typing recovers if killed mid-expansion | **Measured**, including SIGKILL |
| Works with no input-method daemon | **Measured** — falls back cleanly in 20 ms |
| D-Bus timeouts are honoured | **Measured** — 3017 ms → 108 ms |
| **Works in terminals** | **Unproven.** Answers correctly; a commit was never confirmed |
| **Works in Firefox** | **Unproven** — same reason |
| **The item-select freeze** | **Fixed in 1.0.0.** Root-caused under gdb on real hardware (self-deadlock on Clipnest's own clipboard write) and verified fixed there |
| X11 unaffected | **Inferred** from the code, never run |

All of the above was measured on **one** machine — arm64 Ubuntu 24.04, GNOME 46,
Wayland. That machine passed, and then a real machine froze. Testing on
different hardware is the point of this build.

---

## Reporting back

Most useful, in order:

1. The `clipnest-hang-*.txt` capture — **the `ping exit:` line above all else**
2. Whether an earlier version ever ran on this machine without freezing
3. Terminal expansion with a real mouse selection: worked / did nothing / corrupted
4. `echo $XDG_SESSION_TYPE`, distro and version, GNOME version

For anything that misbehaves: what you did, what you expected, what happened,
and which app. "Did nothing" and "corrupted the text" are very different
failures — the second is far more serious.
