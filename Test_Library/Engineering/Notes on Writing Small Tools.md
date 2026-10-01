# Notes on Writing Small Tools

Small tools are the best kind of software: one job, no settings, finished.

## Rules I try to follow

1. Do one thing.
2. Read from stdin, write to stdout.
3. Fail loudly with a useful message.

## Example: word counter in Swift

```swift
import Foundation

let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
let words = text.split { $0.isWhitespace || $0.isNewline }
print("\(words.count) words")
```

And the same thing as a shell one-liner:

```bash
wc -w < post.md
```

Inline code like `let x = 1` should render in a monospaced font, and so should paths such as `~/Notes/Engineering`.

## Further reading

- The Unix philosophy (look it up — it holds up)
- [Why I switched to light roasts](../Coffee/Why%20I%20Switched%20to%20Light%20Roasts.md), because every engineer needs coffee

Math placeholder for v2: $E = mc^2$
