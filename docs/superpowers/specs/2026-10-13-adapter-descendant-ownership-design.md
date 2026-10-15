# Adapter descendant ownership

Status: self-approved. Brian authorized the separate upstream design and repair. Execution: Native.

## Goal and evidence

On Linux without terminal input, Adapter#stop must stop and reap ordinary descendants in the adapter's owned process group before returning. Preserve STOP_GRACE_SECONDS=1.0, direct-child exit status, and the existing PID-based public API. A captured pinned adapter at1da10c6 (SHA256223255ad3a5ffcbc1204c11071665992cdbc22e8e6cdadb829f542c053488e7d) only kills its direct child. A controlled scheduling pause after cleanup starts reproduces a live cleanup SSH child after stop. Latest released v0.3.0 has identical bytes; no released fix exists. Historical CI's precise schedule remains unknown.

## Approach and alternatives

Use a private process group for non-terminal Linux adapters and Linux child-subreaper adoption in the ASR caller. Kill only that group after direct-child completion or forced stop, then reap only adopted children in that group. Serialize wait/stop per owned invocation so concurrent event-loop wait and error cleanup cannot compete for reaping. Keep completed status available to both callers.

Increasing grace or shrinking HNP deadlines is rejected: it cannot guarantee cleanup after forced kill. A separate always-running supervisor is rejected for this slice: it changes adapter PID/exit/event contracts and still needs an outer forced-stop ownership boundary.

## Interfaces and limits

Adapter.new accepts descendant_cleanup: :auto (default), true, or false. Auto enables supervision only on Linux with non-terminal stdin. Explicit true rejects unsupported platforms and terminal input before spawning. False retains existing direct-child behavior. No terminal foreground-group changes are made; interactive adapters retain current behavior and have no new forced-descendant-reaping guarantee. Deliberate process-group escape and SIGKILL of the ASR caller are outside this contract.

Enabling supervision sets the caller's Linux subreaper flag for its remaining lifetime. This is process-global adoption, not permission to signal or reap unrelated processes. Never call wait(-1), never signal the caller's group, and never disable an existing subreaper setting. Embedders that require their original adoption policy can use false. No service deployment or HNP dependency update is included.

## Verification

Real-process tests must force a stopped adapter with an active TERM-resistant child, normal completion with a surviving child, and concurrent wait/stop. Verify absent /proc records and ECHILD, preserved exit status, and an unrelated sentinel still alive and waitable. Use pipes/markers for readiness; preserve one-second grace. Keep mock argument tests on explicit legacy mode to avoid treating invented PIDs as real owned groups.

Run the full upstream suite, then both unchanged HNP real-ASR cases against candidate source and the same controlled-pause driver. Record local identity and distinguish this from unavailable exact CI-image replay. Independent final branch review precedes publication. Brian owns upstream merge; later HNP integration and fresh CI are separate. No release-age exception for a new ASR pin is inferred from the Pi approval.
