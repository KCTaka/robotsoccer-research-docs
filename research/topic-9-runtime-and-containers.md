# Topic 9 Research: Runtime, Container, and Compute Architecture

- Status: Complete research baseline; update before any Topic 9 architecture revision
- Evidence last verified: 2026-09-01
- Scope: Research input for Topic 9; architecture proposal presented separately
- Canonical decisions: [ADR-001](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md), [ADR-002](../architecture/ADR-002-safety-and-fault-management.md), [ADR-003](../architecture/ADR-003-zenoh-middleware.md), [ADR-005](../architecture/ADR-005-behavior-game-state-and-team-networking.md)
- Related research: [Topic 4](topic-4-sensors-timing-state-estimation.md), [Topic 5](topic-5-perception-pipeline.md), [Topic 8](topic-8-gamecontroller-networking.md)

## Purpose and evidence policy

Every prior topic assumed a runtime that can deliver a 5 ms cycle, run CUDA and TensorRT, host a
supervised Zenoh router, and receive UDP broadcasts. This document establishes whether that runtime
exists on the target platform, and on what terms.

Evidence tags follow the Topic 4-8 convention:

| Tag            | Meaning                                                                                           |
| -------------- | ------------------------------------------------------------------------------------------------- |
| **[Primary]**  | Read directly from a source file, Kconfig, manifest, or vendor documentation page at a named URL. |
| **[Upstream]** | Stated by the maintainer or vendor in their own documentation.                                    |
| **[Derived]**  | Computed or concluded here from tagged inputs. Reasoning shown.                                   |
| **[Project]**  | A target or constraint set by this project.                                                       |
| **NR**         | **Not reported.** Never means zero.                                                               |

**Scope note.** This topic does not select a Jetson module. The physical envelope, mass, and power
budget remain open at Topic 3 Model Gate 0, and module choice depends on them. Everything below is
stated so that it holds for the Orin family and identifies exactly which numbers become computable once
the module is fixed.

## Confirmed project inputs

| Input              | Value                                                                                          | Source                 |
| ------------------ | ---------------------------------------------------------------------------------------------- | ---------------------- |
| Compute            | NVIDIA Jetson Orin, module **not selected**                                                    | [Project]              |
| ROS 2 distribution | Jazzy Jalisco                                                                                  | [Project]              |
| Middleware         | `rmw_zenoh_cpp`, supervised robot-local `rmw_zenohd` router, loopback TCP, no multicast        | ADR-003                |
| Control loop       | 200 Hz, 5 ms, physically scheduled by the STM32; no ROS, no allocation, no filesystem in-cycle | ADR-001                |
| Release manifest   | Must already pin container image digests and the host kernel baseline                          | ADR-003                |
| Perception         | ZED SDK (closed source), TensorRT, CUDA                                                        | Topic 5                |
| Network gateway    | **Must be in the host network namespace** to receive UDP broadcast                             | ADR-005-12, Topic 8 §6 |
| Licensing          | AGPL and GPL excluded for distributed application code                                         | Topic 5 §4.1.1         |

---

## 1. The platform collision, and why containers are not optional

This is the finding that determines the rest of the topic.

### 1.1 What ROS 2 Jazzy actually supports on arm64

From REP-2000, the Jazzy Jalisco targeted-platform table, read verbatim [Primary]:

| Architecture | Ubuntu Noble (24.04)   | Windows 10      | RHEL 9             | **Ubuntu Jammy (22.04)** | macOS        | Debian Bookworm | OpenEmbedded |
| ------------ | ---------------------- | --------------- | ------------------ | ------------------------ | ------------ | --------------- | ------------ |
| amd64        | Tier 1 `[d][a][s]`     | Tier 1 `[a][s]` | Tier 2 `[d][a][s]` | Tier 3 `[s]`             | Tier 3 `[s]` | Tier 3 `[s]`    | Tier 3 `[s]` |
| **arm64**    | **Tier 1 `[d][a][s]`** | —               | —                  | **(blank)**              | —            | Tier 3 `[s]`    | Tier 3 `[s]` |
| arm32        | Tier 3 `[s]`           | —               | —                  | —                        | —            | Tier 3 `[s]`    | Tier 3 `[s]` |

