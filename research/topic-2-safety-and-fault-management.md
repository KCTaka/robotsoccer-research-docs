# Topic 2 Research: Safety and Fault Management

- Status: **Retroactive evidence baseline.** Assembled 2026-09-02, after ADR-002 was accepted on 2026-07-27 and amended on 2026-08-28. Update before any Topic 2 architecture revision.
- Evidence last verified: 2026-09-02
- Scope: Research input for Topic 2. The decision itself is recorded in ADR-002 and is not restated or revised here.
- Canonical decisions: [ADR-002](../architecture/ADR-002-safety-and-fault-management.md), with dependencies on [ADR-001](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md), [ADR-005](../architecture/ADR-005-behavior-game-state-and-team-networking.md), [ADR-006](../architecture/ADR-006-runtime-and-containers.md), [ADR-007](../architecture/ADR-007-simulation-sil-hil.md)
- Related research: [Topic 1](topic-1-real-time-actuation-and-hardware-abstraction.md), [Topic 3](topic-3-locomotion-survey.md), [Topic 4](topic-4-sensors-timing-state-estimation.md), [Topic 8](topic-8-gamecontroller-networking.md), [Topic 11](topic-11-observability-and-operations.md)

## Purpose and evidence policy

ADR-002 is the longest and most prescriptive decision in this repository. It defines six
independent authorities, a twelve-state safety machine, a coupled command envelope, seven reaction
deadlines with numeric values, and a rearm matrix. None of it was preceded by a written evidence
baseline. This document supplies one.

