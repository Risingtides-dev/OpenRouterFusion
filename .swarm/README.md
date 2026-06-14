# OpenRouterFusion Agent Swarm Workspace

## Active Agents
- **tester** — Builds, runs, stress-tests the app. Writes findings to findings/tester.md
- **debugger** — Reads findings, diagnoses bugs, writes fixes. Logs to findings/debugger.md
- **reviewer** — Audits code quality. Writes findings to findings/reviewer.md
- **refiner** — Implements reviewer suggestions. Logs to findings/refiner.md
- **architect** — Evaluates overall architecture. Writes findings to findings/architect.md

## Workflow
1. Tester runs → writes findings
2. Debugger reads findings → fixes bugs → writes log
3. Reviewer reads code + fixes → writes quality report
4. Refiner reads review → implements improvements → writes log
5. Architect reads everything → proposes structural improvements

## Communication
- All agents write to `findings/` directory
- Each agent reads previous agents' findings before starting
- Use `status.md` to track current phase

## Model
All agents use `openrouter/owl-alpha` unless otherwise specified.
