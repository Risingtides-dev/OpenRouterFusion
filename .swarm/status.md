# OpenRouterFusion Crew Status

## Current canonical plan

Read: `/Users/risingtidesdev/dev/OpenRouterFusion/PLAN.md`

## Latest direction

- Product modes are **Fast | Fusion | Solo**.
- **Fast** = `openrouter/free`.
- **Fusion** = our custom Fusion Router algorithm:
  1. decompose prompt into tasks/angles,
  2. route tasks across configured free models,
  3. collect successful partials and tolerate failures,
  4. synthesize one answer.
- **Solo** = selected explicit model.
- Do **not** use OpenRouter `openrouter/fusion` plugin/router.

## Isolation rule

OpenRouterFusion/PiParty must be 100% independent from the user's real Pi/Thoth runtime:

- no global `~/.pi`,
- no Thoth memories,
- no real/global pi-messenger mesh,
- no global agents/extensions/skills/prompts/config/sessions.

Future runtime should be a fork/vendor of PiSwift as `PiPartyKit`, with app-owned paths only.

## Done

- task-30 custom free fusion engine ✅
- task-31 app-local isolated Pi sessions list ✅
- task-32 Fusion Router v2 task decomposition/routing/synthesis ✅

## Ready / next

- task-33 Swift LSP integration via SourceKit-LSP
- task-34 PiPartyKit fork/vendor PiSwift as independent runtime
- task-35 Native MarkdownView/swift-markdown renderer

## Build baseline

`swift build` ✅
`bash build-app.sh` ✅

Known warning: `NSLock` in async context under Swift 6 strict mode; currently still builds.
