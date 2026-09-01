# Topic 11 Research: Observability, Telemetry, and Competition Operations

- Status: Complete research baseline; update before any Topic 11 architecture revision
- Evidence last verified: 2026-09-01
- Scope: Research input for Topic 11; architecture proposal presented separately
- Canonical decisions: [ADR-001](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md), [ADR-002](../architecture/ADR-002-safety-and-fault-management.md), [ADR-003](../architecture/ADR-003-zenoh-middleware.md), [ADR-005](../architecture/ADR-005-behavior-game-state-and-team-networking.md), [ADR-006](../architecture/ADR-006-runtime-and-containers.md), [ADR-007](../architecture/ADR-007-simulation-sil-hil.md)
- Related research: [Topic 8](topic-8-gamecontroller-networking.md), [Topic 9](topic-9-runtime-and-containers.md), [Topic 10](topic-10-simulation-sil-hil.md)

## Purpose and evidence policy

ADR-007 established what is recorded. This topic establishes what can be read, when, by whom, and
under what rule constraints — and what the measurement tools can actually deliver on the target
platform.

Evidence tags follow the Topic 4-10 convention:

| Tag            | Meaning                                                                                            |
| -------------- | -------------------------------------------------------------------------------------------------- |
| **[Rules]**    | Quoted verbatim from the RoboCup Humanoid League _Laws of the Game 2025_ (14 April 2025). Binding. |
| **[Primary]**  | Read directly from a source file, specification, manifest, or kernel documentation at a named URL. |
| **[Upstream]** | Stated by the maintainer or vendor in their own documentation.                                     |
| **[Derived]**  | Computed or concluded here from tagged inputs. Reasoning shown.                                    |
| **[Project]**  | A target or constraint set by this project.                                                        |
| **NR**         | **Not reported.** Never means zero.                                                                |

## Confirmed project inputs

| Input                 | Value                                                                                                 | Source         |
| --------------------- | ----------------------------------------------------------------------------------------------------- | -------------- |
| In-cycle telemetry    | Preallocated lock-free ring buffer, full 200 Hz, drained to MCAP by a non-RT thread, always on        | ADR-007 §10    |
| In-cycle volume       | ~848 B/cycle, ~170 kB/s, ~204 MB per 20-minute match uncompressed                                     | ADR-007 §10    |
| Non-RT telemetry      | `rosbag2` 0.26.11-1, default storage plugin `mcap`                                                    | ADR-007 §10    |
| In-cycle restrictions | No ROS, logging, filesystem, allocation, or unbounded wait in the 5 ms cycle                          | ADR-001        |
| Startup interlock     | Configuration, calibration, protocol, and safety identities must match before actuator power is armed | ADR-002        |
| Container privilege   | Minimum device privilege via udev; `--privileged` and whole-bus passthrough prohibited                | ADR-006 §9     |
| Release identity      | Every image referenced by digest; digest participates in the startup interlock                        | ADR-006 §10    |
| Unified memory risk   | Core pinning does not partition memory bandwidth or last-level cache on Orin. **Open gap.**           | Topic 9        |
| Robot model           | **Not designed.** Topic 3 Model Gate 0 is open.                                                       | Topic 3        |
| Licensing             | AGPL and GPL excluded for distributed application code                                                | Topic 5 §4.1.1 |

---

## 1. The rule envelope for operations

The rulebook constrains observability more tightly than any engineering consideration, and does so in
places that are easy to miss because they appear in Law 3 and Law 4 rather than in any section about
software. All quotations are verbatim from _Laws of the Game 2025_.

### 1.1 A hard 1 Mbit/s per-robot bandwidth cap

> "The total bandwidth of each robot belonging to one team may not exceed 1 Mbit/s." [Rules]

**[Derived]** 1 Mbit/s is 125 kB/s, and it is a **total**, shared with GameController return messages
and the ADR-005 team-communication plane. The ADR-007 in-cycle control log is approximately
170 kB/s. Streaming it live would consume roughly

$$\frac{170\ \mathrm{kB/s}}{125\ \mathrm{kB/s}} \approx 1.36$$

times the entire per-robot allowance, before a single team or GameController packet is sent.

**Live streaming of control telemetry is therefore not merely inadvisable; it is prohibited by the
bandwidth cap.** ADR-007's on-board ring buffer with local storage is the only configuration the rules
permit, and this is now a rule-derived requirement rather than an engineering preference.

The same arithmetic bounds post-match extraction over the competition network. Transferring one
match's control log at the full 1 Mbit/s cap takes

$$\frac{204 \times 10^{6}\ \mathrm{B} \times 8}{1 \times 10^{6}\ \mathrm{bit/s}} \approx 1632\ \mathrm{s} \approx 27\ \mathrm{minutes}$$

against a half-time interval that "must not exceed 5 minutes" [Rules]. **Log extraction over the
competition WLAN is structurally impossible.** It must be physical: removable storage or a tethered
link, off the competition network.

### 1.2 Monitoring is receive-only, and the operator station must be wired

> "During a physical competition, only robots are allowed to communicate by WLAN. Any other computers
> of team members are only allowed to communicate by tethered LAN. **No other wireless communication
> is allowed onsite. All other wireless hardware must be deactivated. A team may be disqualified if
> one of the team members violates this rule.**" [Rules]

> "**Any kind of transmission from an external computer to the playing robots is prohibited.** During a
> physical event, this implies that any monitoring is only done by **receiving UDP communication from
> the robots** using an external computer connected by tethered LAN to the official wireless router."
> [Rules]

Two consequences, both architectural:

1. **The in-play telemetry path must be one-way UDP emitted by the robot.** A Zenoh session is
   bidirectional by construction — the operator peer transmits to the robot to establish and maintain
   the link, subscribe, and acknowledge. ADR-003 permits an operator station over "named, allowlisted
   TLS router links"; **that path must be disabled during play.** This is a live constraint on an
   accepted ADR that no prior topic has recorded.
2. **The operator laptop must have its wireless hardware deactivated on site**, with disqualification
   as the stated penalty. This is a checklist item with a team-level consequence, not a preference.

Related, and relevant to the substitute-robot bench:

> "Substitute robots in a physical competition need to be turned away from the field in order to ensure
> they are not accidentally or purposefully sending game-relevant information to the robots in play."
> [Rules]

### 1.3 Touching the robot costs playing time, and resets the clock

> "Any time the robot handler or another team member is touching the robot, **a cable is connected** or
> another form of communication with the robot (**including button clicks**) take place, the robot is
> considered in service." [Rules]

> "**The regular penalty time will start counting only after any type of communication with the robot
> has finished and will be reset whenever the robot handler attempts to service the robot again.**"
> [Rules]

**[Derived] This is the decisive constraint on field diagnostics.** Plugging in a laptop to read a log,
or pressing a button to trigger a self-test, does not merely cost the seconds it takes: it **restarts
the penalty timer from zero**. A three-attempt diagnostic session costs three full penalty periods of
playing time with four players on a 9 × 6 m field.

The correct design response is not a faster diagnostic cable. It is that **the robot must be
diagnosable without being touched.**

### 1.4 Pick-up is not available for debugging

> "A robot handler may request to pick-up a robot **if and only if a robot is in a dangerous situation
> that is likely to lead to physical injuries.** If a robot handler touches a robot without the
> allowance of the referee, the respective robot receives a **yellow card** and the robot handler an
> official warning. ... After two warnings for robot touching, the robot handler may not serve as a
> robot handler again for the rest of the game and needs to be replaced." [Rules]

A misbehaving but safe robot cannot be retrieved. **In-match recovery must be autonomous**, which
routes back to ADR-002: fall recovery, rearm workflow, and degraded policies are the recovery
mechanism, and there is no manual fallback.

### 1.5 The operational time budget

| Window                  | Duration                                                      | Source  |
| ----------------------- | ------------------------------------------------------------- | ------- |
| Half-time interval      | "must not exceed 5 minutes"                                   | [Rules] |
| Substitutions per match | "Up to a maximum of two substitutes may be used in any match" | [Rules] |
| Free-kick positioning   | "up to 30 seconds to position themselves"                     | [Rules] |
| Between matches         | **NR.** Set by the competition schedule, not the Laws.        | [Rules] |

**[Derived]** Five minutes is the entire between-halves triage window, and it must cover battery
change, physical inspection, and any software action. Anything that cannot be completed and verified
inside it is not a half-time procedure. Substitution is limited to two per match, so swapping in a
spare robot is a scarce resource rather than a general recovery strategy.

### 1.6 The remote emergency stop cannot be repurposed

> "This button must be worn either around the neck or on the belt of the robot handler and must be
> clearly marked. Each emergency stop button can only be connected to the robot of the robot handler
> that holds the button. **The remote emergency button cannot perform any additional functions and does
> not replace the regular emergency button.**" [Rules]

No log-dump trigger, mode switch, or reset may be attached to it. This confirms ADR-002 from the rule
side rather than only from the safety side.

---

## 2. Telemetry architecture

### 2.1 "MCAP versus custom binary" is a false dichotomy

The MCAP specification defines a container, not a message format. Its `Schema` record carries a free
`encoding` string: "Format for the schema. The well-known schema encodings are preferred. **An empty
string indicates no schema is available.**" [Primary]

A custom fixed-layout in-cycle record is therefore representable **inside** MCAP, declared by its own
schema, without pretending to be a ROS message. The choice is not between the two; it is a custom
binary record carried in a standard indexed container.

What that buys, verified from the specification [Primary]:

| MCAP record   | Opcode | Use here                                                                                             |
| ------------- | ------ | ---------------------------------------------------------------------------------------------------- |
| `Schema`      | 0x03   | Declares the in-cycle record layout and its version, in the file, so an old log stays readable       |
| `Channel`     | 0x04   | Separates control-loop, safety-event, and status streams; carries a `Map<string,string>` of metadata |
| `Message`     | 0x05   | Carries `sequence`, `log_time`, and `publish_time` — see §2.3                                        |
| `Chunk`       | 0x06   | Compression that remains indexable                                                                   |
| `Chunk Index` | 0x08   | Lookup by log time or topic without reading the file                                                 |
| `Attachment`  | 0x09   | "auxiliary artifacts such as text, core dumps, **calibration data**, or other arbitrary data"        |
| `Metadata`    | 0x0C   | "arbitrary user data in key-value pairs. Example keys: `part_id`, `serial`, `board_revision`"        |

Two of these are worth more than they first appear:

- **`Metadata` is where the release identity belongs.** Container digest, host L4T version, safety
  manifest ID, calibration digest, protocol version, simulator version. ADR-006 §10 already requires
  those to exist; putting them in the log means a log can never be analysed against the wrong build.
- **`Attachment` makes the log self-contained.** The calibration files actually in force can be
  embedded in the recording. Post-match analysis then never depends on someone remembering which
  calibration was loaded.

Two constraints from the specification that affect the writer [Primary]:

- "Message records outside of chunks cannot be indexed, and may not be found by readers using the
  index." So the drain thread must chunk.
