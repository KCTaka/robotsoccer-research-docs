# ADR-005: Behaviour, Game State, and Team Networking

- Status: Accepted
- Decision date: 2026-09-01
- Evidence last verified: 2026-09-01
- Scope: Topics 7 and 8
- Depends on: [ADR-001](ADR-001-real-time-actuation-and-hardware-abstraction.md), [ADR-002](ADR-002-safety-and-fault-management.md), [ADR-003](ADR-003-zenoh-middleware.md)
- Research baselines: [Topic 7](../research/topic-7-behavior-and-strategy.md), [Topic 8](../research/topic-8-gamecontroller-networking.md), [Topic 6](../research/topic-6-localization-world-model.md)

## Context

The behaviour layer sits between a world model that is provably ambiguous and a set of motion
primitives that are not yet designed. Topic 6 established, from the rulebook rather than from sensor
performance, that the permanent visual features of the KidSize field are invariant under a 180-degree
rotation about the field centre, and recorded decision D3: the pose estimate is a **two-mode set with
weights that is never collapsed**. Topic 6 assigned the consequences of that decision to this topic.

Topic 7 and Topic 8 research then surfaced three structural conflicts that this ADR exists to resolve.

1. **The GameController return struct is unimodal.** `RoboCupGameControlReturnData` carries
   `float pose[3]` with the comment "+ve x-axis points towards the goal we are attempting to score
   on". It has no covariance field, no confidence field, and no second hypothesis.
2. **Neither rule-recommended team protocol can express a bimodal pose.** `RobocupProtocol` carries a
   single `fmat3` covariance; `mitecom` carries a single scalar `ROBOT_ABSOLUTE_BELIEF`.
3. **Symmetry can only be broken with information from outside the field-feature measurement model,
   and the rules restrict where that information may come from.** A handler may not supply _"the
   orientation of the robots own or opponents goal"_, and the rules count _"button clicks"_ as
   communication. Robot-to-robot communication is explicitly permitted, but robots _"must not rely on
   the quality of the wireless network"_.

Taken together, these mean that **playing with an unresolved 50/50 heading belief is a permanent
supported operating mode, not a recovery state**. There is no rule-guaranteed escape from it for a
robot that is alone on the field.

Separately, competition network traffic is unauthenticated UDP on a shared field WLAN, and the
GameController is broadcast at 500 ms with a 200 ms burst after state changes. Neither may be allowed
to affect the 5 ms control cycle.

## Decision

### 1. Rule state is a supervisor, not a subtree

Game state is the tuple $(\texttt{state}, \texttt{stopped}, \texttt{gamePhase}, \texttt{setPlay},
\texttt{kickingTeam})$ plus packet age and this robot's penalty record. It is **not** a single enum:
`stopped` is an independent boolean, and the GameController implements an `undo` action, so game state
is not monotonic.

A rule-state supervisor consumes this tuple and **selects** the active behaviour tree. Rules are not
encoded as guard conditions distributed through a single tree. The supervisor is the one place where
rule compliance is implemented and therefore the one place a Technical Committee inspection must read.

### 2. Behaviour engine: `BehaviorTree.CPP` v4, sticky by default

`behaviortree_cpp` 4.10.0-1, MIT licensed, released for Jazzy. C++ rather than Python, because the
decision-loop jitter requirement is a measurement gate and a garbage-collected runtime adds a variable
that cannot be removed later.

Project node discipline is mandatory:

| Rule                  | Requirement                                                                                                                                          |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Default control node  | `SequenceWithMemory`. Stickiness is the default.                                                                                                     |
| Reactive nodes        | `ReactiveSequence` and `ReactiveFallback` require written justification at each use site.                                                            |
| Hysteresis primitives | `RunOnce`, `KeepRunningUntilFailure`, and `ScriptPrecondition` are the sanctioned mechanisms. Ad-hoc equivalents are not.                            |
| ROS integration       | `behaviortree_ros2` is **not released for Jazzy**. The ROS glue is project-owned code and follows the ADR-003 QoS catalogue like any other endpoint. |

