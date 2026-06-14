# PiSwift Isolation Audit — Path & Global-State Scan for PiPartyKit

**Date:** 2026-06-14  
**Auditor:** KeenKnight  
**Task ID:** task-38  
**Repo Audited:** [xibbon/PiSwift](https://github.com/xibbon/PiSwift) (cloned 2026-06-14)  
**Scope:** All `.swift` files in `Sources/` — 9 library targets  
**Goal:** Identify every global-state/path hazard that would cause PiPartyKit to mingle with the user's real Pi/Thoth runtime.

---

## Executive Summary

PiSwift has **26 distinct hard-coded path references** spread across 7 modules and ~14 files. The codebase uses a **centralized config module** (`Config.swift`) that provides injectable overrides, but many downstream modules **bypass the injection** and directly call `NSHomeDirectory()` or `getAgentDir()`.

**Severity breakdown:**
- 🔴 **CRITICAL (will touch real ~/.pi):** 14 locations — 5 in PiMCPAdapter, 4 in Skills/System, 3 in Session/Extension/Hook loaders, 2 in TUI
- 🟡 **MAJOR (discoverable cross-contamination):** 6 locations — skills from ~/.claude/~/.codex, AGENTS.md/CLAUDE.md auto-discovery, ancestor-walking project paths
- 🟢 **SAFE / INJECTABLE:** 6 locations — already accept parameters or env var overrides

**No pi_messenger mesh, no Thoth memory, no Telegram, no inter-agent communication exists in PiSwift.** The isolation concern is purely filesystem-based.

**Fork viability:** Good. The centralized `Config.swift` pattern means most fixes involve making downstream modules accept injected path providers instead of calling global functions. However, `PiMCPAdapter` is the worst offender with 5 independent hardcoded `NSHomeDirectory()` calls that ignore any injection.

---

## Risk Matrix

| # | Location | Severity | What It Touches | Injected? | Patch Difficulty |
|---|----------|----------|----------------|-----------|-----------------|
| 1 | `McpConfig.defaultConfigPath()` | 🔴 | `~/.pi/agent/mcp.json` | ❌ | Easy |
| 2 | `McpConfig.importPaths` | 🔴 | `~/.cursor/mcp.json`, `~/.claude/claude_desktop_config.json`, `~/.codex/config.json`, `~/.windsurf/mcp.json` | ❌ | Easy |
| 3 | `McpConfig` project merge | 🔴 | `<project>/.pi/mcp.json` | ❌ | Easy |
| 4 | `McpMetadataCache.metadataCachePath()` | 🔴 | `~/.pi/agent/mcp-metadata-cache.json` | ❌ | Easy |
| 5 | `NpxResolver.npxCachePath()` | 🔴 | `~/.pi/agent/mcp-npx-cache.json` + `~/.npm/` | ❌ | Easy |
| 6 | `McpOAuthHandler.oauthDir()` | 🔴 | `~/.pi/agent/mcp-oauth/<server>/tokens.json` | ❌ | Easy |
| 7 | `McpAdapter` OAuth store | 🔴 | `~/.pi/agent/mcp-oauth/<server>/` (duplicated) | ❌ | Easy |
| 8 | `Skills.loadSkills()` codex-user | 🟡 | `~/.codex/skills` | ⚠️ Flag-based | Easy |
| 9 | `Skills.loadSkills()` claude-user | 🟡 | `~/.claude/skills` | ⚠️ Flag-based | Easy |
| 10 | `Skills.loadSkills()` claude-project | 🟡 | `<project>/.claude/skills` | ⚠️ Flag-based | Easy |
| 11 | `Config.getAgentDir()` | 🔴 | `~/.pi/agent/` | ✅ ENV override | N/A — already injectable |
| 12 | `PackageManager` .agents/skills | 🟡 | `~/.agents/skills` | ❌ | Medium |
| 13 | `SessionManager.defaultSessionDir()` | 🔴 | `~/.pi/agent/sessions/` | ⚠️ Parameter optional | Easy |
| 14 | `ExtensionLoader` global/local | 🔴 | `~/.pi/agent/extensions/`, `<project>/.pi/extensions/` | ⚠️ Parameter optional | Easy |
| 15 | `HookLoader` global/local | 🔴 | `~/.pi/agent/hooks/`, `<project>/.pi/hooks/` | ⚠️ Parameter optional | Easy |
| 16 | `CustomToolLoader` global/local | 🔴 | `~/.pi/agent/tools/`, `<project>/.pi/tools/` | ⚠️ Parameter optional | Easy |
| 17 | `Subagents.loadSubagents()` | 🔴 | `~/.pi/agent/agents/`, `<project>/.pi/agents/` (ancestor walk) | ⚠️ Parameter optional | Easy |
| 18 | `discoverSystemPromptFile()` | 🟡 | `<project>/.pi/SYSTEM.md`, `~/.pi/agent/SYSTEM.md`, `<project>/AGENTS.md`, `<project>/CLAUDE.md` | ⚠️ Parameter optional | Easy |
| 19 | `PromptTemplates` project discovery | 🟡 | `<project>/.pi/prompts/` | ⚠️ Parameter optional | Easy |
| 20 | `findNearestProjectAgentsDir()` | 🟡 | Walks ancestors looking for `.pi/agents/` up to `/` | ❌ | Easy |
| 21 | `SessionSelectorComponent` (TUI) | 🔴 | `NSHomeDirectory()` for path abbreviation | ❌ | Trivial |
| 22 | `ConfigSelectorComponent` (TUI) | 🟢 | Display string only: "User (~/.pi/agent/)" | N/A | Cosmetic |
| 23 | `KeybindingsManager` (TUI) | 🔴 | `getAgentDir()` default | ⚠️ Parameter optional | Trivial |
| 24 | `InteractiveMode` (TUI) | 🔴 | `getAgentDir()` | ⚠️ Parameter optional | Trivial |
| 25 | `ExtensionCompiler.resolveSDKPaths()` | 🟢 | `PI_EXTENSION_SDK_PATH` env → `~/.pi/agent/sdk/` → relative | ✅ ENV override | Already injectable |
| 26 | `Shell.swift` error messages | 🟢 | Display strings: "~/.pi/agent/settings.json" | N/A | Cosmetic |

---

## Detailed Findings by Module

### 1. PiSwiftCodingAgent/Config.swift — Central Path Provider

This is the **single point of truth**. Everything SHOULD flow through here.

```swift
public let CONFIG_DIR_NAME = ".pi"            // Hardcoded (but overridable downstream)
public let ENV_AGENT_DIR = "PI_CODING_AGENT_DIR"
public let ENV_PACKAGE_DIR = "PI_PACKAGE_DIR"

public func getAgentDir() -> String           // → ~/.pi/agent/ on macOS
public func getHomeDir() -> String            // → $HOME on macOS
public func getSessionsDir() -> String        // → ~/.pi/agent/sessions/
public func getAuthPath() -> String           // → ~/.pi/agent/auth.json
public func getSettingsPath() -> String       // → ~/.pi/agent/settings.json
public func getToolsDir() -> String           // → ~/.pi/agent/tools/
public func getPromptsDir() -> String         // → ~/.pi/agent/prompts/
public func getAgentsDir() -> String          // → ~/.pi/agent/agents/
// ... etc.
```

**Good:** `getAgentDir()` respects `PI_CODING_AGENT_DIR` env override. `getPackageDir()` respects `PI_PACKAGE_DIR`. Both can be pointed to an app-owned root.

**Problem:** Most downstream loaders call these functions with default parameter values, so the env override only works if you set the env var globally — which would also affect the real Pi CLI.

**Patch:** Introduce a `PathProvider` protocol that downstream loaders accept. No more `getAgentDir()` as default parameter. Inject paths at SDK bootstrap.

---

### 2. PiMCPAdapter — Worst Offender (5 independent hardcoded paths)

This module **completely ignores** Config.swift's injection and independently hardcodes `NSHomeDirectory()` in 5 files.

#### McpConfig.swift
```swift
// Line 6
private let importPaths: [String: String] = {
    let home = NSHomeDirectory()
    return [
        "cursor": (home as NSString).appendingPathComponent(".cursor/mcp.json"),
        "claude-code": (home as NSString).appendingPathComponent(".claude/claude_desktop_config.json"),
        "claude-desktop": (home as NSString).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
        "codex": (home as NSString).appendingPathComponent(".codex/config.json"),
        "windsurf": (home as NSString).appendingPathComponent(".windsurf/mcp.json"),
    ]
}()

// Line 85
func defaultConfigPath() -> String {
    let agentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    return (agentDir as NSString).appendingPathComponent("mcp.json")
}

// Line 33, 73 — project merge
let projectPath = (resolvedCwd as NSString).appendingPathComponent(".pi/mcp.json")
```

**Impact:** Even if you inject a custom agentDir via Config.swift, `McpConfig` reads the user's real `~/.pi/agent/mcp.json` AND imports from their real Claude/Cursor/Codex configs.

**Patch:** Parameterize `defaultConfigPath()` and `importPaths`. Pass agent root + optional import disable flag from app.

#### McpMetadataCache.swift (line 60)
```swift
func metadataCachePath() -> String {
    let agentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    return (agentDir as NSString).appendingPathComponent("mcp-metadata-cache.json")
}
```

#### NpxResolver.swift (line 32, 293)
```swift
private func npxCachePath() -> String {
    let agentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    return (agentDir as NSString).appendingPathComponent("mcp-npx-cache.json")
}

// Line 293 — NPM cache probe
let defaultPath = (NSHomeDirectory() as NSString).appendingPathComponent(".npm")
```

#### McpOAuthHandler.swift (line 22)
```swift
private func oauthDir(serverName: String) -> String {
    let agentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    return ((agentDir as NSString).appendingPathComponent("mcp-oauth") as NSString).appendingPathComponent(serverName)
}
```

#### McpAdapter.swift (line 806)
```swift
let tokenDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/mcp-oauth/\(serverName)")
```

**Patch strategy for entire PiMCPAdapter:** Create a `McpPathProvider` struct that provides the 5 path roots (config, cache, npx, oauth, metadata). Thread it through all public functions. Default to `NSHomeDirectory()` only for CLI usage; PiPartyKit injects app-owned root.

---

### 3. PiSwiftCodingAgent/Core/Skills.swift — Cross-Agent Skill Discovery

```swift
// Lines 372-392
if enableCodexUser {
    let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/skills").path
    addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "codex-user")))
}
if enableClaudeUser {
    let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills").path
    addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "claude-user")))
}
if enableClaudeProject {
    let path = URL(fileURLWithPath: cwd).appendingPathComponent(".claude/skills").path
    addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "claude-project")))
}
if enablePiUser {
    let path = URL(fileURLWithPath: agentDir).appendingPathComponent("skills").path
}
if enablePiProject {
    let path = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("skills").path
}
```

**Good:** Each source has a boolean flag (`enableCodexUser`, `enableClaudeUser`, `enableClaudeProject`, `enablePiUser`, `enablePiProject`). PiPartyKit can pass `false` for all non-PiParty sources.

**Problem:** The `NSHomeDirectory()` calls are still hardcoded even when disabled — they just don't load. For full isolation, these paths should be injectable so PiPartyKit can point to its own `PiParty/skills/`.

**Patch:** Change `LoadSkillsOptions` to accept explicit path overrides per source instead of computing from NSHomeDirectory.

---

### 4. PiSwiftCodingAgent/Core/PackageManager.swift — ~/.agents/skills Discovery

```swift
// Line 1005
let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let userAgentsSkillsDir = URL(fileURLWithPath: homeDir).appendingPathComponent(".agents").appendingPathComponent("skills").path

// Line 1770 — ancestor walk
result.append(URL(fileURLWithPath: dir).appendingPathComponent(".agents").appendingPathComponent("skills").path)
```

This discovers skills from `~/.agents/skills/` (a separate convention from `~/.pi/agent/skills/`) and walks ancestor directories looking for `.agents/skills/` per project.

**Patch:** Make the user agents skills directory injectable. Provide a flag to disable ancestor walking.

---

### 5. PiSwiftCodingAgent/Core/SessionManager.swift — Sessions Directory

```swift
// SessionManager.create() defaults
let dir = sessionDir ?? defaultSessionDir(cwd: cwd)
// → getAgentDir()/sessions/ → ~/.pi/agent/sessions/
```

**Good:** `SessionManager.create()` and `SessionManager.continueRecent()` both accept optional `sessionDir` parameter. If provided, they use the injected path.

**Problem:** The default falls through to `defaultSessionDir()` which calls `getSessionsDir()` → `getAgentDir()/sessions/` → real `~/.pi`.

**Patch:** Always pass `sessionDir` explicitly from PiPartyKit. No behavior change needed — just never use the default.

---

### 6. Extension/Hook/Tool/Subagent Loaders — Dual Discovery (Global + Project)

All four loaders follow the same pattern:

```swift
// ExtensionLoader (line 207, 224)
let globalDir = URL(fileURLWithPath: agentDir).appendingPathComponent("extensions").path
let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("extensions").path

// HookLoader (line 154, 157)
let globalDir = URL(fileURLWithPath: agentDir).appendingPathComponent("hooks").path
let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("hooks").path

// CustomToolLoader (line 148, 152)
let globalDir = URL(fileURLWithPath: agentDir).appendingPathComponent("tools").path
let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("tools").path

// Subagents (line 175, 148-165) — walks ancestors for .pi/agents/
let userAgentsDir = getAgentsDir()  // → ~/.pi/agent/agents/
findNearestProjectAgentsDir(cwd)    // walks up to / looking for .pi/agents/
```

**Good:** The global paths come from `agentDir` which can be overridden. Most loaders accept it as a parameter.

**Problem:**
1. The project-local path is always `CONFIG_DIR_NAME` (`.pi`) — hardcoded string, not injectable.
2. `findNearestProjectAgentsDir()` walks from cwd all the way to `/` looking for `.pi/agents/` directories. In a PiPartyKit workspace inside a user's dev folder, this could find their real Pi project agents.
3. `discoverAndLoadExtensions()` line 192 has a hardcoded `~/.pi/agent/sdk/` string in its error message.

**Patch:**
1. Make `CONFIG_DIR_NAME` injectable (or accept a `projectConfigDirName` parameter like `"piparty"`).
2. Add a `maxAncestorDepth` parameter to ancestor-walking functions.
3. Fix error messages to use injected path, not hardcoded string.

---

### 7. System Prompt & Context File Discovery

```swift
// ResourceLoader.swift line 493-513
private func discoverSystemPromptFile() -> String? {
    let projectPath = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("SYSTEM.md").path
    let globalPath = URL(fileURLWithPath: agentDir).appendingPathComponent("SYSTEM.md").path
}

// ResourceLoader.swift line 505-513
private func discoverAppendSystemPromptFile() -> String? {
    let projectPath = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("APPEND_SYSTEM.md").path
    let globalPath = URL(fileURLWithPath: agentDir).appendingPathComponent("APPEND_SYSTEM.md").path
}

// ResourceLoader.swift line 325
// AGENTS.md / CLAUDE.md auto-discovery at project root
// v0.67.4: --no-context-files / noContextFiles option disables this
```

**Good:** There's already a `--no-context-files` / `noContextFiles` flag that skips AGENTS.md/CLAUDE.md auto-discovery.

**Problem:** SYSTEM.md and APPEND_SYSTEM.md discovery still uses CONFIG_DIR_NAME (hardcoded `.pi`).

**Patch:** Same as above — inject CONFIG_DIR_NAME. Use `noContextFiles: true` for PiPartyKit.

---

### 8. PiSwiftCodingAgentTui — TUI Module

The TUI module depends on `PiSwiftCodingAgent` and has minor path references:

```swift
// SessionSelectorComponent.swift line 14
let home = NSHomeDirectory()
// Used for path abbreviation in display: ~/Projects/... instead of /Users/smaths/Projects/...

// ConfigSelectorComponent.swift line 176
return metadata.scope == "user" ? "User (~/.pi/agent/)" : "Project (.pi/)"
// Display string only — cosmetic

// Keybindings.swift line 33
public static func create(agentDir: String = getAgentDir()) -> KeybindingsManager
// Has default parameter

// InteractiveMode.swift line 2932
let agentDir = getAgentDir()
```

**Patch:** TUI is the CLI surface — PiPartyKit likely won't ship it. For an in-app PiParty experience, you'd use SwiftUI views, not MiniTui. Low priority.

---

### 9. FileMutationQueue — Global Singleton

```swift
// FileMutationQueue.swift line 7
public actor FileMutationQueue {
    public static let shared = FileMutationQueue()
```

This is a **global singleton actor** that serializes file mutation operations across the process. It doesn't reference any paths directly — it just coordinates locks on path strings.

**Risk:** If PiPartyKit runs **in-process** with OpenRouterFusion and the real Pi CLI is also running, there's no conflict — FileMutationQueue locks are per-process (actor-isolated). No cross-process coordination is implied.

**No patch needed** unless PiPartyKit runs in the same process as the real Pi (unlikely).

---

### 10. PiSwiftAI — Google Cloud Credentials Check

```swift
// Stream.swift line 118
let defaultPath = fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/gcloud/application_default_credentials.json")
```

This is the **standard Google Application Default Credentials path**. It's a GCloud convention, not PiSwift-specific. Only relevant if PiPartyKit supports Google Gemini as a provider.

**No patch needed** for PiPartyKit isolation.

---

## Patch Checklist for task-34/GoldPhoenix

### Phase 1: PathProvider Protocol (Core)

- [ ] Create `PiPartyPathProvider` protocol with all path roots that `Config.swift` currently provides:
  - `agentDir`, `sessionsDir`, `settingsPath`, `authPath`, `promptsDir`, `agentsDir`, `hooksDir`, `toolsDir`, `customThemesDir`, `modelsPath`, `debugLogPath`, `cacheDir`
- [ ] Create default impl that delegates to existing `Config.swift` globals (for CLI compatibility)
- [ ] Create PiPartyKit impl that resolves all paths under `~/Library/Application Support/OpenRouterFusion/PiParty/agent/`
- [ ] Make all `discover*` and `load*` functions in SDK.swift accept pathProvider parameter
- [ ] Change all default parameters from `= getAgentDir()` to require explicit injection at the SDK bootstrap level

### Phase 2: PiMCPAdapter Fix (Critical)

- [ ] Create `McpPathProvider` struct with: configPath, cachePath, npxCachePath, oauthDir, metadataCachePath, importPaths (with disable flag)
- [ ] Parameterize `loadMcpConfig()`, `McpMetadataCache`, `NpxResolver`, `McpOAuthHandler`, `McpAdapter` to accept McpPathProvider
- [ ] Add `disableImports: Bool` flag to skip Claude/Cursor/Codex/Windsurf import merging

### Phase 3: CONFIG_DIR_NAME Injection

- [ ] Make `CONFIG_DIR_NAME` a parameter (default `.pi`, PiPartyKit uses `.piparty` or app-owned root)
- [ ] Update: ExtensionLoader, HookLoader, CustomToolLoader, SkillLoader, PromptTemplates, ResourceLoader, SubagentLoader, SessionManager

### Phase 4: Disable External Discovery

- [ ] Skills: Pass all `enableCodexUser`, `enableClaudeUser`, `enableClaudeProject`, `enablePiUser`, `enablePiProject` as `false` except PiParty-specific paths
- [ ] Context files: Pass `noContextFiles: true` to skip AGENTS.md/CLAUDE.md auto-discovery
- [ ] PackageManager: Disable `~/.agents/skills` ancestor walking or inject override path
- [ ] Ancestor walking: Add `maxAncestorDepth` (preferably 0 for PiPartyKit) to `findNearestProjectAgentsDir`

### Phase 5: Test Guard — Isolation Sentinel

- [ ] Write test: `testPiPartyKitNeverTouchesRealPi()` that creates a temp fake home, injects PiParty paths, and verifies no filesystem reads of the real `~/.pi/`
- [ ] Use `FileMonitor` / `kqueue` or override `FileManager.default` in tests to detect unauthorized path access

---

## PiSwift Package Structure & What PiPartyKit Needs

From `Package.swift`:

```
Products (libraries):
├── PiSwift                     — Root (tiny, no deps)
├── PiSwiftAI                   — AI providers (OpenAI, Anthropic) + streaming
├── PiSwiftAgent                — Agent loop (depends on PiSwiftAI)
├── PiSwiftCodingAgent          — Coding agent core (depends on AI + Agent) ← MOST PATHS
├── PiSwiftCodingAgentTui       — TUI (depends on CodingAgent + MiniTui) ← skip for app
├── PiSwiftSyntaxHighlight      — Syntax highlighting
├── PiMCPAdapter                — MCP server adapter (depends on CodingAgent + AI + Agent) ← WORST PATHS
└── PiExtensionSDK              — Extension SDK (dylib, depends on AI + Agent + CodingAgent)

Executables:
├── pi-ai                       — CLI for PiSwiftAI
├── pi-coding-agent             — Full CLI ← skip for PiPartyKit
```

### Dependencies

- `MacPaw/OpenAI` (branch: main)
- `jamesrochabrun/SwiftAnthropic` (branch: main)
- `apple/swift-argument-parser` (≥ 1.4.0)
- **`../MiniTui`** (local path dependency) ⚠️ — this is the blocker mentioned in PLAN.md

### What PiPartyKit Needs (Minimum Viable Fork)

For an embedded PiParty runtime inside OpenRouterFusion:

1. **PiSwiftAI** — AI provider abstraction + SSE streaming
2. **PiSwiftAgent** — Agent loop (message → tool call → completion)
3. **PiSwiftCodingAgent** — Coding agent (session management, tools, skills, extensions, hooks, prompts, MCP, subagents)
4. **PiExtensionSDK** — For compiling/loading PiParty-specific extensions
5. **PiMCPAdapter** — MCP server support (after patching)

**Skip:**
- PiSwiftCodingAgentTui (MiniTui dependency — don't need TUI in SwiftUI app)
- PiSwiftSyntaxHighlight (nice-to-have, not critical)
- Executables (pi-ai, pi-coding-agent — don't need CLI)
- PiSwift (root module — almost empty)

---

## Key Blockers Summary

From PLAN.md's assessment:

| Blocker | Risk | Mitigation |
|---------|------|------------|
| Local `../MiniTui` dependency | 🔴 Fork won't resolve without MiniTui | Remove Tui target from Package.swift, skip Tui module entirely |
| Hardcoded `NSHomeDirectory()` / `~/.pi` | 🔴 14 critical locations | PathProvider protocol + injection (this audit's primary deliverable) |
| No releases / young repo | 🟡 Maintenance burden | Pin to commit SHA, vendor into app repo |
| Cross-agent skill discovery | 🟡 Reads ~/.claude/skills, ~/.codex/skills | Boolean flags already exist — just set them false |
| Ancestor-walking discovery | 🟡 Walks to `/` looking for .pi dirs | Add depth limit or inject explicit root |

---

## Migration Path: From Shell-Command Stopgap to Embedded PiPartyKit

### Current state (task-31)
Project-local Pi sessions list uses isolated shell commands with private HOME, `--session-dir`, and `PI_OFFLINE=1`.

### Phase 1 (this audit + task-34 plan)
Define the path provider protocol and fork strategy. No source changes yet.

### Phase 2 (task-34 — fork)
1. Clone PiSwift tag/commit into `Sources/PiPartyKit/` (vendored, not SPM dependency)
2. Strip `Package.swift` — remove Tui, CLI, argument-parser dependency
3. Apply path provider patches from this audit
4. Rename modules: `PiSwiftCodingAgent` → `PiPartyCodingAgent`, `PiMCPAdapter` → `PiPartyMCP`, etc.
5. Create `PiPartyEnvironment` type that resolves all paths under `~/Library/Application Support/OpenRouterFusion/PiParty/`

### Phase 3 (integration)
1. Replace shell-command Pi spawning with in-process PiPartyKit calls
2. Wire OpenRouterFusion's model API keys to PiPartyKit's provider abstraction
3. Implement `SwiftLSPService` (task-33) → inject into PiPartyKit workspace
4. Build PiParty-specific extensions/agents/skills under app-owned root

### Phase 4 (full isolation)
1. Write isolation sentinel tests
2. Verify zero filesystem reads to real `~/.pi/` 
3. Remove shell-command stopgap entirely

---

## What's NOT a Concern

| Item | Why it's safe |
|------|--------------|
| `FileMutationQueue.shared` | In-process actor only; no cross-process state |
| No pi_messenger in PiSwift | PiSwift has zero mesh/networking code — it's a local agent library |
| No Thoth memory references | PiSwift has no memory tools, no Telegram, no inter-agent comms |
| `Google ADC credentials` path (PiSwiftAI) | Standard GCloud convention, not Pi-specific |
| `~/.npm` cache probe (NpxResolver) | Read-only check for npx binary existence; doesn't modify |

---

## Recommendation for task-34/GoldPhoenix

1. **Start with Config.swift** — it's the leverage point. Everything downstream should accept injected paths.
2. **Fix PiMCPAdapter first** — it's the worst offender with 5 independent hardcoded paths that ignore Config.swift entirely.
3. **Vendor, don't SPM-depend** — the `../MiniTui` local dependency and hardcoded paths make SPM dependency management risky. Copy into `Sources/PiPartyKit/` and patch in-tree.
4. **Strip aggressively** — remove Tui, CLI, argument-parser. You only need the agent loop + tools + MCP.
5. **Write the isolation sentinel test early** — before any integration, have a test that fails if PiPartyKit reads real `~/.pi/`. This prevents regression as you patch more modules.

**Estimated patch scope:** ~20 files touched, ~200 lines changed (mostly adding parameters and creating PathProvider structs). Moderate effort, low risk — the changes are additive (adding optional parameters) and don't change runtime behavior when defaults are used.

---

**Audit complete.** 🎯
