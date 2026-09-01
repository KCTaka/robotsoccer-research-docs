# ADR-006: Runtime, Container, and Compute Architecture

- Status: Accepted
- Decision date: 2026-09-01
- Evidence last verified: 2026-09-01
- Scope: Topic 9
- Depends on: [ADR-001](ADR-001-real-time-actuation-and-hardware-abstraction.md), [ADR-002](ADR-002-safety-and-fault-management.md), [ADR-003](ADR-003-zenoh-middleware.md), [ADR-005](ADR-005-behavior-game-state-and-team-networking.md)
- Research baseline: [Topic 9](../research/topic-9-runtime-and-containers.md)

## Context

Every accepted decision so far assumed a runtime that could deliver a 5 ms cycle, run CUDA and
TensorRT, host a supervised Zenoh router, and receive UDP broadcast. Topic 9 established whether such
a runtime exists on the target platform, and found one hard platform constraint and one conflict
between two already-accepted ADRs.

### The platform constraint

REP-2000's Jazzy Jalisco targeted-platform table has a **blank cell at arm64 x Ubuntu Jammy 22.04**.
Jazzy on arm64 is a targeted platform on Ubuntu Noble 24.04 and nowhere else, except Tier 3
source-only entries for Debian Bookworm and OpenEmbedded. There is no arm64 Jammy entry at any tier.

JetPack 6 is a Ubuntu 22.04 platform: its kernel source tree is `kernel-jammy-src` and its default
container base image is `ubuntu:22.04`. JetPack 7 moves to `ubuntu:24.04`.

**Therefore no ROS 2 Jazzy arm64 binary packages exist for the JetPack 6 host operating system, at any
support tier.** Containerisation is not a deployment convenience for this project; on JetPack 6 it is
the only supported route to the ROS 2 distribution that ADR-003 already fixed.

A Ubuntu 24.04 container on a JetPack 6 host is a published, dated, CUDA-capable configuration. The
mechanism is the split between kernel driver and userspace runtime: the NVIDIA driver stays on the
host, the CUDA userspace lives in the container, and the NVIDIA Container Toolkit injects the former
into the latter.

### The real-time constraint

NVIDIA has shipped a `PREEMPT_RT` kernel package for Jetson since L4T r35, installable by apt and
switchable at boot. It describes that support as **"Developer-Preview quality"** on Jetson Orin AGX,
NX, and Nano, publishes no latency distribution, and states that "the UEFI runtime services are
enabled by default which may increase latency". Building out-of-tree modules against it requires
`IGNORE_PREEMPT_RT_PRESENCE=1`, a flag that exists because of the NVIDIA display driver.

Upstream, `arch/arm64/Kconfig` carries `select ARCH_SUPPORTS_RT` and `kernel/Kconfig.preempt` carries
`config PREEMPT_RT`, unchanged across v6.8, v6.11, and v6.12. Real-time preemption on arm64 is an
upstream kernel option, not an out-of-tree patch requirement. The uncertainty is entirely about
NVIDIA's platform integration, not about the kernel feature.

This matters less than it appears, because ADR-001 placed the 200 Hz physical exchange under **STM32**
scheduling and ADR-002 gave the Embedded Safety Agent independent command-loss authority. A missed
Jetson cycle degrades control quality; it cannot by itself produce an uncontained hazard. That
containment was designed two ADRs earlier and is what makes an unqualified vendor kernel tolerable
here at all. It is not a reason to skip measuring it.

### The conflict between ADR-003 and ADR-005

ADR-003 requires onboard Zenoh peers to reach the supervised robot-local `rmw_zenohd` router over
**explicit loopback TCP**. ADR-005-12 requires the competition network gateway to run in the **host
network namespace**, because a default bridge network does not receive host-subnet broadcasts and that
failure is silent.

Loopback is per network namespace. These two accepted decisions did not conflict within either topic
and do conflict at deployment. Resolving it is one of the reasons this ADR exists; see §6.

## Decision

### 1. Containers are mandatory, and the container OS is Ubuntu 24.04 Noble

No ROS 2 installation exists on the host. The host provides the kernel, the NVIDIA driver, the
container runtime, and systemd. Everything else runs in a container built on Ubuntu 24.04.

This is a consequence of the platform constraint above, not a preference. Building all of ROS 2 from
source on Jammy is an unsupported configuration with no upstream binary guarantee and would contradict
ADR-003's requirement to pin "identical compatible package versions on `arm64` and `amd64`".