where `[d]` means distribution packages are provided, `[a]` a binary archive, and `[s]` compilation from
source.

**The arm64 / Ubuntu Jammy cell is blank.** Jazzy on arm64 is a targeted platform on Ubuntu 24.04 and
on nothing else except Tier 3 source builds for Debian Bookworm and OpenEmbedded. There is no Tier 3
source entry for arm64 on Jammy at all.

### 1.2 What JetPack actually ships

| JetPack        | L4T         | Kernel source directory | Default container base | CUDA     |
| -------------- | ----------- | ----------------------- | ---------------------- | -------- |
| 6.0 DP         | r36.2.0     | `kernel-jammy-src`      | `ubuntu:22.04`         | 12.2     |
| 6.0 GA         | r36.3       | `kernel-jammy-src`      | `ubuntu:22.04`         | 12.4     |
| **6.1+ / 6.2** | **r36.4.x** | `kernel-jammy-src`      | `ubuntu:22.04`         | **12.6** |
| **7.0+**       | **r38.1.x** | NR                      | **`ubuntu:24.04`**     | **13.0** |

[Primary — base image and CUDA mapping from `dusty-nv/jetson-containers` `docs/build.md`; kernel source
directory name from the NVIDIA Jetson Linux Developer Guide r36.4.3, which instructs
`export KERNEL_HEADERS=$PWD/kernel/kernel-jammy-src`]

**JetPack 6 is a Ubuntu 22.04 platform.** Combined with §1.1: _there are no ROS 2 Jazzy arm64 binary
packages for the JetPack 6 host operating system, at any support tier._

### 1.3 The resolution, and why it is load-bearing

A Ubuntu 24.04 container on a JetPack 6 host is a published, working configuration.

> "Ubuntu 24.04 containers for JetPack 6 and JetPack 7 are now available (with CUDA support)"
> [Upstream, `jetson-containers` README]

Built against `LSB_RELEASE=24.04 L4T_VERSION=36.4.4 CUDA_VERSION=13.1 CUDNN_VERSION=9.17`, and
runnable "from JetPack 6.1+" [Primary, `jetson-containers` `docs/build.md` §"24.04 Containers"]. The
published list includes:

| Image                                            | Size   |
| ------------------------------------------------ | ------ |
| `dustynv/ros:jazzy-ros-base-r36.4.4-cu128-24.04` | 5.1 GB |
| `dustynv/ros:jazzy-desktop-r36.4.4-cu128-24.04`  | 5.9 GB |

[Primary, same document, dated 2025-03-03]

The mechanism is the split between kernel driver and userspace runtime:

> "Note that you do not need to install the CUDA Toolkit on the host system, but the NVIDIA driver
> needs to be installed" [Upstream, NVIDIA Container Toolkit README]

and, for Jetson specifically:

> "On JetPack 6 (L4T r36.x) and JetPack 7 (L4T r38.x), the CUDA components will automatically be
> installed on top of your base image if required." [Primary, `jetson-containers` `docs/build.md`]

**Derived conclusion.** Containerisation is not a deployment convenience for this project. On JetPack 6
it is _the only route to supported ROS 2 Jazzy arm64 binaries_. The alternatives are building all of
ROS 2 from source on Jammy — an unsupported configuration with no upstream binary guarantee, which
contradicts ADR-003's requirement to pin "identical compatible package versions on `arm64` and
`amd64`" — or moving to JetPack 7, where the host is already Noble and the mismatch disappears.

This also means the container image is a **release identity artifact**, which ADR-003 already
anticipated by requiring container image digests in the release manifest.

### 1.4 The JetPack 6 versus JetPack 7 question

|                             | JetPack 6.2 (L4T r36.4.x)    | JetPack 7.x (L4T r38.1.x)                                                                                                     |
| --------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Host Ubuntu                 | 22.04                        | 24.04 [Primary, container base]                                                                                               |
| Jazzy host-native           | **No** (§1.1)                | Yes                                                                                                                           |
| CUDA                        | 12.6                         | 13.0                                                                                                                          |
| Noble container support     | Yes, published and dated     | Yes, native                                                                                                                   |
| RT kernel quality statement | **Developer-Preview** (§2.2) | **NR**                                                                                                                        |
| Maturity                    | Multiple point releases      | Newer; "Jetson Orin now receives ARM SBSA CUDA in CUDA 13.2 ... requires JetPack 7.2 with CUDA driver R595 minimum" [Primary] |

