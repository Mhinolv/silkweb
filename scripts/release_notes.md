## Install

1. Download `Silkweb-{{VERSION}}.dmg` below and open it.
2. Drag **Silkweb** onto the **Applications** shortcut in the window that opens.
3. Eject the “Silkweb {{VERSION}}” disk image, then open Silkweb from your Applications folder.

Silkweb needs macOS 15 or later on a Mac with Apple silicon.

## This build is unsigned

This preview isn’t signed with a Developer ID or notarized by Apple yet, so macOS stops it the first time you
open it. To open it anyway:

1. Open Silkweb once and dismiss the warning.
2. Go to **System Settings ▸ Privacy & Security**, find the message about Silkweb and click **Open Anyway**.
3. Confirm with your password or Touch ID. Silkweb opens normally from then on.

Or, in Terminal, after copying the app to Applications:

```sh
xattr -dr com.apple.quarantine /Applications/Silkweb.app
```

## Agent memory helper (not included)

The `silkweb` command-line helper that lets coding agents read and write Silkweb notes isn’t part of this
download. Build it from source with `./scripts/build.sh`; `docs/agent-memory.md` explains how to install it.