### 2. Baseline JetPack 6.2 (L4T r36.4.x) with a Noble container

JetPack 7 removes the host/container OS mismatch and is the eventual destination. It is not the
baseline today because ZED SDK, TensorRT, and Orin module support on L4T r38 are all **NR**.

The migration trigger is explicit: move to JetPack 7 when every closed-source dependency has a **named
supported version** on r38. Not when JetPack 7 is merely available, and not on the assumption that
support will arrive.

### 3. Docker with the NVIDIA container runtime

Docker is the configuration NVIDIA and the Jetson container ecosystem document and test. The NVIDIA
Container Toolkit does have active Podman support and is converging on CDI, which is runtime-agnostic,
so this is a revisitable decision rather than a structural one.

Podman's rootless advantage is largely neutralised here. This robot requires `CAP_SYS_NICE`, elevated
`rtprio` and `memlock` limits, specific device access, and host networking. The privilege surface is
set by those requirements, not by the daemon model.

### 4. Containers are split by failure domain and privilege

Container boundaries follow what can fail independently and what needs elevated privilege, not code
structure or team ownership.

| Container      | Contents                                                      | Distinguishing requirement                                                       |
| -------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `control`      | `ros2_control` node, `HumanoidActuatorSystem`, `SafetyKernel` | `CAP_SYS_NICE`, `rtprio`, `memlock`, pinned to isolated cores, STM32 device node |
| `perception`   | ZED SDK, detector, TensorRT                                   | GPU access, largest image, highest restart cost                                  |
| `estimation`   | Tier 0 and Tier 1 estimators, TF                              | No GPU, no elevated privilege                                                    |
| `behaviour`    | Rule-state supervisor, behaviour tree, role arbitration       | No GPU, no elevated privilege                                                    |
| `net-gateway`  | GameController and team sockets                               | Sole owner of every competition socket (ADR-005-09)                              |
| `zenoh-router` | `rmw_zenohd`                                                  | Supervised per ADR-003                                                           |

### 5. systemd supervises; `ros2 launch` composes

**`ros2 launch` is not a process supervisor.** It provides no bounded restart backoff, no
readiness-gated dependency ordering, no health-based restart decision, and no supervision that
survives its own death. ADR-003 already requires that "the process supervisor applies bounded restart
backoff and exposes router process state, connection state, reconnect count, and configuration
identity". `ros2 launch` alone cannot satisfy that clause.

The layering is:

| Layer            | Tool                                        | Responsibility                                                                                                                     |
| ---------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Host supervision | systemd                                     | Starts containers with correct resource limits and ordering; bounded restart backoff; survives container death; owns the boot path |
| Process model    | **One long-running process per container**  | Container liveness equals process liveness; removes the need for an in-container supervisor such as `s6-overlay`                   |
| Node composition | `ros2 launch` plus a lifecycle orchestrator | Composes nodes and drives managed-lifecycle transitions in dependency order                                                        |

Startup ordering is a **readiness** problem, not a sequencing problem. A started router is not a
connectable router. The real ordering constraint is already stated as an ADR-001 and ADR-002
invariant: configuration, calibration, protocol, and safety identities must match before actuator
power can be armed. The managed-lifecycle contract mandated by ADR-005-10 generalises: `configure`
validates and acquires resources so failure is loud and early; `activate` starts producing.

Router restart is a supervision event, never a motion event. ADR-003's rule that router loss "never
triggers automatic motion when communication returns" is unchanged by containerisation.

### 6. All ROS containers run in the host network namespace

This resolves the ADR-003 / ADR-005-12 conflict stated in the Context.

**The rationale matters more than the choice.** The trust boundary established by ADR-005-09 is a
_process_ boundary: one gateway process owns every competition socket. It is enforced by binding
discipline and by the validation ladder in Topic 8 §5.1, not by network-namespace isolation.
Namespace isolation was never the enforcement mechanism and cannot be, because ADR-005-12 places the
gateway itself outside any isolated namespace. Preserving namespace separation for the remaining
containers would therefore protect a property that does not actually enforce anything, while forcing
the gateway onto a non-loopback link that ADR-003 requires to be mutually authenticated TLS — paying
latency and complexity on an on-box hop for no security gain.

The accepted costs are stated plainly: there is no network-namespace isolation between the project's
own processes, and the port namespace is shared, so port conflicts between containers become real and
must be managed by convention. On a single-purpose robot with a fixed, audited process set, that is
the correct trade.

ADR-005-12's testing requirement is unchanged and becomes more important: broadcast reception is
verified against the deployed container network configuration, never over loopback, and re-verified
whenever that configuration changes.