This is a genuine fork and it is **not resolvable from documentation**. It depends on whether the ZED
SDK, TensorRT versions, and the chosen Orin module are supported on r38 — all currently **NR** — and it
is gate 1.

---

## 2. Real-time kernel

### 2.1 Upstream status

`arch/arm64/Kconfig` contains `select ARCH_SUPPORTS_RT`, and `kernel/Kconfig.preempt` contains
`config PREEMPT_RT` with `depends on EXPERT && ARCH_SUPPORTS_RT`. Both are present unchanged in v6.8,
v6.11, and v6.12 [Primary, `torvalds/linux`]. Real-time preemption on arm64 is therefore an upstream
kernel configuration option, not an out-of-tree patch requirement, on these versions.

### 2.2 What NVIDIA actually ships and says

From the NVIDIA Jetson Linux Developer Guide r36.4.3, Kernel Customization page [Primary]:

| Statement          | Verbatim                                                                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Availability       | "Real-Time Kernel Package # Starting with release 35."                                                                                            |
| **Quality**        | "Real-Time Kernel support is provided with **Developer-Preview quality** for the following platforms: Jetson Orin AGX, Jetson Orin NX and Nano"   |
| Installation       | "The real-time (RT) kernel can be installed with a Debian package management-based OTA on Jetson devices" — via an apt source configuration       |
| Switching          | Documented switch "to `real-time` for the real-time kernel, or to `primary` for the generic kernel" without reinstalling packages                 |
| **Latency caveat** | "The UEFI runtime services are enabled by default **which may increase latency**."                                                                |
| Build friction     | Building out-of-tree modules against an RT kernel requires `export IGNORE_PREEMPT_RT_PRESENCE=1`, a flag that "pertains to the nvdisplay drivers" |

Three things follow, and they matter more than the availability itself.

1. **NVIDIA does not call this production quality on Orin.** "Developer-Preview" is the vendor's own
   term. No latency distribution, worst-case figure, or qualification result is published. Every
   timing number for this platform is **NR** until measured here.
2. **The RT kernel and the NVIDIA display stack are in tension.** An explicit override flag exists
   solely to let the display driver build against a PREEMPT_RT kernel. A robot has no display
   requirement, so this is a reason to strip the display stack rather than a blocker — but it is
   evidence that the RT configuration is not the well-trodden path on this platform.
3. **UEFI runtime services are on by default and NVIDIA says they may increase latency.** This is a
   concrete, actionable configuration item, and it is exactly the class of platform detail that does
   not appear in a benchmark run on a developer kit.

### 2.3 Why this is a jitter risk rather than a safety risk

ADR-001 placed the 200 Hz physical exchange under **STM32 scheduling**, not Jetson scheduling, and
ADR-002 gave the Embedded Safety Agent independent authority over command-loss detection with a local
damping-then-disable response.

**Derived consequence.** If the Jetson misses a cycle because of scheduler jitter, the STM32 observes a
missing command and applies its own qualified response. A Developer-Preview RT kernel therefore
degrades _control quality_ — the robot walks worse, or stops — but cannot by itself produce an
uncontained hazard. That containment was designed in two ADRs earlier and it is what makes an
unqualified vendor kernel tolerable here at all.

This is not permission to skip measurement. It bounds the consequence of the measurement coming out
badly.

### 2.4 Configuration levers, and which are container-visible

| Lever                                    | Where applied                          | Container-visible?                                                 |
| ---------------------------------------- | -------------------------------------- | ------------------------------------------------------------------ |
| `PREEMPT_RT` kernel                      | Host, via NVIDIA apt package           | No — host property                                                 |
| `isolcpus`, `nohz_full`, `rcu_nocbs`     | Host kernel command line               | No — host property                                                 |
| `irqaffinity` and per-IRQ `smp_affinity` | Host                                   | No — host property                                                 |
| UEFI runtime services                    | Host firmware / boot configuration     | No                                                                 |
| CPU pinning of a process                 | `--cpuset-cpus`, cgroup v2             | **Yes**                                                            |
| `SCHED_FIFO` / `SCHED_RR` priority       | `sched_setscheduler`                   | **Yes, but requires `CAP_SYS_NICE` and an `rtprio` ulimit**        |
| `mlockall(MCL_CURRENT \| MCL_FUTURE)`    | Process                                | **Yes, subject to `RLIMIT_MEMLOCK`**                               |
| Real-time throttling                     | `/proc/sys/kernel/sched_rt_runtime_us` | **No — host-wide, and it applies to containerised RT threads too** |

