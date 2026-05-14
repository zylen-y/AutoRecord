AutoRecord — install notes
==========================

1. Drag AutoRecord.app into the Applications folder shortcut in this window.

2. First launch on macOS:
   AutoRecord is not signed with an Apple Developer ID (this is a personal
   project), so Gatekeeper will block the first launch with a message like
   "Apple cannot verify the developer of this app." Two ways to bypass it
   once — after that, macOS will remember your choice:

   Option A — right-click open:
     • In /Applications, right-click (or Control-click) AutoRecord.app
     • Choose "Open"
     • Click "Open" again in the confirmation dialog

   Option B — strip the quarantine flag (Terminal):
     xattr -dr com.apple.quarantine /Applications/AutoRecord.app

3. Grant permissions when prompted:
   • Microphone — required to record audio.
   • Screen Recording — required to capture the audio of other apps
     (Zoom, Chrome, etc.). Without it, AutoRecord records mic-only.

4. Register the MCP server with Claude Desktop:
   • Make sure Claude Desktop has been installed and launched at least once.
   • Open AutoRecord → Settings → "MCP for Claude" → click
     "Install for Claude Desktop".
   • Fully quit Claude Desktop (⌘Q) and reopen it.
   • Now ask Claude: "List my AutoRecord schedules." or
     "Add a schedule called Demo from 2pm to 3pm tomorrow."