A behaviour tree re-ticks from the root and is therefore reactive by default; two nearly-equal guard
conditions will otherwise flip the selected branch every tick. In soccer this produces a robot that
alternates between approaching the ball and returning to position and does neither.

### 3. Symmetry sensitivity is a declared property, gated once

Every action node declares whether its correctness depends on knowing the field direction.

$$\mathbb{E}[U(\text{shoot})] = w(+1) + (1-w)(-1) = 2w - 1$$

where $w$ is the weight on the mode in which the robot faces the opponent goal. This is **zero at
$w = 0.5$ and negative below it**, because an own goal is a two-goal swing. The admissible weight
threshold for a symmetry-sensitive action is therefore strictly above 0.5.

Symmetry-sensitive actions — shooting, role positioning, goalkeeper block positioning, directional
dribbling — are gated as a group at the tree root and cannot execute below the threshold.
Symmetry-insensitive actions — tracking the ball, walking to the ball, retaining possession, staying
upright, standing — remain available at all times.

This is enforced structurally, in the same manner and for the same reason as the ADR-002 coupled tuple
envelope: a scattered per-node runtime check is not a proof, and cannot be audited.

### 4. Distributed role arbitration; no captain

Every robot broadcasts its own state and runs the same pure arbitration function over the same
teammate set. Ordering is by **time-to-ball**, not distance, because time-to-ball incorporates
orientation, obstacles, walking speed, and fallen state. Ties are broken by a total order on player
number. An empty teammate set yields a valid solo role.

A central captain is rejected. The rules force a working standalone path regardless, so a captain adds
election and captain-loss failure modes without removing any requirement. The captain's one genuine
advantage — multi-viewpoint opponent fusion — is a world-model feature obtainable by sharing
observations without centralising the decision.

### 5. Team wire format

`robocup_extension.proto` from `RoboCup-Humanoid-TC/RobocupProtocol`, extended with a mode-set message
at **field ID above 100**, which the protocol reserves for extensions. A receiver that does not
understand the extension still reads a conformant `current_pose`. Target rate 10 Hz, costing
approximately 4.4 % of the 1 Mbit/s per-robot ceiling.

Teammate state remains an enhancement and never a dependency, per Topic 6 D7.

### 6. Exactly one mode-collapse point

The two-mode posterior is projected to its maximum-weight mode at **one** place: the GameController
return-packet encoder, a 32-byte egress message used for monitoring and refereeing.

The collapsed value never re-enters any decision, is never published internally, and is never stored.
Every other consumer — behaviour, gaze, world model, team messages — receives the full mode set.

This is an invariant, not a guideline. It exists because the wire format admits nothing else, and it is
recorded explicitly so that a later change cannot "simplify" the estimator to match the wire format.

### 7. A robot with an ambiguous pose withdraws from symmetry-sensitive roles

Its time-to-ball is computed in the field frame and is therefore unreliable. It advertises low
confidence and declines those roles rather than competing for them. Without this, one confused robot
corrupts the whole team's assignment.

### 8. Three network planes, isolated

| Plane                                          | Transport                                                          | Trust         |
| ---------------------------------------------- | ------------------------------------------------------------------ | ------------- |
| Competition — GameController and team messages | Raw UDP, league-defined, unauthenticated                           | **Untrusted** |
| Internal — all ROS 2 traffic                   | `rmw_zenoh_cpp`, loopback TCP via the supervised local router      | Trusted       |
| Operator — telemetry and development           | Zenoh over mutually authenticated TLS, **tethered at competition** | Authenticated |

Competition UDP is never carried by Zenoh, and Zenoh is never used to reach the field network. A single
**network gateway process** owns every competition socket and is the only place untrusted bytes become
typed ROS messages. An external bridge that re-broadcast game state to robots is prohibited by rule.

At competition the wireless interface carries competition traffic only.

### 9. Gateway lifecycle and socket semantics

The gateway is a managed lifecycle node. Sockets are **bound at `configure`**, not at `activate`, so a
port conflict or missing interface is a failed transition rather than silence on the field.

