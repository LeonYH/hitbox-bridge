# 8BitDo Xbox Hitbox macOS Bridge

This is a first-pass user-space bridge for `8BitDo Arcade Controller for Xbox`
on macOS.

It configures the USB device, sends a minimal Xbox/GIP-style init sequence, reads
the interrupt input endpoint, and maps the decoded controls to keyboard events.

## Build the app

```sh
make app
```

The app bundle is written to:

```sh
build/HitboxBridge.app
```

Open the app, use the switch to start/stop the bridge, and click a key mapping
button to record a new key from the keyboard. Recording supports letters,
numbers, common punctuation keys, and Space. Press `Esc` while recording to
cancel. Changes are saved immediately; `Apply` is still available as a manual
save/release action. The runtime log is off by default; turn on `Log` only when
you need to inspect helper output.

The app stores its key map at:

```sh
~/Library/Application Support/8BitDo Hitbox Bridge/keymap.conf
```

## Dry run

```sh
./hitbox_bridge --seconds 20
```

This only prints decoded button changes.

## Emit keyboard

```sh
./hitbox_bridge --emit --seconds 3600
```

Run until stopped:

```sh
./hitbox_bridge --emit --forever
```

Default key map:

- Directions: `W A S D`
- `X -> U`
- `Y -> I`
- `RB -> O`
- `A -> J`
- `B -> K`
- `RT -> L`
- `LSB -> Y`
- `RSB -> H`
- `LB -> P`
- `LT -> ;`

Use a custom key map:

```sh
./hitbox_bridge --emit --forever --config keymap.conf
```

Config format:

```txt
UP=W
DOWN=S
LEFT=A
RIGHT=D
X=U
Y=I
RB=O
A=J
B=K
RT=L
LSB=Y
RSB=H
LB=P
LT=;
```

If keyboard events are ignored, enable Accessibility permission for the app that
launches this tool, then rerun:

`System Settings > Privacy & Security > Accessibility`

For example, enable Terminal, iTerm, or Codex depending on where you started it.
When using the bundled app, enable `HitboxBridge.app`. The app runs the USB
helper in decode-only mode and posts keyboard events from the app process.
The target game/browser window must also be the focused foreground window.

## Probe tool

```sh
./usb_probe --set-config --init-gip --read-pipes --reads 60 --brief
```

Use this when changing the mapping or inspecting raw reports.
