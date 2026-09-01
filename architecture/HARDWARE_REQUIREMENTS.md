# Hardware Requirements Register

- Status: Living document
- Last updated: 2026-09-01
- Purpose: Track requirements that software architecture decisions place on the mechanical, electrical,
  and firmware domains, so they are not lost inside software ADRs.

## How to read this register

Every entry originates in an accepted ADR or a completed research baseline. The **Driven by** column is
the authority; this document summarises and does not replace it. Nothing here is a design: it states
what the software architecture requires of the hardware and why, and leaves the implementation to the
domain that owns it.

Status values:

| Status       | Meaning                                                                             |
| ------------ | ----------------------------------------------------------------------------------- |
| **Required** | Follows from an accepted decision. Not optional.                                    |
| **Blocked**  | Required, but cannot be specified until a named gate closes.                        |
| **Open**     | A decision the hardware domain owns, with a stated software consequence either way. |
| **Advisory** | A performance recommendation with its derivation shown.                             |

Several entries depend on **Topic 3 Model Gate 0**, which is open: no kinematic tree, joint count,
masses, inertias, sole geometry, or physical envelope exists yet.

---

## 1. Safety and power

| ID    | Requirement                                                                                                                                                                                                                                          | Driven by        | Status   |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | -------- |
| HW-01 | A latching, de-energize-to-stop actuator-power chain on an independent electrical path, with monitored feedback. It must not depend on the Jetson, ROS 2, Zenoh, USB, or STM32 application scheduling to remove energy.                              | ADR-002          | Required |
| HW-02 | Resetting the emergency stop must permit a later arm sequence but must never start motion. The reset must be physically distinct from a motion-enable action.                                                                                        | ADR-002          | Required |
| HW-03 | Diagnostic and embedded logic power should remain available while actuator power is removed, where the electrical design permits. Without it, the robot cannot report why it stopped.                                                                | ADR-002          | Required |
| HW-04 | A league-compliant remote emergency stop: worn on neck or belt, clearly marked, connected to exactly one robot, and **performing no additional function**. It is an independent input to the HW-01 chain, not a replacement for the on-robot button. | ADR-002, Rules   | Required |
| HW-05 | **Independently monitored per-joint power switching.** Its absence is why an unverified joint isolation must currently escalate to removing shared actuator power, which costs the whole robot for one drive fault.                                  | ADR-002          | Open     |
| HW-06 | Battery voltage must be readable by the host at a rate sufficient for the health beacon and for the thermal and power terms of the `SafetyKernel` envelope.                                                                                          | ADR-002, ADR-008 | Required |

**Note on HW-05.** This is the highest-value open electrical item in the register. Per-joint switching
with monitored feedback converts a whole-robot power removal into a single-joint isolation, which is the
difference between a match ending and a degraded-policy continuation under ADR-002.

---

## 2. Actuation, buses, and timing

| ID    | Requirement                                                                                                                                                                                                                                                               | Driven by        | Status   |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | -------- |
| HW-10 | The physical path must deliver genuinely fresh command and feedback samples for **every** controlled joint in **every** 5 ms cycle. Repeated or interpolated samples are not a 200 Hz loop.                                                                               | ADR-001          | Required |
| HW-11 | The protocol must carry protocol version and feature bits, robot/actuator/calibration/safety-manifest identities, cycle sequence and freshness data, complete per-joint tuples and feedback, whole-frame integrity checking, and non-replayable arm/disable/reset epochs. | ADR-001          | Required |
| HW-12 | The STM32 must remain the physical scheduler of the 5 ms cycle and must retain independent watchdogs, integrity checking, and local safe-damping authority that survive total host failure.                                                                               | ADR-001, ADR-002 | Required |
| HW-13 | **Multi-bus CAN segmentation, or CAN FD.** See the derivation below.                                                                                                                                                                                                      | ADR-001          | Advisory |
| HW-14 | A hardware time-synchronisation signal between the STM32 and the Jetson at a future board revision, if proprioceptive timestamp quality proves insufficient over USB CDC alone.                                                                                           | Topic 4          | Open     |

