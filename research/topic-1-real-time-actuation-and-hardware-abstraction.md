# Topic 1 Research: Real-Time Actuation and Hardware Abstraction

- Status: **Retroactive evidence baseline.** Assembled 2026-09-02, after ADR-001 was accepted on 2026-07-24. Update before any Topic 1 architecture revision.
- Evidence last verified: 2026-09-02
- Scope: Research input for Topic 1. The decision itself is recorded in ADR-001 and is not restated or revised here.
- Canonical decisions: [ADR-001](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md), and downstream [ADR-002](../architecture/ADR-002-safety-and-fault-management.md), [ADR-006](../architecture/ADR-006-runtime-and-containers.md), [ADR-007](../architecture/ADR-007-simulation-sil-hil.md)
- Related research: [Topic 2](topic-2-safety-and-fault-management.md), [Topic 3](topic-3-locomotion-survey.md), [Topic 4](topic-4-sensors-timing-state-estimation.md), [Topic 9](topic-9-runtime-and-containers.md), [Topic 10](topic-10-simulation-sil-hil.md)

## Purpose and evidence policy

Topics 1 and 2 were decided before this project adopted the research-first convention used from
Topic 3 onwards. Every later ADR rests on Topic 1's timing and interface claims, but those claims
were never written down as an auditable evidence baseline. This document supplies that baseline
after the fact.

