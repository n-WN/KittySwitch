# KittySwitch

A macOS menu bar app to manage kitty terminal tabs and Claude Code sessions.

## Features

- Lists all open kitty terminal tabs in the menu bar with tab count badge
- Detects running Claude Code sessions and displays session metadata (ID, prompt, flags)
- Click any tab to focus it instantly
- Browse recent Claude Code sessions sorted by last activity
- Resume past sessions directly from the menu (with optional permission skip)
- Lightweight single-file Swift app with no dependencies

## Build & Run

```bash
swiftc -O -o KittySwitch KittySwitch.swift -framework Cocoa
./KittySwitch
```

The app appears as a terminal icon in the menu bar.

## Requirements

- macOS 14+
- [kitty](https://sw.kovidgoyal.net/kitty/) terminal with remote control enabled (`allow_remote_control yes` in `kitty.conf`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (optional, for session management features)

## License

MIT