### HW-13 derivation: a single 1 Mbps classic CAN bus does not scale to 20 DOF at 200 Hz

**Assumptions, stated so they can be challenged.** One command frame and one feedback frame per joint
per control cycle, 8 data bytes each, 29-bit extended identifiers, classic CAN at 1 Mbit/s. An extended
data frame with an 8-byte payload occupies approximately 130 bits without bit stuffing and up to
approximately 155 bits with worst-case stuffing, including the inter-frame space.

Bus utilisation for $N$ joints at 200 Hz is

$$U = \frac{N \times 2 \times B \times 200}{1 \times 10^{6}}$$

where $B$ is bits per frame.

| Joints | $B = 130$ bits | $B = 155$ bits |
| ------ | -------------- | -------------- |
| 12     | 62 %           | 74 %           |
| 14     | 73 %           | 87 %           |
| 20     | **104 %**      | **124 %**      |

**Conclusions.**

1. **A 20-DOF humanoid cannot run on one 1 Mbps classic CAN bus at 200 Hz.** It exceeds 100 % of the
   bus before any margin, error frame, retransmission, or configuration traffic is considered.
2. Even the currently assumed 14 joints sit at 73 to 87 % utilisation, which is far past the range where
   classic CAN arbitration latency remains predictable.
3. At a 50 % utilisation target with worst-case stuffing, one bus carries about **8 joints**. A 20-DOF
   robot therefore needs **at least three CAN segments**, and segmenting by kinematic chain — left leg,
   right leg, upper body — also contains a bus fault to one limb.
4. **CAN FD is the alternative that removes the constraint rather than dividing it**, and it also removes
   the 8-byte payload limit, which matters because a five-field MIT tuple is a tight fit in 8 bytes.

**Unverified input.** The exact RobStride frame count and payload layout per joint per cycle has not been
confirmed against vendor documentation. If a single MIT command requires more than one frame, every
number above doubles and the 12-joint case also fails. This must be confirmed before any bus topology is
committed.

---

## 3. Sensing

| ID    | Requirement                                                                                                                                                                                                                    | Driven by        | Status   |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------- | -------- |
| HW-20 | **Camera shutter type must be selected deliberately.** The ZED 2i has a rolling shutter. On a walking humanoid, rolling-shutter skew during head motion and impact corrupts the geometry that localisation depends on.         | Topic 5          | Open     |
| HW-21 | The camera and its mount must hold extrinsic calibration across impacts, or extrinsics must be re-validated after every fall. Vision is the **only** source of absolute heading, because magnetometers are prohibited by rule. | Topic 5, Topic 6 | Required |
| HW-22 | An IMU whose bias stability, not merely its noise density, is characterised. Datasheet noise density does not bound drift.                                                                                                     | Topic 4          | Open     |
| HW-23 | Ground-contact sensing modality: physical sensors versus dynamic and kinematic inference. Both remain live; neither is selected. Resolution requires the physical envelope and compute budget.                                 | Topic 4          | Blocked  |
| HW-24 | Per-joint temperature and voltage telemetry, since both enter the `SafetyKernel` state-dependent torque and power envelope.                                                                                                    | ADR-002          | Required |

---

## 4. Compute, storage, and thermal

| ID    | Requirement                                                                                                                                                                                                                                              | Driven by        | Status   |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | -------- |
| HW-30 | Jetson Orin module selection. Blocked on the physical envelope, mass, and power budget at Model Gate 0. Peak EMC bandwidth is a module property, so no memory-bandwidth budget is computable until it closes.                                            | ADR-006, Topic 9 | Blocked  |
| HW-31 | **Log storage medium, capacity, and write endurance.** The control plane alone writes approximately 170 kB/s continuously, or 204 MB per match. Across a tournament and a season of testing this is a write-endurance question, not a capacity question. | ADR-007, ADR-008 | Blocked  |
| HW-32 | Storage must be physically accessible for off-network extraction, because rule-capped bandwidth makes network extraction take about 27 minutes against a 5 minute half-time. Removable media or a dedicated wired service port.                          | ADR-008          | Required |
| HW-33 | The perception-plane recording volume is unbudgeted and will likely dominate storage by one to two orders of magnitude. No figure exists until the camera and resolution are chosen.                                                                     | ADR-008, Topic 5 | Blocked  |
| HW-34 | Thermal design must sustain the compute profile for a full 20 minute match plus warm-up without throttling, since throttling changes EMC frequency and therefore control-loop timing behaviour.                                                          | Topic 9          | Blocked  |
| HW-35 | Stable device paths for every host-visible peripheral, so that ADR-006 udev rules can grant minimum device privilege without whole-bus passthrough.                                                                                                      | ADR-006          | Required |