**The container-specific trap.** A container defaults to no `CAP_SYS_NICE` and an `rtprio` ulimit of 0.
A process that calls `sched_setscheduler(SCHED_FIFO)` fails with `EPERM` and, if the return value is
unchecked, **silently continues at normal priority**. The system then appears to work and misses
deadlines under load. Kernel real-time throttling is a second such trap: it is host-wide, defaults to
capping RT tasks below 100 % of a period, and is invisible from inside the container.

Both must be asserted at startup and reported, not assumed. This is gate 3.

---

## 3. Container runtime and image strategy

### 3.1 Runtime

| Option     | Status                                                                                               | Assessment                                                                                 |
| ---------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| **Docker** | The documented path for JetPack; `jetson-containers` invokes `docker run --runtime nvidia` [Primary] | Lowest friction, best-trodden on Jetson                                                    |
| **Podman** | NVIDIA Container Toolkit has active Podman support in its changelog, alongside CDI [Primary]         | Rootless and daemonless are genuine advantages, but this is off the documented Jetson path |

The NVIDIA Container Toolkit changelog shows active work on **CDI** (Container Device Interface), **CSV
mode** — the Tegra mechanism that mounts host L4T libraries into the container — and Orin-specific
handling (`isOrinGPUID`) [Primary]. CDI is runtime-agnostic and is the convergence point for both
Docker and Podman.

**Assessment.** Docker is the lower-risk selection today purely because it is the configuration NVIDIA
and the Jetson container ecosystem document and test. The rootless advantage of Podman is real but is
partly neutralised here: this robot needs `CAP_SYS_NICE`, elevated `rtprio` and `memlock` limits,
device access, and host networking for one process. The privilege surface is set by those
requirements, not by the daemon model.

### 3.2 Image layering

A multi-stage layout with a shared runtime base, so that CUDA and the ZED SDK are downloaded and built
once:

```text
L4T-matched CUDA/cuDNN/TensorRT base   (pinned to the host L4T version)
  -> ROS 2 Jazzy ros-base (Ubuntu 24.04)
    -> project runtime deps (no compilers, no headers)
      -> [build stage: colcon build] --copy artifacts--> runtime image
```

Constraints that follow from earlier ADRs:

- **The image tag must encode the L4T version it was built against.** The published naming convention
  already does this: `jazzy-ros-base-r36.4.4-cu128-24.04`. A container built against one L4T and run on
  another is exactly the configuration-identity mismatch ADR-003 requires to be detected at startup.
- **Runtime images contain no build toolchain.** This is a size and attack-surface decision, not a
  purity one; the perception image already carries 5+ GB of CUDA and TensorRT.
- **The ZED SDK is closed source** (Topic 5). It is installed into the image, and its licence terms
  govern redistribution of that image. Publishing an image containing the SDK is a separate question
  from publishing the project's own AGPL-free source, and it is **NR** — gate 8.

### 3.3 Process decomposition

Container boundaries should follow **failure domains and privilege requirements**, not code structure.

| Container                      | Contents                                                      | Distinguishing requirement                                                                    |
| ------------------------------ | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **Real-time control**          | `ros2_control` node, `HumanoidActuatorSystem`, `SafetyKernel` | `CAP_SYS_NICE`, `rtprio`, `memlock`, pinned to isolated cores, USB device access to the STM32 |
| **Perception**                 | ZED SDK, detector, TensorRT                                   | GPU access, large image, highest restart cost                                                 |
| **Estimation and world model** | Filters, TF                                                   | Neither GPU nor privilege                                                                     |
| **Behaviour**                  | Rule supervisor, behaviour tree, role arbitration             | Neither GPU nor privilege                                                                     |
| **Network gateway**            | GameController and team sockets                               | **Host network namespace** (ADR-005-12)                                                       |
| **Zenoh router**               | `rmw_zenohd`                                                  | §5                                                                                            |

