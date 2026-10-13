# Adapter descendant ownership implementation plan

Status: self-approved. Execute with superpowers:executing-plans (Native). Final independent review belongs to the PR workflow.

Goal: stop and reap owned Linux non-terminal adapter descendants without changing the one-second grace or unrelated process ownership.
Architecture: private group, process-global Linux subreaper adoption, per-invocation wait/stop serialization; retain explicit legacy mode and interactive behavior.
Spec: ../specs/2026-10-13-adapter-descendant-ownership-design.md
Tech stack: Ruby Process, Mutex, Linux prctl through standard-library Fiddle, Minitest.

## Constraints and review focus

- STOP_GRACE_SECONDS=1.0 unchanged; no broad wait(-1) or caller-group signals.
- Unrelated children, concurrent wait/stop, normal adapter exit with leftover descendants, TERM-resistant and stopped children, and legacy/interactive behavior require coverage.
- Terminal behavior stays legacy. Non-Linux explicit supervision fails before spawn. Adoption is process-global and opt-out is documented.
- Original failures remain recorded; local tests do not replace exact-head HNP CI recovery.

## Task1: ownership boundary and behavioral proof

- [ ] Add test/adapter_ownership_test.rb with real executable fixtures and observable readiness. Force STOP after child-ready, then assert stop reaps both PIDs while unrelated sentinel remains owned/alive; normal wait preserves exit17 and reaps leftovers; concurrent wait/stop returns one stored status; legacy mode remains opt-out.
- [ ] Run new file against baseline and retain RED result. Baseline upstream suite77/491 passed after public locked gems were installed in private /tmp path; original absent minitest/mock prerequisite failure remains recorded.
- [ ] Add lib/agent_session_registry/owned_adapter_process.rb for Linux subreaper setup, serialized direct-PID collection, owned-group KILL and group-scoped adopted-child draining. Adapter delegates only supervised PIDs; no change to legacy wait/stop. Validate supervision arguments and terminal/platform boundary before spawn.
- [ ] Run new file GREEN. Update only existing spawn-argument mocks to explicit legacy mode and run complete bundle exec rake test, zero errors/skips.
- [ ] Document ownership, terminal, platform, adoption and detached-descendant limits in README; preserve unchanged stop grace.
- [ ] Run both unchanged HNP real-ASR cases with ASR_SOURCE candidate and ASR_INTEGRATION_REQUIRED=1; rerun the controlled-pause driver against candidate. Require all reaping assertions pass before original fixture fallback cleanup.
- [ ] Inspect complete diff and git diff --check, commit explicit files with z-commit. Mark plan progress.
- [ ] Run final fresh-context review through z-pull-request, fix material findings and rerun relevant verification, publish first-party GitHub PR and arm native monitoring. No merge, deployment or HNP pin change.
