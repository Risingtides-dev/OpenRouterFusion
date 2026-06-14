# task-32 — Fusion Router v2

Implemented the intended product flow:

- **Fast**: `openrouter/free`
- **Fusion**: custom Fusion Router algorithm
- **Solo**: one selected model

## Fusion Router flow

Fusion no longer does a flat all-model council. It now runs:

1. **Planner / decomposer**
   - Uses `fusion.plannerModel` (`openrouter/owl-alpha` by default).
   - Takes the conversation and asks for JSON-only task decomposition.
   - Fallback: local deterministic task set (`Direct answer`, `Critical check`, `Action plan`, `Alternatives`).

2. **Task router**
   - Routes each task to a configured free model in `fusion.panelModels`, round-robin.
   - Each task gets a self-contained worker prompt with the original conversation and assigned task.
   - Partial failures are tolerated.

3. **Synthesis compiler**
   - Successful routed task outputs are sent to `fusion.judgeModel` (`openrouter/owl-alpha` by default), with fallback to `openrouter/free`.
   - If synthesis fails, app returns a local markdown report of successful task outputs.

## Solo fix

Added `RouterManager.sendSolo(...)` so Solo mode uses the selected explicit model instead of the old fallback-router behavior. If user leaves model as Auto, it uses config default.

## UI/config changes

- Renamed `Single` mode to `Solo`.
- Updated sidebar description:
  - Fusion: "Router decomposes prompt into tasks, fans out to free models, then synthesizes."
- Config now supports:
  - `fusion.panelModels`
  - `fusion.plannerModel`
  - `fusion.judgeModel`
  - `fusion.maxTasks`
  - `fusion.maxParallelRequests`
  - `fusion.responseTimeoutSeconds`

## Verification

- `swift build` ✅
- `bash build-app.sh` ✅
- Forbidden OpenRouter Fusion plugin/router grep stays clean ✅

## Remaining note

`maxParallelRequests` is present in config but not yet used for throttling. Current task fanout is bounded by `maxTasks` and panel size, default 5.
