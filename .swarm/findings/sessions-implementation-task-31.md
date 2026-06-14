# task-31 — Project-local Pi Sessions List / Isolated Pi Sandbox

Implemented a native SwiftUI sessions list for a sealed Pi environment owned by OpenRouterFusion.

## Key isolation decisions
- Uses app support directory only:
  - `~/Library/Application Support/OpenRouterFusion/isolated-pi/`
- Private Pi HOME:
  - `.../isolated-pi/home`
- Private Pi agent config:
  - `.../isolated-pi/home/.pi/agent/settings.json`
- Private session directory:
  - `.../isolated-pi/sessions`
- Generated Pi commands set:
  - `HOME=<isolated-pi/home>`
  - `PI_OFFLINE=1`
  - `--session-dir <isolated-pi/sessions>`
  - `--no-extensions`
  - `--no-skills`
  - `--no-context-files`
  - `--no-prompt-templates`
  - `--no-themes`
  - `--no-approve`

This prevents launched Pi sessions from loading Thoth, pi-messenger, memory extensions, global skills, global context files, or global `~/.pi` settings.

## Changed
- Added `Sources/OpenRouterFusion/PiSessionManager.swift`
  - Parses app-local Pi JSONL sessions.
  - Creates isolated home/agent/session directories.
  - Writes private empty settings file.
  - Copies isolated new-session/resume commands to clipboard.
- Added `Sources/OpenRouterFusion/SessionsListView.swift`
  - Native SwiftUI session list sheet.
  - Shows isolated root path.
  - Copies new session command.
  - Copies per-session resume commands.
  - Reveals isolated session directory in Finder.
- Updated `ChatViewModel.swift`
  - `showingSessionsList` state.
- Updated `ContentView.swift`
  - Presents `SessionsListView` sheet.
- Updated `SidebarView.swift`
  - Added `Pi Sessions` button.

## Removed conflicting ghost-worker files
- Deleted incomplete `LocalSessionService.swift` and `SessionsView.swift` created by a failed worker wave. They referenced importing global Pi and did not compile.

## Verification
- `swift build` ✅
- `bash build-app.sh` ✅
- Grep confirmed no `Import from Global Pi`, `importFromGlobalPi`, `LocalSessionService`, or old `SessionsView` references ✅

## Note
Current UI copies commands rather than spawning Terminal directly. That is safer for now and avoids hidden global side effects. Later we can add an explicit "Launch Isolated Pi" button that runs the same sealed command.