---

## 5. Operations and field diagnostics

| ID    | Requirement                                                                                                                                                                             | Driven by      | Status   |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | -------- |
| HW-40 | **Visual status indication legible from the touchline**, with enough distinguishable states to encode the ADR-002 safety state, degraded communications, and ambiguous field direction. | ADR-008        | Required |
| HW-41 | **Audible indication on safety-state transitions.** Sound carries when the robot is facing away or occluded by other players.                                                           | ADR-008        | Required |
| HW-42 | Battery replacement must be achievable, with the robot inspected and re-checked, inside the 5 minute half-time window. Tool-free or single-tool access.                                 | ADR-008, Rules | Required |
| HW-43 | The on-robot emergency stop must remain reachable while the robot is upright, fallen, and being carried.                                                                                | ADR-002        | Required |

**Why HW-40 and HW-41 are Required rather than Advisory.** The Laws make any physical contact a service
event that resets the penalty timer, and forbid picking up a robot that is not physically dangerous.
Every diagnostic channel that requires touching the robot is therefore unavailable during play. The
touchline signal and the one-way health beacon are the complete in-play diagnostic surface. Without
HW-40 and HW-41, half of that surface does not exist.

**Open risk.** The state encoding is proposed from reasoning, not measurement. Legibility under
competition lighting, viewing distance, and crowd noise is untested, and the physical envelope that
would carry the indicators is undesigned.

---

## 6. Test and validation equipment

| ID    | Requirement                                                                                                                                                                                                                                         | Driven by        | Status   |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | -------- |
| HW-50 | **A separate physical STM32 emulator** presenting a real USB CDC endpoint to the Jetson. Host-side software loopback is explicitly rejected: it tests the parser only and leaves the USB stack, `cdc_acm`, the udev rule, and real timing untested. | ADR-007          | Required |
| HW-51 | A firmware-side test fixture that drives the STM32 with scripted command streams and captures bus traffic.                                                                                                                                          | ADR-007          | Required |
| HW-52 | A gantry or tether rig permitting full-stack hardware-in-the-loop runs without a fall risk.                                                                                                                                                         | ADR-007          | Required |
| HW-53 | Physical test apparatus for the emergency-stop chain. No software test can reach it, because ADR-002 requires the chain to be independent of every software layer, so it is tested physically or not at all.                                        | ADR-002, ADR-007 | Required |
| HW-54 | Instrumentation capable of capturing physical timing traces at the bus and transport level, since average latency is not acceptance evidence and worst-case values must be measured.                                                                | ADR-001          | Required |

---

## Cross-references

- [ADR-001](ADR-001-real-time-actuation-and-hardware-abstraction.md) — actuation, transport, protocol
- [ADR-002](ADR-002-safety-and-fault-management.md) — safety authorities, power chain, degraded operation
- [ADR-006](ADR-006-runtime-and-containers.md) — device privilege, compute isolation, release identity
- [ADR-007](ADR-007-simulation-sil-hil.md) — hardware-in-the-loop configurations and emulator requirements
- [ADR-008](ADR-008-observability-and-operations.md) — telemetry storage, field diagnostics, competition operations
- [Topic 3](../research/topic-3-locomotion-survey.md) — Model Gate 0, which blocks every entry marked Blocked
- [Topic 4](../research/topic-4-sensors-timing-state-estimation.md) — IMU, contact sensing, timestamp quality
- [Topic 5](../research/topic-5-perception-pipeline.md) — camera selection and shutter evidence
- [Topic 9](../research/topic-9-runtime-and-containers.md) — Jetson platform, unified memory, thermal