The gateway is deliberately alone in the host network namespace. Isolating it as the only process with
field-network access is exactly the trust boundary ADR-005-09 requires, and confining the namespace
exception to one small container preserves that isolation for everything else.

---

## 4. GPU and device access

| Concern                              | Position                                                                                                                                                                                                                         |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CUDA userspace                       | Installed in the container; the driver stays on the host [Upstream, NVIDIA Container Toolkit]                                                                                                                                    |
| Tegra library injection              | CSV/CDI mode mounts host L4T libraries into the container [Primary, toolkit changelog]                                                                                                                                           |
| Camera access                        | The ZED connects over USB; the container needs the corresponding device node and udev-stable naming. Passing the whole USB bus is a privilege escalation and should not be the default.                                          |
| PCIe and memory bandwidth contention | **NR and genuinely uncertain.** Jetson Orin uses unified memory shared between CPU and GPU. A large TensorRT inference and the real-time control loop contend for **memory bandwidth**, which core pinning does _not_ partition. |

**The honest statement about §4's last row.** CPU isolation solves CPU contention. It does not solve
memory-bandwidth or last-level-cache contention, and on a unified-memory SoC those are the more likely
cause of a control-cycle overrun under perception load. No source consulted quantifies this for Orin
with this workload. It must be measured with perception at worst case while the control loop runs —
this is the specific reason gate 4 exists and why a benchmark of the control loop _in isolation_ is
not acceptance evidence. ADR-003 already anticipated this by requiring "Cross-layer tests proving
network and perception overload cannot violate the 5 ms actuator cycle".

---

## 5. Supervision, startup ordering, and the Zenoh router

### 5.1 ROS 2 launch is not a process supervisor

`ros2 launch` composes and starts nodes. It does not provide bounded restart backoff, dependency
ordering gated on readiness rather than on process start, health-based restart decisions, or
supervision that survives its own death.

ADR-003 already requires more than that, verbatim: "The process supervisor applies bounded restart
backoff and exposes router process state, connection state, reconnect count, and configuration
identity."

**Derived conclusion: ROS 2 launch alone cannot satisfy ADR-003.** A real supervisor is required
underneath it.

### 5.2 The three layers, and what each is for

| Layer                            | Tool                                                                                              | Responsibility                                                                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Host supervision                 | **systemd**                                                                                       | Starts containers with correct resource limits, ordering, and bounded restart backoff. Survives container death. Owns the boot path. |
| In-container process supervision | systemd is unsuitable in a container; **s6-overlay** or a single-process-per-container discipline | Only needed where a container genuinely holds more than one process                                                                  |
| Node composition and lifecycle   | **ROS 2 launch** plus a lifecycle orchestrator                                                    | Composes nodes, drives managed-lifecycle transitions in dependency order                                                             |

The strong simplifying position is **one long-running process per container**, which removes the
middle layer entirely and makes container liveness equal process liveness. `s6-overlay` earns its
place only where that is impossible; the more processes a container holds, the less the orchestrator
can tell about what actually failed.

### 5.3 Startup ordering is a readiness problem, not a sequencing problem

Process start order does not imply readiness. The router being _started_ is not the router being
_connectable_; the STM32 link being _open_ is not the actuator manifest being _validated_.

ADR-001 and ADR-002 already define the correct gate: "Configuration, calibration, protocol, and safety
identities must match before actuator power can be armed." That interlock is the real ordering
constraint, and it is enforced by the arm sequence rather than by boot order.

The managed-lifecycle contract already mandated by ADR-005-10 for the network gateway generalises:
`configure` validates and acquires resources so that failure is loud and early; `activate` starts
producing. A supervisor that only checks "is the process alive" will happily run a fully started system
in which nothing works.

### 5.4 Zenoh router placement

ADR-003 requires one supervised robot-local `rmw_zenohd` router, with onboard peers connecting to it
over explicit **loopback TCP**.

**Loopback is per network namespace.** This collides with ADR-005-12, which puts the network gateway in
the host network namespace. Three configurations are possible:

