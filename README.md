# 8BitDo Xbox Hitbox macOS Bridge

This is a first-pass user-space bridge for `8BitDo Arcade Controller for Xbox`
on macOS.

It configures the USB device, sends a minimal Xbox/GIP-style init sequence, reads
the interrupt input endpoint, and maps the decoded controls to keyboard events.

## Dry run

```sh
./hitbox_bridge --seconds 20
```

This only prints decoded button changes.

## Emit keyboard

```sh
./hitbox_bridge --emit --seconds 3600
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

If keyboard events are ignored, enable Accessibility permission for the app that
launches this tool, then rerun:

`System Settings > Privacy & Security > Accessibility`

For example, enable Terminal, iTerm, or Codex depending on where you started it.
The target game/browser window must also be the focused foreground window.

## Probe tool

```sh
./usb_probe --set-config --init-gip --read-pipes --reads 60 --brief
```

Use this when changing the mapping or inspecting raw reports.
