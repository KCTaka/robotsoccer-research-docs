# Topic 7 Research: Behaviour, Game State, and Team Strategy

- Status: Complete research baseline; update before any Topic 7 architecture revision
- Evidence last verified: 2026-09-01
- Scope: Research input for Topic 7; architecture proposal presented separately
- Canonical decisions: [ADR-001](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md), [ADR-002](../architecture/ADR-002-safety-and-fault-management.md), [ADR-003](../architecture/ADR-003-zenoh-middleware.md)
- Related research: [Topic 3 locomotion](topic-3-locomotion-survey.md), [Topic 4 sensors and estimation](topic-4-sensors-timing-state-estimation.md), [Topic 5 perception](topic-5-perception-pipeline.md), [Topic 6 localization and world model](topic-6-localization-world-model.md)

## Purpose and evidence policy

Topic 7 sits between an ambiguous world model and a set of motion primitives. Topic 6 decision D3
fixed that the pose estimate is a **two-mode set with weights that is never collapsed**, and made
Topic 7 responsible for acting sensibly under that ambiguity. Topic 6 D6 additionally made Topic 7 the
owner of gaze _intent_. This document establishes what the rules permit, what frameworks exist, what
the GameController actually transmits, and what team coordination can cost.

Evidence tags follow the Topic 4-6 convention:

| Tag                 | Meaning                                                                                                   |
| ------------------- | --------------------------------------------------------------------------------------------------------- |
| **[Rules]**         | Quoted verbatim from the RoboCup Humanoid League _Laws of the Game 2025_ (14 April 2025). Binding.        |
| **[Primary]**       | Read directly from a source file, licence file, protocol header, or manifest at a named URL.              |
| **[Peer reviewed]** | Published in a refereed venue. Cited for the method, not for numeric results unless the number is quoted. |
| **[Upstream]**      | Stated by the maintainer in their own documentation.                                                      |
| **[Derived]**       | Computed here from tagged inputs. Derivation and assumptions shown.                                       |
| **[Project]**       | A target or constraint set by this project.                                                               |
| **NR**              | **Not reported.** Never means zero.                                                                       |

**Status of external league repositories.** Per the standing rule established in Topic 5, other teams'
repositories are consulted for rule interpretation, protocol facts, licence facts, and **transferable
technique**. Their architectural choices are not constraints on this design, and the absence of a
precedent is not a risk factor. Where a team's code is quoted below it is because it demonstrates a
mechanism, not because it establishes a norm.

## Confirmed project inputs

| Input               | Value                                                                                             | Source           |
| ------------------- | ------------------------------------------------------------------------------------------------- | ---------------- |
| Size class          | KidSize, **4 v 4**, 9 x 6 m field                                                                 | [Rules]          |
| Pose input          | **Two-mode set with weights. Never collapsed.** Topic 7 must hold a policy for ambiguous heading. | Topic 6 D3       |
| Gaze intent         | **Owned by Topic 7.** Kinematic execution is Topic 3; perception consumes camera pose via TF.     | Topic 6 D6       |
| Gaze policy phasing | Behaviour-driven first; information-theoretic gated behind estimator consistency                  | Topic 6 D6       |
| Frame consumption   | Behaviour consumes `map` (may jump). Control and safety consume `odom` only.                      | Topic 6 D1       |
| Ball state          | From a dynamics-constrained filter with a measured turf deceleration model                        | Topic 6 D5       |
| Teammate sharing    | Enhancement, never a dependency                                                                   | Topic 6 D7       |
| Control loop        | 200 Hz, 5 ms hard deadline. Behaviour is **not** in it.                                           | ADR-001, ADR-002 |
| Middleware          | `rmw_zenoh_cpp`, all QoS explicitly declared, no `SYSTEM_DEFAULT`                                 | ADR-003          |
| Licensing           | AGPL and GPL excluded                                                                             | Topic 5 §4.1.1   |

---

## 1. The rule envelope for behaviour

### 1.1 Autonomy and the anti-coaching law

The strongest constraint on Topic 7 is not a performance budget. It is a rule about what information
may reach the robot.

> "Robots participating in the Humanoid League competitions must act autonomously while a competition
> is running. No external power supply, teleoperation, remote control, or remote brain of any kind is
> allowed." [Rules]

> "Teams may not use any type of communication with robots in play, in service or with robots serving
> their 10 seconds penalty time that contains information which **reduces the need for autonomy in
> detecting the current game state of the robots, including the position of the ball, the location
> where the robot re-enters the field, the orientation of the robots own or opponents goal, and the
> position of team members or opponents.** In a physical game, verbal communication is excluded from
> this rule. In case of doubt that a team violates this rule, the code must be made available to
> members of the Technical Committee for inspection." [Rules]

> "Any time the robot handler or another team member is touching the robot, a cable is connected or
> another form of communication with the robot (**including button clicks**) take place, the robot is
> considered in service." [Rules]

**This is the decisive rule for Topic 6 D3.** The two-fold field symmetry established in Topic 6 §1.2
means the robot may not know which way its own goal is. The rulebook names _"the orientation of the
robots own or opponents goal"_ and _"the location where the robot re-enters the field"_ as information
a **human may not supply**, and closes the obvious loophole by counting a button click as
communication.

So the ambiguity cannot be resolved by a handler. It must be resolved by the robot, or tolerated by
the behaviour. There is no third option.

Two exclusions matter and are easy to misread:

| Permitted                                                                             | Rule text                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Robot-to-robot** sharing of ball position, teammate positions, and goal orientation | "Robots in play may communicate with each other at any time during a game." [Rules]                                                                                                                                                                                                                                                                          |
| **The official GameController**                                                       | "During the game an official game controller/referee box will be used. It uses UDP to broadcast information to the robots like elapsed time, current score, game state (ready, set, playing, finished) and the robot-specific penalized state. The source code is open. Teams have to be able to use the referee box in order to respect the rules." [Rules] |

The anti-coaching law restricts **humans**, not teammates and not the referee box. A teammate telling
this robot where the ball is, is legal. A handler doing so, is not.

### 1.2 Network law

