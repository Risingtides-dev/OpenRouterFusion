# task-30 — Custom Free Fusion Engine

Implemented client-side free-model fusion. This replaces the failed OpenRouter `openrouter/fusion` plugin/router path.

## Changed
- `Sources/OpenRouterFusion/RouterManager.swift`
  - Replaced old Fusion API request with custom client-side council logic.
  - Fusion mode now reads `fusion.panelModels` from config.
  - Sends the same conversation to all configured free models in parallel using non-streaming OpenRouter chat completion calls.
  - Tolerates partial failures: failed/empty models are recorded, successful models proceed.
  - Synthesizes successful panel responses with a free judge model (`judgeModel`, then `openrouter/owl-alpha`, then `openrouter/free`).
  - Falls back to a deterministic local markdown report if judge synthesis fails.
- `Sources/OpenRouterFusion/ChatViewModel.swift`
  - Updated Fusion copy/model-used metadata for custom fusion.
- `Sources/OpenRouterFusion/SidebarView.swift`
  - Updated mode description: "our own free-model council".
- `Resources/ModelConfig.json`
- `Sources/OpenRouterFusion/Resources/ModelConfig.json`
  - Replaced plugin config with:
    - `fusion.enabled`
    - `fusion.panelModels`
    - `fusion.judgeModel`
    - `fusion.maxParallelRequests`
    - `fusion.responseTimeoutSeconds`

## Verification
- `swift build` ✅
- `bash build-app.sh` ✅
- Grep check for forbidden OpenRouter Fusion plugin/router strings ✅

## Notes
- `maxParallelRequests` is config-shaped but not yet used to throttle because the default panel is only 5 models. Current behavior is true parallel fanout.
- Build has pre-existing Swift 6 warning about `NSLock` in async context; project is still set to Swift 5 language mode and builds successfully.