**What "retroactive" means here, precisely.** This is not a justification of ADR-001. The evidence
was gathered independently, from primary sources, without treating the accepted decision as a
conclusion to be reached. Where the evidence supports ADR-001 it says so. Where it does not, it
says that too, in a dedicated section, and the ADR is left untouched. Several findings in
[section 8](#8-evidence-that-challenges-the-accepted-decision) are of the second kind, and two of
them are serious.

Evidence tags follow the Topic 4-12 convention:

| Tag             | Meaning                                                                                                         |
| --------------- | --------------------------------------------------------------------------------------------------------------- |
| **[Primary]**   | Read directly from a source file, generated header, configuration file, or vendor document at a named location. |
| **[Upstream]**  | Stated by the maintainer or vendor in their own documentation.                                                  |
| **[Community]** | Stated by a third-party implementation or an unaffiliated publisher. Corroboration, not authority.              |
| **[Derived]**   | Computed or concluded here from tagged inputs. Reasoning shown so it can be checked or refuted.                 |
| **[Project]**   | A target or constraint set by this project.                                                                     |
| **NR**          | **Not reported.** Never means zero.                                                                             |

**Primary-source note.** The as-built firmware lives outside this documentation repository, at
`C:\dev\soccer-firmware`. Every `[Primary]` claim about the current actuation path in
[section 5](#5-the-as-built-path-audited) was read from that tree on 2026-09-02. File paths are
given relative to that root. Nothing in that section is inferred from the project brief or from
the architecture documents that describe the firmware, because in three cases those documents and
the firmware disagree.

## Confirmed project inputs

| Input              | Confirmed state                                                                                    | Architectural consequence                                                    |
| ------------------ | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Control law        | MIT-style joint impedance, five commanded fields per joint                                         | The command unit is a tuple, not five independent scalars                    |
| Cycle rate         | 200 Hz, 5 ms period, scheduled by the microcontroller not the host [Project]                       | The host must meet a deadline it does not own                                |
| Framework          | ROS 2 Jazzy Jalisco with `ros2_control` [Project]                                                  | Command and state interfaces are the only sanctioned data path into hardware |
| Middleware         | `rmw_zenoh_cpp` (ADR-003), explicitly excluded from the actuation cycle                            | No DDS or Zenoh call may appear inside `read`/`write`                        |
| Compute            | Jetson Orin family, module not fixed at Model Gate 0 (Topic 9)                                     | Timing claims must hold across Orin Nano through AGX                         |
| Actuators          | RobStride RS-series, models RS00/RS02 built, RS03 planned for hips                                 | Per-model differences are load-bearing, not cosmetic                         |
| Physical path      | Jetson USB CDC to master STM32F446RE, SPI to slave STM32F446RE, 1 Mbit/s classic CAN to drives     | Four protocol hops between controller and actuator                           |
| Degrees of freedom | 7 motors wired today; 14-joint kinematic target at Model Gate 0 (Topic 3); 20+ as a scaling target | Bus capacity must be checked against the target, not the build               |
| Simulation seam    | The same interface must serve SIL, HIL, replay and fault injection (ADR-007)                       | The abstraction cannot leak bus concepts upward                              |

## Binding external constraints

| Constraint                                                                                 | Source     | Consequence                                                              |
| ------------------------------------------------------------------------------------------ | ---------- | ------------------------------------------------------------------------ |
| `controller_manager` `update_rate` is a read-only parameter, default 100                   | [Upstream] | The ROS-side rate is fixed at launch; it cannot be retuned live          |
| A hardware component's `rw_rate` is clamped to the `controller_manager` rate if set higher | [Upstream] | `rw_rate` can only make a component slower, never faster                 |
| `get_lifecycle_state()` is documented as not real-time safe                                | [Upstream] | Lifecycle state cannot be consulted inside the cycle                     |
| Command interfaces remain available and are written even in the `INACTIVE` state           | [Upstream] | Deactivation is not a command gate; see Topic 2                          |
| Classic CAN 2.0B, 1 Mbit/s, 8-byte payload, 29-bit identifier                              | [Primary]  | Frame cost and therefore joint count per bus are fixed by arithmetic     |
| RobStride MIT frame encodes each field as a 16-bit unsigned integer over a per-model span  | [Primary]  | The span is part of the interface contract, not an implementation detail |

---

## 1. The control law, and why the command is one object

### 1.1 The law

Every RobStride drive in MIT mode closes the following loop internally, at its own current-loop
rate:

$$\tau = K_p\,(q_d - q) \;+\; K_d\,(\dot q_d - \dot q) \;+\; \tau_{ff}$$

The host therefore supplies five numbers per joint per cycle:

| Field     | Symbol      | Unit      | Meaning                                    |
| --------- | ----------- | --------- | ------------------------------------------ |
| position  | $q_d$       | rad       | target joint angle                         |
| velocity  | $\dot q_d$  | rad/s     | target joint rate                          |
| effort    | $\tau_{ff}$ | N·m       | feed-forward torque                        |
| stiffness | $K_p$       | N·m/rad   | proportional gain, host-selected per cycle |
| damping   | $K_d$       | N·m·s/rad | derivative gain, host-selected per cycle   |

[Primary] `docs/robostride-motor-reference.md`, and the `Communication_Type_MotionControl` frame
layout in the vendor and community implementations cited in [section 3.4](#34-the-can-protocol).

### 1.2 Why partial application is not a degraded version of the same command

The tempting simplification is to treat $K_p$ and $K_d$ as configuration and stream only
$(q_d, \dot q_d, \tau_{ff})$. That is not a reduced-fidelity version of the law; it is a different
law with different stability properties.

Consider a single joint tracking a reference while the host intends a compliance change. Suppose
the host wants to move from a stiff stance configuration $(K_p = 60, K_d = 2)$ to a compliant
swing configuration $(K_p = 8, K_d = 0.5)$ while simultaneously commanding a position step of
$0.15$ rad. If the tuple is applied atomically, the resulting torque at the instant of the step is

$$\tau = 8 \times 0.15 = 1.2\ \text{N·m}$$

If the gains are stale by one cycle and only the position updates, the same instant produces

$$\tau = 60 \times 0.15 = 9.0\ \text{N·m}$$

[Derived] A 7.5-fold torque overshoot, lasting one 5 ms cycle, from a one-cycle ordering error.
On an RS02 with a 17 N·m peak that is survivable; on an RS03 with a 60 N·m peak driving a hip it
is a leg kick. The magnitude of the error is set by the _gain ratio_, which for a stance-to-swing
transition on a biped is routinely between 5 and 10.

The symmetric failure is worse: applying the low gain with the _old_ position produces a limp
joint at exactly the moment the controller believed it had commanded a stiff one.

**Conclusion.** [Derived] Atomicity of the five fields is not a convenience. It is the condition
under which the commanded torque is the torque the controller computed. Any interface that lets
the five fields arrive at the actuator at different times has changed the plant.

### 1.3 What this demands of the interface

Three properties follow, and they are independent:

1. **Co-ownership.** All five interfaces for a joint must be claimed by one controller.
   Splitting them across controllers reproduces the ordering error at the resource-manager level.
2. **Co-transmission.** The five values for a joint must reach the drive in one message, or in a
   set of messages the drive applies together. A transport that delivers three of five has not
   delivered a degraded command; it has delivered a different one.
3. **Co-validation.** Any safety projection must operate on the tuple, not field by field. This is
   the load-bearing input to Topic 2 §3 and is developed there.

---

## 2. The `ros2_control` surface in Jazzy

All claims in this section were read from the `jazzy` branch of `ros-controls/ros2_control` on
2026-09-02, from the reStructuredText sources under `hardware_interface/doc/` and
`controller_manager/doc/`.

### 2.1 Interface naming and data types

[Upstream] `hardware_interface_types_userdoc.rst`. A joint declares command and state interfaces
by name, with an optional `data_type` and optional `min`, `max`, and `initial_value` parameters.
The framework attaches no meaning to the name. The standard names `position`, `velocity`, `effort`
are conventions used by shipped controllers, not a closed set.

Supported data types and their default initial values [Upstream]:

| `data_type`        | Default initial value |
| ------------------ | --------------------- |
| `double` (default) | NaN                   |
| `float32`          | NaN                   |
| `bool`             | `false`               |
| `uint8`            | 255                   |
| `int8`             | 127                   |
| `uint16`           | 65535                 |
| `int16`            | 32767                 |
| `uint32`           | 4294967295            |
| `int32`            | 2147483647            |

[Derived] Two consequences for Topic 1:

- The five-field MIT contract is expressible directly and without extension: a joint declares
  `position`, `velocity`, `effort`, `stiffness`, `damping` as command interfaces. No fork, no
  patch, no custom resource manager.
- Drive fault words can be surfaced as typed state interfaces (`uint32` or `uint16`) rather than
  being packed into a `double`. The non-NaN sentinel defaults are useful: an unwritten `uint32`
  status interface reads as `4294967295`, which is distinguishable from a genuine all-clear zero.

**Caveat.** [Derived] The `min` and `max` parameters on a `command_interface` are per-interface
scalars. They are exactly the independent-field clamping that section 1.2 shows to be unsound as a
torque bound. They are useful as a coarse sanity limit and unusable as the safety envelope. Topic
2 §3 develops this.

### 2.2 Rates: `update_rate`, `rw_rate`, and asynchronous components

[Upstream] `controller_manager` `update_rate`: integer, **read-only**, default 100 Hz. Read-only
means it is fixed for the lifetime of the process.

[Upstream] `rw_rate` is an optional attribute on the `ros2_control` tag. Default `0`, meaning "the
same rate as the controller manager". **If the specified rate is higher than the controller
manager rate, the component runs at the controller manager rate.**

[Derived] `rw_rate` is a divider, never a multiplier. It can express "this sensor only needs 50 Hz"
but cannot express "this actuator needs 500 Hz while everything else runs at 200 Hz". A component
requiring a faster rate than the manager forces the manager's rate up, which raises the rate of
every synchronous component. This is the mechanism behind ADR-001's rule that `rw_rate` is only
for explicitly slower hardware.

[Upstream] `asynchronous_components.rst`. A component may set `is_async="true"` and configure,
inside a `properties` block, an `async` element with `thread_priority` (0-99, default 50),
`affinity` (list of CPU ids, default empty), `scheduling_policy`, and `print_warnings` (default
`true`). Asynchronous components use FIFO scheduling. `scheduling_policy` takes:

- `synchronized` (default): the controller manager still triggers `read` and `write`.
- `detached`: the component manages its own `read`/`write` timing.

[Derived] `detached` is the only `ros2_control`-native construct that decouples a hardware
component's cadence from the manager's. It costs the guarantee that controller output and hardware
write belong to the same cycle, which reintroduces the ordering hazard of section 1.2 at the
component boundary. For an actuation path whose whole premise is tuple atomicity, `detached` is a
poor fit; for a camera or an IMU it is appropriate.

### 2.3 The real-time contract the framework imposes and admits

[Upstream] `controller_manager` documentation, determinism section:

- The main thread attempts `SCHED_FIFO` at priority 50. Parameters `thread_priority`,
  `cpu_affinity` (integer or integer array), and `lock_memory` are provided. `lock_memory` defaults
  to `false` on a non-real-time kernel and `true` on a real-time kernel.
- Under Docker the process needs `--cap-add=sys_nice`, `--ulimit rtprio=99`, and
  `--ulimit memlock=-1` for those settings to take effect. This is the direct upstream basis for
  the container capability set in ADR-006.
- **"Avoid using the `get_lifecycle_state()` method in the real-time control loop ... it is not
  real-time safe."**
- `prepare_command_mode_switch` and `perform_command_mode_switch` calls **cause jitter in the main
  control loop**.
- `hardware_synchronization.expect_blocking_read_write` (default `false`) and
  `hardware_synchronization.minimum_cycle_time` (default 0.0001 s) exist specifically to describe
  hardware whose `read`/`write` blocks.
- Overrun handling is exposed as `overruns.manage` and `overruns.print_warnings`.
- Diagnostics thresholds are published with defaults: execution-time mean error warn at 1000 µs and
  error at 2000 µs; execution-time standard deviation warn at 100 µs and error at 200 µs;
  periodicity mean error warn at 5.0 Hz and error at 10.0 Hz.

[Derived] Three observations that matter for ADR-001:

1. The framework's own diagnostics treat a 2000 µs mean execution-time error as an error condition.
   On a 5 ms budget that is 40 % of the period. The default thresholds were chosen for 100 Hz
   loops and are too loose for this application; they must be tightened, not accepted.
2. `expect_blocking_read_write` is an admission that blocking transports exist and a request to
   declare them. Declaring it does not make the blocking safe; it changes how the manager accounts
   for the time. A transport that blocks without a deadline is still unbounded.
3. Mode switching is documented as a jitter source. Any safety design that requires a controller
   switch to complete within a hard deadline is building on a mechanism upstream describes as
   non-deterministic. Topic 2 §2.3 uses this.

### 2.4 Error handling and the hardware lifecycle

[Upstream] `handling_errors_during_read_write.rst`, quoted in full because it is short and
consequential:

> If `hardware_interface::return_type::ERROR` is returned from `read()` or `write()` methods of a
> hardware_interface class, `on_error(previous_state)` method will be called to handle any error
> that happened. Error handling follows the node lifecycle. If successful
> `CallbackReturn::SUCCESS` is returned and hardware is again in `UNCONFIGURED` state, if any
> `ERROR` or `FAILURE` happens the hardware ends in `FINALIZED` state and can not be recovered.
> The only option is to reload the complete plugin, but there is currently no service for this in
> the Controller Manager.

[Upstream] `lifecycle_of_a_hardware_component.rst`. States and the methods that produce them:

| State          | Entered by                      | Command interfaces                                  |
| -------------- | ------------------------------- | --------------------------------------------------- |
| `UNCONFIGURED` | `on_init`, `on_cleanup`         | Not imported into the resource manager              |
| `INACTIVE`     | `on_configure`, `on_deactivate` | **Available and written** (see caveat below)        |
| `ACTIVE`       | `on_activate`                   | Available; power circuits active, brakes disengaged |
| `FINALIZED`    | `on_shutdown`                   | Component ready for destruction                     |

The `INACTIVE` entry carries an upstream note that is the single most important upstream fact in
this document:

> As of now, it is left to the hardware component implementation to continue using the command
> received from the `CommandInterfaces` or to skip them completely. ... currently, all command
> interfaces are available and will be written.

[Primary] The linked issue is `ros-controls/ros2_control#931`, "All command interfaces are
available in `inactive` state", opened 2023-02-02 and **still open** as of 2026-09-02. The linked
roadmap item for safety-critical interfaces is a plan, not a shipped feature.

[Derived] Three conclusions:

1. **ROS-level fault recovery is a one-way door.** Returning `ERROR` from `write()` puts the
   component on a path whose best outcome is `UNCONFIGURED` and whose failure outcome is
   `FINALIZED` with no recovery service. A design that returns `ERROR` on a transient bus fault
   has converted a recoverable fault into a process restart. This is a strong argument for
   handling transient faults below the `return_type` boundary and reserving `ERROR` for conditions
   that genuinely warrant tearing the stack down.
2. **Deactivation is not a command gate.** Because command interfaces remain available and written
   in `INACTIVE`, moving a component to `INACTIVE` does not stop commands reaching the hardware.
   Whatever stops them must be inside the component. This is developed in Topic 2 §2.3 and is the
   evidentiary basis for placing the final gate in the hardware component rather than in the
   lifecycle.
3. **Recovery must be designed around the framework, not with it.** Re-arming after a fault, if it
   is to happen without a process restart, cannot route through `on_error`.

### 2.5 Isolation granularity, and the `group` tag

[Upstream] `hardware_interface_types_userdoc.rst`, "Hardware Groups". A `group` tag inside a
`ros2_control` block associates hardware components so that an error in one propagates to the
others. **By default, actuator errors are isolated to their own hardware component, allowing the
rest to continue operation unaffected.**

[Upstream] `controller_manager` documentation: if a hardware component's `read` or `write` returns
`ERROR`, the controller manager stops all controllers using that hardware's interfaces. A
controller returning `ERROR` is deactivated along with its chain, and fallback controllers are
then attempted.

[Derived] The granularity of ROS-level fault isolation is **the hardware component**, not the
joint. A design with one `System` component covering every joint therefore has exactly two states
at the ROS level: all joints commanded, or no joints commanded. There is no per-joint ROS-level
isolation available, with or without the `group` tag — the `group` tag makes isolation _coarser_,
never finer.

This is not an argument against the single-component design. It is a statement of what that design
does and does not buy: per-joint isolation, if it is wanted, must be implemented below the
`return_type` boundary, inside the component and in the firmware. Topic 2 §7 takes this up.

### 2.6 What `ros2_control` does not provide

[Derived] Enumerated because absence is easy to assume away:

| Not provided                                         | Consequence                                                   |
| ---------------------------------------------------- | ------------------------------------------------------------- |
| Any notion of a safety-rated or privileged interface | The gate must be application code                             |
| Command validity or freshness semantics              | Staleness detection is the component's job                    |
| A per-joint enable or disable concept                | Availability must be modelled in the component's own types    |
| Guaranteed atomic multi-interface write to hardware  | Atomicity is the component's job                              |
| A plugin-reload service                              | `FINALIZED` is terminal within the process                    |
| Bounded-time guarantees for `read`/`write`           | The deadline must be enforced by the transport implementation |

---

## 3. Actuator evidence: RobStride RS-series drives

### 3.1 Product envelope

[Primary] `docs/robostride-motor-reference.md`, transcribed from the vendor product tables.

| Model | Rated torque (N·m) | Peak torque (N·m) | No-load speed (rpm / rad·s⁻¹) | Rated / peak current (A) | Torque constant (N·m/Arms) | Gear ratio | Poles | Mass (g) | Voltage (V)     |
| ----- | ------------------ | ----------------- | ----------------------------- | ------------------------ | -------------------------- | ---------- | ----- | -------- | --------------- |
| RS00  | 5                  | 14                | 315 / 33.0                    | 4.7 / 15.5               | 1.48                       | 10:1       | 28    | 310      | 24-60, 48 rated |
| RS02  | 6                  | 17                | 410 / 42.9                    | 7 / 23                   | 1.22                       | 7.75:1     | 28    | 380      | 24-60, 48 rated |
| RS03  | 20                 | 60                | 195 / 20.4                    | 13 / 43                  | 2.36                       | 9:1        | 42    | 900      | 15-60, 48 rated |
| RS05  | 1.6                | 5.5               | 480 / 50.3                    | 2.4 / 11                 | 0.94                       | 7.75:1     | 20    | 191      | 15-60, 48 rated |
| RS06  | 11                 | 36                | 480 / 50.3                    | 14.3 / 57                | 1.1                        | 9:1        | 28    | 621      | 15-60, 48 rated |

Environment [Primary]: FOC drive, operating −20 to 50 °C, storage −30 to 70 °C, humidity 5-85 %,
Class B insulation.

[Derived] Operating ceiling of 50 °C ambient is a competition-relevant constraint. Indoor venues
under stage lighting with a robot's own dissipation inside a shell are plausibly within 15 °C of
that ceiling; see Topic 2 §3.5 on thermal derating.

### 3.2 Electrical characteristics

[Primary]

| Model | Rated power (W) | No-load current (Arms) | Back-EMF constant | Phase resistance (Ω) | Phase inductance |
| ----- | --------------- | ---------------------- | ----------------- | -------------------- | ---------------- |
| RS00  | 50              | 0.5                    | 0.095 Vrms/rpm    | 1.5                  | 750 µH           |
| RS02  | 60              | 0.5                    | 0.096 Vrms/rpm    | 0.55                 | 486 µH           |
| RS03  | 210             | 0.6                    | 17 Vrms/krpm      | 0.39                 | 275 µH           |
| RS05  | 17              | 0.14                   | 7.4 Vrms/krpm     | 2.72                 | 813 µH           |
| RS06  | 115             | 0.98                   | 7.6 Vrms/krpm     | 0.23                 | 165 µH           |

[Derived] Continuous electrical budget for the currently wired configuration (2 × RS02 + 3 × RS00
on slave 0, per `configs/slave0.yaml`) is $2(60) + 3(50) = 270$ W. Adding the four RS03 hips
implied by the 14-joint target adds $4(210) = 840$ W, for **1110 W continuous** before the
remaining joints, host, and sensors. This is a power-system input for Topic 3 Model Gate 0 and is
recorded here because it is a direct consequence of actuator selection, which is a Topic 1 concern.

### 3.3 Overload curves

[Primary] The vendor publishes a discrete overload curve per model: torque against permitted
duration. These are the empirical basis for any time-dependent torque envelope.

| Model | Continuous (N·m) | Overload points (N·m / s)        |
| ----- | ---------------- | -------------------------------- |
| RS00  | 5                | 7/120, 10/18, 12/10, 14/5        |
| RS02  | 6                | 6.5/3000, 11/100, 15/18, 17/10   |
| RS03  | 20               | 30/189, 40/126, 50/12, 60/7      |
| RS05  | 1.6              | 2/300, 3/41, 4/12, 5/5.5, 5.5/4  |
| RS06  | 11               | 17/200, 20/36, 25/18, 30/8, 36/4 |

[Derived] Three properties of these curves shape the envelope design:

1. **They are not a single peak-plus-duration pair.** RS02 permits 6.5 N·m for 3000 s and 17 N·m
   for 10 s: a 2.6-fold torque range across a 300-fold duration range. A model with one
   `torque_peak` and one `torque_peak_duration` cannot represent this without discarding most of
   the usable envelope or overstating it. See [section 8](#8-evidence-that-challenges-the-accepted-decision), finding 15.
2. **They are steeply non-linear near the top.** RS03 goes from 189 s at 30 N·m to 7 s at 60 N·m.
   Any implementation must interpolate conservatively — piecewise-linear in $\log t$ is defensible;
   linear in $t$ is not.
3. **They are stated at an unspecified ambient temperature and duty history.** The vendor does not
   report the thermal starting condition. NR. A robot that has been walking for four minutes is not
   at the curve's starting condition, and the curve therefore bounds an idealisation, not the
   machine. Treating a published overload point as available capacity is the single most likely way
   to burn a drive.

### 3.4 The CAN protocol

[Primary] `docs/robostride-motor-reference.md` and, independently, the two community
implementations cited below. The drive uses classic CAN 2.0B with a 29-bit extended identifier
partitioned as:

```text
bits 28..24   communication type (mode)
bits 23..8    data field (host id, or type-specific payload)
bits  7..0    target node id
```

The host identifier is `0xFD`.

Communication types [Primary], with the project firmware's implementation status:

| Type | Name                 | Implemented in project firmware |
| ---- | -------------------- | ------------------------------- |
| 0    | Get device id        | Yes                             |
| 1    | Motion (MIT) control | Yes                             |
| 2    | Motor feedback       | Yes                             |
| 3    | Enable               | Yes                             |
| 4    | Disable              | Yes                             |
| 6    | Set mechanical zero  | Yes                             |
| 7    | Set CAN id           | Yes                             |
| 17   | Read parameter       | Yes                             |
| 18   | Write parameter      | Yes                             |
| 21   | Fault report frame   | **No**                          |
| 22   | Save parameters      | **No**                          |
| 23   | Set baud rate        | **No**                          |
| 24   | Active report frame  | **No**                          |
| 25   | Set protocol         | **No**                          |

[Community] Types 21 to 25 are documented in `ROBSTRIDE-DYNAMICS/Robstride-Dynamics-Python-SDK`
(`robstride_dynamics/protocol.py`, MIT licence). Type 21 is corroborated by
`RobStride/robstride_ros_sample` (`include/motor_ros2/motor_cfg.h`) as
`Communication_Type_ErrorFeedback 0x15`.

**Provenance caution.** [Community] The GitHub organisation `ROBSTRIDE-DYNAMICS` uses the vendor's
name, was created 2025-05-11, and publishes no contact address or homepage. `RobStride` is a
personal account, not an organisation. Neither is provably vendor-operated. Both are treated here
as third-party corroboration, never as authority. Where they disagree with the project's own
transcription of the user manual, [section 3.5](#35-mit-wire-scaling-two-sources-two-answers)
records the disagreement rather than resolving it.

Run modes, selected by writing register `0x7005` [Primary], corroborated [Community]:

| Value | Mode                   |
| ----- | ---------------------- |
| 0     | MIT / motion control   |
| 1     | Position, profile (PP) |
| 2     | Velocity               |
| 3     | Current                |
| 4     | Position, CSP          |

Feedback frame (type 2) identifier data field [Primary]:

| Bits  | Meaning     |
| ----- | ----------- |
| 7:0   | motor id    |
| 13:8  | fault flags |
| 15:14 | status      |

Fault bits [Primary]: 0 undervoltage, 1 driver fault, 2 overheat, 3 encoder fault, 4 stall or
overload, 5 uncalibrated.

STM32 bus configuration in use [Primary] `firmware/slave/slave_general`: CAN1 at 1 Mbit/s,
prescaler 2, BS1 16 TQ, BS2 4 TQ, normal mode, **automatic retransmission disabled (NART)**.

[Derived] NART is the correct choice for a cyclic control bus and deserves recording as a positive
finding: with retransmission enabled, a frame that loses arbitration or errors out can be
re-attempted arbitrarily far into the future, delivering a command from an earlier cycle. Disabling
it converts a transmission failure into a dropped cycle, which is detectable, rather than a stale
command, which is not.

### 3.5 MIT wire scaling: two sources, two answers

Every MIT field is transmitted as a 16-bit unsigned integer interpreted over a per-model span. The
span is therefore part of the interface contract: get it wrong and the physical quantity is wrong
by the ratio of the spans, silently, with no error reported anywhere.

**Position span.** Three independent sources agree.

| Source                                                                    | Position span        |
| ------------------------------------------------------------------------- | -------------------- |
| Project firmware, from RS00/RS02 user manuals [Primary]                   | ±12.57 rad           |
| `ROBSTRIDE-DYNAMICS` SDK, all models [Community]                          | $4\pi$ = ±12.566 rad |
| `sirwart/robstride` `client.py` decode, `raw/65535 × 8π − 4π` [Community] | ±12.566 rad          |

[Derived] Position span ±$4\pi$ rad is corroborated by three sources and can be treated as settled.

**Velocity, torque, stiffness and damping spans. The sources disagree.**

| Model | Project firmware [Primary]                     | `ROBSTRIDE-DYNAMICS` SDK [Community]                  |
| ----- | ---------------------------------------------- | ----------------------------------------------------- |
| RS00  | V ±33 rad/s, T ±14 N·m, $K_p$ 0-500, $K_d$ 0-5 | V ±50 rad/s, T ±17 N·m, $K_p$ 0-500, $K_d$ 0-5        |
| RS02  | V ±44 rad/s, T ±17 N·m, $K_p$ 0-500, $K_d$ 0-5 | V ±44 rad/s, T ±17 N·m, $K_p$ 0-500, $K_d$ 0-5        |
| RS03  | NR                                             | V ±50 rad/s, T ±60 N·m, **$K_p$ 0-5000, $K_d$ 0-100** |
| RS05  | NR                                             | V ±33 rad/s, T ±17 N·m, $K_p$ 0-500, $K_d$ 0-5        |
| RS06  | NR                                             | V ±20 rad/s, T ±60 N·m, **$K_p$ 0-5000, $K_d$ 0-100** |

Two findings follow, of different severity.

**Finding A — the RS00 torque span is disputed.** [Derived] If the SDK is right and the firmware
wrong, a commanded $\tau_{ff}$ of 5 N·m encodes as

$$\text{raw} = \frac{5 - (-14)}{28} \times 65535 = 44\,470$$

and the drive decodes it over ±17 N·m as

$$\tau = \frac{44\,470}{65535} \times 34 - 17 = 6.07\ \text{N·m}$$

a 21 % overshoot. The firmware's RS00 figures do match the RS00 product spec exactly (no-load speed
315 rpm = 33.0 rad/s, peak torque 14 N·m), which is circumstantial support for the firmware, but the
SDK's `rs-05` entry (±33 rad/s) likewise fails to match the RS05 product spec (480 rpm = 50.3
rad/s), so neither table is internally consistent with the product data. **Unresolved. Requires
bench verification.**

**Finding B — the gain spans are not model-invariant, and the firmware assumes they are.** This is
the more serious of the two.

[Primary] The project firmware defines `KP_MAX 500.0f` and `KD_MAX 5.0f` as global constants, and
`configs/slave0.yaml` states in comments that $K_p$ and $K_d$ ranges are identical across the
models in use. That is true for RS00 and RS02. [Community] It is false for RS03, RS04 and RS06,
which the SDK gives as $K_p$ 0-5000 and $K_d$ 0-100.

[Derived] The consequence, computed for the exact default gains in `configs/slave0.yaml`
($K_p = 15$, $K_d = 1$) applied to an RS03:

$$\text{raw}_{K_p} = \frac{15}{500} \times 65535 = 1966 \quad\longrightarrow\quad \frac{1966}{65535} \times 5000 = 150\ \text{N·m/rad}$$

$$\text{raw}_{K_d} = \frac{1}{5} \times 65535 = 13\,107 \quad\longrightarrow\quad \frac{13\,107}{65535} \times 100 = 20\ \text{N·m·s/rad}$$

**A ten-fold stiffness error and a twenty-fold damping error**, on the 60 N·m peak-torque actuator
intended for the hips, arising from a constant that is correct for every drive currently wired and
wrong for the first drive to be added. At $K_p = 150$ N·m/rad, a 0.4 rad position error saturates
the RS03's 60 N·m peak.

[Derived] The architectural conclusion is not "fix the constant". It is that **per-model wire
scaling is part of the joint's identity and must travel with the manifest**. The current
`JointEntry` in [joint_manifest.hpp](../src/humanoid_transport/include/humanoid_transport/joint_manifest.hpp)
carries `bus_segment`, `can_node_id`, `gear_ratio`, `direction_sign` and `zero_offset_rad`, but no
actuator model and no wire spans. A manifest that cannot express the difference between an RS02 and
an RS03 cannot detect this class of error, and the digest interlock of ADR-002 will happily certify
a configuration that is off by a factor of ten.

### 3.6 Drive-side capabilities not currently used

[Primary] Register map, corroborated [Community] `robstride_dynamics/protocol.py`:

| Register            | Name           | Type    | Relevance                                                                                                                   |
| ------------------- | -------------- | ------- | --------------------------------------------------------------------------------------------------------------------------- |
| `0x7028`            | `canTimeout`   | uint32  | **The drive's own CAN command timeout.** An independent, drive-enforced watchdog that requires no host or MCU participation |
| `0x700B`            | `limit_torque` | float32 | Drive-side torque ceiling                                                                                                   |
| `0x7017`            | `limit_spd`    | float32 | Drive-side speed ceiling                                                                                                    |
| `0x7018`            | `limit_cur`    | float32 | Drive-side current ceiling                                                                                                  |
| `0x7029`            | `zero_sta`     | uint8   | Zero-calibration state                                                                                                      |
| `0x2005`            | `mechOffset`   | float32 | Mechanical offset                                                                                                           |
| `0x2023`            | `damper`       | float32 | Unpowered back-drive damping                                                                                                |
| `0x2024`            | `add_offset`   | float32 | Position offset                                                                                                             |
| `0x3048` / `0x3041` | `can_status`   | —       | Terminator presence on later RS02 / RS03 batches                                                                            |

[Derived] `canTimeout`, `limit_torque`, `limit_spd` and `limit_cur` are four independent
enforcement points that live in the actuator itself, below every software layer this project
controls, and none of them is currently configured. They are the cheapest available defence in
depth in the entire system: they survive a hung MCU, a hung host, and a corrupted manifest. This is
carried into Topic 2 §5.3 as a concrete recommendation and is recorded here because it is a
property of the chosen actuator, which is a Topic 1 fact.

**Hardware caveat.** [Primary] Later RS02 and RS03 production batches may omit the 240 Ω CAN
terminator. Terminator presence is readable from `can_status`. A bus assembled on the assumption of
built-in termination and populated with late-batch drives is unterminated, which manifests as
intermittent frame errors under load rather than as a clean failure.

**Firmware versions on which the above was verified** [Primary]: RS00 up to `RS00_0.0.3.6`, RS02 up
to `RS02_0.2.3.9`, RS03 up to `RS03_APP_V0311_V1001_20250507`. RS05 and RS06 have no published
changelog. NR.

---

## 4. Capacity arithmetic

This section computes what the physical path can carry. The numbers are [Derived] from documented
frame formats and configured bit rates, and are reproducible from the shown working.

### 4.1 Worst-case classic CAN 2.0B frame

A 29-bit extended data frame with an 8-byte payload comprises:

| Field                | Bits    |
| -------------------- | ------- |
| Start of frame       | 1       |
| Identifier A         | 11      |
| SRR                  | 1       |
| IDE                  | 1       |
| Identifier B         | 18      |
| RTR                  | 1       |
| r1, r0               | 2       |
| DLC                  | 4       |
| Data                 | 64      |
| CRC sequence         | 15      |
| CRC delimiter        | 1       |
| ACK slot + delimiter | 2       |
| End of frame         | 7       |
| **Subtotal**         | **128** |
| Interframe space     | 3       |
| **Total, unstuffed** | **131** |

Bit stuffing applies from the start of frame through the CRC sequence, a region of
$1+11+1+1+18+1+1+1+4+64+15 = 118$ bits. A stuff bit is inserted after five identical consecutive
bits, so the worst case is

$$n_{\text{stuff}} = \left\lfloor \frac{118 - 1}{4} \right\rfloor = 29$$

$$n_{\text{worst}} = 131 + 29 = 160\ \text{bits}$$

At 1 Mbit/s that is **160 µs worst case**, 131 µs unstuffed. Every figure below uses the worst
case, because a control bus must be sized for the frame it will actually meet, not the average one.

### 4.2 Bus utilisation against joint count and rate

Each joint costs one MIT command frame and one feedback frame per cycle: $2 \times 160 = 320$ µs.

$$U = \frac{n \times 320\ \mu\text{s}}{T_{\text{cycle}}}$$

| Joints on one bus        | 200 Hz (5 ms)      | 500 Hz (2 ms)      | 1000 Hz (1 ms)     |
| ------------------------ | ------------------ | ------------------ | ------------------ |
| 4                        | 25.6 %             | 64.0 %             | 128 % — infeasible |
| 5                        | 32.0 %             | 80.0 %             | infeasible         |
| 7 (as built)             | 44.8 %             | 112 % — infeasible | infeasible         |
| 10                       | 64.0 %             | infeasible         | infeasible         |
| 14 (Model Gate 0 target) | 89.6 %             | infeasible         | infeasible         |
| 20 (scaling target)      | 128 % — infeasible | infeasible         | infeasible         |

[Derived] Conclusions:

1. **200 Hz on one 1 Mbit/s classic CAN bus supports at most about 10 joints with usable margin.**
   At 14 joints the bus is 90 % loaded, leaving no room for parameter reads, fault frames,
   discovery traffic, or the retransmission that NART has already been disabled to avoid.
2. **The 14-joint target requires bus segmentation regardless of any other decision.** This is the
   evidentiary basis for `bus_segment` existing as a field in `JointEntry`, and it is a hard
   arithmetic result, not a preference.
3. **Raising the rate is not available on this bus.** 500 Hz caps at four joints per segment. The
   200 Hz choice in ADR-001-03 is consistent with the physical layer; a faster loop would require
   CAN FD, more segments, or a different bus entirely.
4. Utilisation above roughly 60 % on a priority-arbitrated bus makes the latency of the
   lowest-priority node strongly dependent on the traffic of the higher-priority ones. The 44.8 %
   figure for the current build is acceptable; the 89.6 % figure for the target is not, and the
   difference is not a matter of degree.

### 4.3 The SPI segment

[Primary] `firmware/master/Core/Src/main.c` and `master.ioc`. HSE 8 MHz; PLLM 4, PLLN 72, PLLP 2,
giving SYSCLK 72 MHz; PLLQ 3 giving USB 48 MHz; APB2 at 72 MHz. `SPI1` is master with
`BaudRatePrescaler = 64`.

$$f_{\text{SPI}} = \frac{72\ \text{MHz}}{64} = 1.125\ \text{MHz}$$

[Primary] Packet size is `SPI_PKT_SIZE(n) = 1 + 13n` bytes.

| Slave     | Motors | Packet (bytes) | Bits    | Transfer time |
| --------- | ------ | -------------- | ------- | ------------- |
| 0         | 5      | 66             | 528     | 469 µs        |
| 1         | 2      | 27             | 216     | 192 µs        |
| **Total** | **7**  | **93**         | **744** | **661 µs**    |

[Derived] 661 µs is 13.2 % of the 5 ms cycle, spent inside a blocking call
([section 5.3](#53-blocking-calls-inside-the-cycle)). Scaled to 14 joints across three slaves the
figure approaches 1.3 ms, or 26 % of the cycle. The SPI clock is the binding constraint here, not
the packet size: 1.125 MHz is roughly a fortieth of what an STM32F446 SPI peripheral can sustain,
and the prescaler appears to have been chosen for signal-integrity margin rather than for a timing
budget. Raising it is the cheapest available headroom in the whole path.

### 4.4 The USB segment

[Primary] `firmware/master/Core/Src/spi_master.c`: `MASTER_TELE_PERIOD_MS 5`, so telemetry is
emitted at 200 Hz for every motor. `firmware/common/include/protocol.h`: `MsgHeader` is 16 bytes,
`MotorStatePayload` is 23 bytes.

$$R = 200\ \text{Hz} \times 7 \times (16 + 23)\ \text{B} = 54.6\ \text{kB/s} = 1400\ \text{frames/s}$$

[Derived] The byte rate is trivial for USB full-speed CDC. The **frame rate** is not trivial for
the host: 1400 packet arrivals per second, each requiring a read, a CRC check, and a dispatch, on a
path that must not allocate. Scaled to 20 joints this is 4000 frames/s. Batching all motors of one
cycle into a single message would reduce this to 200 frames/s at the same byte rate and is the
obvious structural improvement; it is recorded here as evidence, not proposed as a decision.

USB CDC latency itself is NR: no measurement of Jetson-side USB CDC round-trip latency or its
jitter distribution exists in the project. This is the single largest unmeasured quantity in the
actuation path and is carried to [section 10](#10-open-questions-and-evidence-gaps).

### 4.5 Where the 5 ms goes

[Derived] Assembling the measured and computed components for the current 7-joint build:

| Segment                                   | Time        | Basis                  |
| ----------------------------------------- | ----------- | ---------------------- |
| CAN, 7 joints, command and feedback       | 2.24 ms     | [Derived] §4.2         |
| SPI, both slaves, blocking                | 0.66 ms     | [Derived] §4.3         |
| USB CDC round trip                        | NR          | Never measured         |
| Host `read` + controller update + `write` | NR          | Never measured         |
| MCU processing, both hops                 | NR          | Never measured         |
| **Accounted**                             | **2.90 ms** | **58 % of the budget** |
| **Unaccounted**                           | **2.10 ms** | **42 % of the budget** |

This table is the most important result in section 4. **Fifty-eight percent of a 5 ms cycle is
already committed to serialisation alone, before a single line of host code runs, and the remaining
42 % has never been measured.** The claim in ADR-001 that the path "produces genuinely fresh
command and feedback exchanges at 200 Hz" is plausible on this arithmetic but is not established by
it. [Section 7](#7-what-must-be-measured) sets out what would establish it.

---

## 5. The as-built path, audited

Read from `C:\dev\soccer-firmware` on 2026-09-02. This section describes what the firmware does,
not what it is documented to do. Where those differ, both are stated.

### 5.1 Topology and rates

[Primary] `firmware/common/include/system_config.h`, generated from `slave0.yaml` and `slave1.yaml`:
`NUM_SLAVES 2`, `MAX_MOTORS_PER_SLAVE 5`, `TOTAL_MOTORS 7`, `slave_motor_counts = {5, 2}`,
`slave_motor_ids = {{1,2,3,4,5},{6,7,0,0,0}}`.

[Primary] `firmware/master/Core/Src/spi_master.c`: `MASTER_POLL_PERIOD_MS 5` (200 Hz),
`MASTER_TELE_PERIOD_MS 5` (200 Hz), `MASTER_STATUS_PERIOD_MS 50` (20 Hz). A stale comment in the
same file describes a "50 Hz Jetson command stream"; the code does not implement one.

[Primary] `firmware/slave/slave_general/Core/Src/main.c`: `PHASE1_POLL_PERIOD_MS` equals
`MOTOR_LOOP_PERIOD_MS` equals 5, giving 200 Hz on the slave as well.

[Primary] `firmware/master/Core/Src/main.c` is a bare `while(1) { MotorMaster_ProcessLoop(); }`.
Scheduling is cooperative, driven by `HAL_GetTick()` comparisons with `next_poll_ms += 5`.

[Derived] Two timing consequences. First, `HAL_GetTick()` has 1 ms resolution, so a nominal 5 ms
period carries ±1 ms of quantisation jitter — ±20 % of the period — independent of any load.
Second, `next_poll_ms += 5` rather than `next_poll_ms = now + 5` means that after any overrun the
scheduler catches up by issuing back-to-back cycles. That is the correct choice for long-run rate
accuracy and the wrong one for instantaneous rate stability: a 30 ms stall is followed by six
cycles with no spacing.

### 5.2 What survives of the five-field tuple

This is the finding with the widest consequences.

[Primary] `firmware/common/include/protocol.h`:

```c
typedef struct { float pos; float vel; uint8_t valid; } SpiMitCmd;   /* 9 bytes */
```

The SPI command structure carries **position and velocity only**. There are no fields for
stiffness, damping, or feed-forward torque.

[Primary] `firmware/master/Core/Src/spi_master.c`, first statements of `MotorMaster_SetMitCmd`:

```c
(void)kp; (void)kd; (void)tau_ff;   /* slave uses default_kp/kd from motor_config */
```

The master accepts all five fields at its API and discards three of them.

[Primary] `firmware/slave/slave_general/Core/Src/motor_runtime.c`: every call path invokes
`send_mit(i, 0.0f, ...)`. **Feed-forward torque is hard-coded to zero.** Gains are always
`cfg->default_kp` and `cfg->default_kd` from the generated configuration, or `MOTOR_ZERO_KP` /
`MOTOR_ZERO_KD` during the zeroing routine.

[Primary] `configs/slave0.yaml` sets `default_kp: 15.0` and `default_kd: 1.0` for all five motors.

[Derived] End to end, the host can command $q_d$ and $\dot q_d$. It cannot command $\tau_{ff}$,
$K_p$, or $K_d$. The control law actually executing is

$$\tau = 15\,(q_d - q) + 1.0\,(\dot q_d - \dot q)$$

with fixed gains, on every joint, at all times. This is a fixed-gain PD position controller, not
variable impedance control.

The consequences are not confined to feature completeness:

- The stance-to-swing gain scheduling that section 1.2 analyses is not merely unimplemented; it is
  unrepresentable on this transport.
- Gravity compensation, which is the principal use of $\tau_{ff}$ on a biped, is unavailable. The
  position loop must generate all holding torque from tracking error, which means a steady-state
  error proportional to the load is structural.
- ADR-001-02's atomic five-tuple is satisfied by the C++ types in
  [batch_types.hpp](../src/humanoid_transport/include/humanoid_transport/batch_types.hpp) and defeated
  by the transport beneath them. The abstraction is correct; the one production implementation does
  not honour it.

**The abstraction is doing its job here.** `JointCommand` carries all five fields, and
`TransportCapabilities` exists precisely so a transport can declare what it supports. That a
capability flag for tuple completeness does not yet exist is a gap, not a design error; see
[section 8](#8-evidence-that-challenges-the-accepted-decision), finding 1.

### 5.3 Blocking calls inside the cycle

[Primary] `firmware/master/Core/Src/spi_master.c`, `spi_exchange()`:

```c
HAL_SPI_TransmitReceive(master_hspi, tx, rx, len, HAL_MAX_DELAY);
```

Blocking, polled, with an unbounded timeout. `master.ioc` initialises DMA2 Stream 0 and Stream 3
and enables `SPI1_IRQn`, so the DMA path exists and is not used by the master.

[Primary] The firmware's own `docs/architecture-overview.md` describes this link as "SPI (DMA)".
The master does not use DMA. The slave does: `firmware/slave/slave_general/Core/Src/slave_spi.c`
uses `HAL_SPI_TransmitReceive_DMA` with `NSS_HARD_INPUT` and double-buffered A/B buffers.

[Primary] `firmware/slave/slave_general/Core/Src/motor_runtime.c` contains blocking `HAL_Delay`
sequences: approximately 40 ms per motor in `motor_runtime_arm` (about 200 ms for five motors),
further delays in `motor_runtime_goto_zero`, and roughly 70 ms in the zeroing-arrival re-enable
path. `discover()` blocks up to three attempts of a 300 ms wait plus a 50-100 ms pause per motor at
initialisation.

[Derived] ADR-001's real-time rule that the path must "never wait indefinitely" is violated at the
master by construction. `HAL_MAX_DELAY` converts an unresponsive or absent slave into an
indefinitely stalled control loop rather than a detected, bounded, reportable fault. The
`ActuatorTransport::exchange` signature in
[actuator_transport.hpp](../src/humanoid_transport/include/humanoid_transport/actuator_transport.hpp)
takes a `MonotonicStamp deadline` and documents exactly this hazard — "a transport that waits
indefinitely converts a bus fault into a missed control cycle" — but the deadline cannot be honoured
by a firmware layer that has no concept of one.

The 200 ms arming delay is a separate class of problem: it occurs during a lifecycle transition
rather than in steady state, but it occurs inside the same cooperative loop that services the
watchdog and the SPI link, so for its duration the slave is unresponsive to everything.

### 5.4 Command delivery is not guaranteed per cycle

[Primary] `firmware/master/Core/Src/spi_master.c` builds one command byte per 5 ms tick, from a
mutually exclusive priority ladder:

```text
DISARM  >  GOTO_ZERO  >  ARM  >  MIT  >  HOLD  >  NOP
```

`SPI_CMD_MIT` is emitted only when `mit_pending[s]` is set. Any pending one-shot — arm, disarm,
go-to-zero — displaces the MIT command for that tick.

[Derived] There is no cycle in which a motion command is guaranteed to be delivered. In the cycle
where a joint is armed, no motion command is sent. If two one-shots are pending, two consecutive
cycles carry no motion command. The claim that the system "produces genuinely fresh command and
feedback exchanges at 200 Hz" (ADR-001, Context) holds for feedback and does not hold for commands:
**commands are delivered at up to 200 Hz, opportunistically, with no lower bound.**

This matters beyond throughput. A control law whose command arrival is irregular but whose
feedback is regular experiences the gaps as an unmodelled zero-order hold of varying length. For a
stiff position loop this appears as an impulse each time a delayed command finally lands.

### 5.5 Framing, integrity, and three incompatible protocols

**Framing.** [Primary] `firmware/master/USB_DEVICE/App/usbd_cdc_if.c`, `CDC_Receive_FS()`
accumulates into `static uint8_t accum[128]` and parses a 16-byte header directly from the byte
stream. There is **no COBS encoding, no frame delimiter, and no magic or synchronisation word**. A
file `soccer_cobs.h` exists in the tree and is not included by any `.c` file.

[Derived] The COBS framing described in the project brief, in the firmware's own architecture
document, and in ADR-001's Context block **is not implemented**. Resynchronisation after a byte
loss is therefore accidental: the parser will interpret whatever 16 bytes follow as a header and
rely on CRC failure to reject it.

**Length handling.** [Primary] `hdr.len` is never bounds-checked against the accumulator. The
parser computes `total = 16 + hdr.len` and waits for that many bytes.

[Derived] For `hdr.len > 112` the required total exceeds the 128-byte accumulator and the decoder
stalls until the accumulator overflows and resets, discarding buffered data. This is a
self-inflicted denial of service on a corrupted length field, and it is _not_ a buffer over-read:
the CRC is computed only once `accum_len >= total`, which can never be satisfied. The correct fix
is a bound check; the finding is recorded because a reader of the code could reasonably assume the
worse failure.

**CRC.** [Primary] CRC16-CCITT, initial value 0xFFFF, polynomial 0x1021, computed over the header
with the CRC field zeroed plus the payload. On mismatch the handler executes
`master_link_errors++; accum_len = 0;`.

[Derived] Resetting `accum_len` discards every buffered byte, not merely the failed frame. One
corrupted frame therefore destroys any complete frames that arrived behind it in the same USB
transfer. At 1400 frames/s this converts a single-bit error into a multi-frame outage.

**SPI integrity.** [Primary] Both `SPI_CRCCALCULATION_DISABLE` on master and slave. There is no
checksum on the SPI link at all. Slave presence is inferred by `tele_valid()`, which checks only
that `tele[i].motor_idx == i`.

[Derived] An ordering heuristic on an unchecksummed link is not integrity checking. A stuck-at
pattern, a shifted transfer, or a half-clocked exchange can satisfy it.

**Three protocols.** [Primary] The tree contains three mutually incompatible wire definitions:

| Definition                                              | Header stamp | Message type numbering                                                                                                  | Lifecycle states | Command struct                            |
| ------------------------------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------- | ---------------- | ----------------------------------------- |
| `firmware/common/include/protocol.h` (used by master C) | `ts_ms`      | PING 0x01, MASTER_STATUS 0x02, SLAVE_STATUS 0x03, MOTOR_STATE 0x04, CONTROL_REQ 0x05, CONTROL_RESP 0x06, MOTOR_CMD 0x07 | 8                | `SpiMitCmd`, 9 B, pos+vel                 |
| `firmware/common/include/soccer_protocol.h`             | `ts_us`      | PING 1, DISCOVER 2, MOTOR_STATE_REQ 3, ARM_HOLD 4, DISABLE 5, MOTOR_STATE 6                                             | 10               | `SoccerMotorCmd`, 20 B, pos+vel+kp+kd+tau |
| `host/jetson/protocol.py` (used by the host)            | `ts_us`      | matches `soccer_protocol.h`                                                                                             | 10               | matches `soccer_protocol.h`               |

[Derived] **The host Python and the master firmware implement different protocols.** The host
mirrors `soccer_protocol.h`; the master parses `protocol.h`. The two disagree on the timestamp
field width, on every message type number, on the lifecycle enumeration, and on whether a command
carries gains. A fourth inconsistency exists inside the SPI layer: `slave_spi.c`'s
`spi_update_all_motors()` contains a legacy five-byte-per-motor layout
(`ID | LSB POS | MSB POS | LSB SPD | MSB SPD`) that does not match the nine-byte `SpiMitCmd` the
master transmits.

This is an interface-governance failure of the kind ADR-009-07 exists to prevent, and it is the
strongest available argument for generating wire definitions from a single source rather than
maintaining parallel hand-written ones.

**One documentation defect worth correcting.** [Primary] `protocol.h` annotates `MOTOR_CMD 0x07` as
`/* stub – not wired */` and `SET_ZERO 0x03` as `/* stub – not implemented */`. `CDC_Receive_FS()`
does in fact dispatch `MSG_MOTOR_CMD`, calling `MotorMaster_SetMitCmd(...)`. The comment is wrong,
which matters because it is the comment a reader would trust when deciding whether the path is
live.

**Encoding asymmetry.** [Primary] `slave_spi.c` implements `float_to_uint` using `(1 << bits)` while
`uint_to_float` uses `(1 << bits) - 1`. [Community] `RobStride/robstride_ros_sample` uses
`((1 << bits) - 1)` in both directions.

[Derived] A one-LSB asymmetric encode/decode. Negligible in magnitude, and worth fixing because it
means a value written and read back never compares equal, which silently defeats any round-trip
verification test.

### 5.6 Generated-configuration drift

[Primary] `firmware/common/include/motor_config.h` is auto-generated and the committed copy was
generated **from `slave1.yaml` only**: `N_MOTORS 2u`, CAN ids 6 and 7. `configs/slave0.yaml`
describes five motors with CAN ids 1 to 5.

[Derived] The committed generated header does not describe the five-motor slave. Whether this is
benign depends entirely on the build system regenerating per target, which is exactly the kind of
assumption that generated-artifact commits exist to remove. Committing a generated file that is
valid for one of two targets is worse than committing none.

[Primary] Other constants from the same header: `MOTOR_ZERO_TOL 0.05f` rad, `MOTOR_ZERO_RATE 0.3f`,
`MOTOR_ZERO_KP 4.0f`, `MOTOR_ZERO_KD 1.0f`. `MotorConfig` fields: `can_id`, `model`, `joint_name`,
`soft_min`, `soft_max`, `max_vel`, `max_tau`, `default_kp`, `default_kd`.

[Primary] `configs/slave0.yaml` per-motor limits:

| Index | Bus  | Model | Soft range (rad) | `max_vel` | `max_tau` | `default_kp` | `default_kd` |
| ----- | ---- | ----- | ---------------- | --------- | --------- | ------------ | ------------ |
| 0     | CAN1 | RS02  | ±0.79            | 10.0      | 0.8       | 15.0         | 1.0          |
| 1     | CAN2 | RS02  | ±1.05            | 10.0      | 0.8       | 15.0         | 1.0          |
| 2     | CAN3 | RS00  | ±1.31            | 10.0      | 0.8       | 15.0         | 1.0          |
| 3     | CAN4 | RS00  | ±1.05            | 10.0      | 0.8       | 15.0         | 1.0          |
| 4     | CAN5 | RS00  | ±0.52            | 10.0      | 0.8       | 15.0         | 1.0          |

[Derived] `max_tau` of 0.8 N·m is 13 % of the RS02's 6 N·m rated torque and 16 % of the RS00's
5 N·m. Its interaction with `default_kp` is analysed in Topic 2 §9, because it is a safety finding
rather than an actuation one; the short version is that with $K_p = 15$ the torque trip fires at a
position error of $0.8/15 = 0.053$ rad, or 3.1 degrees.

**A positive finding.** [Primary] `motor_runtime_apply_mit()` enforces per-motor `soft_min` and
`soft_max` on the slave, with a one-sided velocity clamp, independently of anything the host sends.
`wrap_pi()` plus `pos_offset` correctly handles the RobStride single-turn power-up wrap. These are
genuine independent enforcement points at the lowest software layer, and they are the part of the
as-built system that most closely matches the layered-authority intent of ADR-002.

---

## 6. Transport alternatives, recorded and not decided

ADR-001's abstraction exists so that this choice stays open. This section records the state of the
options as of 2026-09-02. **No option is recommended here.** Selecting one is a future decision
with its own ADR.

### 6.1 Direct SocketCAN from the Jetson

Removes both microcontrollers from the command path.

- Removes two protocol hops, the SPI segment, and the USB CDC segment: by
  [section 4.5](#45-where-the-5-ms-goes), roughly 0.66 ms of measured serialisation plus an
  unmeasured USB round trip.
- Requires a CAN controller on the Jetson carrier. Availability is carrier-dependent and the module
  is unfixed at Model Gate 0. NR.
- Moves 200 Hz timing from a bare-metal loop to a Linux userspace process. This is a real cost:
  the microcontroller's 5 ms tick is currently the system's time base, and ADR-001-03 depends on it.
- Eliminates the entire class of findings in [section 5.5](#55-framing-integrity-and-three-incompatible-protocols),
  because there is no custom framing left to get wrong.
- Loses the independent slave-side soft-limit enforcement noted in section 5.6 unless it is
  reimplemented, which would place it in the same failure domain as the controller.

### 6.2 CAN FD

- Raises the payload to 64 bytes and the data-phase bit rate to 5 Mbit/s or more, which changes the
  arithmetic of [section 4.2](#42-bus-utilisation-against-joint-count-and-rate) substantially.
- **Requires drives that speak CAN FD.** The RobStride units in hand are classic CAN 2.0B
  [Primary]. This is therefore not a transport change; it is an actuator change.
- The STM32F446 has no FDCAN peripheral, so it is also a microcontroller change.

Recorded for completeness. Not available without replacing the actuators.

### 6.3 EtherCAT

Two mature open implementations exist: the IgH EtherCAT Master and SOEM (Simple Open EtherCAT
Master).

- Distributed clocks provide sub-microsecond synchronisation across slaves, which is a genuine
  qualitative gain over CAN arbitration for a multi-limb robot.
- Requires EtherCAT slave hardware at every joint. The RobStride drives are CAN. This is again an
  actuator change, not a transport change.
- IgH requires patched network drivers or a generic driver with reduced performance; kernel-module
  coupling interacts badly with the container strategy in ADR-006.
- Licensing must be checked before adoption; the project excludes GPL and AGPL for distributed
  application code (Topic 5 §4.1.1) and IgH's licensing has historically been a point of care. Not
  verified here. NR.

[Derived] ADR-001's amendment dropping EtherCAT and multi-CAN from the near-term plan is consistent
with this evidence: both options require replacing the actuators, which places them outside a
transport decision.

### 6.4 Comparison

| Option                      | Actuators unchanged | MCUs unchanged | Removes custom framing | Cycle owner     | Joints per segment at 200 Hz |
| --------------------------- | ------------------- | -------------- | ---------------------- | --------------- | ---------------------------- |
| Dual-STM32 serial (current) | Yes                 | Yes            | No                     | STM32           | ~10 (bus), 7 (built)         |
| Direct SocketCAN            | Yes                 | N/A — removed  | Yes                    | Linux userspace | ~10                          |
| CAN FD                      | **No**              | **No**         | Yes                    | Either          | ~40+ [Derived, unverified]   |
| EtherCAT                    | **No**              | **No**         | Yes                    | Master stack    | Many                         |

### 6.5 Why the seam matters more than the choice

[Derived] The findings in section 5 are the argument for ADR-001's central decision, stated more
strongly than the ADR states it. The current transport discards three of five command fields,
blocks indefinitely, delivers commands opportunistically, and implements none of the framing it is
documented to implement. **Every one of those is invisible above `ActuatorTransport`.** The
abstraction is what makes the audit in section 5 a bounded problem rather than a whole-system
review, and it is what makes fixing any of these findings a change to one class.

The corresponding weakness is that `TransportCapabilities` does not currently let a transport
_declare_ those limitations. A capability structure that reports `provides_temperature` but cannot
report "this transport ignores stiffness, damping and feed-forward torque" lets a defective
transport pass as a complete one. See [section 8](#8-evidence-that-challenges-the-accepted-decision),
finding 1.

---

## 7. What must be measured

[Derived] Nothing in this document establishes that the 5 ms deadline is met, because no
end-to-end timing measurement exists. The following is the minimum set that would settle it. Each
entry states the falsification condition, because a measurement that cannot fail is not a
measurement.

| #   | Quantity                                                     | Method                                                                                                   | Falsifies the design if                                                  |
| --- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| 1   | Host `read`-to-`write` execution time, distribution not mean | `controller_manager` execution-time diagnostics with thresholds tightened from the 1000/2000 µs defaults | 99.9th percentile exceeds the budget remaining after §4.5                |
| 2   | Cycle periodicity at the host                                | `controller_manager` periodicity diagnostics                                                             | Mean error exceeds 1 Hz, or the distribution is bimodal                  |
| 3   | USB CDC round-trip latency and jitter                        | Timestamp echo through `MSG_PING`, host-side steady clock, 10⁶ samples                                   | 99.9th percentile exceeds 1 ms, or the tail is unbounded                 |
| 4   | Command-to-motion latency, end to end                        | External instrumentation: command a step, capture joint motion optically or with an independent encoder  | Median exceeds 15 ms, or the distribution has a tail beyond 25 ms        |
| 5   | Actual MIT command delivery rate per joint                   | Instrument `mit_pending` consumption on the master; count MIT frames per joint per second on the CAN bus | Any joint receives fewer than 195 MIT frames/s under representative load |
| 6   | CAN bus utilisation under load                               | Bus analyser during a walking gait, not at idle                                                          | Sustained utilisation above 60 %, or error-frame rate above zero         |
| 7   | SPI exchange duration distribution                           | Toggle a GPIO around `spi_exchange`                                                                      | Any exchange exceeds 1 ms, or the maximum is unbounded                   |
| 8   | Worst-case jitter attributable to `HAL_GetTick` quantisation | Same GPIO trace, measure period distribution                                                             | Period standard deviation exceeds 0.5 ms                                 |
| 9   | Behaviour on slave absence                                   | Physically disconnect a slave mid-cycle                                                                  | Master blocks, or motors remain enabled — see Topic 2                    |
| 10  | MIT wire scaling per model                                   | Bench: command a known torque, measure with a calibrated load cell; repeat per model                     | Measured torque differs from commanded by more than 5 %                  |

Measurement 10 is not optional. [Section 3.5](#35-mit-wire-scaling-two-sources-two-answers)
establishes that the scaling is disputed for RS00 and that the firmware's global gain constants are
wrong for RS03 by a factor of ten. No amount of documentation review resolves this; only a load
cell does.

**Environment discipline.** [Project] Every timing measurement must be taken on the target Jetson
module under representative thermal and CPU load, inside the production container, with the
production kernel. A number from a desktop x86 host, an idle Jetson, or a native build does not
qualify the system and must not be recorded as if it did.

---

## 8. Evidence that challenges the accepted decision

ADR-001 is accepted and is not modified by this document. The following findings are recorded
because they contradict, or are not supported by, statements in or assumptions behind that
decision. They are ordered by severity.

**Severity key:** _Critical_ — can produce uncommanded motion or actuator damage. _Major_ —
invalidates a stated architectural property. _Moderate_ — creates a latent hazard or a maintenance
trap.

| #   | Finding                                                                                                                                                                                                                                                 | Severity     | Conflicts with                                                                     |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ---------------------------------------------------------------------------------- |
| 1   | The production transport delivers **two of five** MIT fields. $\tau_{ff}$ is hard-coded to `0.0f` in the slave; $K_p$ and $K_d$ come from static per-motor configuration; the master explicitly discards all three. The executing law is fixed-gain PD. | **Critical** | ADR-001-02 atomic five-tuple                                                       |
| 2   | Global `KP_MAX 500` / `KD_MAX 5` constants are wrong for RS03 and RS06 by 10× and 20× respectively. `slave0.yaml` documents the assumption that gain spans are model-invariant. The RS03 is the planned hip actuator.                                   | **Critical** | Actuator-model neutrality assumed by the manifest                                  |
| 3   | RS00 torque and velocity spans are disputed between the project's transcription and a third-party SDK (±14 vs ±17 N·m; ±33 vs ±50 rad/s). A 21 % torque error is possible and would be silent.                                                          | **Critical** | Any torque-based safety envelope                                                   |
| 4   | Master SPI exchange uses `HAL_SPI_TransmitReceive(..., HAL_MAX_DELAY)`: blocking, polled, unbounded. DMA is initialised and unused.                                                                                                                     | **Major**    | ADR-001 "never wait indefinitely"; `ActuatorTransport::exchange` deadline contract |
| 5   | One mutually exclusive command byte per 5 ms tick. Arm, disarm and go-to-zero displace the motion command. No lower bound on command delivery rate.                                                                                                     | **Major**    | ADR-001-03 "genuine 200 Hz" — true for feedback, unestablished for commands        |
| 6   | No COBS framing, no delimiter, no synchronisation word on the USB link, despite `soccer_cobs.h` existing and the framing being described in the project brief, the firmware architecture document, and ADR-001's own Context block.                     | **Major**    | ADR-001 Context; resynchronisation after byte loss                                 |
| 7   | Three incompatible protocol definitions coexist (`protocol.h`, `soccer_protocol.h`, `host/jetson/protocol.py`), plus a fourth legacy SPI layout in `slave_spi.c`. Host and master do not agree on the wire format.                                      | **Major**    | ADR-009-07 interface governance                                                    |
| 8   | SPI CRC disabled on both ends; slave presence detected by a `motor_idx` ordering heuristic.                                                                                                                                                             | **Major**    | Integrity of the only link carrying commands                                       |
| 9   | `hdr.len` unbounded; a corrupted length stalls the decoder until accumulator overflow. CRC failure flushes the entire accumulator, destroying intact frames behind the bad one.                                                                         | **Moderate** | Robustness under bit errors                                                        |
| 10  | 42 % of the 5 ms budget is unaccounted and unmeasured. No end-to-end latency measurement exists.                                                                                                                                                        | **Major**    | ADR-001-03; the entire timing premise                                              |
| 11  | Blocking `HAL_Delay` sequences of 40-200 ms inside the slave's cooperative loop during arm, go-to-zero, and zeroing-arrival.                                                                                                                            | **Moderate** | Responsiveness during lifecycle transitions                                        |
| 12  | `HAL_GetTick()` 1 ms resolution gives ±20 % period quantisation; `next_poll_ms += 5` produces catch-up bursts after any overrun.                                                                                                                        | **Moderate** | Cycle-time stability                                                               |
| 13  | `motor_config.h` is committed pre-generated from `slave1.yaml` only and does not describe the five-motor slave.                                                                                                                                         | **Moderate** | Reproducibility of the built artifact                                              |
| 14  | `TransportCapabilities` cannot express "this transport ignores stiffness, damping and feed-forward torque". A transport with finding 1 passes capability checks as complete.                                                                            | **Major**    | The purpose of the capability structure                                            |
| 15  | `JointEnvelope` models the overload curve as a single `torque_peak_nm` plus `torque_peak_duration_s`. The vendor curves have four to five points spanning a 300-fold duration range.                                                                    | **Moderate** | Fidelity of the ADR-002 envelope; see Topic 2                                      |
| 16  | `JointEntry` carries no actuator model identity and no wire-scaling spans, so the manifest digest cannot detect findings 2 or 3.                                                                                                                        | **Major**    | ADR-002 startup identity interlock                                                 |
| 17  | `protocol.h` documents `MOTOR_CMD` as `/* stub – not wired */`; it is dispatched and live.                                                                                                                                                              | **Moderate** | Trustworthiness of in-tree documentation                                           |
| 18  | Drive-side `canTimeout`, `limit_torque`, `limit_spd` and `limit_cur` registers are unconfigured, forgoing four independent enforcement points that survive host and MCU failure.                                                                        | **Moderate** | Defence in depth                                                                   |

**What these findings do not challenge.** The central decisions of ADR-001 — a single
`SystemInterface`, a swappable `ActuatorTransport` seam, five-field atomicity as the command
contract, no ROS or middleware inside the cycle, monotonic timestamps, and `rw_rate` used only for
slower components — are all supported by the evidence above. Findings 1, 4, 5, 6, 8 and 14 are
implementation defects in `Stm32SerialTransport` and the firmware beneath it. Findings 2, 3, 15 and
16 identify genuine gaps in the manifest and envelope _types_, which is a design matter and belongs
in a future ADR revision, not in an implementation ticket.

---

## 9. Qualification gates

[Project] Derived from the findings above. A gate is a condition that must hold before the stated
capability is exercised on hardware, not a wish list.

| Gate | Condition                                                                                                                                                                                       | Blocks                                                  |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| G1   | Measurement 10 of §7 complete for every actuator model in the build; measured torque within 5 % of commanded                                                                                    | Any torque-based control or any safety envelope claim   |
| G2   | Per-model wire scaling present in the joint manifest and covered by the digest                                                                                                                  | Introducing any actuator model other than RS00 and RS02 |
| G3   | `TransportCapabilities` able to express tuple completeness, and `HumanoidActuatorSystem` refusing to activate a transport that cannot deliver all five fields when a controller claims all five | Deploying variable-impedance control                    |
| G4   | Master SPI exchange bounded by an explicit timeout derived from §4.3, with timeout counted and reported                                                                                         | Any autonomous operation                                |
| G5   | Measurements 1-4 and 7 of §7 complete on the target module, in the production container                                                                                                         | Declaring ADR-001-03 satisfied                          |
| G6   | One generated wire definition, one source of truth, host and firmware built from it                                                                                                             | Any change to the wire protocol                         |
| G7   | Bus segmentation designed and verified against §4.2                                                                                                                                             | Exceeding 10 joints on a single CAN segment             |

---

## 10. Open questions and evidence gaps

| #   | Question                                                                                                | Status                              | What would close it                                                          |
| --- | ------------------------------------------------------------------------------------------------------- | ----------------------------------- | ---------------------------------------------------------------------------- |
| 1   | Which RS00 torque and velocity spans are correct?                                                       | **Disputed**, two sources           | G1 bench measurement with a calibrated load cell                             |
| 2   | What are the RS03 wire spans on the firmware revision actually shipped?                                 | NR                                  | G1, plus reading `0x7005` and the drive firmware string on the received unit |
| 3   | Jetson USB CDC round-trip latency and jitter on the target module                                       | NR — never measured                 | §7 measurement 3                                                             |
| 4   | Host `read`/`write` execution-time distribution in the production container                             | NR                                  | §7 measurement 1                                                             |
| 5   | Actual per-joint MIT command delivery rate under representative load                                    | NR                                  | §7 measurement 5                                                             |
| 6   | CAN bus utilisation and error-frame rate during a gait                                                  | NR — arithmetic only                | §7 measurement 6                                                             |
| 7   | Whether the target Jetson carrier exposes a usable CAN controller                                       | NR — module unfixed at Model Gate 0 | Topic 3 Model Gate 0 module selection                                        |
| 8   | Whether the RS02/RS03 units in hand carry the 240 Ω terminator                                          | NR                                  | Read `can_status` at `0x3048` / `0x3041` per unit                            |
| 9   | Thermal starting condition assumed by the vendor overload curves                                        | NR                                  | Vendor enquiry; otherwise derate empirically                                 |
| 10  | Whether raising the SPI prescaler above 1.125 MHz is signal-integrity limited or merely conservative    | NR                                  | Bench: sweep prescaler, count SPI errors over 10⁶ exchanges                  |
| 11  | IgH EtherCAT Master licence terms against the project's GPL/AGPL exclusion                              | NR — not verified here              | Read the licence before any EtherCAT evaluation                              |
| 12  | Whether `detached` asynchronous components can meet the cycle contract for any component in this system | NR                                  | Only relevant if a slow component is added; defer                            |
| 13  | Power budget at the 14-joint target: 1110 W continuous by §3.2 against an unfixed battery               | **Open**                            | Topic 3 Model Gate 0                                                         |
| 14  | Whether the 200 ms slave arming stall is acceptable, or must be made non-blocking                       | **Open**                            | Depends on the rearm policy in Topic 2 §8                                    |

**Evidence gaps that are structural rather than answerable.** Four of the fourteen entries above
are blocked on Model Gate 0 and cannot be closed by research. Six require bench access to hardware.
The remaining four are documentation or licence questions. **No entry in this table can be closed by
further reading of the existing repository**, which is itself the finding: the actuation path's
timing properties have been asserted consistently across three documents and measured nowhere.
