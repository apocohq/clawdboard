#!/usr/bin/env python3
"""Focus an iTerm2 pane by its session UUID using AppleScript.

Usage: python3 iterm2-focus.py <iterm2_session_uuid>

Uses osascript for instant (<100ms) one-shot execution rather than
the iTerm2 Python API which requires a persistent connection.
"""

from __future__ import annotations

import subprocess
import sys

APPLESCRIPT_TEMPLATE = """
tell application "iTerm2"
    set targetId to "{uuid}"
    repeat with w in windows
        tell w
            repeat with t in tabs
                tell t
                    repeat with s in sessions
                        tell s
                            if unique id is targetId then
                                select
                                tell t to select
                                set index of w to 1
                                activate
                                return
                            end if
                        end tell
                    end repeat
                end tell
            end repeat
        end tell
    end repeat
end tell
"""


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <iterm2_session_uuid>", file=sys.stderr)
        return 1

    uuid = sys.argv[1]
    script = APPLESCRIPT_TEMPLATE.format(uuid=uuid)

    try:
        subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except subprocess.TimeoutExpired:
        print("Timed out waiting for AppleScript", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"Failed to run osascript: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