| Clause                | Text                                                                                                                                                                                                                                                                                        | Consequence                                                                               |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Bandwidth             | "The total bandwidth of each robot belonging to one team may not exceed 1 Mbit/s."                                                                                                                                                                                                          | The budget in §5.3.                                                                       |
| Reliability           | "the robots must not rely on the quality of the wireless network. They must be able to play if the network is of low quality."                                                                                                                                                              | Team coordination is degradable by rule. §5.4.                                            |
| Direction             | "Any kind of transmission from an external computer to the playing robots is prohibited... any monitoring is only done by receiving UDP communication from the robots using an external computer connected by tethered LAN to the official wireless router."                                | Telemetry is **egress only** during play. No debug command channel exists at competition. |
| Medium                | "only robots are allowed to communicate by WLAN. Any other computers of team members are only allowed to communicate by tethered LAN. No other wireless communication is allowed onsite."                                                                                                   | ADR-003's operator-station TLS link must be tethered at competition.                      |
| Recommended protocols | "Teams are **strongly encouraged** to implement the mitecom team communication protocol which is available at `https://github.com/RoboCup-Humanoid-TC/mitecom` or the Protobuf-based communication protocol which can be found at `https://github.com/RoboCup-Humanoid-TC/RobocupProtocol`" | §5.1. Both were read directly.                                                            |

### 1.3 Sound is the only permitted active channel

Topic 5 established that "the only active external sensor allowed is sound". For Topic 7 this matters
because the referee's **whistle** starts play in some situations, and a robot that reacts to the
whistle acts before the GameController state change propagates. This is a latency advantage, not a
requirement. Whistle detection is a perception capability with a behaviour consumer; no rule compels
it.

---

## 2. Behaviour frameworks

### 2.1 Availability and licensing, verified

Read from `ros/rosdistro` `jazzy/distribution.yaml` and from the projects' own licence files
[Primary]:

| Package                                         | Jazzy version            | Licence          | Verified from                                                      |
| ----------------------------------------------- | ------------------------ | ---------------- | ------------------------------------------------------------------ |
| `behaviortree_cpp` (repo `behaviortree_cpp_v4`) | **4.10.0-1**             | **MIT**          | `BehaviorTree/BehaviorTree.CPP/master/LICENSE`                     |
| `behaviortree_cpp_v3`                           | 3.8.8-1                  | MIT              | same project, v3 line                                              |
| `py_trees`                                      | **2.5.0-1**              | **BSD**          | `splintered-reality/py_trees/devel/LICENSE`                        |
| `py_trees_ros`                                  | 2.5.0-1                  | BSD              | same project                                                       |
| `py_trees_ros_viewer`, `py_trees_js`            | 0.3.0-1, 0.6.7-1         | BSD              | same project                                                       |
| `yasmin`                                        | **6.1.1-1**              | **Apache-2.0**   | `uleroboticsgroup/yasmin/main/LICENSE`                             |
| `flexbe_behavior_engine`                        | **3.0.7-1**              | **BSD-3-Clause** | `flexbe/flexbe_behavior_engine/ros2-devel/LICENSE`                 |
| `smach`                                         | 3.0.3-3                  | —                | ROS 1 lineage, ROS 2 port                                          |
| `nav2_behavior_tree`                            | in `navigation2` (jazzy) | —                | Topic 6 §5.1                                                       |
| `dynamic_stack_decider` (Bit-Bots)              | **not released**         | **MIT**          | `bit-bots/bitbots_main/main/src/lib/dynamic_stack_decider/LICENSE` |
| `CABSL` (B-Human)                               | **not released**         | custom, non-SPDX | `bhuman/CABSL`                                                     |

**Every released candidate is permissively licensed.** Topic 5 §4.1.1 imposes no constraint on this
topic. That is a clean result and removes licensing from the selection criteria entirely.

### 2.2 Execution models compared

The frameworks differ less in features than in **what happens between ticks**. That difference
determines oscillation behaviour, which is the dominant practical failure mode in soccer behaviour.

| Model                          | Representative                                                                                                                                                                                                                                                                                              | What executes per tick                                                                  | Memory between ticks                                                                | Oscillation risk                                                                                                           |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Behaviour tree**             | `BehaviorTree.CPP` 4.10.0, `py_trees` 2.5.0, `nav2_behavior_tree`                                                                                                                                                                                                                                           | Traversal from the root; every guard condition above the running node is re-evaluated   | Only where a node is explicitly stateful, or a reactive-sequence memory flag is set | **High by default.** Two nearly-equal conditions flip the selected branch every tick unless hysteresis is added explicitly |
| **Hierarchical state machine** | `yasmin` 6.1.1, `flexbe` 3.0.7, `smach`                                                                                                                                                                                                                                                                     | Only the active state; transitions are explicit and enumerated                          | Full — the current state is the memory                                              | **Low**, but transition count grows combinatorially and unhandled combinations become dead ends                            |
| **Option-based HSM**           | CABSL: "hierarchical state machines, the so-called _options_... In each execution cycle, a subset of all options is executed, i.e. the options that are reachable from the root option through the actions of their current states. This current set of options is called the _activation graph_" [Primary] | The activation graph only                                                               | Per-option current state                                                            | Low, with a re-derived active set each cycle                                                                               |
| **Decision stack**             | Bit-Bots `dynamic_stack_decider`: "It combines the advantages of behavior trees, decision trees and state machines... The underlying model for the DSD is a stack... This action stays on top of the stack until it calls `self.pop()` or one of the decisions on the stack is reevaluated" [Primary]       | Top of stack, plus **only those decisions that opted into reevaluation**, bottom-to-top | The stack itself is the memory                                                      | **Low and tunable.** Preemption is opt-in per decision rather than global                                                  |
| **Utility / expected value**   | No released ROS 2 package found                                                                                                                                                                                                                                                                             | Score every candidate action, take the argmax                                           | None inherent                                                                       | High without an explicit switching cost, because the argmax is not sticky                                                  |

**The structural finding.** A behaviour tree is _reactive by default and sticky only by exception_; a
state machine is _sticky by default and reactive only by exception_; the DSD stack model makes
stickiness the default and reactivity a per-decision opt-in. For soccer, where the world model is
noisy and — per Topic 6 D3 — sometimes genuinely ambiguous, default stickiness with explicit
preemption points is the property that matters. A robot that alternates between "go to ball" and
"return to role position" at tick rate does neither.

This is visible in production code. The Bit-Bots behaviour specification uses explicit latching and
run-once guards throughout, for example [Primary, `main.dsd`]:

```text
$ReachedAndAlignedToPathPlanningGoalPosition + threshold:0.2 + latch:true
```

`latch:true` and the `$DoOnce` decider exist precisely to suppress re-entry oscillation. In a
behaviour tree the same suppression must be built for every comparable guard.

### 2.3 Transferable technique from league implementations

The following are quoted as **mechanisms**, not as precedents.

**Distributed role arbitration by time-to-ball, not distance.** The rule-recommended `mitecom`
protocol defines, among its key-value fields [Primary, `mitecom-data.h`]:

```text
ROBOT_CURRENT_ROLE, ROBOT_CURRENT_ACTION, ROBOT_CURRENT_STATE
ROBOT_ABSOLUTE_X, ROBOT_ABSOLUTE_Y, ROBOT_ABSOLUTE_ORIENTATION, ROBOT_ABSOLUTE_BELIEF
TEAM_ROBOT_A_X, TEAM_ROBOT_A_Y, TEAM_ROBOT_A_BELIEF          (and B, C)
ROBOT_AVG_WALKING_SPEED_IN_CM_PER_SECOND
ROBOT_TIME_TO_POSITION_AT_BALL_IN_SECONDS
ROBOT_MAX_KICKING_DISTANCE
```

with a single arbitration entry point `MixedTeamRoleEnum decideRole(const MixedTeamMates &teamMates,
const int myID)` [Primary, `mitecom-roledecider.h`].

Three properties are worth extracting:

1. **`ROBOT_TIME_TO_POSITION_AT_BALL_IN_SECONDS`, not distance.** Time-to-ball incorporates
   orientation, obstacles, walking speed, and fallen state. Two robots equidistant from the ball are
   not equally able to reach it.
2. **`ROBOT_ABSOLUTE_BELIEF` is a first-class field.** The protocol already assumes a robot may be
   unsure of its own pose and that teammates need to know. This is the closest existing analogue to
   what Topic 6 D3 requires — though see §5.2 for why it is not sufficient.
3. **Capability advertisement** (`AVG_WALKING_SPEED`, `MAX_KICKING_DISTANCE`) exists because KidSize
   runs **Drop-In games** with mixed teams [Rules]. Role arbitration cannot assume homogeneous
   teammates.

**Explicit liveness-conditional role collapse.** Bit-Bots' goalkeeper branch [Primary, `main.dsd`]:

```text
#GoalieBehavior
$CountActiveRobotsWithoutGoalie
    ZERO --> #KickWithAvoidance
    ELSE --> $ClosestToBall
        NO --> @GoToBlockPosition
        YES --> $BallInGoalieZone
            YES --> #KickWithAvoidance
            NO  --> @GoToBlockPosition
```

The goalkeeper abandons its post when no field player is alive. Teammate dropout is handled as an
ordinary decision input, not as an exception path.

**Localization state is itself governed by behaviour.** Bit-Bots run a separate decision tree purely
for localization lifecycle [Primary, `localization.dsd`]:

```text
$GettingUpState
    YES   --> @LocalizationStop
    GOTUP --> @LocalizationStart
    NO    --> $CheckGameStateReceived
        NO_GAMESTATE_INIT --> @InitSide
        GAMESTATE_RECEIVED --> $CheckPenalized
            YES              --> @LocalizationStop
            JUST_UNPENALIZED --> @InitSide, @LocalizationStart
```

This independently corroborates two Topic 6 findings: that a fall breaks pose continuity and requires
an explicit stop and restart, and that **unpenalisation requires re-seeding the field side**. It also
shows a team treating "which side am I on" as a discrete, repeatedly re-asserted decision rather than
as a filter output — which is what D3 formalises.

**Gaze is commanded from the behaviour layer.** `@LookAtFieldFeatures`, `@LookAtBallPenalty`,
`@LookForward`, `@LookAtFront`, and `@TrackBall` appear as ordinary actions alongside locomotion
actions throughout `main.dsd` [Primary]. This corroborates the Topic 6 D6 ownership split
independently of our reasoning for it.

### 2.4 Real-time properties

Behaviour is **not** in the 200 Hz path (ADR-001). The relevant timing questions are different:

| Question                                     | Answer                                                                                                                                                                                                                                       |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Does the decision loop have a hard deadline? | No. It has a **staleness** requirement: a decision made on a world model older than the ball's traversal time is wrong regardless of how fast it was computed.                                                                               |
| What rate is needed?                         | **NR.** Derivable only once ball speed and neck slew are measured (Topic 6 gate 3, Topic 3 Model Gate 0). Topic 6 §3.3 shows the ball filter runs at the perception cadence of 30-60 Hz; a decision rate far above that adds no information. |
| Is a Python framework admissible?            | Yes, structurally — `py_trees` and the DSD are Python and run outside the control loop. The risk is **jitter and GC pauses**, not throughput. This must be measured (gate 4), not assumed either way.                                        |
| What must never happen                       | A behaviour node must not block on a service call, hold a lock shared with the control path, or allocate unboundedly. ADR-003 already forbids services and actions from carrying cyclic or first-response safety traffic.                    |

---

## 3. Decision making under ambiguity

This section is the direct consequence of Topic 6 D3.

### 3.1 The problem, stated precisely

Topic 6 §1.2 proved the field-feature likelihood satisfies $p(z \mid x) = p(z \mid \mathcal{R}_\pi x)$.
The behaviour layer therefore receives, in the worst case, a posterior

$$p(x) = w_A\,\mathcal{N}(x; \mu_A, \Sigma_A) + w_B\,\mathcal{N}(x; \mathcal{R}_\pi \mu_A, \Sigma_B), \qquad w_A + w_B = 1$$

with $w_A \approx w_B \approx 0.5$ after a fall or an unpenalisation, per §2.3's corroborating
evidence that both events break continuity.

The naive response — act on $\arg\max_i w_i$ — is wrong for a reason that has nothing to do with
probability: **the outcomes are not symmetric.** Scoring in the correct goal gains one goal. Scoring
in the wrong goal gains the opponent one goal, a swing of two. Under a 50/50 belief, shooting has
negative expected value even before accounting for the possibility that the ball simply misses.

### 3.2 Expected value over the mode set

The correct formulation is standard decision theory: choose the action maximising expected utility
over the **full** posterior rather than over its mode.

$$a^* = \arg\max_{a \in \mathcal{A}} \sum_{i \in \{A,B\}} w_i \, U(a \mid x_i)$$

[Peer reviewed — the expected-utility formulation is standard; see von Neumann and Morgenstern,
*Theory of Games and Economic Behavior*, Princeton, 1944, and its treatment for sequential robot
decision-making in Thrun, Burgard, Fox, *Probabilistic Robotics*, MIT Press, 2005, Ch. 15-16.]

Worked example with the two-mode posterior. Let $w$ be the weight on the mode in which the robot is
facing the opponent goal, and assign a goal scored $+1$ and a goal conceded $-1$:

| $w$  | $\mathbb{E}[U(\text{shoot})] = w(+1) + (1-w)(-1)$ | Verdict                                                                                                                 |
| ---- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 0.50 | **0.00**                                          | No better than doing nothing, and strictly worse once the shot's own failure probability and the time cost are included |
| 0.75 | +0.50                                             | Positive, but half the value of a certain shot                                                                          |
| 0.90 | +0.80                                             | Acceptable                                                                                                              |
| 0.99 | +0.98                                             | Effectively certain                                                                                                     |

[Derived]

The important consequence is not the numbers but the shape: **expected value falls to zero at $w = 0.5$
and goes negative below it.** There is a weight threshold below which shooting is irrational, and it is
strictly above 0.5. Actions must therefore be classified by their **symmetry sensitivity**:

| Action class                       | Depends on knowing which goal is which?                   | Admissible at $w \approx 0.5$?                   |
| ---------------------------------- | --------------------------------------------------------- | ------------------------------------------------ |
| Stand, stay upright, avoid falling | No                                                        | Yes                                              |
| Track the ball, keep it in view    | No                                                        | Yes                                              |
| Walk to the ball                   | No — the ball's relative position is directly observed    | Yes                                              |
| Dribble in any direction           | Direction yes, possession no                              | Partially — possession is safe, direction is not |
| Position at a role location        | **Yes** — role positions are defined relative to own goal | No                                               |
| Kick or shoot                      | **Yes**                                                   | **No**                                           |
| Goalkeeper block positioning       | **Yes**                                                   | **No**                                           |

**This table is the core Topic 7 output for D3.** It says the robot is not paralysed by ambiguity: it
can keep playing, keep the ball, and stay safe. What it must not do is commit to any action whose sign
depends on the field direction.

### 3.3 Information-gathering as an action

The third option, beyond act-and-hope and freeze, is to **spend time reducing $|w_A - w_B|$**. This
makes gaze an action in the same decision space as locomotion, which is exactly why Topic 6 D6 placed
gaze intent in this topic.

Topic 6 §1.3 established that every rule-guaranteed symmetry-breaking source is either a prior or
inter-robot. Turning to look at a goal does **not** help — both goals are white. The admissible
information-gathering actions are therefore narrower than intuition suggests:

| Candidate action                            | Effective?                          | Why                                                                                                                                                                                                                                                                              |
| ------------------------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Look at the nearest goal                    | **No**                              | Both goals are white and identical (Topic 6 §1.2). Zero information.                                                                                                                                                                                                             |
| Look at field lines or the centre circle    | **No**                              | Symmetric under $\mathcal{R}_\pi$. Refines position within a mode; does not reweight modes.                                                                                                                                                                                      |
| **Look for a teammate and read its number** | **Yes**                             | Teammate identity is rule-guaranteed: "The robots of each team must be uniquely identifiable. They must be marked with numbers or names." [Rules] A recognised teammate at a known self-reported pose is a genuine absolute measurement. Range limit is **NR** — Topic 6 gate 5. |
| **Look for a team-marker colour**           | **Partial**                         | Red/blue markers distinguish own team from opponent and give a coarse facing, but colour assignment is per game: "The color teams play in is randomly assigned and announced in the game plan" [Rules]. Useful once the assignment is loaded.                                    |
| **Look for the own goalkeeper**             | **Yes, if the keeper is localized** | "The goal keeper robot must be marked uniquely" [Rules]. A stationary uniquely-marked robot at one end is the closest thing the field has to a landmark.                                                                                                                         |
| **Query teammates over the network**        | **Yes, but not always available**   | Legal (§1.1) and cheap (§5.3), but by rule cannot be depended upon.                                                                                                                                                                                                              |
| Walk and integrate odometry                 | No                                  | Propagates both modes equally.                                                                                                                                                                                                                                                   |

**The finding.** Information-gathering for symmetry resolution is **entirely inter-robot**. There is no
solo visual action that breaks the tie. A robot alone on the field with a 50/50 posterior and no
GameController prior has no admissible action that resolves it. That is a property of the rulebook,
not a deficiency of the design, and the behaviour layer must be built to keep playing safely in that
state rather than to escape it.

### 3.4 The switching cost

Information-gathering is not free: looking away from the ball degrades the ball velocity estimate
immediately (Topic 6 §3.3), and turning the body costs time in a match with a running clock. The
decision is therefore sequential, not a per-tick argmax:

$$a^* = \arg\max_a \left[ \sum_i w_i\,U(a \mid x_i) - C_{\text{switch}}(a_{t-1} \rightarrow a) \right]$$

$C_{\text{switch}}$ is **NR** in every term until Topic 3 Model Gate 0 and Topic 6 gate 3 close. This
is the same conclusion Topic 6 §4.2 reached for gaze, and it has the same practical consequence: the
first implementation uses explicit hysteresis with hand-set thresholds, and a principled cost model
waits for measurements.

---

## 4. GameController integration

### 4.1 The protocol, verified from source

Read directly from `RoboCup-HumanoidSoccerLeague/GameController`, file
`game_controller_msgs/headers/RoboCupGameControlData.h`, branch `master`. Repository licence: **MIT**,
Copyright (c) 2023 Arne Hasselbring. [Primary]

| Constant                               | Value    |
| -------------------------------------- | -------- |
| `GAMECONTROLLER_DATA_PORT`             | **3838** |
| `GAMECONTROLLER_RETURN_PORT`           | **3939** |
| `GAMECONTROLLER_STRUCT_HEADER`         | `"RGme"` |
| `GAMECONTROLLER_STRUCT_VERSION`        | **20**   |
| `GAMECONTROLLER_RETURN_STRUCT_HEADER`  | `"RGrt"` |
| `GAMECONTROLLER_RETURN_STRUCT_VERSION` | **4**    |
| `MAX_NUM_PLAYERS`                      | 20       |

**Game state** is not one enum but four orthogonal fields:

| Field       | Values                                                                                                                 |
| ----------- | ---------------------------------------------------------------------------------------------------------------------- |
| `state`     | `INITIAL` 0, `READY` 1, `SET` 2, `PLAYING` 3, `FINISHED` 4                                                             |
| `stopped`   | `1 = play is currently stopped, 0 otherwise` — **independent of `state`**                                              |
| `gamePhase` | `NORMAL` 0, `PENALTY_SHOOT_OUT` 1, `EXTRA_TIME` 2, `TIMEOUT` 3                                                         |
| `setPlay`   | `NONE` 0, `DIRECT_FREE_KICK` 1, `INDIRECT_FREE_KICK` 2, `PENALTY_KICK` 3, `THROW_IN` 4, `GOAL_KICK` 5, `CORNER_KICK` 6 |