| Option                                                                              | Consequence                                                                                                                                                               |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Router in the host namespace; all ROS containers share the host namespace           | Simplest, and all loopback TCP works as ADR-003 describes. Cost: no network isolation between ROS containers, and container port conflicts become real.                   |
| Router in a shared non-host namespace; gateway in the host namespace                | The gateway cannot reach the router over loopback. It would need a non-loopback link, which ADR-003 requires to be mutually authenticated TLS. Adds TLS to an on-box hop. |
| Router in the host namespace; ROS containers join the router's namespace explicitly | Keeps one namespace for all ROS traffic while making the sharing explicit rather than incidental.                                                                         |

**This is a genuine architectural fork created by two accepted ADRs interacting**, and it did not exist
in either topic separately. It is resolved in the Topic 9 proposal, not here.

The router must also be restart-tolerant in a way that does not cause a motion event: ADR-003 states
router loss "never triggers automatic motion when communication returns". Supervision restarts the
router; it does not re-arm the robot.

---

## 6. CI/CD and image management

| Concern                       | Finding                                                                                                                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Cross-building arm64 on amd64 | `docker buildx` with QEMU binfmt emulation works but is very slow for CUDA and TensorRT compilation. Actual build times are **NR** and workload-specific. Native arm64 runners — a Jetson or an arm64 cloud instance — avoid emulation entirely. |
| Version parity                | ADR-003 requires "Identical compatible package versions on `arm64` and `amd64`". This forces both architectures to be built from the same manifest, not independently.                                                                           |
| Digest pinning                | **Already mandated.** ADR-003 lists "Container image digests and host kernel baseline" among the immutable release-identity artifacts. Topic 9 implements it rather than deciding it.                                                            |
| Base image drift              | A `FROM ubuntu:24.04` tag is mutable. Base images must be referenced by digest, or the release manifest's digest guarantee is decorative.                                                                                                        |
| Signing                       | Sigstore/cosign is the mainstream approach for OCI artifacts. Specific tooling choice is open; the requirement that images be verifiable is not, given the ADR-003 identity requirements.                                                        |
| Startup identity check        | ADR-003 already requires each process to report its configuration identity and requires "a required mismatch keeps motion disabled". The container digest and L4T version are part of that identity.                                             |

**Derived note on emulated builds.** Cross-architecture emulation is acceptable for pure-Python and
small C++ packages, and is a poor fit for the CUDA and TensorRT layers. A split is likely: emulate the
cheap layers, build the expensive layers natively and cache them. Whether that is necessary depends on
measured build times, which are NR.

---

## 7. Falsifiable gates

| #   | Gate                                                                                                                                                                                             | Pass condition                                                                                                                                                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Platform selection.** Verify ZED SDK, TensorRT, and the selected Orin module are supported on the candidate JetPack.                                                                           | JetPack 6 versus 7 resolved with a named supported-version matrix for every closed-source dependency, not an assumption.                                                                                  |
| 2   | **Jazzy-on-JetPack.** Build and run the full stack in a Ubuntu 24.04 container on the selected JetPack.                                                                                          | ROS 2 Jazzy binaries install from apt inside the container; CUDA, TensorRT, and the ZED SDK all initialise; no host-side ROS installation exists.                                                         |
| 3   | **Real-time privilege assertion.** Start the control container and check the actual scheduler policy, priority, `mlockall` result, `RLIMIT_MEMLOCK`, `RLIMIT_RTPRIO`, and `sched_rt_runtime_us`. | Every value asserted and reported at startup. A failed `sched_setscheduler` is a **startup failure**, never a silent downgrade.                                                                           |
| 4   | **Cycle timing under full load.** Run perception at worst case, the network flood from Topic 8 gate 5, and logging, with the 200 Hz loop active, for a full match duration.                      | Cycle-time distribution and worst observed value reported, not the mean. Zero overruns, or a stated and accepted overrun budget. ADR-002 CPU margin holds. Shared with Topic 5 gate 6 and Topic 8 gate 5. |
| 5   | **RT kernel comparison.** Measure gate 4 on both the generic and the Developer-Preview RT kernel, with UEFI runtime services enabled and disabled.                                               | Quantified difference. If the RT kernel does not measurably help, it is not adopted merely because it is available.                                                                                       |
| 6   | **Container boundary for broadcast.** Topic 8 gate 3, run against the deployed container network configuration.                                                                                  | Broadcast received. Re-run on every change to container networking.                                                                                                                                       |
| 7   | **Supervision and restart.** Kill each container in turn, including the Zenoh router, during simulated play.                                                                                     | Bounded restart backoff observed; no restart storm; no automatic re-arm; the control loop and the STM32 safety response behave as ADR-002 specifies.                                                      |
| 8   | **Image identity and redistribution.** Verify digest pinning end to end and audit image contents against the licence policy.                                                                     | Every image and base image referenced by digest; startup reports the digest; ZED SDK redistribution terms explicitly assessed against the open-source publication plan.                                   |
| 9   | **Reproducible build.** Build the same manifest twice, on a native arm64 runner and via emulation.                                                                                               | Functionally identical artifacts; build times recorded so the emulation decision is made on data.                                                                                                         |

