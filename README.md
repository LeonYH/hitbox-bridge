# 8BitDo Xbox Hitbox macOS Bridge

A user-space macOS bridge for `8BitDo Arcade Controller for Xbox`. It initializes
the USB device, decodes controller input, and emits keyboard events from the app.

## Build the app

```sh
make app
```

The app is built at `build/HitboxBridge.app`.

Use the switch to start or stop the bridge. Click a mapping button and press a
letter, number, punctuation key, or Space. Press `Esc` to cancel. Changes save
immediately; `Apply` saves manually and releases active keys. The optional log
shows bridge activity. The app reconnects automatically after a disconnect.

Key map: `~/Library/Application Support/8BitDo Hitbox Bridge/keymap.conf`

## Project layout

- `app/`: SwiftUI app, bridging header, and app bundle metadata.
- `src/`: embeddable C USB bridge core plus the CLI debug wrapper.
- `tools/`: USB probe/debug utility source.
- `build/`: generated app bundle, objects, and compiler module cache.

## Default key map

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

## Accessibility

If keyboard events are ignored, enable `HitboxBridge.app` at:

`System Settings > Privacy & Security > Accessibility`

The target game or browser must be the focused foreground window.