**A naive five-state machine over `state` is wrong.** The behaviour-relevant condition is the tuple
$(\texttt{state}, \texttt{stopped}, \texttt{gamePhase}, \texttt{setPlay}, \texttt{kickingTeam})$. In
particular `stopped` is a separate boolean, and `setPlay` with `kickingTeam` determines whether this
robot must retreat from the ball — the highest-frequency source of avoidable penalties.

**Penalties** carried per player in `RobotInfo { penalty, secsTillUnpenalised, cautions }`:

`NONE` 0, `ILLEGAL_POSITIONING` 1, `MOTION_IN_SET` 2, `MOTION_IN_STOP` 3, `LOCAL_GAME_STUCK` 4,
`INCAPABLE_ROBOT` 5, `PICK_UP` 6, `BALL_HOLDING` 7, `LEAVING_THE_FIELD` 8,
`PLAYING_WITH_ARMS_HANDS` 9, `PUSHING` 10, `CAUTIONED` 11, `SENT_OFF` 12, `SUBSTITUTE` 13.

`MOTION_IN_SET` and `MOTION_IN_STOP` are directly caused by behaviour failing to stop. `secsTillUnpenalised`
is available, so a robot can prepare to resume rather than react on transition.

Also carried: `kickingTeam` (team number or `KICKING_TEAM_NONE` 255), `secsRemaining`, `secondaryTime`
("remaining ready, until free ball"), `score`, `teamNumber`, `fieldPlayerColour`, `goalkeeperColour`,
`goalkeeper` (player number), and `messageBudget` (see §5.5).

### 4.2 Transmission cadence, verified from source

From `game_controller_net/src/control_message_sender.rs` [Primary]:

```rust
const SEND_INTERVAL: Duration = Duration::from_millis(500);
const SEND_INTERVAL_FAST: Duration = Duration::from_millis(200);
/// The number of messages that are sent at the fast interval before switching back to normal.
```

| Property                     | Value                                                       |
| ---------------------------- | ----------------------------------------------------------- |
| Nominal broadcast period     | **500 ms (2 Hz)**                                           |
| Post-transition burst period | **200 ms (5 Hz)**, for a bounded count (count value **NR**) |
| Transport                    | UDP broadcast (`socket.set_broadcast(true)`)                |

**Consequences, derived:**

1. **One lost packet leaves game state up to 1.0 s stale**; two consecutive losses, 1.5 s. At 2 Hz there
   is no redundancy in steady state.
2. **The protocol already mitigates the worst case.** State changes — the moments where staleness is
   most costly — are sent as a fast burst. Losing an entire transition therefore requires losing
   several consecutive packets, not one.
3. **A staleness timeout must not be set near 500 ms.** A threshold below roughly 1.5 s will declare
   the GameController lost during ordinary single-packet loss. This is a concrete design number that
   falls straight out of the source.
4. Broadcast UDP means **no delivery feedback**. The robot cannot know whether it is being addressed;
   it can only observe whether packets arrive.

### 4.3 The return struct demands a unimodal pose — a direct conflict with D3

The return message the robot sends to the GameController is fully specified [Primary]:

```c
struct RoboCupGameControlReturnData {
  char header[4];     // "RGrt"
  uint8_t version;    // 4
  uint8_t playerNum;  // starts with 1
  uint8_t teamNum;
  uint8_t fallen;     // 1 = fallen, 0 = can play
  float pose[3];      // x, y, theta -- mm and radians, 0,0 at field centre
                      // +ve x-axis points towards the goal we are attempting to score on
  float ballAge;      // seconds since last seen; -1.f if never
  float ball[2];      // mm, relative to robot
};
```

Note the comment: **"+ve x-axis points towards the goal we are attempting to score on."** The struct
requires the robot to assert a field direction, has **no covariance field, no confidence field, and no
representation for a second hypothesis.**

**This is not a reason to abandon D3.** The return channel is monitoring and refereeing telemetry — the
rules describe monitoring as "only done by receiving UDP communication from the robots" [Rules]. It does
not feed gameplay. The resolution is a clean separation:

| Consumer                                                | Representation                                                                                               |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Internal behaviour, gaze, world model, teammate sharing | **Full two-mode set with weights.** Never collapsed. (D3)                                                    |
| GameController return packet only                       | **Projected to the maximum-weight mode** at serialisation time, because the wire format admits nothing else. |

The projection is a **serialisation artefact confined to one 32-byte egress message**, and must be
implemented at the encoder, not by collapsing the estimator. Documenting it explicitly prevents the
much worse outcome of someone "simplifying" the estimator to match the wire format.

### 4.4 The released Jazzy package does not fit — verified

`game_controller_spl` 4.1.0-1 is released into Jazzy [Primary]. Its own README states: "ROS2 Package to
interface RoboCup **Standard Platform League's** Game Controller." [Primary]

Its released package set is `rcgcd_spl_14`, `rcgcd_spl_14_conversion`, `rcgcrd_spl_4`,
`rcgcrd_spl_4_conversion`, `gc_spl`, `gc_spl_2022`, and the source tree contains `rcgcd_14`,
`rcgcd_15`, `rcgcd_16` with corresponding `RCGCD14.msg`, `RCGCD15.msg`, `RCGCD16.msg`, and
`RCGCRD4.msg`. [Primary]

| Direction                 | HL version | Package support            | Verdict                                                                                                                                                                            |
| ------------------------- | ---------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Control data, GC to robot | **20**     | 14, 15, 16                 | **Not supported.** The HL struct also carries `THROW_IN`, `GOAL_KICK`, `CORNER_KICK` set plays and `competitionType` `SMALL`/`MIDDLE`/`LARGE`, which are Humanoid League concepts. |
| Return data, robot to GC  | **4**      | `rcgcrd_4` / `RCGCRD4.msg` | **Version matches.** Field-by-field byte compatibility is plausible but unverified — gate 6.                                                                                       |

So: a project-local receiver for struct version 20 is required. The released package remains useful as
a **structural template** (UDP socket to typed ROS message, with conversion isolated per version), and
its per-version directory layout is worth copying because the HL struct version will change between
competition years.

### 4.5 Loss, staleness, and rule-state safety