---

## 8. Open gaps

1. **Jetson module not selected.** Core count, memory bandwidth, and power envelope are all downstream
   of it, and of Topic 3 Model Gate 0. No core-allocation budget can be written yet.
2. **JetPack 6 versus 7 is unresolved** and depends on closed-source dependency support matrices that
   are NR (§1.4).
3. **No RT latency figures exist for Orin under this workload.** NVIDIA publishes none and calls the
   support Developer-Preview. Everything is gate 4 and gate 5.
4. **Memory-bandwidth contention on unified memory is unquantified** (§4) and is the most likely cause
   of a control overrun that core pinning will not fix.
5. **The Zenoh router namespace fork is open** (§5.4), created by ADR-003 and ADR-005-12 interacting.
6. **ZED SDK image redistribution terms are unassessed** against the project's open-source publication
   intent (§3.2).
7. **Build times, and therefore the cross-compilation strategy, are NR.**
8. **Thermal behaviour under sustained load is unaddressed.** A Jetson that thermally throttles changes
   every timing result in this document, and a robot has no fan budget to spare. Interacts with the
   unmeasured physical envelope.
9. **Storage endurance and logging volume are unscoped.** A 200 Hz system that logs per cycle will
   write substantially; the medium, retention, and whether logging is disabled at competition are all
   undecided.

---

## References

- **[S-1]** REP-2000, _ROS 2 Releases and Target Platforms_, `ros-infrastructure/rep`, `rep-2000.rst`. Jazzy Jalisco targeted-platform table.
- **[S-2]** `dusty-nv/jetson-containers`, `README.md` and `docs/build.md`. JetPack-to-L4T-to-CUDA mapping, default container base images, and the Ubuntu 24.04 container list including `dustynv/ros:jazzy-ros-base-r36.4.4-cu128-24.04`.
- **[S-3]** NVIDIA, _Jetson Linux Developer Guide r36.4.3_, Kernel Customization. Real-Time Kernel package availability, Developer-Preview quality statement, OTA installation, kernel switching, UEFI runtime-services latency note, and `IGNORE_PREEMPT_RT_PRESENCE`.
- **[S-4]** `torvalds/linux`, `arch/arm64/Kconfig` (`select ARCH_SUPPORTS_RT`) and `kernel/Kconfig.preempt` (`config PREEMPT_RT depends on EXPERT && ARCH_SUPPORTS_RT`), tags v6.8, v6.11, v6.12.
- **[S-5]** `NVIDIA/nvidia-container-toolkit`, `README.md` and `CHANGELOG.md`. Host-driver / container-CUDA split; CDI, CSV mode, Podman support, and Orin-specific handling.
- **[D-1]** [architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md)
- **[D-2]** [architecture/ADR-002-safety-and-fault-management.md](../architecture/ADR-002-safety-and-fault-management.md)
- **[D-3]** [architecture/ADR-003-zenoh-middleware.md](../architecture/ADR-003-zenoh-middleware.md) — release identity, router supervision, cross-layer overload testing.
- **[D-4]** [architecture/ADR-005-behavior-game-state-and-team-networking.md](../architecture/ADR-005-behavior-game-state-and-team-networking.md) — the host-network-namespace requirement.
- **[D-5]** [research/topic-5-perception-pipeline.md](topic-5-perception-pipeline.md) — ZED SDK closed-source status and the licence policy.