- "Attachment records must not appear within a chunk."
- Opcodes 0x80-0xFF are "reserved for private records", so a project-specific record type is legal.
- The summary section carries a CRC32, and the footer's `summary_start` is 0 when there is no summary
  section. **[Derived]** A file truncated by power loss therefore has no summary and no chunk index.
  The reader must tolerate that, and the drain thread should close and roll files on a bounded
  interval so an abrupt power cut costs at most one interval of index, never the whole match.

### 2.2 The in-cycle record schema

The ADR-007 sizing fixed the budget at approximately 848 B per cycle. The schema that fits it:

| Group               | Fields                                                                                                                                                                                                                | Bytes |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| Header              | cycle sequence `uint64`, monotonic cycle start `int64`, safety state `uint8`, availability-mask epoch `uint32`, availability mask `uint32`, active controller ID `uint16`, transport counters, deadline-overrun flags | 48    |
| Per joint, command  | $q_d$, $\dot q_d$, $\tau_{ff}$, $K_p$, $K_d$ as `float32`                                                                                                                                                             | 20    |
| Per joint, feedback | measured $q$, $\dot q$, $\tau$ as `float32`                                                                                                                                                                           | 12    |
| Per joint, status   | temperature, voltage, drive mode, fault bits                                                                                                                                                                          | 8     |

Three properties matter more than the field list:

1. **Fixed size, no optional fields, no strings.** The record must be writable as one bounded store.
   Variable-length encoding in the cycle would reintroduce branching cost and defeat the ring-buffer
   sizing.
2. **The pre-safety and post-safety command must both be recorded, or the `SafetyKernel` cannot be
   audited.** A log that shows only the projected tuple cannot answer whether the kernel intervened.
   **[Derived]** This is not in the 848 B estimate. Recording the pre-projection tuple adds 20 B per
   joint, so 400 B per cycle for 20 joints, taking the total to roughly 1248 B per cycle and
   250 kB/s. Alternatively, record a projection-occurred bitmask plus the delta only for joints that
   were projected, which is nearly free in the common case where nothing is projected. The second is
   preferable and should be measured.
3. **Schema version is in the file**, via the `Schema` record, so a log outlives the build that wrote
   it.

### 2.3 The clock correlation problem

This is the substantive technical difficulty in lane 1, and it comes from a verified mismatch.

ROS 2 offers three clock types [Primary, `rcl/time.h`]:

| Clock             | Behaviour, verbatim                                                                                                                          |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `RCL_ROS_TIME`    | "will report the latest value reported by a ROS time source, or if a ROS time source is not active it reports the same as `RCL_SYSTEM_TIME`" |
| `RCL_SYSTEM_TIME` | "reports the same value as the system clock"                                                                                                 |
| `RCL_STEADY_TIME` | "reports a value from a monotonically increasing clock"                                                                                      |

ADR-001 requires the control loop to use **monotonic** timestamps. Message header stamps in the ROS
graph are normally `RCL_ROS_TIME`, which without an active time source is the **system** clock. The
system clock is settable and can step; the monotonic clock cannot. The two therefore drift apart, and
a log correlated by wall-clock timestamps will silently mis-associate a perception frame with a
control cycle.

**[Derived] The correlation mechanism must be structural, not arithmetic.**

MCAP's `Message` record already provides the fields [Primary]:

- `sequence` — "Optional message counter to detect message gaps. If your middleware publisher provides
  a sequence number you can use that, or you can assign a sequence number in the recorder"
- `log_time` — "Time at which the message was recorded"
- `publish_time` — "Time at which the message was published. If not available, must be set to the log
  time."

So: the in-cycle record's monotonic cycle timestamp goes in `publish_time`, the drain thread's write
time in `log_time`, and the **control cycle sequence number in `sequence`**. `sequence` is `uint32`;
at 200 Hz it wraps after $2^{32}/200 \approx 2.5 \times 10^{7}$ s, roughly 248 days, which is not a
practical concern within a session.

Every non-real-time producer that needs to be correlated with the control loop must then carry the
**cycle sequence number it was derived from**, not a timestamp. A perception result derived from a
frame captured during cycle 41,203 says 41,203. This makes correlation exact and clock-independent.
Where a producer genuinely has no cycle association — a container health report, a Zenoh link metric —
it carries **both** clock readings, and the log carries a periodic pairing record of
`(monotonic, system)` samples so any wall-clock artefact can be mapped back after the fact.

**[Derived]** The cost of not doing this is not a small error. A system-clock step of a few hundred
milliseconds, which NTP or a manual correction can produce, is 40 to 100 control cycles. Correlating
by timestamp would place a fault report in entirely the wrong part of the match.

### 2.4 The non-real-time plane

`rosbag2` 0.26.11-1 provides the mechanisms already needed [Primary, `StorageOptions`,
`RecordOptions`]:

| Field                                      | Use                                                                                         |
| ------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `snapshot_mode`                            | Circular in-memory buffer written out only on trigger — the classic black box               |
| `max_bagfile_size`, `max_bagfile_duration` | Bounded file rolling, which bounds power-loss damage                                        |
| `max_cache_size`                           | Bounds recorder memory, which matters under the ADR-006 unified-memory pressure             |
| `custom_data`                              | `Map<string,string>` for release identity, mirroring §2.1                                   |
| `compression_threads_priority`             | POSIX nice value — compression must not be scheduled against the isolated real-time cores   |
| `exclude_topics`, `exclude_regex`          | Keeps raw camera streams out of the default recording                                       |
| `topic_qos_profile_overrides`              | Required because ADR-003 forbids `SYSTEM_DEFAULT`; the recorder must declare QoS explicitly |