| Situation                                 | Required behaviour                                                                                                                                                                                                                                                                                                                 |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No packet yet at startup                  | Do **not** assume `INITIAL`. Bit-Bots handle this as an explicit `NO_GAMESTATE_INIT` branch [Primary]. A distinct "no game state" condition is needed because the safe action differs from any real state.                                                                                                                         |
| Single packet lost                        | Hold the last state. Age it. Do not act on the gap (§4.2 item 3).                                                                                                                                                                                                                                                                  |
| Prolonged loss                            | Fail **safe by rule, not by convenience**. The penalties `MOTION_IN_SET` and `MOTION_IN_STOP` mean that when in doubt about whether play is stopped, **standing still is the rule-safe default**, and it is also the ADR-002-safe default. These align, which is fortunate and should be stated so nobody later optimises it away. |
| State regresses or jumps implausibly      | Accept it. The referee can undo actions — the GameController source contains an explicit `undo.rs` action [Primary]. Behaviour must not assume monotonic game state.                                                                                                                                                               |
| Own robot shows `PICK_UP` or `SUBSTITUTE` | Couples to ADR-002 and Topic 6: continuity is broken, the pose prior is invalid, and the field side must be re-seeded on unpenalisation.                                                                                                                                                                                           |

---

## 5. Team coordination

### 5.1 The two rule-named protocols, read directly

**`RoboCup-Humanoid-TC/RobocupProtocol`, `robocup_extension.proto`, proto3** [Primary]:

| Field               | Type                                                                    | Note                                                          |
| ------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------- |
| `timestamp`         | `google.protobuf.Timestamp`                                             |                                                               |
| `state`             | `UNKNOWN_STATE`, `UNPENALISED`, `PENALISED`                             |                                                               |
| `current_pose`      | `Robot` = `player_id`, `fvec3 position`, **`fmat3 covariance`**, `Team` | "x meters along the field... positive towards opponent goals" |
| `walk_command`      | `fvec3`                                                                 | local x, y m/s and theta rad/s                                |
| `target_pose`       | `Robot`                                                                 | where this robot intends to be                                |
| `kick_target`       | `fvec2`                                                                 | "If no kick is planned set to [0, 0]"                         |
| `ball`              | `Ball` = `fvec3 position`, `fvec3 velocity`, **`fmat3 covariance`**     |                                                               |
| `others`            | `repeated Robot`                                                        | detected robots, with team                                    |
| `max_walking_speed` | `float`, field 101                                                      | "IDs 1-100 are reserved for official use"                     |

**`RoboCup-Humanoid-TC/mitecom`** [Primary]: a flat key-value encoding, with the fields listed in
§2.3, plus `MixedTeamRoleEnum`, `MixedTeamActionEnum`, `MixedTeamStateEnum`, `MixedTeamSideEnum`, and
the `decideRole()` arbitration entry point.

**Critical shared limitation.** Both protocols express pose uncertainty as at most a **single
covariance** (protobuf `fmat3`) or a **single scalar belief** (`ROBOT_ABSOLUTE_BELIEF`). Neither can
represent a two-mode posterior. **Neither rule-named protocol can express what Topic 6 D3 produces** —
the same structural conflict as the GameController return struct in §4.3, arriving from a different
direction.

The protobuf protocol provides the escape hatch: field IDs above 100 are explicitly available for
extensions. A mode-set extension is legal, standards-compatible, and interoperable — a receiver that
does not understand it still gets the projected `current_pose`. That is the correct place to put it.

### 5.2 Central coordinator versus distributed — both exist

`Rhoban/hl_communication` demonstrates a **central captain** on top of the same family of messages
[Primary, `proto/captain.proto`]:

```protobuf
message CommonBall    { required uint32 nb_votes = 1; required Position2d position = 2; }
message CommonOpponent{ required uint32 nb_votes = 1; required Pose2d pose = 2; }
enum Role { OFFENDER = 0; DEFENDER = 1; GOALIE = 2; }
message StrategyOrder { required uint32 robot_id = 1; optional Pose2d target = 2;
                        optional Action action = 3; optional BallTarget ball_target = 4;
                        optional Role role = 5; }
message Captain { repeated StrategyOrder orders = 1; optional CommonBall ball = 2;
                  repeated CommonOpponent opponents = 3; }
```

and `proto/team_play.proto` carries a health status enum that maps almost exactly onto ADR-002 states
[Primary]:

```protobuf
enum Status { UNSPECIFIED_STATUS = 0; OKAY = 1; FALLING = 2; FALLEN = 3;
              STANDING_UP = 4; FREEZE = 5; HANDLED = 6; HARDWARE_FAILURE = 7; }
```

with `FREEZE` documented as "Robot is freezing all motion in order to fulfill the rules" and `HANDLED`
as "Robot is handled (carried by the handler)".

| Architecture                   | Mechanism                                                                                                                                   | Strength                                                                                                                                             | Weakness under the HL rules                                                                                                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Central captain**            | One robot aggregates, votes on ball and opponent positions, and issues `StrategyOrder` per robot                                            | Globally consistent assignment; explicit vote counts give a natural confidence measure; opponent fusion is genuinely better with multiple viewpoints | **Directly contradicts "must not rely on the quality of the wireless network"** unless every robot can also run standalone. Captain election and captain loss are additional failure modes. |
| **Distributed, deterministic** | Every robot broadcasts state; every robot runs the same pure arbitration function over the same inputs, as in `decideRole(teamMates, myID)` | No single point of failure; degrades to solo play automatically; trivially testable as a pure function                                               | Transient disagreement while messages are in flight; requires tie-breaking by a total order such as player number                                                                           |

**The rule settles this.** "the robots must not rely on the quality of the wireless network. They must
be able to play if the network is of low quality" [Rules] means a robot with zero teammate messages
must still play. A distributed deterministic arbitration **degenerates correctly** to that case: with
an empty teammate set, `decideRole` returns a solo role. A captain architecture must implement the
standalone path anyway, and then also implement election. The captain's genuine advantage —
multi-viewpoint opponent fusion — is a **world-model enhancement**, and can be obtained by sharing
observations without also centralising the role decision.

### 5.3 Bandwidth, derived

**GameController ingress.** `RoboCupGameControlData` with standard C alignment:

| Part                                                                                           | Bytes        |
| ---------------------------------------------------------------------------------------------- | ------------ |
| `header[4]` + 10 `uint8_t` fields                                                              | 14           |
| padding to 2-byte alignment                                                                    | 2            |
| `secsRemaining`, `secondaryTime` (`int16_t`)                                                   | 4            |
| `TeamInfo` x2: 6 x `uint8_t` + `singleShots` + `messageBudget` + `RobotInfo players[20]` x 3 B | 2 x 70 = 140 |
| **Total**                                                                                      | **160 B**    |

At 2 Hz: 320 B/s = **2.6 kbit/s**, i.e. **0.26 %** of the 1 Mbit/s budget. Negligible. [Derived]

