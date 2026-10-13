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

- [x] Add test/adapter_ownership_test.rb with real executable fixtures and observable readiness. Force STOP after child-ready, then assert stop reaps both PIDs while unrelated sentinel remains owned/alive; normal wait preserves exit17 and reaps leftovers; concurrent wait/stop returns one stored status; legacy mode remains opt-out.
- [x] Run new file against baseline and retain RED result. Baseline upstream suite77/491 passed after public locked gems were installed in private /tmp path; original absent minitest/mock prerequisite failure remains recorded.
- [x] Add lib/agent_session_registry/owned_adapter_process.rb for Linux subreaper setup, serialized direct-PID collection, owned-group KILL and group-scoped adopted-child draining. Adapter delegates only supervised PIDs; no change to legacy wait/stop. Validate supervision arguments and terminal/platform boundary before spawn.
- [x] Run new file GREEN. Update only existing spawn-argument mocks to explicit legacy mode and run complete bundle exec rake test, zero errors/skips.
- [x] Document ownership, terminal, platform, adoption and detached-descendant limits in README; preserve unchanged stop grace.
- [x] Run both unchanged HNP real-ASR cases with ASR_SOURCE candidate and ASR_INTEGRATION_REQUIRED=1; rerun the controlled-pause driver against candidate. Require all reaping assertions pass before original fixture fallback cleanup.
- [x] Inspect complete diff and git diff --check, commit explicit files with z-commit. Mark plan progress.

## Execution evidence and rulings

- Ruling: declare fiddle in Gemfile and lock1.1.8. Ruby4 removes it from default gems; Bundler otherwise rejects the prctl boundary. No existing dependency version changed. Installation uses private /tmp/hnp-ci-speed/asr-stop-gems.
- Baseline:77 upstream scenarios/491 assertions passed. New forced-stop and normal-exit cases then failed with surviving owned children,2 cases/12 assertions/2 failures. Original RED evidence was not replaced by retries.
- Final upstream suite:83 scenarios/534 assertions, zero failures/errors/skips, Ruby4.0.7 Linux. Ownership file has6 cases/43 assertions, including unrelated direct and adopted children, nested descendants, concurrent wait/stop, opt-out and PTY behavior.
- Unchanged HNP actual integration cases against candidate:2 cases/5 assertions, zero failures/errors/skips. Controlled cleanup scheduling pause:1 case/3 assertions passed; pause0.379466484s, stop return1.007447922s. Original pinned source failed the identical driver. No test deadline was changed.
- These are local closest-boundary results, not exact failed CI-image replay, new-head HNP CI or live deployment. Published upstream merge and later supported HNP source acquisition remain separate gates.
- [ ] Run final fresh-context review through z-pull-request, fix material findings and rerun relevant verification, publish first-party GitHub PR and arm native monitoring. No merge, deployment or HNP pin change.
