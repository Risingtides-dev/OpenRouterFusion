# OpenRouterFusion Agent Swarm

## Project
SwiftUI macOS chat app at /Users/risingtidesdev/dev/OpenRouterFusion

## Workspace
- Shared findings: /Users/risingtidesdev/dev/OpenRouterFusion/.swarm/findings/
- Status file: /Users/risingtidesdev/dev/OpenRouterFusion/.swarm/status.md
- Source code: /Users/risingtidesdev/dev/OpenRouterFusion/Sources/OpenRouterFusion/

## Rules
1. Always run `swift build` after any code changes
2. Write findings to .swarm/findings/<agent-name>.md
3. Read other agents' findings before starting your phase
4. Update .swarm/status.md with your phase completion
5. Use `openrouter/owl-alpha` as the model

## Workflow
1. tester → finds bugs → writes findings/tester.md
2. debugger → reads tester.md → fixes bugs → writes findings/debugger.md
3. reviewer → reads all code → writes findings/reviewer.md
4. refiner → reads reviewer.md → implements fixes → writes findings/refiner.md
5. architect → reads everything → writes findings/architect.md