**GameController egress.** `RoboCupGameControlReturnData` = 4 + 4 x `uint8_t` + 3 x `float` +
`float` + 2 x `float` = **32 B**. Rate is a team choice; at 2 Hz it is 0.05 % of budget. [Derived]

**Team messages.** Estimating the `robocup_extension.proto` `Message` on the wire, with protobuf
varint keys and 4-byte floats:

| Component                                        | Approx. bytes     |
| ------------------------------------------------ | ----------------- |
| `timestamp`                                      | 12                |
| `state`                                          | 2                 |
| `current_pose` (`Robot` with `fmat3` covariance) | 76                |
| `walk_command` (`fvec3`)                         | 17                |
| `target_pose` (`Robot`)                          | 76                |
| `kick_target` (`fvec2`)                          | 12                |
| `ball` (2 x `fvec3` + `fmat3`)                   | 89                |
| `others` (3 x `Robot`)                           | 228               |
| `max_walking_speed`                              | 5                 |
| **Payload**                                      | **approx. 520 B** |
| + UDP/IP headers                                 | 28                |
| **On the wire**                                  | **approx. 550 B** |

| Rate      | Throughput    | Share of 1 Mbit/s |
| --------- | ------------- | ----------------- |
| 5 Hz      | 22 kbit/s     | 2.2 %             |
| **10 Hz** | **44 kbit/s** | **4.4 %**         |
| 20 Hz     | 88 kbit/s     | 8.8 %             |

[Derived]

**Total coordination traffic at 10 Hz is under 5 % of the per-robot budget.** This is consistent with,
and supersedes in detail, the Topic 6 §3.5 estimate of 12 kbit/s for a minimal message — the full
rule-recommended message with covariances and three observed robots is roughly four times larger and
still cheap. **Bandwidth is not the binding constraint on team coordination.** The binding constraints
are the network-independence rule and the protocols' inability to express a bimodal pose.

### 5.4 Dropout and role stability

| Event                                | Handling                                                                                                                                                                                                                                                     |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Teammate silent                      | Age its state; drop it from the arbitration set past a timeout. `CountActiveRobotsWithoutGoalie`-style liveness counting makes this an ordinary decision input rather than an exception (§2.3).                                                              |
| Teammate penalised                   | Known from **two** independent channels: the GameController `RobotInfo.penalty` array and the teammate's own `state` field. The GameController is authoritative and does not depend on the team network.                                                     |
| All teammates lost                   | Every role collapses to solo play. The deterministic arbitration must produce a sensible solo role with an empty input set.                                                                                                                                  |
| Role thrashing                       | Two robots with near-equal time-to-ball can swap roles repeatedly. Requires hysteresis plus a total order tie-break by player number. This is the same oscillation problem as §2.2, at team scale.                                                           |
| Own pose ambiguous ($w \approx 0.5$) | This robot's contribution to arbitration is unreliable, because time-to-ball is computed in the field frame. It should **advertise low confidence and decline symmetry-sensitive roles** rather than compete for them. Requires the §5.1 protocol extension. |

The last row is the team-level consequence of D3 and does not appear in any protocol read for this
document.

### 5.5 The `messageBudget` field

`TeamInfo` contains `uint16_t messageBudget; // number of team messages the team is allowed to send for
the remainder of the game` [Primary].

The 2025 Humanoid League rules were searched for a corresponding limit: `message budget` **0 hits**,
`number of messages` **0 hits**. The rules instead state "Robots in play may communicate with each
other at any time during a game" [Rules].

**Assessment.** The field is present in the struct — which the HL GameController shares its lineage
with the SPL controller — but **no Humanoid League rule imposes a message budget**. The honest position
is that the field exists and its Humanoid League semantics are **NR**. A receiver must parse it, and
behaviour should not depend on it, but a team-message rate should be chosen conservatively enough that
a future budget would not break the design. Gate 8.

---

## 6. Compute and timing

| Stage                                         | Placement                  | Cost                                                                     |
| --------------------------------------------- | -------------------------- | ------------------------------------------------------------------------ |
| GameController receive and decode             | Non-RT, 2-5 Hz             | Trivial — 160 B UDP                                                      |
| Team message send and receive                 | Non-RT, target 10 Hz       | Trivial — §5.3                                                           |
| Role arbitration                              | Non-RT                     | Small, bounded — at most 4 teammates                                     |
| Behaviour tick                                | Non-RT, rate **NR** (§2.4) | **NR**                                                                   |
| Expected-utility evaluation over the mode set | Non-RT                     | 2x a single-mode evaluation. Bounded because D3 fixes exactly two modes. |
| Gaze scheduling                               | Non-RT                     | **NR** — Topic 6 §4.2, every term unmeasured                             |

Nothing in this topic enters the 200 Hz cycle. The ADR-002 40 % CPU-time margin must still hold with
behaviour, perception, and estimation all at worst-case load — gate 5.

---

## 7. Falsifiable gates

| #   | Gate                                                                                                                                                                       | Pass condition                                                                                                                                                                                                                      |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Ambiguity behaviour.** Force $w_A \approx w_B \approx 0.5$ and run a full play scenario.                                                                                 | The robot performs only actions from the symmetry-insensitive classes in §3.2. **Zero** shots, zero role-position commitments, zero goalkeeper block positioning. A shot taken at $w = 0.5$ is a failure even if it scores.         |
| 2   | **Own-goal avoidance under adversarial ambiguity.** Deliberately seed the wrong mode at high weight, then present a ball near the own goal.                                | Either the robot declines to shoot, or a subsequent teammate observation reweights the modes before it commits. Log which.                                                                                                          |
| 3   | **Role stability.** Two robots at near-equal time-to-ball for 60 s.                                                                                                        | Role swaps counted. Hysteresis and the player-number tie-break bound the swap rate to a stated maximum.                                                                                                                             |
| 4   | **Behaviour loop jitter.** Measure the decision-loop period distribution over a full half, including any Python garbage-collection pauses.                                 | 99th percentile period stated. Decision staleness bounded against the measured ball speed from Topic 6 gate 3.                                                                                                                      |
| 5   | **Control-loop non-interference.** Run behaviour, perception, and estimation at worst case with the 200 Hz loop active.                                                    | Zero cycle overruns; ADR-002 40 % margin holds. Shared with Topic 5 gate 6.                                                                                                                                                         |
| 6   | **GameController conformance.** Replay recorded traffic from the official controller, including `undo`, all set plays, all penalties, `stopped` toggling, and packet loss. | Every field of struct version 20 decoded correctly. Return packets accepted by the official controller. Byte compatibility of `RGrt` v4 with `rcgcrd_4` confirmed or refuted (§4.4).                                                |
| 7   | **GameController loss.** Drop 1, 2, 5, and all subsequent packets during PLAYING and during SET.                                                                           | No spurious state change on single loss. Staleness threshold above 1.5 s (§4.2). Prolonged loss yields the rule-safe stationary default with no `MOTION_IN_SET` or `MOTION_IN_STOP` penalty incurred.                               |
| 8   | **Team message conformance and budget.** Interoperate with the reference `robocup_extension.proto` and measure sustained egress.                                           | Standard fields parsed by an unmodified reference receiver; the mode-set extension confined to field IDs above 100; total robot egress under 1 Mbit/s with margin (shared with Topic 5 gate 10). `messageBudget` parsed and logged. |
| 9   | **Network-loss degradation.** Remove all team communication mid-game.                                                                                                      | Every robot continues to play; roles collapse deterministically; no crash, no deadlock, no permanent role vacancy. Shared with Topic 6 gate 8.                                                                                      |
| 10  | **Return-struct projection.** Verify that the two-mode posterior is projected **only** at the GameController encoder.                                                      | No collapse anywhere else in the stack. Static or architectural test, not merely a runtime observation (§4.3).                                                                                                                      |
| 11  | **Set-play compliance.** Present each `setPlay` value with `kickingTeam` set to the opponent.                                                                              | The robot retreats the required distance and does not touch the ball. Verified per set-play type.                                                                                                                                   |