**[Derived]** `snapshot_mode` is the correct default for the **perception** plane and the wrong default
for the **behaviour and safety event** plane. A snapshot buffer is discarded unless something triggers
it, and the events most worth keeping — a safety transition, a role change, a GameController state
change — are cheap and must be recorded unconditionally. The split is by volume, not by importance:
continuous recording for low-rate event streams, snapshot for high-rate image streams.

---

## 3. Field diagnostics and triage

### 3.1 The zero-touch requirement

§1.3 established that touching the robot resets the penalty clock and §1.4 that a safe-but-broken
robot cannot be picked up. **[Derived]** Every diagnostic that requires physical contact is therefore
unavailable during play, and the entire in-play diagnostic surface reduces to:

1. What the robot emits on the network, subject to §1.2's receive-only constraint and the 1 Mbit/s cap.
2. What a human can see and hear from the touchline.

The second is not a joke. It is the only channel with zero rule cost and zero bandwidth cost, and it
is systematically underused. A small number of distinguishable states expressed through an LED colour
or pattern, and a distinguishable audible tone on a safety transition, give the handler a diagnosis
from three metres away without incurring a service. The states worth encoding are exactly the ADR-002
safety states plus the ADR-005 degraded-communications and ambiguous-pose conditions.

### 3.2 The health beacon

**[Derived] budget.** Allocating a small share of the 125 kB/s cap to a periodic one-way UDP status
datagram: a 1 kB beacon at 5 Hz is 5 kB/s, which is 40 kbit/s, or **4 % of the per-robot cap**. That
is affordable and leaves the ADR-005 team plane and the GameController return path intact.

What must be in it is determined by what cannot be recovered later: the beacon is not a log, it is a
triage aid. Candidate content, all of which is already produced elsewhere in the architecture:

| Field group    | Content                                                                                           |
| -------------- | ------------------------------------------------------------------------------------------------- |
| Identity       | Release digest short form, safety manifest ID, calibration digest — proves which build is playing |
| Safety         | ADR-002 state, availability-mask epoch, last fault class, cycles since last fault                 |
| Control        | Cycle overrun count, worst cycle duration in the last window, transport reject counters           |
| Estimation     | Odometry validity flag, pose mode weights, time since last accepted vision update                 |
| Behaviour      | Active tree, active role, GameController state and its age                                        |
| Platform       | Battery voltage, worst joint temperature, EMC utilisation and EMC frequency (§5.4), thermal state |
| Communications | Teammates heard, Zenoh router state, packets rejected per validation rung                         |

This is a strict superset of what the ADR-005 team-communication message carries, and it must be a
**separate** message on a separate port: team communication is consumed by robots and is rule-bounded
in content; the beacon is consumed by humans. Merging them would put debug information on the channel
the anti-coaching rule polices.

**Constraint.** The beacon is emitted by the ADR-005 network gateway, because that process already
owns every competition-plane socket. No other process may open a competition-network socket.

### 3.3 Black box extraction

Given §1.1, extraction is physical. Two viable mechanisms:

| Mechanism                  | Assessment                                                                                                                          |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Removable storage          | Fastest to swap, but a removed card is a configuration change and the mount must be verified at startup or a match records nothing. |
| Tethered link, off-network | Uses the existing service connection; incurs an in-service event, so it is a between-matches action, never an in-match one.         |

**[Derived]** Whichever is chosen, the failure mode to design against is **silent non-recording**. A
full disk, an unmounted card, or a permission error produces exactly the same observable behaviour as
a healthy system, and is discovered only when the log is needed. Storage writability and free space
must therefore be part of the ADR-002 startup interlock, on the same footing as a calibration
mismatch, and free space must appear in the §3.2 beacon.

Durability against power loss follows §2.1: bounded file rolling, so an abrupt cut costs at most one
roll interval.

### 3.4 Automated health checks

`diagnostics` 4.2.7-1 is released for Jazzy with status `maintained` [Primary], providing
`diagnostic_updater` and `diagnostic_aggregator`. It is the ROS-native mechanism and there is no
reason to build a parallel one for the non-real-time plane.

**[Derived]** It is the wrong mechanism for the real-time plane, for the same reason `rosbag2` is:
`diagnostic_updater` publishes on a ROS topic, and ADR-001 forbids that in the cycle. Control-loop
health must be exported by the same non-real-time thread that drains the ring buffer, from copied
snapshots — which ADR-001 already mandates.

The distinction worth preserving is between a **health check** and a **gate**. A diagnostic that
merely reports is advisory. A diagnostic whose failure must prevent motion belongs in the ADR-002
startup interlock, not in the diagnostics aggregator, because the aggregator has no authority to keep
actuator power off.

---

## 4. Calibration workflows

### 4.1 Four classes with different lifetimes and different gates

| Calibration                       | Changes when                                           | Can be validated on site?                                  | Gate                                             |
| --------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------- | ------------------------------------------------ |
| **Joint zero offsets**            | Reassembly, drive replacement, hard impact             | Yes — against a mechanical reference pose                  | ADR-002 startup interlock (calibration identity) |
| **IMU bias**                      | Every power cycle (turn-on bias), and with temperature | Partly — a static estimate needs the robot still and level | Estimator validity signal, Topic 4               |
| **Camera extrinsics**             | Head reassembly, impact, lens disturbance              | Marginal — needs a target and controlled conditions        | Perception validity, Topic 5                     |
| **Turf friction / ball dynamics** | Every venue, and with surface wear                     | **Must be** — it is venue-specific by definition           | Topic 6 D5 ball filter                           |

**[Derived]** These are not one workflow. They differ in trigger, in whether they can be done between
matches, and in what happens if they are wrong:

- A wrong **joint zero** is a safety problem. The `SafetyKernel` joint envelope is expressed in joint
  coordinates, so an offset error shifts the entire envelope. It must be interlocked.
- A wrong **IMU bias** is an estimator problem that degrades gracefully and is already covered by the
  Topic 4 validity signal.
- Wrong **extrinsics** produce a confidently wrong world model, which is worse than no world model. It
  needs an independent consistency check, not just a residual from its own fit.
- Wrong **turf friction** degrades the Topic 6 D5 ball filter and nothing else.

Only the first belongs in the startup interlock. Putting all four there would mean a robot cannot play
because the turf model is stale, which is the wrong trade.

### 4.2 Identity, storage, and the interlock

ADR-002 already requires calibration identity to match before actuator power is armed, and ADR-006 §10
requires digest-level release identity. **[Derived]** Calibration is therefore a digest-identified,
immutable-within-a-release artifact like any other, with three properties:

1. **Written once, never edited in place.** A new calibration is a new digest.
2. **Recorded into every log** as an MCAP `Attachment` (§2.1), so analysis never has to reconstruct it.
3. **Reported in the §3.2 beacon** in short form, so a handler can see from the touchline that a robot
   is running the calibration they think it is.

The failure this prevents is specific and common: a robot that was recalibrated on the bench, then
restarted from a stale configuration, and plays a match producing data that looks like a controller
regression.

### 4.3 Available tooling

`image_pipeline` 5.0.13-1 is released for Jazzy with status `maintained` [Primary] and contains
`camera_calibration`. `geometry2` 0.36.22-1 provides the TF machinery the extrinsics feed. Both are
BSD-licensed and compatible with the Topic 5 §4.1.1 exclusion.

**NR:** No released Jazzy package was identified for IMU Allan-variance characterisation or for turf
friction estimation. Both are expected to be project-built. Turf friction in particular has no
off-the-shelf answer because the measurement is of a specific competition carpet.

### 4.4 The model gate

Joint zeroing needs a mechanical reference pose. Camera extrinsics need a head geometry. Neither
exists while Topic 3 Model Gate 0 is open. The **workflow, storage format, identity scheme, and
interlock** can and should be built now; the **procedures** cannot be written until the robot exists.

---

## 5. Performance measurement and profiling

### 5.1 Tool availability

| Tool                                      | Jazzy / Orin status                                                                  | Answers                                                      |
| ----------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| `ros2_tracing` 8.2.6-1                    | Released for Jazzy, status `developed`. LTTng-UST is a ROS 2 dependency as of Iron.  | ROS-layer causality: callback durations, executor scheduling |
| `tracetools`                              | "claims to be in the **Quality Level 1** category"                                   | Instrumentation library                                      |
| LTTng kernel tracer                       | **Not included.** Requires `lttng-modules-dkms` installed separately.                | Kernel scheduling, preemption, IRQ latency                   |
| `perf`                                    | Requires `CAP_PERFMON`; see §5.3                                                     | CPU sampling, PMU counters                                   |
| Nsight Systems Embedded Platforms Edition | Separate edition, "supports Tegra processors for the embedded and automotive market" | GPU and CUDA timeline, Arm PMU, cache utilisation            |
| `tegrastats`                              | Ships with L4T                                                                       | EMC utilisation, GPU frequency, thermal, power — see §5.4    |
| `jetson_stats` / `jtop`                   | **AGPL-3.0 licensed** [Primary]                                                      | Friendlier `tegrastats`                                      |
| `diagnostics` 4.2.7-1                     | Released, `maintained`                                                               | Aggregated component health                                  |
| `libstatistics_collector` 1.7.4-1         | Released, `developed`                                                                | Topic statistics                                             |
| `system_metrics_collector`                | **Not released for Jazzy** — absent from the distribution manifest                   | —                                                            |

**Licence note.** `jetson_stats` is AGPL-3.0. Topic 5 §4.1.1 excluded AGPL and GPL for **distributed
application code**. A standalone diagnostic binary that is merely executed is a different case from
linked application code, but the AGPL network clause makes any arrangement that serves its output over
a network a genuine question rather than an obvious non-issue. **[Derived]** The safe position is that
`jetson_stats` is a lab convenience that is never included in a distributed image, and that anything
the architecture depends on reads `tegrastats` directly, which ships with L4T and carries no such
condition.

### 5.2 `ros2_tracing`, verified

> "`ros2_tracing` currently only supports the LTTng tracer." [Upstream]

> "As of Iron, the LTTng tracer is a ROS 2 dependency." [Upstream]

> "A ROS 2 installation only includes the LTTng **userspace** tracer (LTTng-UST), which is all that is
> needed to trace ROS 2. To trace the Linux kernel, the LTTng kernel tracer must be installed
> separately: `sudo apt-get install lttng-modules-dkms`" [Upstream]

