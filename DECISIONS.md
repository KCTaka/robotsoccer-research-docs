# Architecture Decision Register

This register indexes accepted and superseded architecture decisions. Detailed rationale and qualification criteria live in the linked ADRs.

| ID                                                                                 | Topic               | Decision                                                                                                                           | Status   | Date       |
| ---------------------------------------------------------------------------------- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------- | ---------- |
| [ADR-001-01](architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md) | Real-time actuation | Use `HumanoidActuatorSystem` as the stable `ros2_control` system boundary.                                                         | Accepted | 2026-08-28 |
| [ADR-001-02](architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md) | Real-time actuation | Expose each MIT command as the atomic five-interface tuple `position`, `velocity`, `effort`, `stiffness`, and `damping`.           | Accepted | 2026-08-28 |
| [ADR-001-03](architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md) | Real-time actuation | Run the current actuator control and hardware exchange at a genuine 200 Hz.                                                        | Accepted | 2026-08-28 |
| [ADR-001-04](architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md) | Real-time actuation | Use `Stm32SerialTransport` as the production baseline behind a swappable `ActuatorTransport` interface.                            | Accepted | 2026-08-28 |
| [ADR-001-05](architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md) | Real-time actuation | Leave the successor physical bus and topology undecided.                                                                           | Accepted | 2026-08-28 |
| [ADR-002-01](architecture/ADR-002-safety-and-fault-management.md)                  | Safety              | Use layered, transport-agnostic safety authorities with a final tuple-aware gate in `HumanoidActuatorSystem`.                      | Accepted | 2026-08-28 |
| [ADR-002-02](architecture/ADR-002-safety-and-fault-management.md)                  | Safety              | Use an independent, de-energize-to-stop actuator-power chain for emergency containment.                                            | Accepted | 2026-08-28 |
| [ADR-002-03](architecture/ADR-002-safety-and-fault-management.md)                  | Safety              | Isolate a failed joint first; continue only through an explicitly approved degraded controller policy.                             | Accepted | 2026-08-28 |
| [ADR-002-04](architecture/ADR-002-safety-and-fault-management.md)                  | Safety              | On command loss, apply local safe damping and then disable; never resume motion automatically.                                     | Accepted | 2026-08-28 |
| [ADR-002-05](architecture/ADR-002-safety-and-fault-management.md)                  | Safety              | Escalate failed or unverifiable joint isolation to actuator-power removal.                                                         | Accepted | 2026-08-28 |
| [ADR-002-06](architecture/ADR-002-safety-and-fault-management.md)                  | Safety              | Require tiered explicit rearming and a versioned safety manifest shared by Jetson and STM32.                                       | Accepted | 2026-08-28 |
| [ADR-002-07](architecture/ADR-002-safety-and-fault-management.md)                  | Safety              | Treat fall detection, protective bracing, post-fall handling, and fall recovery as first-class safety behavior.                    | Accepted | 2026-08-28 |
| [ADR-003-01](architecture/ADR-003-zenoh-middleware.md)                             | Middleware          | Standardize ROS 2 communication on Zenoh through `rmw_zenoh_cpp`; verify and mitigate its limitations without reopening selection. | Accepted | 2026-08-28 |
| [ADR-005-01](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Behaviour           | Treat rule state as a supervisor that selects the active behaviour tree, not as guard conditions inside one.                       | Accepted | 2026-09-01 |
| [ADR-005-02](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Behaviour           | Use `behaviortree_cpp` v4 with sticky-by-default node discipline; reactive nodes require justification.                            | Accepted | 2026-09-01 |
| [ADR-005-03](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Behaviour           | Declare symmetry sensitivity on every action node and gate the sensitive set once, structurally.                                   | Accepted | 2026-09-01 |
| [ADR-005-04](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Team strategy       | Assign roles by distributed deterministic arbitration on time-to-ball; no central captain.                                         | Accepted | 2026-09-01 |
| [ADR-005-05](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Team strategy       | Use `robocup_extension.proto` extended with a mode-set message above field ID 100.                                                 | Accepted | 2026-09-01 |
| [ADR-005-06](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | World model         | Collapse the two-mode pose at exactly one point: the GameController return encoder.                                                | Accepted | 2026-09-01 |
| [ADR-005-07](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Game state          | Hold and age GameController state with a staleness threshold above 1.5 s; fail to the rule-safe stationary default.                | Accepted | 2026-09-01 |
| [ADR-005-08](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Team strategy       | Require a robot with an ambiguous pose to advertise low confidence and decline symmetry-sensitive roles.                           | Accepted | 2026-09-01 |
| [ADR-005-09](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Networking          | Separate competition, internal, and operator network planes; a single gateway process owns every competition socket.               | Accepted | 2026-09-01 |
| [ADR-005-10](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Networking          | Run the gateway as a managed lifecycle node that binds at `configure` and drains sockets keeping only the last valid packet.       | Accepted | 2026-09-01 |
| [ADR-005-11](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Networking          | Treat all competition UDP as untrusted; every reachable consequence must degrade toward less motion, never more authority.         | Accepted | 2026-09-01 |
| [ADR-005-12](architecture/ADR-005-behavior-game-state-and-team-networking.md)      | Networking          | Place the gateway in the host network namespace; broadcast reception must be tested across the real container boundary.            | Accepted | 2026-09-01 |

## Reserved identifiers

ADR numbers no longer track topic numbers, because ADR-003 records a cross-cutting middleware decision rather than Topic 3, and ADR-005 records Topics 7 and 8 jointly.

| ID      | Reserved for                                     | State                                            |
| ------- | ------------------------------------------------ | ------------------------------------------------ |
| ADR-004 | Topic 3: robot model, kinematics, and locomotion | Reserved. Research complete; decision not taken. |
| ADR-006 | Next topic to reach an accepted decision         | Unassigned                                       |

## Research baselines

Research precedes decisions. These documents are durable evidence baselines, not accepted decisions, and must be updated before the corresponding ADR is revised.

| Topic                                    | Document                                                                                          | Status                             | Evidence last verified |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------- | ---------------------------------- | ---------------------- |
| 3 — Robot model, kinematics, locomotion  | [topic-3-locomotion-survey.md](research/topic-3-locomotion-survey.md)                             | Complete                           | 2026-08-28             |
| 4 — Sensors, timing, state estimation    | [topic-4-sensors-timing-state-estimation.md](research/topic-4-sensors-timing-state-estimation.md) | Complete                           | 2026-09-01             |
| 5 — Perception pipeline                  | [topic-5-perception-pipeline.md](research/topic-5-perception-pipeline.md)                         | Complete                           | 2026-09-01             |
| 6 — Localization, world model, gaze      | [topic-6-localization-world-model.md](research/topic-6-localization-world-model.md)               | Complete, decisions D1-D8 approved | 2026-09-01             |
| 7 — Behaviour, game state, team strategy | [topic-7-behavior-and-strategy.md](research/topic-7-behavior-and-strategy.md)                     | Complete, decided in ADR-005       | 2026-09-01             |
| 8 — GameController and team networking   | [topic-8-gamecontroller-networking.md](research/topic-8-gamecontroller-networking.md)             | Complete, decided in ADR-005       | 2026-09-01             |
| 9 — Runtime, containers, compute         | [topic-9-runtime-and-containers.md](research/topic-9-runtime-and-containers.md)                   | Complete, decision pending         | 2026-09-01             |