| Requirement        | Value                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------ |
| Bind address       | Wildcard. The GameController packet is a broadcast and its source is not known in advance. |
| `SO_REUSEADDR`     | Set                                                                                        |
| Read discipline    | **Drain the socket fully each wake and keep only the last valid packet.**                  |
| Blocking           | Never. Non-blocking or bounded-timeout poll only.                                          |
| Return destination | The observed source address of the accepted control packet, never a configured constant.   |
| Self-filtering     | Own team broadcasts are discarded before reaching the world model.                         |
| Age                | Published by the gateway as data. Consumers do not compute their own staleness.            |

Drain-and-keep-last is a correctness requirement, not an optimisation: the controller sends a burst
after a state change, and processing a queued burst in order after a scheduling stall replays the same
transition several times.

The gateway makes no behavioural decisions, performs no retries, and holds no handle the real-time
process depends on.

### 10. Staleness and loss policy

| Condition                                      | Response                                                                                                        |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| No packet ever received                        | A distinct first-class condition. **Not** a default to `INITIAL`.                                               |
| Single packet lost                             | Hold the last state and age it. Take no action on the gap.                                                      |
| Staleness threshold                            | **Above 1.5 s.** A threshold near the 500 ms broadcast period declares loss during ordinary single-packet loss. |
| Prolonged loss                                 | Fail to the rule-safe stationary default.                                                                       |
| State regression or jump                       | Accept it. Behaviour must not assume monotonic game state.                                                      |
| Own robot penalised, picked up, or substituted | Continuity is broken. The field-side prior is re-seeded on unpenalisation.                                      |

The rule-safe default and the ADR-002-safe default coincide here: `MOTION_IN_SET` and `MOTION_IN_STOP`
penalise motion when play is stopped, and standing still is also the lower-energy safety state. This
coincidence is recorded so that it is not later optimised away.

### 11. Untrusted input handling

Both competition protocols are unauthenticated and spoofable by any host on the field WLAN. No
cryptographic authentication is added, because the wire formats are league-defined and must
interoperate with the official controller and with mixed-team opponents.

A validation ladder is applied in order, and a packet failing any rung is counted and dropped, never
partially processed: exact datagram length, header and version match, this robot's team and player
number in range, enumerated and numeric fields in range, source-address consistency, and rate
plausibility.

The load-bearing control is not the ladder but this invariant:

> **Every reachable consequence of an injected or corrupted competition packet degrades toward less
> motion, never toward more actuator authority.**

A spoofed stop makes the robot stand still. A spoofed play state produces a refereeing penalty inside
the normal locomotion envelope. A poisoned teammate pose degrades play but cannot be depended on by
construction. Any future change that allows a network input to increase actuator authority breaks this
argument and must be rejected.

### 12. Container network placement

The gateway process runs in the **host network namespace**, or in a namespace holding a macvlan or
ipvlan interface on the field WLAN. No other process requires field-network access.

A container on a default bridge network is behind NAT on a separate namespace and does not receive
host-subnet broadcasts. The failure is silent: the socket binds successfully and never receives
anything. Conformance testing must use a real broadcast source across the real container boundary; a
unicast test to loopback passes in every configuration and proves nothing.

This constrains the Topic 9 process layout, including where the `rmw_zenohd` router must be reachable,
and is binding on that topic.

## Consequences

### Positive

- The robot keeps playing under an unresolved heading belief instead of freezing or gambling.
- Rule compliance is implemented in one auditable component, which matches the inspection clause.
- Team coordination degrades to solo play by construction rather than by an exception path.
- No network input can increase actuator authority, so the competition plane cannot become a safety
  path.
- The estimator's multimodality survives contact with two wire formats that cannot represent it.

### Costs and constraints

- Behaviour-tree stickiness must be maintained by discipline and review; the framework defaults are the
  opposite of what this design requires.
- Project-owned ROS glue is required because `behaviortree_ros2` is not released for Jazzy.
- A protocol extension must be specified, implemented, and interoperability-tested.
- Symmetry-sensitivity declarations add a required annotation to every action node.
- The gateway's host-namespace requirement constrains the container topology and weakens the network
  isolation that containerisation would otherwise provide for that one process.