### 7. CPU isolation is mandatory; the RT kernel is conditional

The following are mandatory and independent of kernel choice:

- Host kernel command line: `isolcpus`, `nohz_full`, `rcu_nocbs`, and `irqaffinity` configured to
  reserve cores for the control container
- UEFI runtime services disabled
- The control container pinned to the isolated cores via `--cpuset-cpus`
- `mlockall(MCL_CURRENT | MCL_FUTURE)` in the real-time process
- `SCHED_FIFO` for the real-time thread

The NVIDIA `PREEMPT_RT` kernel is adopted **only if gate 5 shows a measured benefit**. The default is
the generic kernel. Adopting a kernel the vendor labels Developer-Preview, for which no latency data
is published, purely because it exists, is faith rather than evidence.

Core counts and a concrete core-allocation budget are deliberately not fixed here. They depend on the
Jetson module, which depends on the physical envelope, which is still open at Topic 3 Model Gate 0.

### 8. Real-time privileges are asserted at startup, and failure is a startup failure

A container defaults to no `CAP_SYS_NICE` and an `rtprio` ulimit of 0. `sched_setscheduler(SCHED_FIFO)`
then returns `EPERM`, and an unchecked return value leaves the process **running at normal priority
while appearing healthy**. It will miss deadlines only under load, which is the worst possible time to
discover it.

The control process therefore reads back and reports, at startup: scheduler policy, thread priority,
the `mlockall` result, `RLIMIT_MEMLOCK`, `RLIMIT_RTPRIO`, and `/proc/sys/kernel/sched_rt_runtime_us`.
Any value outside its required range is a startup failure. There is no silent downgrade path.

`sched_rt_runtime_us` is called out explicitly because it is host-wide, defaults to throttling RT
tasks below 100 % of a period, and is invisible from inside the container.

### 9. Minimum device privilege

The `perception` container receives the specific ZED device node through a stable udev rule. The
`control` container receives the specific STM32 device node the same way. `--privileged` is prohibited
and whole-USB-bus passthrough is prohibited.

The gateway already holds a network-namespace exception. A second blanket exception is not granted on
top of it.

### 10. Image identity is release identity

- Every image and every base image is referenced by **digest**. A `FROM ubuntu:24.04` tag is mutable
  and would make ADR-003's digest guarantee decorative.
- The image tag encodes the L4T version it was built against, following the published convention
  (`jazzy-ros-base-r36.4.4-cu128-24.04`).
- The running image digest and the host L4T version are reported at startup and participate in the
  ADR-003 identity interlock. A mismatch keeps motion disabled.
- Runtime images contain no build toolchain.

ADR-003 already lists "Container image digests and host kernel baseline" among the immutable
release-identity artifacts. This section implements that requirement rather than creating it.

### 11. CUDA, TensorRT, and ZED SDK layers build natively on arm64

QEMU binfmt emulation is permitted for cheap layers only. Emulated compilation of the CUDA and
TensorRT layers is slow enough to distort the development loop, and native arm64 runners avoid it
entirely. Both architectures build from one manifest so that ADR-003's cross-architecture version
parity holds by construction rather than by inspection.

## Consequences

### Positive

- The Jazzy platform requirement is satisfied on a supported configuration rather than an improvised
  one, and the same container runs on the amd64 workstation and the arm64 robot.
- Container image digest becomes part of the existing ADR-003 identity interlock at no extra
  machinery cost.
- Failure-domain container boundaries mean a perception crash does not restart the control loop, and a
  router restart does not restart anything else.
- The `EPERM` assertion in §8 converts the single most likely silent real-time failure into a loud
  startup failure.
- Choosing the generic kernel by default means the RT kernel must earn its place with measurements
  instead of being adopted on vendor availability.

### Costs and constraints

- No network-namespace isolation between the project's own containers, and a shared port namespace
  (§6). Port assignment becomes a convention that must be documented and checked.
- A 5+ GB perception image makes deployment bandwidth and on-robot storage real constraints.
- Native arm64 build capacity is now a CI requirement, not an optimisation.
- Digest pinning means base-image security updates are an explicit, reviewed action rather than an
  automatic one. That is the intent, and it carries an obligation to actually perform the reviews.
- The RT kernel decision is deferred to measurement, so the timing risk stays open until gates 4 and 5
  produce numbers.
- Unified memory means core pinning does not partition memory bandwidth or last-level cache. The
  largest remaining timing risk is not addressed by any decision in this ADR and is handed to gate 4.