**What "retroactive" means here.** The evidence was gathered from primary sources without treating
ADR-002's conclusions as the target. Where the evidence supports the decision it says so, and in
several places it supports it more strongly than the ADR itself argues. Where it does not, or where
the as-built machine does the opposite of what the ADR requires, that is recorded in
[section 9](#9-the-as-built-safety-gap-register) and
[section 10](#10-evidence-that-challenges-the-accepted-decision). **The ADR is not edited.**

**A necessary statement about scope.** This is a competition robot, not a machine placed on the
market. Nothing here constitutes a functional-safety assessment, and no claim of conformity to any
standard is made or implied. Standards are cited by designation for their concepts and vocabulary,
because those concepts are useful, not because compliance is being asserted. See
[section 1.4](#14-what-this-system-is-not).

Evidence tags follow the Topic 4-12 convention:

| Tag             | Meaning                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------- |
| **[Primary]**   | Read directly from a source file, configuration file, rules source, or vendor document at a named location. |
| **[Upstream]**  | Stated by the maintainer or vendor in their own documentation.                                              |
| **[League]**    | Stated in the RoboCup Humanoid League rules source.                                                         |
| **[Standard]**  | Cited by designation. Full texts are paywalled and were **not** inspected. Concepts only.                   |
| **[Community]** | Stated by a third-party implementation. Corroboration, not authority.                                       |
| **[Derived]**   | Computed or concluded here from tagged inputs. Reasoning shown so it can be checked or refuted.             |
| **[Project]**   | A target or constraint set by this project.                                                                 |
| **NR**          | **Not reported.** Never means zero.                                                                         |

## Confirmed project inputs

| Input                   | Confirmed state                                                              | Consequence for safety                                                       |
| ----------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Cycle                   | 200 Hz, 5 ms, scheduled by the STM32 (ADR-001)                               | Every reaction deadline is a multiple of 5 ms whether stated that way or not |
| Command unit            | Five-field MIT tuple; torque is a function of all five plus measured state   | Field-by-field limits do not bound torque                                    |
| Actuators               | RobStride RS-series; peak torque 5.5 to 60 N·m depending on model            | Hazard magnitude is set by actuator selection, not by software               |
| Drive fault reporting   | Six fault bits carried in the type-2 feedback frame identifier               | Fault notification arrives with normal feedback, at cycle rate               |
| Framework               | ROS 2 Jazzy, `ros2_control`                                                  | Upstream provides no safety-critical interface concept (§2.3)                |
| Middleware              | `rmw_zenoh_cpp` (ADR-003), excluded from the cycle                           | No safety decision may depend on middleware delivery                         |
| Competition             | RoboCup Humanoid League                                                      | League rules bind the _outcome_, not the mechanism (§1.3)                    |
| GameController          | UDP broadcast, low rate (Topic 8)                                            | A GameController stop is an operational command, never an emergency stop     |
| Robot mass and geometry | **Not fixed.** Model Gate 0 open (Topic 3)                                   | Energy figures below are parametric; absolute values are NR                  |
| Current build           | 7 motors, dual-STM32 path, no hardware watchdog, no power-interruption chain | The as-built machine implements a small fraction of ADR-002 (§9)             |

## Binding external constraints

| Constraint                                                                                                                          | Source     | Consequence                                                       |
| ----------------------------------------------------------------------------------------------------------------------------------- | ---------- | ----------------------------------------------------------------- |
| "Robot handlers must be able to immediately and physically bring a robot to a safe state at any point in the game."                 | [League]   | A human-actuated stop path is mandatory                           |
| "It is the responsibility of the teams to ensure that a robot can be physically stopped by their handler in case of emergency."     | [League]   | The stop path must work with the handler as the actuator          |
| "The team must be able to demonstrate their ability to physically stop their robots on request at any time during the competition." | [League]   | The stop path must be demonstrable on demand, not merely designed |
| Robots "must comply with the GameController protocol and immediately assume a safe pose when the command is sent"                   | [League]   | A software safe-pose path is also mandatory, separately           |
| Command interfaces remain available and are written in the `INACTIVE` state; issue #931 open since 2023-02-02                       | [Upstream] | Lifecycle deactivation is not a command gate                      |
| `read`/`write` returning `ERROR` leads to `UNCONFIGURED` at best and unrecoverable `FINALIZED` at worst, with no reload service     | [Upstream] | ROS-level fault recovery is a one-way door                        |
| `get_lifecycle_state()` is not real-time safe                                                                                       | [Upstream] | Safety logic in the cycle cannot consult lifecycle state          |
| `prepare_command_mode_switch` / `perform_command_mode_switch` cause jitter in the main loop                                         | [Upstream] | Controller switching cannot be on a hard deadline path            |

---

## 1. What "safety" means for this machine

### 1.1 Hazard inventory

[Derived] Hazards are enumerated from the energy sources actually present, with magnitudes computed
from the actuator data in [Topic 1 §3](topic-1-real-time-actuation-and-hardware-abstraction.md#3-actuator-evidence-robstride-rs-series-drives).
Robot mass and link lengths are unfixed at Model Gate 0, so quantities that depend on them are given
per unit or with the assumption stated.

| #   | Hazard                                              | Energy source                     | Magnitude                                                                                                                                                          | Exposed party                                  |
| --- | --------------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------- |
| H1  | Limb strike during commanded motion                 | Actuator torque                   | RS02 at 17 N·m peak through a 0.20 m link is **85 N** at the tip; RS03 at 60 N·m through 0.25 m is **240 N** [Derived]                                             | Handler, opponent robot, spectator             |
| H2  | Crush or pinch at a joint                           | Actuator torque                   | Same magnitudes, applied at short lever arm; the drive will hold indefinitely if commanded to                                                                      | Handler's fingers during setup                 |
| H3  | Uncommanded motion after fault                      | Latched enable plus stale command | Full H1 magnitude, indefinite duration if nothing disarms the drive                                                                                                | Anyone in reach                                |
| H4  | Fall onto a person or equipment                     | Gravitational potential           | **2.45 J per kg of robot mass** for a CoM drop from 0.35 m to 0.10 m; CoM impact speed **2.21 m/s**, independent of mass [Derived]                                 | Anyone within a robot-height radius            |
| H5  | Fall damaging the robot                             | Same                              | Same                                                                                                                                                               | The robot; a broken robot is a forfeited match |
| H6  | Thermal runaway in stall                            | Electrical, continuous            | See [§3.5](#35-thermal-dependence-is-not-optional)                                                                                                                 | The drive, then the robot                      |
| H7  | Battery fault                                       | Chemical                          | NR — pack not selected                                                                                                                                             | Everyone, severely                             |
| H8  | Regenerative overvoltage during a fall or hard stop | Kinetic returned to the bus       | NR — no measurement, no brake resistor specified                                                                                                                   | Drives and pack                                |
| H9  | Runaway from a wire-scaling error                   | Software, silent                  | A 10× stiffness error is achievable today; see [Topic 1 §3.5](topic-1-real-time-actuation-and-hardware-abstraction.md#35-mit-wire-scaling-two-sources-two-answers) | Anyone in reach                                |

[Derived] H9 deserves emphasis because it is the only hazard in this table that is invisible to
every existing check. A joint commanded at $K_p = 15$ that physically executes $K_p = 150$ reports
nothing anomalous: the position converges faster, the torque is higher, and no limit in the
firmware is expressed in units that would notice.

**Stored kinetic energy, worked.** [Derived] Take a leg segment approximated as a point mass of
0.4 kg at 0.25 m, at the configured `max_vel` of 10 rad/s:

$$I = m r^2 = 0.4 \times 0.25^2 = 0.025\ \text{kg·m}^2, \qquad E_k = \tfrac12 I \omega^2 = 1.25\ \text{J}, \qquad v_{tip} = 2.5\ \text{m/s}$$

1.25 J at 2.5 m/s is not lethal and is comfortably enough to break a finger or a camera. The
relevant number for design is not the peak but the **time to remove it**, which is
[§6.2](#62-damping-versus-disable-the-arithmetic).

### 1.2 The standards frame, used for vocabulary

[Standard] Cited by designation. Texts are paywalled and were not read for this document; only the
well-established structure of each is used.

| Designation             | Subject                                                                                 | What is borrowed                                                                                                                                                      |
| ----------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ISO 12100               | Safety of machinery — general principles for design, risk assessment and risk reduction | The three-step method: inherently safe design first, then guards and protective devices, then information for use. ADR-002's layering is an instance of this ordering |
| ISO 13850               | Emergency stop function — principles for design                                         | The distinction between an emergency stop and an operational stop, and the requirement that an emergency stop latch                                                   |
| IEC 60204-1             | Electrical equipment of machines                                                        | Stop categories: 0 = immediate removal of power; 1 = controlled stop then removal of power; 2 = controlled stop with power retained                                   |
| ISO 13849-1 / IEC 61508 | Performance levels / safety integrity levels                                            | The concept that a protective function has a quantified reliability, and that unrated software does not have one                                                      |

[Derived] The vocabulary maps onto ADR-002 cleanly and usefully:

- ADR-002's **protective damping** is a Category 2 stop: controlled, power retained.
- ADR-002's **damp then disable** is a Category 1 stop: controlled stop followed by removal of
  drive enable.
- ADR-002's **latching stop chain, de-energize-to-stop** is a Category 0 stop.
- ADR-002's statement that "GameController and Zenoh messages are operational stop requests, not
  emergency-stop channels" is exactly the ISO 13850 distinction, and is correct.

The mapping is worth making explicit because it makes one thing obvious that the ADR leaves
implicit: **a Category 1 stop requires the controlled phase to actually work.** If the damping phase
depends on the same link that has just failed, the design has a Category 0 stop with extra latency,
not a Category 1 stop. [§6](#6-what-safe-means-for-a-biped) develops this.

### 1.3 What the league actually requires

[League] `RoboCup-HumanoidSoccerLeague/HSL-Rules`, `rules/robot_players.tex`, sublaw "Safety",
read 2026-09-02. The binding requirements are:

1. "A player must not use equipment or wear anything that is dangerous to himself or another
   player."
2. "Robot handlers must be able to immediately and physically bring a robot to a safe state at any
   point in the game."
3. "It is the responsibility of the teams to ensure that a robot can be physically stopped by their
   handler in case of emergency."
4. "The team must be able to demonstrate their ability to physically stop their robots on request
   at any time during the competition."
5. "The robots must comply with the GameController protocol and immediately assume a safe pose when
   the command is sent by the GameController."

Optional provisions, phrased as "can be equipped":

- **Passive features**: grips or handles on the back, and body design that lets a human safely hold
  the robot.
- **Active features**: a physical button, an emergency switch, or a remote emergency button that
  "make the robot immediately stop all movements and assume a safe posture".
- **Remote emergency button**: not physically attached; one button per robot; if the device also
  performs other functions it must be kept in a marked zone in the Technical Area and touched only
  to trigger the stop.

[Primary] The rules source contains a commented-out — therefore **not binding** — paragraph
encouraging an emergency stop button "that makes the robot immediately desist with all motions, or
ideally go limp and/or cut power to the actuators". Its removal from the binding text is
informative: the league deliberately mandates the _outcome_ and leaves the _mechanism_ to teams.

[Derived] Four conclusions:

1. **No emergency stop device is mandatory.** Requirement 2 can in principle be met by a handler
   physically grabbing the robot. This is why passive handles are listed as a legitimate compliance
   route.
2. **A handler-actuated stop is nonetheless the practical baseline**, because requirement 4 makes
   it demonstrable on demand and requirement 2 makes it available "at any point in the game",
   including while the robot is walking and being approached from behind.
3. **Requirement 5 is a separate, software path.** GameController is a UDP broadcast at low rate
   (Topic 8). A stop triggered by it inherits the packet interval as a floor on its latency —
   plausibly hundreds of milliseconds. It is an operational stop and cannot be a protective one.
   ADR-002 states this and the league rules are consistent with it.
4. **The league imposes no performance level, no SIL, and no architectural constraint.** ADR-002's
   requirements are therefore self-imposed, and are considerably more demanding than the
   competition requires. That is a defensible choice and should be recognised as a choice.

**A design consequence the rules make concrete.** [Derived] Requirement 2 places a human hand on a
moving robot. Hazards H1 and H2 are therefore not hypothetical bystander scenarios; they are the
_expected_ interaction. A handler reaching for a robot that is walking is the single most likely
way a person is injured by this machine, and it is a mandated procedure. Any protective response
that leaves joints stiff makes that procedure more dangerous, which is a direct argument for
damping rather than position hold — see [§6.1](#61-three-candidate-protective-actions).

### 1.4 What this system is not

[Derived] Stated plainly so that no later reader mistakes ADR-002's rigour for certification:

- No component of this system is safety-rated. The STM32 firmware, the Jetson software, and the
  `SafetyKernel` are ordinary software with ordinary defect rates.
- No performance level or SIL is claimed, computed, or claimable. Doing so would require a
  quantified failure-rate budget, diagnostic coverage analysis, and common-cause analysis, none of
  which exist.
- The one element that could carry a rating is the physical stop chain, if it is built from rated
  components with monitored contacts. ADR-002 requires that chain; the as-built machine does not
  have one ([§9](#9-the-as-built-safety-gap-register)).
- **The correct claim is therefore: layered defence with independent authorities, verified by
  measurement and fault injection, on unrated components.** That claim is honest and is what the
  verification gates in ADR-002 are designed to support.

---

## 2. Layered authority: the evidence for placing the gate low

### 2.1 The reaction-time arithmetic

[Derived] The rate at which a biped's balance error grows sets the timescale for every protective
decision. Linearised about upright, a point-mass inverted pendulum of centre-of-mass height $h$
diverges with time constant

$$T_c = \sqrt{h/g}$$

| CoM height $h$ | $T_c$   |
| -------------- | ------- |
| 0.30 m         | 0.175 s |
| 0.35 m         | 0.189 s |
| 0.40 m         | 0.202 s |

Taking $h = 0.35$ m as a representative kid-size value, the divergent component grows by $e^{t/T_c}$:

| Elapsed                                | Growth factor | Interpretation                                    |
| -------------------------------------- | ------------- | ------------------------------------------------- |
| 5 ms (one cycle)                       | 1.027         | 2.7 % — one cycle is cheap                        |
| 15 ms (ADR-002 command-loss assertion) | 1.083         | 8.3 %                                             |
| 20 ms (ADR-002 safe command)           | 1.112         | 11.2 % — still recoverable                        |
| 50 ms                                  | 1.303         | 30 %                                              |
| 200 ms (as-built watchdog)             | **2.881**     | **188 % — the divergent mode has nearly tripled** |

[Derived] Total time from a small disturbance to a fall, taking $\theta_0 = 0.02$ rad and a fall
threshold of 0.5 rad:

$$t_{fall} = T_c \ln\frac{0.5}{0.02} = 0.189 \times 3.22 = 0.61\ \text{s}$$

**This is the single most important number in the document.** ADR-002's 15/20 ms command-loss
deadlines consume 2.5-3.3 % of the available fall time and leave the state recoverable. The
as-built 200 ms watchdog consumes **33 % of the fall**, and by the time it fires, the divergent mode
has grown by a factor of 2.9. A protective action taken at 200 ms is not a slower version of the
same action; it is an action taken in a different, less recoverable state.

**Falsifiability.** This argument depends on $h$ and on the linearisation. If the robot's CoM sits
at 0.20 m, $T_c$ falls to 0.143 s and the 200 ms figure becomes _worse_ (growth factor 4.0). There
is no plausible geometry for a kid-size humanoid in which 200 ms is a control-relevant deadline.

### 2.2 What each layer can promise

[Derived] Each authority is characterised by its response latency, what survives its failure, and
what it structurally cannot know.

| Layer                                         | Best-case latency                                  | Survives failure of                | Cannot know                                                          |
| --------------------------------------------- | -------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------- |
| Drive internal protection and limit registers | Sub-millisecond, internal                          | Everything above it                | Anything about the robot; only its own current, voltage, temperature |
| Embedded Safety Agent on the slave STM32      | One cycle, 5 ms                                    | Host, USB, master MCU              | Balance, geometry, contact, intent                                   |
| Master STM32                                  | 5 ms                                               | Host, USB                          | Same, plus it has no drive contact                                   |
| `SafetyKernel` inside `write()`               | Same `write()` invocation                          | Controller defects, ROS scheduling | Full-body collision geometry; anything it did not receive this cycle |
| `SafetyCoordinator`, non-real-time            | Tens of milliseconds                               | Nothing below it                   | Nothing in time to matter for a physical deadline                    |
| ROS lifecycle and controller switching        | Hundreds of milliseconds, documented jitter source | Nothing                            | —                                                                    |
| Human handler with e-stop                     | Human reaction ≈ 250 ms plus travel                | All software                       | —                                                                    |

[Derived] Reading the table against [§2.1](#21-the-reaction-time-arithmetic): only the top four rows
operate inside the timescale on which a fall develops. The bottom three are, by construction,
orchestration. ADR-002's assignment of "first physical response" away from the `SafetyCoordinator`
and away from lifecycle transitions is directly supported.

The table also shows why the drive registers matter so much
([Topic 1 §3.6](topic-1-real-time-actuation-and-hardware-abstraction.md#36-drive-side-capabilities-not-currently-used)):
they are the only row that survives failure of _every_ piece of software this project writes.

### 2.3 `ros2_control` structurally cannot be the gate

Three independent upstream facts, each sufficient on its own.

**Fact 1 — command interfaces are written in `INACTIVE`.** [Upstream]
`lifecycle_of_a_hardware_component.rst`: "it is left to the hardware component implementation to
continue using the command received from the `CommandInterfaces` or to skip them completely ...
currently, all command interfaces are available and will be written." [Primary] Issue
`ros-controls/ros2_control#931`, "All command interfaces are available in `inactive` state", opened
2023-02-02, **still open** as of 2026-09-02. The planned safety-critical interfaces are a roadmap
item.

[Derived] Deactivating a hardware component does not stop commands reaching it. Whatever stops
commands must be _inside_ the component. This is not a stylistic preference; it is the only place
the framework leaves.

**Fact 2 — `ERROR` is a one-way door.** [Upstream] `handling_errors_during_read_write.rst`:
`ERROR` from `read()` or `write()` invokes `on_error`; success returns the component to
`UNCONFIGURED`, and any failure inside `on_error` lands it in `FINALIZED`, from which "it can not be
recovered. The only option is to reload the complete plugin, but there is currently no service for
this in the Controller Manager."

[Derived] A design that signals every fault by returning `ERROR` has made every fault
process-fatal. ADR-002's ordering — "Returning `ERROR` from `read()` or `write()` happens after
local containment has started" — is therefore not merely good sequencing. It is the only ordering
that preserves the possibility of recovery, because after `ERROR` there may be no component left to
recover with. The rearm matrix in ADR-002 is only implementable if `ERROR` is reserved for
conditions that genuinely warrant a restart.

**Fact 3 — the framework's own control surfaces are not real-time.** [Upstream]
`controller_manager` documentation: "Avoid using the `get_lifecycle_state()` method in the real-time
control loop ... it is not real-time safe", and `prepare_command_mode_switch` /
`perform_command_mode_switch` "cause jitter in the main control loop".

[Derived] Safety logic inside the cycle may not ask what state the system is in, and switching
controllers is not a deterministic operation. ADR-002's requirement that "fallback activation is
coordination only and must not be required to meet a physical deadline" is upstream-supported
almost verbatim.

**Fact 4 — isolation granularity is the component, not the joint.** [Upstream] Hardware Component
Groups propagate errors between components; by default "the actuator errors are isolated to their
own hardware component". A `write()` returning `ERROR` causes the controller manager to stop all
controllers using that hardware.

[Derived] With one `System` covering every joint (ADR-001), ROS-level fault handling has exactly two
outcomes: all joints commanded, or none. **Per-joint isolation is unavailable at the ROS level by
construction.** ADR-002's per-joint availability mask therefore has to be implemented inside the
component and in firmware, which is where the ADR puts it. The `group` tag would make isolation
coarser, never finer, and is not applicable.

### 2.4 The synthesis

[Derived] Combining §2.1 to §2.3: the fall timescale is 0.6 s, protective decisions must land inside
20 ms to stay in a recoverable state, and the only layers fast enough are the drive, the firmware,
and the code inside `write()`. Meanwhile the framework offers no gate, no per-joint isolation, and
no recoverable error path. **ADR-002's layered design is not over-engineering; it is the minimum
structure that the framework's limitations and the physics jointly permit.** This is the strongest
positive finding in this document.

---

## 3. The feasible set, and why scalar clipping fails

### 3.1 The statement

ADR-002 requires the `SafetyKernel` to project the whole tuple into a state-dependent feasible set
$\mathcal U_j(x,s)$ satisfying

$$\max_{(q,\dot q)\in\mathcal X_j} \left|\tau_j(u_j,(q,\dot q))\right| \leq \tau_{allowed,j}(T,V,s), \qquad |\tau_j \dot q_j| \leq P_{allowed,j}(T,V,s)$$

and prohibits scalar field-by-field clipping as the sole method.

### 3.2 The counterexample, worked

[Derived] Take limits that are individually reasonable for an RS02 joint: $K_p \le 60$ N·m/rad,
$K_d \le 3$ N·m·s/rad, $|\tau_{ff}| \le 6$ N·m, $|q_d - q| \le 0.5$ rad,
$|\dot q_d - \dot q| \le 5$ rad/s. Every one of these passes an independent scalar check. The
resulting torque is

$$\tau = 60 \times 0.5 + 3 \times 5 + 6 = 30 + 15 + 6 = 51\ \text{N·m}$$

against a drive whose peak is 17 N·m and whose continuous rating is 6 N·m. **Three times the peak
rating, produced entirely by values that each passed their own limit.**

This is the whole argument, and it is arithmetic rather than opinion. Independent limits on the
factors of a sum do not bound the sum unless the individual limits are each set to the total
budget — which would reduce $K_p$ to 34 N·m/rad _and_ $K_d$ to 3.4 N·m·s/rad _and_ $\tau_{ff}$ to
17 N·m, each conditional on the others being zero, which is unusable.

[Derived] The correct formulation is a single inequality over the tuple, evaluated against the
measured state with an uncertainty margin. ADR-002's $\mathcal X_j$ — "bounded measurement
uncertainty and one-cycle state evolution" — is the right form: at 200 Hz with a joint moving at
10 rad/s, one cycle of state evolution is $10 \times 0.005 = 0.05$ rad, which at $K_p = 60$ is
3 N·m of unmodelled torque. Not including it would make the projection optimistic by half the
drive's continuous rating.

### 3.3 `enforce_command_limits` is exactly the prohibited method

[Upstream] `controller_manager` exposes `enforce_command_limits` as a **read-only** boolean
parameter, **default `false`**. When enabled it clamps commands to the joint limits taken from the
robot description. [Upstream] `hardware_interface_types_userdoc.rst` likewise offers `min` and `max`
parameters on individual `command_interface` declarations.

[Derived] Both mechanisms are per-interface scalar clamping — precisely what §3.2 shows cannot bound
torque. Three consequences:

1. **The default `false` is the correct setting and should be recorded as a deliberate choice, not
   left as an unexamined default.** A future maintainer who sees a safety-sounding parameter set to
   `false` will be tempted to enable it.
2. Enabling it would be actively harmful in one specific way: it would silently modify commands the
   `SafetyKernel` had already projected, breaking the invariant that the kernel's output is what
   reaches the transport, and making the kernel's verdict a lie.
3. It is not useless. As a _coarse outer_ sanity limit it would catch a wild value. But it must
   never be described, in code or documentation, as the joint limit enforcement, because it is not.

### 3.4 Building $\tau_{allowed}$ from the vendor overload curves

[Primary] The RobStride overload curves (transcribed in
[Topic 1 §3.3](topic-1-real-time-actuation-and-hardware-abstraction.md#33-overload-curves)) are the
only published basis for a time-dependent torque limit. The obvious implementation is a
first-order $I^2t$ thermal integrator:

$$\frac{ds}{dt} = \frac{1}{\Theta}\left(\frac{\tau^2}{\tau_{cont}^2} - 1\right), \qquad s \in [0,1], \quad \text{trip at } s = 1$$

[Derived] Fitting $\Theta$ independently at each published point tests whether one time constant
can describe the curve. For the RS02 ($\tau_{cont} = 6$ N·m):

| $\tau$ (N·m) | $(\tau/\tau_{cont})^2 - 1$ | Permitted (s) | Implied $\Theta$ (s) |
| ------------ | -------------------------- | ------------- | -------------------- |
| 6.5          | 0.174                      | 3000          | 522                  |
| 11           | 2.36                       | 100           | 236                  |
| 15           | 5.25                       | 18            | 94.5                 |
| 17           | 7.03                       | 10            | 70.3                 |

For the RS03 ($\tau_{cont} = 20$ N·m):

| $\tau$ (N·m) | $(\tau/\tau_{cont})^2 - 1$ | Permitted (s) | Implied $\Theta$ (s) |
| ------------ | -------------------------- | ------------- | -------------------- |
| 30           | 1.25                       | 189           | 236                  |
| 40           | 3.00                       | 126           | 378                  |
| 50           | 5.25                       | 12            | 63                   |
| 60           | 8.00                       | 7             | 56                   |

For the RS00 ($\tau_{cont} = 5$ N·m): implied $\Theta$ runs 115, 54, 47.6, 34.2 s across the four
points.

**Finding.** [Derived] $\Theta$ varies by 7.4× across the RS02 curve, 6.7× across the RS03 curve,
and 3.4× across the RS00 curve, and in all three the implied time constant **falls monotonically as
overload rises**. That is the signature of a multi-time-constant thermal system — a fast winding
against a slow housing — not of a single lump.

Consequences for implementation:

- A single-time-constant $I^2t$ model **fitted at the peak point is conservative by up to 7× at low
  overloads**, discarding most of the drive's usable capacity.
- The same model **fitted at low overload is dangerously optimistic at the peak**, permitting
  roughly 7× the vendor's allowed duration at peak torque. On an RS03 that is 49 s at 60 N·m against
  a published 7 s.
- The defensible implementations are (a) direct interpolation of the published curve, piecewise
  linear in $\log t$, or (b) a two-time-constant model fitted to all points. Option (a) needs no
  fitting and no thermal theory, and is recommended for that reason.
- The curves themselves assume an unreported thermal starting condition (NR;
  [Topic 1 §3.3](topic-1-real-time-actuation-and-hardware-abstraction.md#33-overload-curves)). Any
  implementation must therefore also derate for accumulated duty, which is what the $s$ state
  variable in ADR-002's $\tau_{allowed}(T,V,s)$ is for.

**Structural gap.** [Primary]
[safety_manifest.hpp](../src/humanoid_transport/include/humanoid_transport/safety_manifest.hpp)
models the curve as a single `torque_peak_nm` plus `torque_peak_duration_s`. That pair can
represent one point of a four-point curve. Whichever point is chosen, the other three are lost. See
[§10](#10-evidence-that-challenges-the-accepted-decision), finding 12.

### 3.5 Thermal dependence is not optional

[Primary] Drive operating range is −20 to 50 °C ambient, Class B insulation. Phase resistances:
RS00 1.5 Ω, RS02 0.55 Ω, RS03 0.39 Ω, RS06 0.23 Ω. Rated powers: 50, 60, 210, 115 W respectively.

[Derived] Stall is the worst thermal case, because none of the electrical input becomes mechanical
work and the rotor does not move to circulate air. Taking the RS02 at its 7 A rated current, copper
loss is

$$P_{Cu} = 3 I^2 R = 3 \times 7^2 \times 0.55 = 81\ \text{W}$$

if the published 0.55 Ω is per-phase, or 40 W if it is line-to-line. **Either figure is a large
fraction of, or exceeds, the drive's entire 60 W rated power, delivered as pure heat with no motion
to dissipate it.** The resistance convention is not stated by the vendor (NR), so the exact figure
is uncertain; the conclusion is not.

[Derived] Two design consequences:

1. **A stall is a thermal event, not merely a control failure.** ADR-002's prohibition on indefinite
   position hold has a thermal justification independent of the safety one: a joint holding against
   a jam is stalled, and a stalled drive at appreciable current has a bounded lifetime measured in
   tens of seconds by the overload curves.
2. **The `SafetyKernel` needs the temperature it already receives.**
   [Primary] `JointFeedback` in
   [batch_types.hpp](../src/humanoid_transport/include/humanoid_transport/batch_types.hpp) carries
   `temperature_c` and `bus_voltage_v`. `JointEnvelope` carries no temperature- or voltage-dependent
   term. The inputs to $\tau_{allowed}(T,V,s)$ are being measured and transported and then not used.

**Measurement resolution caveat.** [Primary]
`firmware/slave/slave_general/Core/Src/motor_runtime.c` `motor_runtime_pack_tele` clamps negative
temperatures to zero and truncates to `uint8_t`. [Derived] Temperature therefore arrives at 1 °C
resolution with no sub-zero range. For a derating curve that must act before a thermal limit, 1 °C
quantisation is coarse but workable; the loss of negative values is harmless indoors and would
silently misreport a cold-start diagnostic.

---

## 4. Fault detection: what is observable, and when

### 4.1 What the drive reports

[Primary] Six fault bits in the type-2 feedback frame identifier, plus two status bits:

| Bit | Fault             | Canonical class      | Recoverable in place?                                            |
| --- | ----------------- | -------------------- | ---------------------------------------------------------------- |
| 0   | Undervoltage      | Electrical / power   | Only if the supply recovers; implies a power-system fault        |
| 1   | Driver fault      | Drive hardware       | No                                                               |
| 2   | Overheat          | Thermal              | Yes, after cooling and a derating policy                         |
| 3   | Encoder fault     | Sensing              | No — position is untrustworthy, so damping is also untrustworthy |
| 4   | Stall or overload | Mechanical / thermal | Yes, if the cause is removed                                     |
| 5   | Uncalibrated      | Configuration        | No — a startup interlock condition, not a runtime fault          |

[Derived] The classification matters more than the list. **Bit 3, encoder fault, is the one bit for
which ADR-002's default protective damping is not safe.** Damping requires $\dot q$; a faulted
encoder means $\dot q$ is unknown, and applying $K_d$ to a wrong velocity injects energy rather than
removing it. ADR-002 anticipates exactly this — "Safe damping is a tested primitive, not a universal
constant. If damping would worsen a detected electrical, runaway, entrapment, or impact hazard, the
fault policy selects immediate disable or power removal instead" — and bit 3 is the concrete case
that must be enumerated in the fault policy table.

Similarly **bit 0, undervoltage, is a whole-robot condition presenting as a per-joint fault.** If one
drive reports undervoltage, the others are on the same rail. Treating it as a joint fault and
isolating that joint would be the wrong response; it is a power-system fault and belongs in the
power path of ADR-002's thermal-and-power section.

### 4.2 What the drive does not report

[Derived] Absence enumerated, because a fault table built only from the six bits will be assumed
complete:

| Not reported                           | Consequence                                                                                                                                    |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Mechanical backlash or gear wear       | Degrades silently; only detectable as tracking error statistics                                                                                |
| Rotor–encoder decoupling (magnet slip) | Position reads plausibly and is wrong. **Undetectable at a single joint**; requires cross-joint kinematic consistency or an external reference |
| Wire-scaling mismatch (H9)             | Undetectable by any drive-side mechanism                                                                                                       |
| Cable or connector intermittency       | Presents as missing feedback, not as a fault bit                                                                                               |
| Bus termination absent                 | Presents as elevated frame errors, which nothing currently counts                                                                              |
| Thermal state below the trip threshold | The overheat bit is binary; the derating input is the analogue temperature, which is separate                                                  |

[Derived] Three of these six are only observable at the host, from cross-joint or statistical
evidence. That is an argument for the `HealthSnapshot` counters in
[batch_types.hpp](../src/humanoid_transport/include/humanoid_transport/batch_types.hpp) —
`framing_errors`, `sequence_rejections`, `deadline_misses`, `worst_round_trip` — being treated as
safety-relevant telemetry (Topic 11) rather than as debugging aids.

### 4.3 Detection latency

[Derived] Fault bits ride in the ordinary feedback frame, so notification latency at the host is
bounded by the cycle plus transport, not by any separate polling:

| Stage                                                 | Latency     | Basis                                                                                                                       |
| ----------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------- |
| Drive sets the bit to bit present in a feedback frame | ≤ 5 ms      | Feedback is emitted per cycle [Primary]                                                                                     |
| Slave receives to slave includes in SPI telemetry     | ≤ 5 ms      | Telemetry refreshed when `can_feedback_count` changes [Primary]                                                             |
| Master SPI exchange to USB emission                   | ≤ 5 ms      | `MASTER_TELE_PERIOD_MS 5` [Primary]                                                                                         |
| USB to host `read()`                                  | NR          | Never measured — [Topic 1 §10](topic-1-real-time-actuation-and-hardware-abstraction.md#10-open-questions-and-evidence-gaps) |
| **Total, excluding USB**                              | **≤ 15 ms** | [Derived]                                                                                                                   |

Against ADR-002's 5 ms deadline for "critical drive fault in a complete feedback batch", measured
from feedback acceptance to isolation command: the deadline is stated from _acceptance_, so the
three cycles of transport latency above are outside it. [Derived] That is defensible as a
measurement definition and it means the ADR's 5 ms figure is **not** the physical detection-to-action
latency, which is at least 15 ms plus USB. Both numbers are worth recording; only one of them is
what a hazard analysis needs.

The time for the drive to _set_ the bit after the physical condition arises is NR, and is not
knowable from the documentation. It must be measured for at least the overheat and stall bits, since
those are the two the robot is expected to encounter in normal play.

---

## 5. Command loss, staleness, and watchdogs

### 5.1 What a watchdog must prove

[Derived] A command watchdog exists to answer one question: _is the entity that is supposed to be
controlling this actuator still controlling it?_ Four properties are needed for an affirmative
answer, and they are strictly ordered — each is useless without the ones before it:

1. **Liveness.** Bytes are arriving.
2. **Integrity.** The bytes form a message that passes a checksum.
3. **Validity.** The message is addressed to this session and this arm epoch, not a replay.
4. **Progression.** The sequence number has advanced; this is a new command, not the last one
   repeated.

ADR-002 requires all four: "The Embedded Safety Agent independently validates packet integrity,
session or arm epoch, sequence progression, and age."

[Derived] A watchdog that only checks property 1 is a _link_ watchdog, not a _command_ watchdog. It
answers "is the cable connected", which is a strictly weaker question. A host that has crashed while
its USB stack continues to enumerate, or a controller stuck in a loop emitting the same command,
both satisfy property 1 indefinitely.

### 5.2 The as-built watchdog checks liveness only

[Primary] `firmware/slave/slave_general/Core/Src/motor_runtime.h`: `MOTOR_WATCHDOG_MS 200u`.

[Primary] `firmware/slave/slave_general/Core/Src/main.c`, lines ≈222-310: the loop that refreshes
each motor's watchdog runs **before** the `switch (cmd & 0x0F)` that decodes the command byte.
`SPI_CMD_NOP` is `0x00`.

[Derived] **Every SPI exchange refreshes every motor's watchdog, including exchanges carrying no
command at all.** The master transmits a command byte every 5 ms tick and emits `SPI_CMD_NOP` when
nothing else is pending ([Topic 1 §5.4](topic-1-real-time-actuation-and-hardware-abstraction.md#54-command-delivery-is-not-guaranteed-per-cycle)),
so the watchdog is refreshed at 200 Hz regardless of whether the host is alive.

[Primary] Further, in the `SPI_CMD_MIT` branch the watchdog is refreshed regardless of the per-motor
`valid` flag in `SpiMitCmd`.

[Derived] The watchdog therefore proves property 1 and nothing else. Since the master generates the
NOP autonomously and has no host-command-age check of its own
([§9](#9-the-as-built-safety-gap-register), gap 4), **a Jetson that is powered off entirely leaves
every motor's watchdog satisfied indefinitely.** The only way the as-built watchdog fires is if the
SPI link itself stops, which is the one failure mode the two microcontrollers can already detect
several other ways.

There is no session epoch, no arm epoch, and no sequence-gap detection anywhere in the firmware.
[Primary] `last_cmd_seq` is stored and echoed in telemetry, and the SPI dispatcher passes it as
`0u`.

### 5.3 The drive's own timeout is the missing layer

[Community] Register `0x7028`, `canTimeout`, `uint32`. The drive maintains its own CAN command
timeout.

[Derived] This is the only watchdog in the system that survives failure of both microcontrollers.
Configured at, say, 50 ms it would bound the duration of uncommanded motion after _any_ upstream
failure, without depending on a single line of project firmware. It is currently unconfigured.

Together with `limit_torque` (`0x700B`), `limit_spd` (`0x7017`) and `limit_cur` (`0x7018`), the
drive offers four enforcement points that sit below every software layer this project controls.
[Derived] Configuring them is the highest safety return per unit of effort available anywhere in
this system, and it requires no architectural change: they are written with communication type 18,
which the firmware already implements.

**Caveat.** [Derived] Their behaviour on timeout is not documented in the sources available here
(NR). Whether `canTimeout` disables the drive, zeroes the command, or enters a damped state
determines whether it is a Category 0 or Category 1 stop, and therefore whether it is safe to rely
on for a leg joint. This must be bench-verified before being trusted, and is
[§12](#12-open-questions-and-evidence-gaps) item 3.

### 5.4 Deadline arithmetic

[Derived] ADR-002 sets command loss at three consecutive missing or invalid 5 ms cycles: assert by
15 ms, safe command by 20 ms. Checking this against §2.1: 20 ms is a 1.112 growth factor on the
divergent balance mode, or 3.3 % of the fall time. That leaves the state recoverable and is
consistent with the physics.

[Primary] `SafetyManifest::max_consecutive_bad_cycles` defaults to `3U` in
[safety_manifest.hpp](../src/humanoid_transport/include/humanoid_transport/safety_manifest.hpp), and
the field is documented as encoding exactly this rule. The host-side type matches the decision.

[Derived] Why three and not one: at 200 Hz over a link with any bit-error rate, single-cycle loss is
expected. A one-cycle threshold would trip constantly and, worse, would train operators to ignore
it. Three cycles is the smallest threshold that tolerates isolated loss while remaining inside the
20 ms envelope. Two would also fit (10/15 ms) and would be defensible if measurement shows isolated
loss is rare. **The choice should be revisited once the frame-loss rate is measured**, which it has
not been (NR).

---

## 6. What "safe" means for a biped

### 6.1 Three candidate protective actions

| Action            | Command                                              | Physical effect                                                                  | Fails badly when                                                                                                                                     |
| ----------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Position hold** | Keep last $q_d$, keep $K_p$                          | Joint resists displacement indefinitely                                          | Always, eventually: a stalled joint is a thermal event (§3.5), a rigid joint is a crush hazard (H2), and a robot frozen mid-stride falls while rigid |
| **Damping**       | $q_d, \dot q_d, \tau_{ff}, K_p$ all zero; $K_d$ only | Joint resists _velocity_, not position; limb yields to a push and settles        | Velocity is unknown (encoder fault), or the limb is already in a hazardous position and gravity will carry it further                                |
| **Disable**       | Drive enable removed                                 | Joint is free apart from residual friction and any configured back-drive damping | The robot is supporting itself; a disabled leg collapses immediately                                                                                 |

[Primary] The drive exposes register `0x2023 damper`, unpowered back-drive damping, so "disable" is
not entirely free-wheeling if that register is configured. It is currently unconfigured (NR for its
effect).

[Derived] ADR-002's ordering — protective damping, then disable after a bounded interval, with
immediate disable substituted when damping would worsen the hazard — is the correct default, and
§6.2 shows why quantitatively. ADR-002's flat prohibition on indefinite position hold is supported
by three independent arguments: thermal (§3.5), the crush hazard during a league-mandated handler
intervention (§1.3), and the fact that a held posture does not converge to a stable one.

### 6.2 Damping versus disable: the arithmetic

[Derived] Under pure damping, a joint of inertia $I$ obeys $I\ddot q = -K_d \dot q$, so

$$\dot q(t) = \dot q_0\, e^{-K_d t / I}, \qquad \text{time constant } \Theta_d = I / K_d$$

For the limb of §1.1 ($I = 0.025$ kg·m²) at the configured $K_d = 1$ N·m·s/rad:

$$\Theta_d = 0.025\ \text{s} = 25\ \text{ms}$$

| Elapsed | Remaining velocity | Remaining kinetic energy |
| ------- | ------------------ | ------------------------ |
| 25 ms   | 37 %               | 13 %                     |
| 50 ms   | 14 %               | 1.8 %                    |
| 75 ms   | 5 %                | 0.25 %                   |

**Damping removes 98 % of the limb's kinetic energy in 50 ms** — an order of magnitude faster than
the 0.6 s fall time and comparable to the reaction deadlines. Under disable, the same limb retains
its velocity and then accelerates under gravity.

[Derived] Two conclusions:

1. Damping is not a compromise between "stop" and "release". On this timescale it is _the_ fast
   energy-removal mechanism, and disable is the slow one. ADR-002's damp-then-disable sequence
   removes the energy first and the authority second, which is the right order.
2. The bounded damping interval in ADR-002 should be at least $3\Theta_d$ for the largest $I/K_d$ in
   the robot. With the current numbers that is 75 ms. An interval shorter than that disables while
   the limb is still moving, which is the worst of both.

$\Theta_d$ scales with $I$, so a hip carrying the whole leg has a much larger time constant than the
arm joint computed here. [Derived] The interval must be computed per joint from the manifest, not
set as a single global constant. `JointEnvelope` has `damping_max_nm_s_rad` but no inertia term, so
the calculation currently has no home in the data model.

### 6.3 Fall management

[Derived] ADR-002 treats falling as a first-class state with a 10 ms deadline from trigger to first
brace tuple. Checking that against the physics: 10 ms is 5.3 % of $T_c$, a growth factor of 1.054.
The deadline is tight but the _decision_ it gates — whether a fall is unrecoverable — is the hard
part, not the actuation.

The trigger evidence ADR-002 lists (base tilt and rate outside the recoverable envelope, predicted
capture failure, contact loss or inconsistency, free-fall or impact signature, estimator invalidity
during dynamic motion) requires IMU and contact sensing at cycle rate. That is a Topic 4
dependency, and the relevant point for Topic 2 is that **a fall trigger is only as fast as the
slowest of its evidence sources.** An IMU at 200 Hz and a contact sensor at 50 Hz gives a trigger no
faster than 20 ms regardless of the deadline written down.

[Derived] The false-positive cost is asymmetric and worth stating: a missed fall costs a damaged
robot and a lost match; a false fall trigger costs a forfeited attacking move and a robot lying on
the ground. The second is much cheaper, which argues for a permissive trigger, and against tuning it
for precision. This asymmetry is not stated in ADR-002 and is the kind of thing that gets tuned the
wrong way under competition pressure.

**Post-fall.** ADR-002 inhibits locomotion after impact, applies a bounded post-impact damping or
load-relief primitive, classifies posture, and requires explicit authorisation for self-righting.
[Derived] The load-relief requirement is the non-obvious one and is correct: a robot that has landed
on a limb has joints holding against the ground reaction, which is a stall (§3.5). A post-fall
policy that only stops motion leaves those joints heating.

### 6.4 The impact energy that must be survived

[Derived] From §1.1, a CoM drop from 0.35 m to 0.10 m releases 2.45 J per kilogram of robot mass at
an impact speed of 2.21 m/s. For a 3.5 kg kid-size robot that is 8.6 J. Distributed over a 5 ms
impact, the mean force is

$$F = \frac{m \Delta v}{\Delta t} = \frac{3.5 \times 2.21}{0.005} = 1547\ \text{N}$$

with the assumed mass flagged: robot mass is NR at Model Gate 0. The figure scales linearly. The
purpose of quoting it is that **it is an order of magnitude larger than any actuator force in the
system** (H1: 85-240 N). No brace primitive can absorb a fall by opposing it; the only available
strategies are increasing $\Delta t$ (compliance on landing) and choosing which part of the robot
takes the load. Both are what ADR-002's brace primitive is for, and both argue for _low_ stiffness
at impact, not high.

---

## 7. Isolation granularity

### 7.1 Per-joint isolation is not free

ADR-002 specifies a per-joint availability mask with a monotonic epoch, and requires that remaining
joints damp while a prequalified degraded policy is selected.

[Derived] The evidence supports this being _hard_, in three ways:

1. **ROS gives no help.** §2.3 fact 4: a single `System` component has all-or-nothing granularity.
   Everything about the mask must be implemented in project code.
2. **Kinematic coupling.** A biped's joints are not independent actuators; they are a serial chain
   under gravity. Masking a knee does not produce a robot with one fewer degree of freedom. It
   produces a robot with an unactuated joint in a load path, which is a different, and generally
   unstable, plant. ADR-002's statement that "an arbitrary gait cannot continue after masking a
   joint" and that dynamic one-leg-joint failure recovery "is not assumed safe until separately
   demonstrated" is the correct level of caution.
3. **Isolation must be _verified_, not commanded.** ADR-002 requires "a drive acknowledgement plus
   observed state, current, or torque behavior". [Derived] This matters because a disable command
   that is not received leaves the joint in exactly the state the isolation was meant to prevent,
   and the availability mask would then be a lie propagated to the controller. ADR-002's escalation
   to shared power removal on unverified isolation is the only sound response.

### 7.2 What the as-built system does instead

[Primary] `firmware/slave/slave_general/Core/Src/motor_runtime.c`: while a motor is in
`ARMED_HOLD`, `ARMED_MIT`, or `ZEROING`, if `fabsf(tau) > cfg->max_tau` the runtime calls
`idle_motor()`, which issues `can_disable_motor()` immediately and latches the motor to `IDLE`.

[Primary] `configs/slave0.yaml` sets `max_tau: 0.8` N·m and `default_kp: 15.0` for every motor.

[Derived] Three findings compound here:

1. **The trip threshold is 3.1 degrees of position error.** With $K_p = 15$ and $\tau_{ff} = 0$, the
   torque reaches 0.8 N·m at

   $$e = \frac{0.8}{15} = 0.053\ \text{rad} = 3.06°$$

   Any disturbance, load, or trajectory step producing more than 3.1° of tracking error disables the
   joint. For comparison, [Primary] `MOTOR_ZERO_TOL` is 0.05 rad — the zeroing routine's own arrival
   tolerance is 94 % of the trip threshold.

2. **The trip drops one joint with no coordinated response.** The other joints are not informed, not
   damped, and continue executing whatever they were doing. This is precisely the situation ADR-002's
   containment sequence exists to prevent: a leg with a silently disabled knee is a falling robot,
   and nothing in the firmware knows it.
3. **The threshold is measured in disputed units.** The torque value compared against `max_tau` is
   decoded [Primary] with the global ±17 N·m span regardless of model. For an RS00 whose true span
   may be ±14 N·m ([Topic 1 §3.5](topic-1-real-time-actuation-and-hardware-abstraction.md#35-mit-wire-scaling-two-sources-two-answers)),
   the comparison is wrong by up to 21 %.

[Derived] The mechanism is not wrong in principle — a per-joint torque limit enforced below the host
is exactly the independent authority ADR-002 wants. It is wrong in three specifics: the threshold is
set an order of magnitude below anything the joint will actually need, the response is disable rather
than damping, and there is no escalation. Fixing the threshold without fixing the response would make
the system less safe, because a rarely-firing uncoordinated disable is more dangerous than a
frequently-firing one that gets noticed.

---

## 8. Rearm, startup interlock, and identity

### 8.1 Why rearm must be hard

[Derived] ADR-002 forbids automatic return to `ARMED` after reconnection, process restart, watchdog
reset, fault-bit clearance, or E-stop release. The argument is straightforward and worth recording:
every one of those events is a _transition of the observer_, not of the robot. A watchdog reset
tells you the firmware restarted; it tells you nothing about whether the robot is now standing,
lying down, tangled in a cable, or being carried by a handler with fingers inside the linkage.

The league rules make this concrete: [League] a handler is expected to physically hold the robot.
The interval immediately after a fault is exactly when a human is most likely to be in contact with
the machine. **Auto-rearm places motion authority into the moment of maximum human exposure.**

### 8.2 The identity interlock, and the hole in it

ADR-002 requires that host, STM32, transport protocol, robot model, motor table, calibration and
safety-manifest identities all match, compared by a shared digest, with drives disabled on mismatch.

[Primary] `JointManifest` in
[joint_manifest.hpp](../src/humanoid_transport/include/humanoid_transport/joint_manifest.hpp) carries a
32-byte `model_digest` documented as the SHA-256 of `model/robot_model.yaml`. `SafetyManifest`
carries its own `manifest_digest`. The mechanism exists in the type system.

[Primary] `JointEntry` carries `name`, `bus_segment`, `can_node_id`, `gear_ratio`, `direction_sign`
and `zero_offset_rad`. **It carries no actuator model identity and no MIT wire-scaling spans.**

[Derived] The digest therefore cannot detect the two most dangerous configuration errors identified
in this research:

- An RS03 fitted where the manifest expects an RS02. Same CAN id, same joint name, same gear ratio
  field — digest matches, and the drive interprets $K_p$ over a 10× different span
  ([Topic 1 §3.5](topic-1-real-time-actuation-and-hardware-abstraction.md#35-mit-wire-scaling-two-sources-two-answers)).
- A wire-scaling constant that is wrong for a correctly-fitted drive.

[Derived] Closing this requires two things, and the second is the important one: (a) actuator model
and wire spans become manifest fields covered by the digest, and (b) **the drive's identity is read
back and compared**, not merely declared. Communication type 0 returns the device id and a 64-bit
MCU unique identifier [Primary], and the firmware already implements it for discovery. Comparing
that identifier against the manifest at startup converts the interlock from "the files agree with
each other" to "the files agree with the hardware", which is the property the interlock is supposed
to have.

**A positive finding.** [Primary] `direction_sign` is a separate `int8_t` field rather than being
folded into the sign of `gear_ratio`, with the comment "so a sign error cannot hide inside a gear
ratio". That is a deliberate, correct decision: a sign error on a joint is a runaway, and making it
a distinct field makes it reviewable.

### 8.3 Startup posture initialisation

[Derived] ADR-002 requires every MIT tuple to be initialised without a step: measured $q$ as the
initial $q_d$, zero $\dot q_d$ and $\tau_{ff}$, zero $K_p$, and only an approved startup $K_d$,
while drives remain disabled.

This is the single most effective line in the whole ADR, because the alternative — arming with
$q_d$ at whatever the last value was — produces exactly the impulse of
[Topic 1 §1.2](topic-1-real-time-actuation-and-hardware-abstraction.md#12-why-partial-application-is-not-a-degraded-version-of-the-same-command)
at the instant of arming, when a handler's hands are most likely on the robot. With $K_p = 15$ and a
0.5 rad stale offset, arming produces 7.5 N·m instantaneously.

[Primary] The as-built arming sequence does not do this. `motor_runtime_arm` enables the drive and
enters `ARMED_HOLD` with `cfg->default_kp` of 15, using the position captured at arm time — which is
correct in effect for the hold target, but the drive is enabled _before_ the gains are known to be
appropriate, and the whole sequence blocks for ~40 ms per motor
([Topic 1 §5.3](topic-1-real-time-actuation-and-hardware-abstraction.md#53-blocking-calls-inside-the-cycle)).
Zero-stiffness initialisation is not implemented.

---

## 9. The as-built safety gap register

[Primary] Read from `C:\dev\soccer-firmware` on 2026-09-02. This register states what the machine
does today against what ADR-002 requires. It is not a task list; it is evidence.

**Severity key:** _Critical_ — can leave actuators energised and commandable with no supervision.
_Major_ — a required independent authority is absent or does not do what its name says.
_Moderate_ — a latent hazard or a defeated diagnostic.

| #   | ADR-002 requirement                                                                                     | As-built state                                                                                                                                                                                                                                 | Severity     |
| --- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| 1   | "STM32 brownout reset and independent-watchdog reset boot into drives-disabled state"                   | `HAL_IWDG_MODULE_ENABLED` and `HAL_WWDG_MODULE_ENABLED` are **commented out in both `stm32f4xx_hal_conf.h` files**. **Neither microcontroller has a hardware watchdog.** A hung MCU leaves drives enabled indefinitely                         | **Critical** |
| 2   | "Latching E-stop and monitored power chain", de-energize-to-stop, independent of all software           | No power-interruption path exists anywhere in the system. There is no contactor, no monitored feedback, and no e-stop input                                                                                                                    | **Critical** |
| 3   | Embedded Safety Agent validates "packet integrity, session or arm epoch, sequence progression, and age" | The watchdog is refreshed by `SPI_CMD_NOP`, i.e. by link liveness alone (§5.2). No session epoch, no arm epoch, no sequence-gap detection. `last_cmd_seq` is echoed and passed as `0u`                                                         | **Critical** |
| 4   | Command loss asserted at three cycles (15 ms), safe command by 20 ms                                    | `MOTOR_WATCHDOG_MS 200u` — **40 cycles, 10× the deadline**. The master has no host-command-age check at all, so a powered-off host never trips it                                                                                              | **Critical** |
| 5   | "Indefinite position hold is prohibited"                                                                | On watchdog expiry in `ARMED_MIT`, the runtime falls back to `ARMED_HOLD`, **holding the current position indefinitely at $K_p = 15$**. This is the prohibited behaviour, reached by the mechanism meant to prevent it                         | **Critical** |
| 6   | Faulted joint isolated, remaining joints damp, prequalified policy selected, escalation if unverified   | Per-joint torque trip at 0.8 N·m calls `idle_motor()` and latches one joint to IDLE. No notification, no damping of the others, no policy, no escalation (§7.2)                                                                                | **Critical** |
| 7   | Packet integrity validated by the Embedded Safety Agent                                                 | SPI CRC is `CRCCALCULATION_DISABLE` on both ends. Presence is a `motor_idx` ordering heuristic                                                                                                                                                 | **Major**    |
| 8   | Protocol identity is part of the startup interlock                                                      | Three incompatible protocol definitions coexist; the host Python and master C implement different wire formats ([Topic 1 §5.5](topic-1-real-time-actuation-and-hardware-abstraction.md#55-framing-integrity-and-three-incompatible-protocols)) | **Major**    |
| 9   | Startup interlock compares host and STM32 digests; mismatch keeps drives disabled                       | No digest exists in the firmware. `motor_config.h` is committed generated from `slave1.yaml` only                                                                                                                                              | **Major**    |
| 10  | On slave absence or garbage, containment then escalation                                                | The master sets `slave_alive = 0`, drops pending one-shots, and **issues no disarm and no fault escalation**. `master_armed[s]` persists and `SPI_CMD_HOLD` streams forever                                                                    | **Major**    |
| 11  | Drive protection is an independent authority                                                            | `canTimeout`, `limit_torque`, `limit_spd` and `limit_cur` are all unconfigured (§5.3)                                                                                                                                                          | **Major**    |
| 12  | Coupled envelope; scalar clipping prohibited as the sole method                                         | The only host-independent limits are per-joint scalar `soft_min`/`soft_max`, `max_vel`, `max_tau`. There is no coupled check anywhere                                                                                                          | **Major**    |
| 13  | Safe damping is the default protective response                                                         | The firmware has no damping primitive. Its two responses are hold and disable                                                                                                                                                                  | **Major**    |
| 14  | Fall, brace, and post-fall are first-class states                                                       | Not implemented in firmware. `MotorLifecycle` has no fall-related state                                                                                                                                                                        | **Major**    |
| 15  | Rearm requires a new arm epoch and explicit command                                                     | `master_armed[s]` persists across slave loss and recovery with no fresh handshake                                                                                                                                                              | **Major**    |
| 16  | Every MIT tuple initialised without a step, zero $K_p$, approved startup $K_d$ only                     | Arming enables the drive at $K_p = 15$ directly (§8.3)                                                                                                                                                                                         | **Moderate** |
| 17  | Reaction latency measured at physical boundaries with percentile distributions                          | No timing measurement of any kind exists                                                                                                                                                                                                       | **Major**    |

[Derived] **Six critical gaps.** The pattern across them is consistent and worth naming: the
as-built machine has _mechanisms_ in roughly the right places — a watchdog, a torque limit, soft
limits, an arm state — but each one answers a weaker question than its name suggests. The watchdog
proves the cable is connected. The torque limit trips on a 3° tracking error and then abandons the
joint. The arm state persists through the loss of its own supervisor. This is a more dangerous
configuration than having none of them, because the names invite the assumption that the properties
hold.

[Derived] The two gaps that are not software fixes are 1 and 2. A hardware watchdog is a
configuration change plus a service routine. A monitored power-interruption chain is an electrical
design task with mass, volume and cost implications, and it is a Model Gate 0 input that does not
currently appear in the hardware requirements. That is the most consequential single observation in
this document.

---

## 10. Evidence that challenges the accepted decision

ADR-002 is accepted and is not modified by this document. The following are recorded because they
contradict, or are not supported by, statements in or assumptions behind that decision. The gaps in
[§9](#9-the-as-built-safety-gap-register) are implementation shortfalls and are not repeated here;
these are issues with the decision's own content or its data model.

| #   | Finding                                                                                                                                                                                                                                                   | Consequence                                                                                                                                                                                      |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | ADR-002's 5 ms deadline for "critical drive fault in a complete feedback batch" is measured from _feedback acceptance_. The physical detection-to-action latency is at least 15 ms plus an unmeasured USB round trip (§4.3)                               | The stated deadline is a valid measurement definition but is not the hazard-relevant latency. A hazard analysis using the 5 ms figure would understate exposure by at least 3×                   |
| 2   | `JointEnvelope` models the overload curve as one `torque_peak_nm` plus one `torque_peak_duration_s`. The vendor curves have four to five points spanning a 300-fold duration range, and no single-time-constant thermal model fits them (§3.4)            | $\tau_{allowed}(T,V,s)$ cannot be implemented faithfully against the current data model. Whichever curve point is chosen, the rest of the envelope is either discarded or overstated by up to 7× |
| 3   | `JointEnvelope` has no temperature- or voltage-dependent terms, though `JointFeedback` transports `temperature_c` and `bus_voltage_v`                                                                                                                     | The $T$ and $V$ arguments of $\tau_{allowed}(T,V,s)$ have no home in the manifest. The inputs are measured, transported, and unused                                                              |
| 4   | `JointEntry` carries no actuator model identity and no MIT wire-scaling spans (§8.2)                                                                                                                                                                      | The startup identity interlock cannot detect an RS03 fitted where an RS02 is expected — a 10× stiffness error on a 60 N·m actuator. The digest certifies file agreement, not hardware agreement  |
| 5   | `JointEnvelope` has no inertia term, so the bounded damping interval of §6.2 ($3I/K_d$) cannot be computed per joint                                                                                                                                      | The damping interval must be a global constant, which is wrong by the ratio of the largest to smallest joint inertia                                                                             |
| 6   | ADR-002 requires damping as the default protective response but does not enumerate the fault classes for which damping is unsafe. Encoder fault (drive fault bit 3) is the concrete case: damping needs $\dot q$, which is exactly what is faulted (§4.1) | The fault policy table needs a per-fault-bit response column. Without it, "if damping would worsen the hazard" is an instruction with no decision procedure                                      |
| 7   | Drive fault bit 0, undervoltage, is a shared-rail condition presenting as a per-joint fault (§4.1)                                                                                                                                                        | Treating it through the per-joint containment path would isolate one joint of many that are equally affected. It belongs in the power path                                                       |
| 8   | The false-positive/false-negative cost asymmetry of the fall trigger is not stated (§6.3)                                                                                                                                                                 | A permissive trigger is much cheaper than a conservative one. Absent an explicit statement, this will be tuned toward precision under competition pressure, which is the wrong direction         |
| 9   | The fall trigger's latency is bounded by its slowest evidence source, which is a Topic 4 sensor-rate question, not a Topic 2 one (§6.3)                                                                                                                   | The 10 ms brace deadline is unachievable if any required evidence source runs below 100 Hz. The dependency is not recorded in ADR-002                                                            |
| 10  | `enforce_command_limits` defaults to `false`, and that default is doing safety-relevant work by accident (§3.3)                                                                                                                                           | An unexamined default is not a decision. A future maintainer enabling a parameter with that name would silently break the `SafetyKernel`'s output invariant                                      |
| 11  | A monitored actuator-power interruption path appears in ADR-002's "Costs and constraints" but not in the hardware requirements, and has no mass, volume, or current budget                                                                                | The requirement is stated without being sized. Contactor mass on a kid-size humanoid is a Model Gate 0 constraint, not an afterthought                                                           |
| 12  | ADR-002 requires reaction latency to be qualified "under maximum CPU/GPU load, thermal throttling, link corruption, low battery, and repeated fault injection", but no timing measurement of any kind currently exists (§9 gap 17)                        | Every numeric deadline in the ADR is presently an aspiration. None has been shown achievable on the target hardware                                                                              |
| 13  | `max_consecutive_bad_cycles = 3` was chosen without a measured frame-loss rate (§5.4)                                                                                                                                                                     | Two cycles would also fit the 20 ms envelope and would react faster. The choice is defensible but not evidence-based                                                                             |

**What these findings do not challenge.** The core structure of ADR-002 — independent overlapping
authorities, the gate inside `write()`, monotonic transitions toward lower energy, coupled tuple
projection, prohibition of scalar clipping as the sole method, prohibition of indefinite position
hold, verified rather than commanded isolation, and rearm as an explicit human-gated action — is
supported by every line of evidence gathered here, and in
[§2.3](#23-ros2_control-structurally-cannot-be-the-gate) and
[§3.2](#32-the-counterexample-worked) more strongly than the ADR argues it. Findings 2 to 5 are
gaps in the _data model_ rather than in the decision, and are the ones most likely to be closed
quietly and wrongly by an implementer working from the ADR text alone.

---

## 11. Measurement and qualification methodology

[Derived] ADR-002 requires physical markers, percentile distributions, worst observed values, and
capture artifacts. The following is the minimum instrumented set, with the falsification condition
for each, because a test that cannot fail is not a test.

| #   | Quantity                                                                       | Instrumentation                                                                                                           | Fails if                                                                                                                                                              |
| --- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Command-loss reaction: last valid command to safe command on the physical link | Host tracepoint at last transmit; STM32 GPIO toggle at safe-command transmission; logic analyser                          | Worst observed exceeds 20 ms over 10⁵ induced losses                                                                                                                  |
| 2   | Watchdog validity, not liveness                                                | Freeze the host process with `SIGSTOP` while the USB link stays enumerated                                                | Motors are not in a safe state within 20 ms. **The as-built system fails this test by construction (§5.2)**                                                           |
| 3   | Isolation verification: disable command to measured containment                | CAN analyser for the disable frame and the acknowledgement; current probe on the motor phase                              | Acknowledgement or measured current decay not observed within 15 ms                                                                                                   |
| 4   | Failed-isolation escalation                                                    | Physically disconnect one drive's CAN line, then command isolation                                                        | Power removal not initiated within 20 ms of the unverified isolation                                                                                                  |
| 5   | E-stop chain: contact edge to monitored contact open                           | Oscilloscope on the input contact and the auxiliary contact                                                               | Coil command later than 10 ms, or auxiliary contact open later than 30 ms                                                                                             |
| 6   | Motion and current decay after each stop primitive                             | Current probe plus optical or external-encoder motion capture, per actuator, per load, per supply voltage                 | Recorded as data; there is no pass threshold, but **an unmeasured decay time may not be assumed equal to contactor opening time**                                     |
| 7   | Drive `canTimeout` behaviour                                                   | Configure `0x7028`, then cut CAN traffic; observe torque, position, and current                                           | Behaviour is anything other than a documented, repeatable safe state                                                                                                  |
| 8   | Torque trip threshold in physical units                                        | Calibrated load cell against commanded and reported torque, per model                                                     | Reported torque differs from measured by more than 5 % ([Topic 1 §7](topic-1-real-time-actuation-and-hardware-abstraction.md#7-what-must-be-measured) measurement 10) |
| 9   | Damping decay time constant per joint                                          | Release a joint from a known velocity under the damping primitive; measure $\dot q(t)$                                    | Measured $\Theta_d$ differs from $I/K_d$ by more than 30 %, indicating unmodelled friction or an incorrect $K_d$                                                      |
| 10  | Thermal derating curve                                                         | Run a joint at each overload point from a known cold start to trip; record time                                           | Achieved duration is shorter than the vendor curve at any point                                                                                                       |
| 11  | Rearm cannot be reached by any single event                                    | Model checking of the state machine plus fault injection: reconnect, restart, watchdog reset, fault clear, e-stop release | Any single event reaches `ARMED` without an explicit command                                                                                                          |
| 12  | Frame-loss rate on each link                                                   | Count `framing_errors` and `sequence_rejections` from `HealthSnapshot` over a full match duration                         | Recorded as data; feeds the choice of `max_consecutive_bad_cycles` (§5.4)                                                                                             |

**Environment discipline.** [Project] Every measurement must be taken on the target Jetson module,
inside the production container, with the production kernel, under representative CPU, GPU and
thermal load, with the actuators under representative mechanical load and at representative battery
voltage. A number from an idle bench, a desktop host, or a native build does not qualify the system.
Reporting a mean where a maximum is required is a reporting defect, not a rounding choice.

**Fault injection is a first-class requirement, not a phase.** [Derived] Of the seventeen gaps in
§9, at least eleven would be detected by a fault-injection campaign covering: host process freeze,
host power loss, USB cable removal, SPI cable removal, single-drive CAN removal, drive power loss,
corrupted frames, replayed frames, reordered frames, and firmware freeze. None of them is detected
by testing the system while it works, which is why the campaign is a release prerequisite in ADR-002
rather than a stretch goal. ADR-007's fault-injection transport class exists for exactly this and is
the correct home for the reproducible subset.

---

## 12. Open questions and evidence gaps

| #   | Question                                                                                                   | Status                                          | What would close it                                                                                                                             |
| --- | ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Robot mass, CoM height, and link inertias                                                                  | **NR — Model Gate 0 open**                      | Topic 3 Model Gate 0. Every energy and inertia figure in §1, §6.2 and §6.4 is parametric until then                                             |
| 2   | Is a monitored power-interruption chain physically feasible within the mass and volume budget?             | **Open, and not currently budgeted**            | Model Gate 0 must carry contactor mass, volume, coil current and mounting as a line item (§10 finding 11)                                       |
| 3   | What does the drive do when `canTimeout` expires?                                                          | NR                                              | §11 measurement 7. Determines whether it is a Category 0 or Category 1 stop and therefore whether a leg joint may rely on it                    |
| 4   | Latency from the physical condition to the drive setting its fault bit                                     | NR                                              | Bench: induce overheat and stall conditions with an instrumented load                                                                           |
| 5   | Which RS00 torque and velocity wire spans are correct?                                                     | **Disputed, two sources**                       | §11 measurement 8. Until resolved, every torque threshold on an RS00 is uncertain by 21 %                                                       |
| 6   | Frame-loss rate on the USB and SPI links under load                                                        | NR                                              | §11 measurement 12. Required before `max_consecutive_bad_cycles` can be called evidence-based                                                   |
| 7   | Sensor rates available for the fall trigger, and therefore the achievable trigger latency                  | NR here                                         | Topic 4. The 10 ms brace deadline depends on it (§10 finding 9)                                                                                 |
| 8   | Regenerative overvoltage during a hard stop or fall; is a brake resistor needed?                           | NR — hazard H8 unquantified                     | Bench: instrument the bus during a commanded fast stop of a loaded joint                                                                        |
| 9   | Battery pack, BMS trip behaviour, and cell-temperature reporting                                           | NR — pack not selected                          | Model Gate 0                                                                                                                                    |
| 10  | Which fault classes make damping unsafe, enumerated per drive fault bit                                    | **Open**                                        | A fault policy table with a response column; encoder fault is the known case (§10 finding 6)                                                    |
| 11  | Per-joint bounded damping interval                                                                         | Cannot be computed — no inertia in the manifest | Add an inertia term to `JointEnvelope`, or compute from the robot model at manifest generation                                                  |
| 12  | Whether two cycles rather than three is the right command-loss threshold                                   | **Open**                                        | Depends on item 6                                                                                                                               |
| 13  | Achievability of every numeric deadline in ADR-002 on the target hardware                                  | **Entirely unmeasured**                         | The §11 campaign in full. Until then the deadlines are requirements, not properties                                                             |
| 14  | Does the physical stop path satisfy the league's demonstrate-on-request requirement without a power chain? | **Open**                                        | A handler grabbing a robot is a compliant answer [League]; whether it is an acceptable one for this team is a decision, not a research question |

**The shape of the gap.** [Derived] Six of the fourteen entries are blocked on Model Gate 0 and
cannot be closed by research. Five require bench access. Two are decisions rather than questions.
Only one — item 10 — can be closed by analysis alone. **Nothing in this table can be closed by
further reading of the repository**, and item 13 is the one that matters most: ADR-002 specifies
seven numeric reaction deadlines, and not one of them has ever been measured.
