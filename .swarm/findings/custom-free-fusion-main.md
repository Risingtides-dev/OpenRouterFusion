# Custom Free Fusion Implementation

Implemented in the main session after worker harness instability.

## What changed
- Removed dependency on OpenRouter's server-side Fusion Router/plugin path.
- Added custom `RouterManager.sendFusion(...)` that:
  - reads `fusionPanel` from `ModelConfig.json`
  - filters to free model IDs / `openrouter/free` / `openrouter/owl-alpha`
  - sends non-streaming panel requests to all configured free models in parallel
  - tolerates partial failures; one successful panel response is enough
  - asks a configured free judge model to synthesize the successful outputs
  - falls back to deterministic local markdown output if the judge fails
- Added `sendFast(...)` using `openrouter/free`.
- Added `RouterManager.ChatMode`: Fast / Fusion / Single.
- Wired `ChatViewModel.sendMessage()` by mode.
- Updated `SidebarView` with mode selector and free fusion panel display.
- Synced `Resources/ModelConfig.json` and `Sources/OpenRouterFusion/Resources/ModelConfig.json`.

## Validation
- `swift build` passed.
- `bash build-app.sh` passed.
- grep validation confirmed no server-side fusion plugin/router literals remain in Sources/Resources/Package.swift.
- `OpenRouterFusion.app` launches successfully.

## Residual notes
- Panel calls are non-streaming, then final synthesized output is emitted to the existing streaming display as one chunk.
- This is the correct custom free fusion baseline; later PiSwift/PiPartyKit can power in-app agents separately.