> "To build and remove all instrumentation, use `TRACETOOLS_DISABLED`: `colcon build --cmake-args
-DTRACETOOLS_DISABLED=ON`" [Upstream]

**[Derived] Instrumentation is present by default.** It must be explicitly compiled out, not
explicitly compiled in. Combined with ADR-006's digest-pinned identity, this is convenient: the shipped
image already carries the tracepoints, so tracing is enabled at runtime by starting a session rather
than by rebuilding. Disabling instrumentation would create a second image and break the ADR-007 §8
principle that the tested binary is the shipped binary.

The overhead figure the project has is second-hand and must be treated as such: the README cites a
survey reporting an "average latency overhead per tracepoint of 158 ns" [Upstream, citing a third-party
paper]. **[Derived]** That is a published average from a different system, not a measurement on Orin,
and at 200 Hz the relevant question is worst case within a 5 ms budget, not average. It must be
measured on the target before tracing is enabled during any timing-qualification run.

Two operational details: kernel tracing by a non-root user requires the `tracing` group to exist with
the user added, and `tracetools_launch`'s `Trace` action sets `LD_PRELOAD` to load LTTng's userspace
helpers [Upstream]. `LD_PRELOAD` in a real-time process is a configuration change that must be
declared, not incidental.

### 5.3 The container privilege collision

This is the finding that constrains lane 4.

Linux kernel documentation, verbatim [Primary, `Documentation/admin-guide/sysctl/kernel.rst`]:

> "`perf_event_paranoid` — Controls use of the performance events system by unprivileged users
> (without `CAP_PERFMON`). **The default value is 2.**"

with the level table:

| Level | Effect, verbatim                                                      |
| ----- | --------------------------------------------------------------------- |
| `-1`  | "Allow use of (almost) all events by all users."                      |
| `>=0` | "Disallow ftrace function tracepoint by users without `CAP_PERFMON`." |
| `>=1` | "Disallow CPU event access by users without `CAP_PERFMON`."           |
| `>=2` | "Disallow kernel profiling by users without `CAP_PERFMON`."           |

The documentation also notes that `CAP_SYS_ADMIN` still works "for backward compatibility reasons" but
that its use for this purpose "is discouraged".

**[Derived] Conclusion.** `perf`, Nsight Systems CPU sampling, and Arm PMU counters all require
`CAP_PERFMON` inside the container plus a host `perf_event_paranoid` relaxation. ADR-006 §9 mandates
minimum device privilege and prohibits `--privileged`. These are in direct tension, and the resolution
must be explicit:

- Profiling is a **named, separate runtime configuration** that grants `CAP_PERFMON` to one container.
  It is never the deployed configuration and never runs at a competition.
- The **image is unchanged**; only the runtime capability set differs. This keeps ADR-006 §10 digest
  identity intact.
- **The profiled configuration is nonetheless not behaviourally identical to production**, because the
  capability set and the paranoid level differ. Any timing number taken under profiling is an upper
  bound on the observed system, not a measurement of the deployed one. This must be stated whenever
  such a number is reported.

### 5.4 Memory bandwidth, and a defect in the vendor documentation

Topic 9 flagged that core pinning does not partition memory bandwidth or last-level cache on Orin, and
left it as an open gap. `tegrastats` is the tool that addresses it. The relevant field, verbatim
[Upstream, NVIDIA _Jetson Linux Developer Guide_ r36.4.3, Tegrastats Utility]:

> "`EMC X%@Y` — External memory controller statistics. **All sysmem/carve-out/GART memory accesses go
> through the memory controller.** ... Percentage of EMC memory bandwidth in use **relative to the
> current running frequency** ... EMC frequency in megahertz"

**[Derived] `EMC %` alone is uninterpretable.** It is normalised to the _current_ frequency, which
DVFS changes at runtime. A rising `EMC %` can mean rising traffic, or falling frequency at constant
traffic. Absolute bandwidth is proportional to the product, so **`EMC %` and `EMC` frequency must
always be recorded and reported together**, and any budget must be stated in absolute terms. A
telemetry design that logs only the percentage will produce a memory-bandwidth history that cannot be
read.

**A documentation-quality finding, reported because it affects confidence in the measurement.** The
published r36.4.3 page contains unresolved internal editorial queries in the shipped text:

> "There's an `EMC_FREQ` in the examples but no `EMC`. Are they the same? If not, we need an
> explanation of `EMC_FREQ` and an example of `EMC`."

> "In the examples there is `GR3D_FREQ` (not documented here) but no `GR3D`. If these are the same
> statistic, which one is named correctly?"

[Primary — read from the live page on 2026-09-01]

**[Derived]** The vendor's own documentation for the primary memory-bandwidth counter contains open
questions about what its fields are called and whether two of them are the same statistic. The field
semantics must therefore be established empirically — by running a known synthetic memory load and
confirming the counter responds as expected — before `EMC %` is used as evidence for anything. This
does not make the counter unusable; it makes an unvalidated reading of it unusable.

Nsight Systems Embedded Platforms Edition is the higher-resolution instrument for the same question:
it offers "Sampling counters from **Arm PMU** (Performance Monitoring Unit). Information such as
**cache misses** gets statistically correlated with function execution" and lets one "identify
functions that have poor cache utilization" [Upstream]. That is precisely the Topic 9 question, at
function granularity.

One operational constraint, verbatim [Upstream, Nsight Systems Installation Guide]:

> "Note that for x86_64 based systems these may be on the same device, whereas **with Tegra or Arm
> based systems they will always be separate.**"

**[Derived]** Profiling the Jetson always requires a second machine as host. It is a lab activity, not
a field one, which is consistent with §5.3.

### 5.5 What each tool can and cannot answer

| Question                                       | Instrument                                          |
| ---------------------------------------------- | --------------------------------------------------- |
| Did the 5 ms cycle overrun, and by how much?   | In-cycle ring buffer. Nothing else — it is in-loop. |
| Why did a ROS callback take too long?          | `ros2_tracing` plus LTTng-UST                       |
| Was the cause scheduling, preemption, or IRQ?  | LTTng kernel tracer, installed separately           |
| Was the cause memory-bandwidth contention?     | `tegrastats` EMC with frequency, then Nsight PMU    |
| Which function has poor cache behaviour?       | Nsight Systems Embedded Platforms Edition           |
| Is the GPU pipeline or the CPU the bottleneck? | Nsight Systems CUDA timeline                        |
| Is a component healthy right now?              | `diagnostics`, and the §3.2 beacon                  |

**[Derived]** The first row is the important one. The tools in every other row are unavailable during
a match, require privileges ADR-006 withholds, or require a second machine. **The only performance
instrument that works at a competition is the one built into the control loop.** That is a strong
argument for putting cycle duration, deadline overruns, and transport counters in the in-cycle record
header as first-class fields rather than deriving them later.

---

## 6. Competition operations

### 6.1 Pre-match validation

**[Derived]** The checks worth automating are the ones whose failure is silent. A robot that will not
boot is obvious; a robot that boots with stale calibration, a full disk, a disabled log mount, or a
gateway bound to the wrong interface is not. Candidates, each already grounded in an accepted ADR:

| Check                                                | Silent if wrong?           | Grounded in         |
| ---------------------------------------------------- | -------------------------- | ------------------- |
| Release digest matches the intended release          | Yes                        | ADR-006 §10         |
| Calibration and safety manifest identities match     | Yes                        | ADR-002             |
| Log storage mounted, writable, sufficient free space | **Yes**                    | §3.3                |
| Real-time privileges granted and read back           | No — startup fails         | ADR-006 §8          |
| GameController broadcast actually received           | **Yes**                    | ADR-005-12, Topic 8 |
| Team-communication packets received from teammates   | Yes                        | ADR-005             |
| Beacon reaching the tethered operator station        | Yes                        | §3.2                |
| Operator station wireless hardware deactivated       | **Yes, and disqualifying** | §1.2                |
| Battery state and worst joint temperature            | No                         | Topic 4             |

### 6.2 Network validation

Topic 8 gate 3 already requires broadcast reception to be verified across the real container boundary
rather than over loopback. **[Derived]** At a competition that test must be re-run **on the venue
network**, because the failure it targets — a container that cannot see host-subnet broadcasts — also
occurs when the venue router's subnet or broadcast behaviour differs from the lab's. Passing in the lab
is not evidence about the venue.

Validation is receive-only per §1.2, so it consists of: confirming GameController packets arrive with
plausible content and age, confirming teammate packets arrive, confirming the beacon reaches the wired
operator station, and confirming the robot's own transmit volume stays under the 1 Mbit/s cap. The last
is measurable at the gateway, which owns every competition socket, and should be reported in the beacon
so that a rule violation is visible rather than inferred.

### 6.3 Rollback

**[Derived]** ADR-006 §10 makes rollback structurally simple: images are digest-pinned, so the previous
release is a different digest and reverting is a configuration change, not a rebuild. Three conditions
make it actually work under time pressure:

1. **The previous release is already on the robot.** Pulling an image at a venue is subject to §1.1 and
   is not realistic. Both digests must be resident before the tournament.
2. **Rollback covers calibration and configuration, not only images.** A release is the image digest
   _plus_ the safety manifest, calibration digests, and Zenoh configuration digests. Reverting one
   without the others recreates the identity mismatch the ADR-002 interlock exists to catch — which
   fails safe, but fails.
3. **Rollback is verified by the same pre-match checks in §6.1**, on the clock, inside the five-minute
   half-time or between matches. A rollback that cannot be validated in that window is not a rollback,
   it is a gamble.

The decision to roll back is a judgement call, but the evidence for it should not be: the beacon and
the in-cycle log are what distinguish "the robot played badly" from "the release regressed".

---

## 7. Falsifiable gates

| #   | Gate                                                                                                                             | Pass condition                                                                                                            |
| --- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Bandwidth compliance.** Measure total transmitted volume per robot over a full match under worst-case team and beacon traffic. | Below 1 Mbit/s with margin. Measured at the gateway and reported in the beacon.                                           |
| 2   | **No transmission to a playing robot.** Audit every process for sockets and sessions that transmit toward the robot during play. | Only receive-only UDP monitoring exists. The ADR-003 operator link is provably disabled in the competition configuration. |
| 3   | **In-cycle logging cost.** Measure cycle duration with logging on and off on the target hardware.                                | Difference within the ADR-006 gate 4 budget. Worst case, not mean.                                                        |
| 4   | **Clock correlation.** Step the system clock during a recorded run.                                                              | Control-cycle correlation is unaffected, because correlation is by cycle sequence number, not timestamp.                  |
| 5   | **Log survives power loss.** Cut power mid-match repeatedly.                                                                     | At most one roll interval is lost; the remainder is readable and indexed.                                                 |
| 6   | **Silent non-recording is impossible.** Boot with a full disk, an unmounted log volume, and a read-only mount.                   | Each is caught by the startup interlock and reported in the beacon. None reaches a match.                                 |
| 7   | **`SafetyKernel` auditability.** Force a projection and inspect the log.                                                         | The pre-projection and post-projection tuples are both recoverable for the affected joints.                               |
| 8   | **Zero-touch triage.** Inject each ADR-002 fault class and diagnose from the beacon and touchline signals alone.                 | Fault class identified without servicing the robot. Any class that cannot be is documented as a known blind spot.         |
| 9   | **Half-time rehearsal.** Execute battery change, inspection, log extraction, and pre-match checks against a 5 minute clock.      | Completed and verified within the window, repeatedly, by someone who did not write the procedure.                         |
| 10  | **EMC counter validated.** Run a known synthetic memory load and observe `tegrastats`.                                           | `EMC %` and frequency respond as predicted. Absolute bandwidth is computed, not inferred from the percentage.             |
| 11  | **Profiling privileges are non-default.** Inspect the deployed runtime configuration.                                            | No deployed container holds `CAP_PERFMON` or `CAP_SYS_ADMIN`. The profiling configuration is separate and named.          |
| 12  | **Tracing overhead measured on target.** Enable `ros2_tracing` under full load on Orin.                                          | Worst-case per-cycle cost measured, not quoted from literature. Tracing state is recorded in every timing report.         |
| 13  | **Rollback drill.** Revert to the previous release digest, including calibration and configuration, and pass the §6.1 checks.    | Completed within the between-matches window, with both digests already resident on the robot.                             |
| 14  | **Venue network re-validation.** Re-run Topic 8 gate 3 on the competition network.                                               | Broadcast reception confirmed on the venue subnet, not inferred from the lab result.                                      |

---

## 8. Open gaps

1. **Storage medium, capacity, and write endurance are undecided**, inherited from Topic 9 gap 9 and
   ADR-007. Approximately 204 MB per match for control data plus an unbudgeted perception volume,
   across a tournament and a season of testing, is an endurance question that has not been asked.
2. **The perception-plane recording volume is unbudgeted.** It is likely to dominate total storage by
   one to two orders of magnitude, and it is the reason `snapshot_mode` exists. No number can be
   produced until the camera and resolution are selected in Topic 5.
3. **`ros2_tracing` overhead on Orin is unmeasured.** The only figure available is a third-party
   average from a different system.
4. **`tegrastats` field semantics are ambiguous in the vendor's own documentation** (§5.4) and must be
   established empirically.
5. **Absolute memory-bandwidth headroom is uncomputable** until the Jetson module is selected, because
   peak EMC bandwidth is a module property.
6. **Beacon content is a proposal, not a measurement.** Its size and rate should be validated against
   gate 1 once the ADR-005 team-message rate is fixed in configuration.
7. **Calibration procedures cannot be written** while Topic 3 Model Gate 0 is open. Only the workflow,
   identity scheme, and interlock can be built.
8. **Turf friction estimation has no identified tooling** and no released package. It is venue-specific
   by nature and must be a project-built procedure executed on site.
9. **Between-matches time is NR in the Laws** and is set by the competition schedule. The five-minute
   half-time is the only rule-bounded window, so procedures should be designed to it and relaxed if the
   schedule proves more generous.
10. **LED and audible state encoding is proposed on reasoning, not evidence.** No measurement exists of
    how reliably a handler can distinguish states from the touchline under competition lighting and
    noise, and the physical envelope that would carry the indicators is undesigned.

---

## References

- **[R-1]** RoboCup Humanoid League, _Laws of the Game 2025_ (14 April 2025) — Law 3 substitutions and
  half-time interval; Law 4 autonomy, bandwidth cap, WLAN and tethered-LAN restrictions, remote
  emergency stop; the in-service and penalty-clock clauses; Request for Pick-up.
- **[S-1]** `foxglove/mcap` `website/docs/spec/index.md` — record opcodes and field semantics for
  `Header`, `Schema`, `Channel`, `Message`, `Chunk`, `Chunk Index`, `Attachment`, `Metadata`, and the
  summary and footer sections.
- **[S-2]** `ros2/rosbag2` `jazzy` — `rosbag2_storage/storage_options.hpp` (`snapshot_mode`,
  `max_bagfile_size`, `max_cache_size`, `custom_data`) and `rosbag2_transport/record_options.hpp`
  (compression, QoS overrides, exclusions, thread priority).
- **[S-3]** `ros2/rcl` `jazzy` `rcl/include/rcl/time.h` — `RCL_ROS_TIME`, `RCL_SYSTEM_TIME`, and
  `RCL_STEADY_TIME` semantics.
- **[S-4]** `ros2/ros2_tracing` `jazzy` `README.md` — LTTng dependency since Iron, userspace-only
  default, `lttng-modules-dkms` for kernel tracing, `TRACETOOLS_DISABLED`, Quality Level 1 declaration,
  the cited 158 ns per-tracepoint average, `tracing` group requirement, and the `LD_PRELOAD` behaviour
  of the `Trace` launch action.
- **[S-5]** `torvalds/linux` `Documentation/admin-guide/sysctl/kernel.rst` — `perf_event_paranoid`
  default and level table.
- **[S-6]** NVIDIA _Jetson Linux Developer Guide_ r36.4.3, Tegrastats Utility — `EMC`, `RAM`, and
  `GR3D_FREQ` field descriptions, and the unresolved editorial queries quoted in §5.4.
- **[S-7]** NVIDIA _Nsight Systems Installation Guide_ — Embedded Platforms Edition scope, L4T support,
  Arm PMU and cache-utilisation features, and the separate-host requirement on Tegra.
- **[S-8]** `ros/rosdistro` `jazzy/distribution.yaml` — released versions and status for `diagnostics`
  4.2.7-1, `image_pipeline` 5.0.13-1, `ros2_tracing` 8.2.6-1, `libstatistics_collector` 1.7.4-1,
  `geometry2` 0.36.22-1, `ros2cli` 0.32.12-1, and the absence of `system_metrics_collector`.
- **[S-9]** `rbonghi/jetson_stats` `LICENSE` — GNU Affero General Public License v3.
- **[D-1]** [ADR-002](../architecture/ADR-002-safety-and-fault-management.md) — startup interlock and
  safety states.
- **[D-2]** [ADR-006](../architecture/ADR-006-runtime-and-containers.md) — container privilege limits
  and digest-pinned release identity.
- **[D-3]** [ADR-007](../architecture/ADR-007-simulation-sil-hil.md) — the two telemetry planes and the
  in-cycle sizing this topic builds on.