## Rejected alternatives

| Alternative                                                              | Why rejected                                                                                                                                                                           |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ROS 2 installed directly on the JetPack 6 host                           | No Jazzy arm64 binaries exist for Ubuntu 22.04 at any support tier.                                                                                                                    |
| Build ROS 2 Jazzy from source on Jammy                                   | Unsupported configuration; no upstream binary guarantee; contradicts ADR-003 cross-architecture version parity.                                                                        |
| Downgrade to a ROS 2 distribution supported on Jammy                     | Reopens ADR-003, which pins Jazzy and `rmw_zenoh_cpp` 0.2.10. Not in scope for a runtime decision.                                                                                     |
| JetPack 7 as today's baseline                                            | ZED SDK, TensorRT, and Orin module support on L4T r38 are all NR. Adopting it now bets the platform on an unverified support matrix.                                                   |
| Podman                                                                   | Off the documented Jetson path; its rootless advantage is neutralised by the privilege requirements this robot has anyway. Revisitable once CDI mode is the documented Jetson default. |
| One container for the whole stack                                        | A perception crash would take down the control loop; the privilege set would be the union of every container's, defeating §9.                                                          |
| `ros2 launch` as the supervisor                                          | Provides no bounded restart backoff, readiness gating, or health-based restart. Cannot satisfy ADR-003's supervision clause.                                                           |
| `s6-overlay` or systemd inside containers                                | Unnecessary under the one-process-per-container rule, and it hides which process actually failed from the orchestrator.                                                                |
| Gateway reaches the router over authenticated TLS on a non-loopback link | Pays TLS latency and certificate management on an on-box hop to preserve a namespace isolation property that does not enforce the ADR-005-09 trust boundary.                           |
| Adopt the NVIDIA RT kernel unconditionally                               | Vendor labels it Developer-Preview on Orin and publishes no latency data. Adoption without measurement is faith.                                                                       |
| Tolerate a failed `sched_setscheduler` and continue at normal priority   | Produces a system that looks healthy and misses deadlines only under load.                                                                                                             |
| Mutable image tags with a pinned application version                     | ADR-003 requires digest-level release identity; a mutable base tag silently breaks it.                                                                                                 |
| Build everything under QEMU emulation                                    | Emulated CUDA and TensorRT compilation is slow enough to distort the development loop.                                                                                                 |

## Verification gates

Topic 9 §7 defines gates 1-9 in full. The binding summary:

| #   | Gate                                                                                                                                                                                               |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Platform selection: a named supported version on the candidate JetPack for every closed-source dependency.                                                                                         |
| 2   | The full stack builds and runs in a Noble container on the selected JetPack, with no host ROS installation.                                                                                        |
| 3   | Real-time privilege assertion: every value in §8 read back and reported; a failure is a startup failure.                                                                                           |
| 4   | Cycle timing under full perception, network-flood, and logging load for a full match duration. Distribution and worst observed value, not the mean. Shared with Topic 5 gate 6 and Topic 8 gate 5. |
| 5   | Gate 4 repeated on generic and RT kernels, with UEFI runtime services enabled and disabled. Quantified difference decides §7.                                                                      |
| 6   | Topic 8 gate 3 (broadcast reception) run against the deployed container network configuration.                                                                                                     |
| 7   | Each container killed in turn during simulated play: bounded backoff, no restart storm, no automatic re-arm.                                                                                       |
| 8   | Digest pinning verified end to end; ZED SDK redistribution terms assessed against the open-source publication plan.                                                                                |
| 9   | The same manifest built natively and under emulation; artifacts functionally identical, build times recorded.                                                                                      |

## References

- [Topic 9 research baseline](../research/topic-9-runtime-and-containers.md) — full evidence, verbatim source quotations, and open gaps.
- REP-2000, Jazzy Jalisco targeted-platform table.
- `dusty-nv/jetson-containers` `README.md` and `docs/build.md` — JetPack/L4T/CUDA mapping and published Jazzy Noble images.
- NVIDIA _Jetson Linux Developer Guide r36.4.3_, Kernel Customization — RT kernel availability, quality statement, and UEFI latency note.
- `NVIDIA/nvidia-container-toolkit` `README.md` and `CHANGELOG.md` — host-driver / container-CUDA split, CDI, CSV mode, Podman support.
- `torvalds/linux` `arch/arm64/Kconfig` and `kernel/Kconfig.preempt`, tags v6.8, v6.11, v6.12.