- Utility values, the weight threshold, the decision rate, and switching costs are all unmeasured. The
  first implementation uses explicit hysteresis with hand-set thresholds.

## Rejected alternatives

| Rejected                                                      | Reason                                                                                                                                             |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Collapse the pose to its maximum-weight mode in the estimator | Topic 6 D3. The posterior is provably bimodal and there is no visual recovery from a wrong collapse.                                               |
| Act on $\arg\max_i w_i$ without a threshold                   | Expected utility is negative below $w = 0.5$ and zero at it. An own goal is a two-goal swing.                                                      |
| Resolve symmetry via the robot handler                        | Prohibited. The rules name goal orientation and re-entry location as information a human may not supply, and count button clicks as communication. |
| Look at a goal or the centre circle to break symmetry         | Both goals are white and all field features are symmetric under the rotation. The information gain is exactly zero.                                |
| A central captain for role assignment                         | The standalone path is required regardless; a captain adds failure modes without removing requirements.                                            |
| `mitecom` as the primary team protocol                        | Carries only a scalar belief and no covariance. Retained as a Drop-In interoperability question.                                                   |
| A single five-state machine over `state`                      | `stopped`, `gamePhase`, and `setPlay` are orthogonal, and set plays are the highest-frequency avoidable penalty source.                            |
| `game_controller_spl` for GameController ingest               | SPL package supporting data versions 14, 15, and 16. The Humanoid League struct is version 20. Retained as a structural template only.             |
| An external host bridging GameController data to robots       | _"Any kind of transmission from an external computer to the playing robots is prohibited."_                                                        |
| Python behaviour framework (`py_trees`, DSD-style stack)      | Garbage-collection jitter is an unremovable variable in a loop whose staleness budget is unmeasured. DSD is additionally unreleased.               |
| Cryptographic authentication on the competition plane         | Would be non-conformant with league-defined wire formats and mixed-team play.                                                                      |

## Verification gates

Gates are stated in full in the research baselines and are referenced here by number.

| Source                                                         | Gates                                                                                                                                                                                                                                                                                                |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Topic 7](../research/topic-7-behavior-and-strategy.md) §7     | 1 ambiguity behaviour; 2 own-goal avoidance; 3 role stability; 4 behaviour-loop jitter; 5 control-loop non-interference; 6 GameController conformance; 7 GameController loss; 8 team message conformance and budget; 9 network-loss degradation; 10 return-struct projection; 11 set-play compliance |
| [Topic 8](../research/topic-8-gamecontroller-networking.md) §7 | 1 protocol conformance; 2 burst handling; 3 broadcast across the container boundary; 4 malformed and hostile input; 5 flood non-interference; 6 egress budget; 7 lifecycle and restart; 8 interface loss; 9 self-message rejection                                                                   |

Release evidence must include, at minimum: a recorded own-goal-avoidance run at forced $w = 0.5$; a
static or architectural demonstration that no collapse occurs outside the return encoder; a fuzzing
report for both wire formats; and a broadcast-reception result obtained across the deployed container
network configuration rather than over loopback.

## References

- RoboCup Soccer Humanoid League, _Laws of the Game 2025_, 14 April 2025.
- `RoboCup-HumanoidSoccerLeague/GameController` (MIT): `game_controller_msgs/headers/RoboCupGameControlData.h`, `game_controller_net/src/control_message_sender.rs`.
- `RoboCup-Humanoid-TC/RobocupProtocol`: `robocup_extension.proto`.
- `RoboCup-Humanoid-TC/mitecom`: `mitecom-data.h`, `mitecom-roledecider.h`.
- `BehaviorTree/BehaviorTree.CPP` (MIT), release 4.10.0-1 in `ros/rosdistro` `jazzy/distribution.yaml`.
- [Topic 6 research](../research/topic-6-localization-world-model.md) — decisions D1-D8.
- [Topic 7 research](../research/topic-7-behavior-and-strategy.md) — decisions D9-D16 and all supporting evidence.
- [Topic 8 research](../research/topic-8-gamecontroller-networking.md) — networking plumbing and trust boundary.