---

## 8. Open gaps

1. **Behaviour framework not selected.** §2.2 characterises the trade; it does not resolve it. The
   decisive criterion — decision-loop jitter under load — is gate 4 and is unmeasured.
2. **Decision rate is NR** and cannot be derived until Topic 6 gate 3 (ball deceleration) and Topic 3
   Model Gate 0 close.
3. **Utility function is undefined.** §3.2 shows the shape of the shooting decision but assigns
   $\pm 1$ arbitrarily. Real utilities must weigh time, scoreline, and penalty risk. No source
   consulted provides these.
4. **The weight threshold for symmetry-sensitive actions is unset.** §3.2 proves it lies above 0.5;
   where exactly is a tuning decision requiring gate 1 and gate 2 data.
5. **Teammate identity legibility is NR** (Topic 6 gate 5). §3.3 shows this is the _only_ effective
   solo information-gathering action, so if numbers cannot be read at range, the ambiguity is
   resolvable only over the network — which the rules forbid depending on.
6. **`messageBudget` semantics in the Humanoid League are NR** (§5.5).
7. **Set-play retreat distances were not extracted** from the rulebook in this pass. Gate 11 depends on
   them.
8. **Whistle detection is unscoped.** §1.3 notes it is legal and potentially advantageous; no
   perception or behaviour work is allocated to it.
9. **The mode-set protocol extension does not exist.** §5.1 and §5.4 both require it; it must be
   specified.
10. **Drop-In games** [Rules] require playing with unknown teammates running unknown software. Only
    `mitecom` appears designed for this. Unscoped.
11. **Opponent modelling is entirely absent** from this document and from both rule-named protocols
    beyond position sharing.

**No ADR is written for Topic 7.** The architecture proposal is presented separately.

---

## References

### Rules

- **[R-1]** RoboCup Soccer Humanoid League, _Laws of the Game 2025_, 14 April 2025. Law 3 (The Players), Law 4 (The Players' Equipment), Section "Communication and Control", Section II (Competition Rules).

### Protocols (Primary)

- **[P-1]** `RoboCup-HumanoidSoccerLeague/GameController`, `game_controller_msgs/headers/RoboCupGameControlData.h`, branch `master`. Struct version 20; return version 4; ports 3838 / 3939.
- **[P-2]** Same repository, `game_controller_net/src/control_message_sender.rs`. `SEND_INTERVAL` 500 ms, `SEND_INTERVAL_FAST` 200 ms, UDP broadcast.
- **[P-3]** Same repository, `LICENSE` — MIT, Copyright (c) 2023 Arne Hasselbring.
- **[P-4]** `RoboCup-Humanoid-TC/RobocupProtocol`, `robocup_extension.proto`, branch `master`.
- **[P-5]** `RoboCup-Humanoid-TC/mitecom`, `mitecom-data.h` and `mitecom-roledecider.h`, branch `master`.
- **[P-6]** `Rhoban/hl_communication`, `proto/captain.proto`, `proto/team_play.proto`, `proto/intention.proto`, branch `master`.

### Software availability and licensing (Primary)

- **[S-1]** `ros/rosdistro`, `jazzy/distribution.yaml`. All Jazzy versions in §2.1.
- **[S-2]** `BehaviorTree/BehaviorTree.CPP`, `LICENSE` — MIT.
- **[S-3]** `splintered-reality/py_trees`, `LICENSE` — BSD.
- **[S-4]** `uleroboticsgroup/yasmin`, `LICENSE` — Apache-2.0.
- **[S-5]** `flexbe/flexbe_behavior_engine`, `LICENSE` — BSD-3-Clause.
- **[S-6]** `ros-sports/game_controller_spl`, `README.md` and source tree (`rcgcd_14`, `rcgcd_15`, `rcgcd_16`, `rcgcrd_4`).
- **[S-7]** `bit-bots/bitbots_main`, `src/lib/dynamic_stack_decider/{README.md,LICENSE}` — MIT.
- **[S-8]** `bit-bots/bitbots_main`, `src/bitbots_behavior/bitbots_body_behavior/.../main.dsd` and `src/bitbots_navigation/bitbots_localization_handler/.../localization.dsd`.
- **[S-9]** `bhuman/CABSL`, `Readme.md` — option-based hierarchical state machines and the activation graph.

### Decision theory

- **[E-1]** von Neumann, J., Morgenstern, O. _Theory of Games and Economic Behavior_. Princeton University Press, 1944.
- **[E-2]** Thrun, S., Burgard, W., Fox, D. _Probabilistic Robotics_. MIT Press, 2005. Chapters 15-16, decision-making and planning under uncertainty.

### Project documents

- **[D-1]** [architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md)
- **[D-2]** [architecture/ADR-002-safety-and-fault-management.md](../architecture/ADR-002-safety-and-fault-management.md)
- **[D-3]** [architecture/ADR-003-zenoh-middleware.md](../architecture/ADR-003-zenoh-middleware.md)
- **[D-4]** [research/topic-5-perception-pipeline.md](topic-5-perception-pipeline.md)
- **[D-5]** [research/topic-6-localization-world-model.md](topic-6-localization-world-model.md) — D1-D8, especially D3 (two-mode pose) and D6 (gaze phasing).
