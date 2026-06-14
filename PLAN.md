# OpenRouterFusion — Current Canonical Plan

_Last updated by NicePhoenix: 2026-06-14_

## Product Goal

Build a native SwiftUI macOS app with Liquid Razor Metal UI that uses OpenRouter free models and a future embedded PiParty harness. This is **not** a WebView app and must not depend on or mingle with the user's real Pi/Thoth runtime.

## Current Mode Model

The app has exactly three user-facing chat modes:

1. **Fast**
   - Uses `openrouter/free`.
   - One random free model through OpenRouter's free router.
   - Goal: quick/cheap answer.

2. **Fusion**
   - Uses our own custom Fusion Router algorithm.
   - Does **not** use OpenRouter's `openrouter/fusion` router/plugin.
   - Current implemented flow:
     1. Planner/decomposer parses the prompt into tasks/angles.
     2. Task router assigns tasks across configured free panel models.
     3. Successful partial results are collected; partial failures are tolerated.
     4. Synthesis compiler merges successful outputs into one answer.
   - Config keys:
     - `fusion.panelModels`
     - `fusion.plannerModel`
     - `fusion.judgeModel`
     - `fusion.maxTasks`
     - `fusion.maxParallelRequests`
     - `fusion.responseTimeoutSeconds`

3. **Solo**
   - Uses one explicit selected model.
   - If model picker is Auto, uses config default.

## Completed Recently

- `task-30` — Custom free fusion engine ✅
- `task-31` — Project/app-local Pi Sessions list with isolated shell command generation ✅
- `task-32` — Fusion Router v2 task decomposition + routed synthesis ✅

Latest relevant commits:
- `1b82213 feat: Fusion Router v2 task decomposition flow`
- `db1285e feat(task-31): Project-local Pi Sessions List — isolated from global Pi settings`

## Hard Isolation Requirement

The user does **not** trust any runtime that can mingle with their real Pi/Thoth setup.

Therefore, future Pi/PiParty work must satisfy:

- No reads/writes to real `~/.pi`.
- No Thoth memory tools or memory stores.
- No real/global `pi_messenger` mesh.
- No global agents/extensions/skills/prompts/config/sessions.
- OpenRouterFusion/PiParty may have its **own** independent agents, extensions, messenger, memory, prompts, and sessions under its own app-owned root.

Target app-owned root:

```txt
~/Library/Application Support/OpenRouterFusion/PiParty/
├── home/
├── agent/
│   ├── settings.json
│   ├── agents/
│   ├── extensions/
│   ├── prompts/
│   ├── skills/
│   ├── sessions/
│   └── messenger/
└── workspaces/
```

Current stopgap session commands use private `HOME`, private `--session-dir`, `PI_OFFLINE=1`, and disable extension/skills/context discovery. This is acceptable only as a bridge, not the final runtime architecture.

## PiParty Runtime Direction

Do **not** write a coding harness from scratch unless absolutely necessary.

Preferred path:

- Fork/vendor `xibbon/PiSwift` as `PiPartyKit`.
- Patch it to use injected runtime paths instead of hardcoded `~/.pi` / `NSHomeDirectory()` defaults.
- Bundle/use it as the app's internal Swift harness.
- Maintain Pi-like tools, agents, subagents, extensions, and messenger — but all namespaced to PiParty only.

PiSwift assessment:

- Legit starting point: MIT, active, Swift-native, has agent/coding-agent/subagent pieces.
- Not safe as direct dependency: young repo, no releases, local `../MiniTui` package dependency, hardcoded `~/.pi` paths.
- Best used as a fork/vendor base.

Relevant Crew task:
- `task-34` — PiPartyKit fork/vendor PiSwift as independent runtime.

## Swift LSP Direction

Use Apple **SourceKit-LSP**.

Verified locally:

```txt
sourcekit-lsp: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp
swift: Swift 6.2.3
```

Target service:

```txt
OpenRouterFusion/PiParty
→ SwiftLSPService
→ sourcekit-lsp subprocess per workspace
→ JSON-RPC over stdio
→ app-local scratch/build path
```

Use app-owned scratch path, e.g.:

```bash
sourcekit-lsp --scratch-path "~/Library/Application Support/OpenRouterFusion/PiParty/lsp-cache"
```

Minimum operations:
- initialize
- textDocument/didOpen
- textDocument/didChange
- textDocument/didClose
- diagnostics
- hover
- definition
- document symbols
- completion

Relevant Crew task:
- `task-33` — Swift LSP integration.

## Markdown Rendering Direction

Use native SwiftUI markdown rendering.

Recommended short-term:
- Use upstream `LiYanan2004/MarkdownView`, pinned to a commit.
- It is a SwiftUI renderer built on top of `swift-markdown`.
- Better fit than the low-activity `aheze/MarkdownView` fork.

Use `swiftlang/swift-markdown` directly only if MarkdownView styling limits block us and we need a custom LRM AST renderer.

Relevant Crew task:
- `task-35` — Native Markdown rendering via MarkdownView/swift-markdown.

## Immediate Next Tasks

1. `task-33`: SourceKit-LSP service layer.
2. `task-34`: PiPartyKit fork/vendor plan + first integration spike.
3. `task-35`: MarkdownView/swift-markdown renderer upgrade.
4. After those: test Fusion Router v2 with real prompts/API key and refine task planning, result formatting, throttling, and progress UI.

## Build Verification Baseline

As of `task-32`:

```bash
cd /Users/risingtidesdev/dev/OpenRouterFusion
swift build
bash build-app.sh
```

Both pass. Release build still has a known Swift 6 warning about `NSLock` in async contexts, but project is compiling under Swift 5 language mode.
