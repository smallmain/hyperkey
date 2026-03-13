# Hyperkey

[简体中文说明](README.zh-CN.md)

A tiny macOS menu bar utility that turns Caps Lock into a Hyper key (Cmd+Ctrl+Opt+Shift pressed simultaneously). Built as a lightweight, dependency-free alternative to Karabiner Elements.

## Why

Karabiner Elements uses a DriverKit virtual keyboard driver that [broke on macOS 26.4 beta](https://github.com/pqrs-org/Karabiner-Elements/issues/4402). Hyperkey takes a simpler approach:

1. `hidutil` remaps Caps Lock to F18 at the HID driver level (Apple's own tool, always works)
2. A `CGEventTap` intercepts F18 and injects all four modifier flags onto key combos
3. External keyboards are handled via IOKit HID seizure, since `CGEventTap` can't see their events on macOS 26+

No kernel extensions, no virtual keyboards, no external dependencies. Just Swift and Apple's built-in APIs.

## Features

- **Hyper key**: CapsLock + any key sends Cmd+Ctrl+Opt+Shift + that key
- **Vim-style navigation**: Optional menu toggle for CapsLock + H/J/K/L to send Left/Down/Up/Right arrows (default off)
- **CapsLock alone to Escape**: Optional toggle, great for vim users
- **External keyboard support**: Works with USB and wireless keyboards via IOKit HID
- **Launch at Login**: One-click toggle from the menu bar
- **Auto-update check**: Notifies you when a new version is available on GitHub
- **Menu bar icon**: Minimal capslock glyph, no Dock icon

## Install

### Download (recommended)

1. Download `Hyperkey.zip` from the [latest release](https://github.com/smallmain/hyperkey/releases/latest)
2. Unzip and move `Hyperkey.app` to `/Applications`
3. Open Hyperkey from Spotlight or Raycast
4. Grant Accessibility permissions when prompted (the app will wait and start automatically once granted)
5. Click the Caps Lock icon in the menu bar and enable **Launch at Login**

Current releases are not signed with a Developer ID certificate and are not notarized by Apple. On a fresh macOS install, Gatekeeper warnings are expected on first launch. See **Install Troubleshooting** below.

### Build from source

```bash
git clone https://github.com/smallmain/hyperkey.git
cd hyperkey
make install    # builds, signs, and installs to /Applications
```

### Uninstall

```bash
make uninstall
# also remove from System Settings > Privacy & Security > Accessibility
```

Or manually: quit from the menu bar, delete `Hyperkey.app` from `/Applications`, and remove `~/Library/LaunchAgents/com.smallmain.hyperkey.plist`.

## Install Troubleshooting

### `"Hyperkey.app" is damaged and can't be opened. You should move it to the Trash.`

This usually means macOS Gatekeeper quarantined a non-notarized app, not that the ZIP is literally corrupt.

Try these in order:

1. Delete the app, re-download `Hyperkey.zip`, and unzip it with Finder
2. Move `Hyperkey.app` to `/Applications`
3. In Finder, Control-click the app and choose **Open**
4. If macOS still blocks it, open **System Settings > Privacy & Security** and click **Open Anyway**
5. If you trust the binary and Gatekeeper still refuses, remove the quarantine attribute manually:

```bash
xattr -dr com.apple.quarantine /Applications/Hyperkey.app
```

If you prefer not to run unsigned binaries, build from source instead:

```bash
git clone https://github.com/smallmain/hyperkey.git
cd hyperkey
make install
```

### `"Hyperkey.app" cannot be opened because Apple cannot check it for malicious software.`

This is the expected warning for an app that is not notarized with Developer ID. The same fixes apply:

1. Move the app to `/Applications`
2. Control-click the app and choose **Open**
3. If needed, allow it in **System Settings > Privacy & Security > Open Anyway**
4. As a last resort, clear quarantine with `xattr -dr com.apple.quarantine /Applications/Hyperkey.app`

### The app launches but nothing happens, or the menu bar icon appears and stays on `Waiting for Accessibility permission...`

Hyperkey needs Accessibility access before keyboard remapping starts.

1. Open **System Settings > Privacy & Security > Accessibility**
2. Enable `Hyperkey`
3. If it was already enabled but Hyperkey still waits, remove it from the list, re-add it, then relaunch the app
4. If the permission record is stale, reset it and reopen Hyperkey:

```bash
tccutil reset Accessibility com.smallmain.hyperkey
```

For local development builds, `make install` already performs this reset.

### Accessibility is enabled, but Hyperkey still does not work after rebuilding from source

macOS tracks Accessibility permission by code signature hash. Rebuilding changes that hash, so the old permission entry may no longer match the new binary.

Use:

```bash
make install
```

If needed, reset TCC manually and grant permission again:

```bash
tccutil reset Accessibility com.smallmain.hyperkey
```

### Caps Lock still toggles capitalization, or Hyper mode never activates

Possible causes:

1. Accessibility permission was never granted
2. `hidutil` failed to apply the Caps Lock -> F18 mapping
3. Another keyboard remapper is already intercepting the same keys

Try:

1. Open the Hyperkey menu and check whether it shows `Warning: HID mapping failed`
2. Quit and reopen Hyperkey
3. Disable other keyboard tools such as Karabiner, BetterTouchTool, or Hammerspoon temporarily
4. If you built from source, rerun `make install`

### Built-in keyboard works, but an external keyboard does not

Hyperkey handles external keyboards through IOKit HID seizure. That means exclusive access can fail if another tool already owns the device.

Try:

1. Unplug and reconnect the external keyboard
2. Open the **Keyboards** submenu and confirm the device appears there
3. Quit other tools that may seize or remap keyboards
4. Relaunch Hyperkey

Notes:

- Media keys and other consumer-page keys are not currently re-injected
- If a device cannot be seized, Hyperkey skips it to avoid double input

### Keys repeat or double-fire on an external keyboard

This usually means another keyboard tool is also processing the same device.

1. Quit Karabiner and any other global keyboard remapper
2. Disconnect and reconnect the keyboard
3. Relaunch Hyperkey and check the **Keyboards** menu again

### `Launch at Login` stops working after moving the app

The LaunchAgent stores the executable path when you enable it.

Fix:

1. Move `Hyperkey.app` to its final location, preferably `/Applications`
2. Open Hyperkey
3. Turn **Launch at Login** off, then on again

If it still fails, delete the stale LaunchAgent and recreate it:

```bash
rm -f ~/Library/LaunchAgents/com.smallmain.hyperkey.plist
```

Then re-enable **Launch at Login** from the menu.

### The app has no Dock icon

This is expected. Hyperkey is a menu bar utility and only shows a caps-lock icon in the macOS menu bar.

### Where to find logs

- When started from a terminal, logs are written to stderr
- When started via LaunchAgent, check `/tmp/hyperkey.err.log`

## How it works

| Layer | What | How |
|-------|------|-----|
| HID | Caps Lock to F18 | `hidutil property --set` (prevents caps lock toggle) |
| Event | F18 to Hyper modifier | `CGEventTap` adds Cmd+Ctrl+Opt+Shift flags to key events |
| External keyboards | Seize and re-inject | IOKit HID seizure with CGEvent re-injection (macOS 26+ fix) |
| UI | Menu bar icon | `NSStatusItem` with settings and update notifications |

### Dual-path architecture

**Built-in keyboard**: `hidutil` remaps CapsLock to F18, and a `CGEventTap` intercepts F18 to apply hyper modifier flags.

**External keyboards**: On macOS 26+, `CGEventTap` no longer receives events from external keyboards. Hyperkey detects external keyboards via IOKit HID, seizes them for exclusive access, and re-injects all key events as CGEvents with hyper mode applied. This happens automatically with no configuration needed.

## Requirements

- macOS 13+
- Accessibility permissions

## License

MIT
