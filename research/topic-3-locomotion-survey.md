# Topic 3 Research: Locomotion and Motion-Control Survey

- Status: Complete research baseline; update before any later Topic 3 revision
- Evidence last verified: 2026-08-28
- Scope: Research input for Topic 3; not an accepted architecture decision
- Canonical decisions: [ADR-001](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md), [ADR-002](../architecture/ADR-002-safety-and-fault-management.md), and [ADR-003](../architecture/ADR-003-zenoh-middleware.md)

## Purpose and evidence policy

This survey compares locomotion paradigms and candidate tools without reopening the accepted 200 Hz actuator, safety, or middleware boundaries. Published controller rates, solve times, robot results, and competition use are evidence for a specific system, not guaranteed targets for this robot. Package availability does not by itself establish target-compute feasibility or production support.

Evidence is labeled as follows:

- **Peer reviewed**: a paper reports the method and experiment.
- **League reported**: a team paper, team description paper (TDP), robot specification, or released team code reports competition practice.
- **Upstream documented**: a project or vendor documents a feature, version, or platform requirement.
- **Project target**: a proposed budget or gate that still requires measurement.

`NR` means that a value was not reported or was not established by the inspected source. It never means zero. A reported mean, nominal update rate, or desktop result is not treated as a worst-case bound or Jetson qualification.

## Confirmed project inputs

| Input | Confirmed state | Architectural consequence |
| --- | --- | --- |
| Kinematic layout | The 14-joint distribution, motor assignment, and any passive, coupled, or parallel mechanisms are not designed yet. | This is Model Gate 0. No production URDF, dynamics result, or dynamic gait claim may assume a topology. |
| Arm scope | Arm swing for balance and fall-protection bracing are in Topic 3. Goalkeeper-specific arm behavior is outside this topic. | Locomotion candidates expose arm momentum tasks and brace transitions; goalkeeper primitives remain a later extension. |
| Physical envelope | Height, total mass, battery chemistry, voltage, capacity, energy, and runtime are unknown or unmeasured. | Physical measurement and electrical characterization are Model Gate 0. Compute and thermal values remain profile budgets, not robot-runtime claims. |
| Timeline and staffing | Competition milestone, active capacity, and skill mix are undecided. | Maintain one primary candidate and at most one time-boxed challenger. Downselect dates are milestone-relative until a dated program plan exists. |
| Simulator preference | Assign roles from evidence. | Isaac Lab is evaluated for parallel learning and domain randomization; MuJoCo is evaluated as the lightweight independent controller-SIL and regression oracle. |

## Paradigm comparison

### Mathematical and architectural comparison

| Lane | Model and mathematical assumptions | Typical output and contact scheduling | What it can establish | What it cannot establish alone | Evidence-supported project role |
| --- | --- | --- | --- | --- | --- |
| A. Classical model-based: gait generator plus IK or QP WBC | Scripted/keyframe motion assumes a known initial pose and repeatable interaction. Analytical gait usually prescribes periodic task-space trajectories. LIPM/ZMP/DCM additionally assumes a simplified centroidal model, commonly constant CoM height and bounded planar support. | Keyframes, joint/task trajectories, CoM/ZMP/DCM references, and prescribed support phases. Instantaneous IK or WBC consumes rather than discovers the contact mode. | Deterministic bring-up, inspectable transitions, conservative walking, and a reproducible fallback. Feedback can add useful balance stabilization. | Open loop does not guarantee friction, torque, momentum, collision, or disturbance robustness. LIPM does not prove full-body feasibility. | Mandatory commissioning path. Closed-loop analytical or LIPM/DCM walking is the provisional primary candidate after its model gates pass. Pure open loop remains supported-rig commissioning only. |
| B. Centroidal or whole-body MPC plus WBC | Centroidal MPC assumes an identified mass distribution, contact geometry, friction model, and a supplied or optimized contact schedule. Whole-body optimal control additionally depends on accurate joint dynamics and often rigid contact. | A finite-horizon state, wrench, foothold, trajectory, or feedback policy. A faster inverse-dynamics/task-space layer realizes the current plan. | Horizon-aware constraint handling, step adjustment, and push recovery when the model and estimator are adequate. | A nominal solve rate does not prove a 5 ms bound. Centroidal feasibility does not imply joint, collision, actuator, or contact feasibility unless those constraints are explicitly coupled. | One time-boxed challenger. Asynchronous centroidal/DCM MPC may advance after Model Gate 3. Whole-body DDP remains research-only until target-compute evidence exists. |
| C. End-to-end RL sim-to-real | A policy approximates a mapping from a declared observation/history distribution to action. Transfer depends on exact actuator, delay, sensor, contact, and randomization semantics represented during training. | Commonly bounded position references at 40-50 Hz in the surveyed humanoid systems; torque or learned-gain output is possible but materially expands safety and identification burden. Contact is learned implicitly or represented through phase/commands and reward design. | Complex feedback behavior and soccer skills can transfer to hardware when the training and deployment contracts match. | No formal OOD, contact-feasibility, torque, collision, or recovery guarantee. A checkpoint without normalization, joint order, simulator, and exporter provenance is not reproducible. | Later bounded reference-policy challenger. It never owns the actuator transport or bypasses the model-based fallback and `SafetyKernel`. |
| D. Hybrid or residual | A deterministic controller supplies the nominal trajectory, torque, or stabilizing structure. A policy modifies a declared bounded channel, such as foothold choice, task reference, model correction, or residual torque. | Base command plus one saturated residual, or a learned reference consumed by the same WBC. Contact scheduling normally remains explicit. | Can focus learning on model error or high-level choices while preserving an inspectable fallback. | Residual learning is not automatically safer. It can cancel stability margins, duplicate feedback, or shift the training dynamics if its authority is not explicit. | Preferred first role for learning after the deterministic baseline: geometric foothold selection, reference correction, or a tightly bounded residual with independent ablation. |

For LIPM/DCM walking with nominal CoM height $h$,

$$
\ddot x = \omega_0^2(x-z), \qquad
\omega_0 = \sqrt{g/h}, \qquad
\xi = x + \dot x/\omega_0, \qquad
\dot\xi = \omega_0(\xi-z),
$$

where $z$ is the ZMP and $\xi$ is the divergent component of motion. This model is useful for reference generation, but it omits full-body angular-momentum and actuator feasibility unless extensions add them.

An inverse-dynamics WBC instead reasons about

$$
M(q)\dot v + h(q,v) = S^\top\tau + J_c(q)^\top\lambda,
\qquad
J_c\dot v + \dot J_c v = 0,
$$

with task, friction, contact-wrench, joint, and actuator constraints. A centroidal MPC plans the evolution of CoM $c$ and angular momentum $L$ through contact wrenches:

$$
m\ddot c = \sum_i f_i + mg, \qquad
\dot L = \sum_i (r_i-c)\times f_i + \tau_i.
$$

Neither formulation selects future contacts unless a scheduler, footstep planner, or contact-implicit optimizer explicitly does so.

### Quantitative controller evidence

| Lane and source | Platform and validation | Reported cadence or computation | Reported result | Exact limitation for this project |
| --- | --- | --- | --- | --- |
| A: Kajita et al. 2003 [C1] | HRP-2P model in OpenHRP; simulation | 5 ms generator sample; 1.6 s preview performed better than 0.8 s in the reported example | Multi-step and spiral-stair trajectories | The cited section is simulation. It does not prove a 200 Hz physical controller or target-compute feasibility. |
| A: Allgeuer and Behnke 2018 [C2] | Four igus robots and Dynaped; physical | Numeric update rate and solve time NR | 21 cm/s omnidirectional walking on 32 mm artificial grass; step and push ablations | Extended walking was often impossible with feedback disabled. This supports feedback, not open-loop robustness. |
| A: Graf and Roefer 2012 [C3] | NAO; physical | 100 Hz is inferred from the paper's 40 ms/four-cycle statement; measured motion lag 40 ms | 31 cm/s forward, 12 cm/s lateral, 22 cm/s backward, and qualitative push recovery | The cadence is an explicit inference, not a stated controller specification; push magnitudes and fall counts were not reported. |
| A/WBC: Herzog et al. 2016 [C4] | Real 14-DoF humanoid lower body | 1 kHz; Table 4 maximum 1.05 ms on an Intel i7-2600 at 3.40 GHz | Hierarchical inverse-dynamics momentum control on hardware | Component timing on a desktop-class x86 CPU is not full-cycle WCET and is not Orin evidence. |
| A/B: Caron et al. 2019 [C5] | HRP-4; physical stair climbing | MPC 10 Hz with 1.6 s horizon; physical controller 200 Hz; full cycle $1.0\pm0.4$ ms on an unspecified consumer laptop | Repeated ascent of five 18.5 cm stairs | The spread is not a maximum. Footsteps were fixed and the constant-height model omitted important swing and impact dynamics. |
| B: Koenemann et al. 2015 [C6] | HRP-2 whole-body DDP; physical multicontact reaching, not gait | About 50 ms offboard optimization; onboard position interpolation at 200 Hz | Whole-body reaching and hand-supported multicontact motion | It is evidence for asynchronous plan realization, not online walking or a 5 ms optimizer. |
| B: Grandia et al. 2019 [C7] | ANYmal quadruped; physical | Feedback MPC about 15 Hz; inverse dynamics and feedback policy 400 Hz; onboard dual-core i7-4600U | Dynamic walking, gait transition, and disturbance response | Strong multirate precedent, but different morphology and no latency distribution or WCET. |
| B: Dantec et al. 2022 [C8] | TALOS; physical flat walking and 10 cm stairs | Policy publication 70 Hz; normally below about 15 ms with contact-switch peaks to 50 ms on external Ryzen 9 5950X | Whole-body DDP locomotion | The optimizer cannot be the 5 ms transaction owner; fixed contact timing and soft wrench treatment limit direct reuse. |
| B: Mastalli et al. 2023 [C9] | ANYmal quadruped; physical | Inverse-dynamics MPC 50 Hz; feedback realization 400 Hz; 1 s horizon with 100 nodes | Damaged stairs, pallet and gap traversal, trot, and push recovery | Processor and solve-time distribution were NR in the inspected evidence; this is not humanoid or Orin qualification. |
| C: Berkeley Humanoid 2024 [C10] | 12 leg joints; physical humanoid | MLP position references 50 Hz; estimator 1 kHz; drive PD 25 kHz | 364 m in 10 minutes outdoors plus trails, hopping, and pushes | Original deployable weights, runtime source, inference hardware, and license were NR. |
| C: DeepMind OP3 soccer 2023 [C11] | Robotis OP3; physical soccer and 1-v-1 | Policy 40 Hz; 20 joint actions; actor layers 256, 256, 128 | Learned get-up, soccer skills, and competitive play | Position-servo hardware and unpublished deployment artifact provenance do not establish transfer to MIT impedance actuators. |
| C/D: FRASA 2024/2025 [C12] | Sigmaban; physical | Policy decisions trained at 20 Hz and executed at 100 Hz; mean inference about 40 microseconds | Unified sagittal fall recovery and stand-up | The published symmetry restriction limits recovery to sagittal cases. Competition use is team-reported. |
| C: Bit-Bots RL motion, audited 2026 [L6] | 12 leg-position outputs behind a 100 Hz HCM | Final-match ONNX shape `[1,50] -> [1,12]`; policy 50 Hz | Team-reported 2026 competition stack outcome; later repository integration is public | The TDP predates some June/July 2026 integration commits. Team outcome is not an isolated gait benchmark, and the model is not an all-joint MIT command source. |
| D: Walk These Ways 2022 [C13] | Unitree Go1 quadruped on Jetson TX2 NX; physical | Policy 50 Hz over drive PD; approximately 20 ms identified latency | Robust, rapidly adaptable walking skills | Different morphology. Its value here is the reproducible reference-policy and actuator-identification pattern, not direct policy transfer. |
| D: ASAP 2025 [C14] | Unitree G1; physical whole-body tracking | 23 deployed position targets; policy rate and network NR in the inspected source | Sim-to-real tracking after simulator alignment | The learned delta-action model is used during simulator fine-tuning, not as a second physical-runtime command owner. |

### League and released-stack evidence

| System | Primary-source finding | Adoption status and transfer limit |
| --- | --- | --- |
| NimbRo 2023 match stack [L1] | Hand-designed CPG gait in abstract leg space with IK, fused-angle and swing-leg feedback, pseudo-CoM/ZMP feedback, and model/servo feed-forward. Competition kicks were waveform overlays in the gait. | Competition-deployed and model-based. The command boundary is position-centric, and the exact match binary/configuration is not reproducible from the old public repository alone. |
| NimbRo direct-centroidal stack [L2] | Five-mass centroidal state with CoM/CMP feedback and reactive step placement at 100 Hz; average computation 143 microseconds was reported. | Hardware-demonstrated in push-recovery work. The paper explicitly contrasts the closed-form controller with MPC; it must not be cited as deployed MPC. |
| Rhoban 2023 stack [L3] | FootstepNet proposal around 100 microseconds, 40 Hz/1.7 s LIPM-ZMP preview QP around 2 ms, and roughly 200 Hz whole-body IK QP around 100 microseconds, ending in position-controlled Dynamixels. Kicks and stand-up were keyframes. | Competition-deployed multirate architecture. The paper calls proper MPC future work, so the preview QP is not evidence of a deployed receding-horizon MPC stack. |
| Rhoban 2025/2026 [L4] | The 2026 TDP reports an end-to-end RL walker that maps proprioception to joint positions on the 2025 robot and reports FRASA use. Dynamic RL kicking and arbitrary 3D recovery remain ongoing work. | Team-reported hardware use. Policy rate, public runtime implementation, and isolated gait metrics were NR. PlaCo capability does not prove that its MPC was used in matches. |
| Hamburg Bit-Bots 2026 [L5, L6] | A 100 Hz HCM arbitrates independent walking, kick, get-up, animation, and head streams. Current RL paths use 50 Hz position policies and fixed requested gains; spline/IK and keyframe paths remain available. | The March TDP described X02 work as simulation/future integration; later commits prove repository integration, not the earlier TDP's hardware status. Its authority-separation pattern transfers better than its actuator interface. |
| B-Human 2025 release [L7] | Separate walking, kick, keyframe/get-up, arm, and fall modules execute against the NAO motion boundary; the released keyframe engine is a concrete mature implementation. | Strong evidence for primitive separation and guarded transitions. NAO's approximately 83 Hz position/stiffness boundary and fixed morphology do not transfer as an MIT tuple implementation. |

The league evidence does not select a universal gait. It shows that mature teams retain multiple motion families behind explicit arbitration and that position-centric competition code must be adapted deliberately for torque-capable MIT actuators.

### Mapping each lane to the accepted MIT tuple

The accepted drive relation is

$$
{} \tau_j = K_{p,j}(q_{d,j}-q_j) + K_{d,j}(\dot q_{d,j}-\dot q_j) + \tau_{ff,j}.
$$

| Lane | $q_d,\dot q_d$ owner | $\tau_{ff}$ owner | $K_p,K_d$ owner | Double-counting rule |
| --- | --- | --- | --- | --- |
| Keyframe/analytical/LIPM | Deterministic trajectory sampler at 200 Hz; source trajectories must be at least velocity-continuous | Initially zero; later identified inverse-dynamics feed-forward only after model qualification | Qualified gain schedule selected by primitive, support phase, joint, and transition | Do not encode a stabilizing correction both as a position offset and as feed-forward torque. |
| Inverse-dynamics QP/WBC | WBC reference and deterministic sampler | Either the WBC's net torque with zero drive impedance, or only its model/feed-forward term with separately allocated drive impedance | Fixed, scheduled, or WBC-requested within a safety-approved profile | If $\tau_{ff}$ already contains joint PD feedback, the same feedback must not also appear through nonzero $K_p,K_d$. |
| End-to-end reference policy | Policy provides bounded references at its trained cadence; the tuple owner interpolates/holds exactly as represented in training and fills uncommanded joints explicitly | Zero unless feed-forward was represented in training and independently qualified | The tuple owner selects an approved profile; learned gains are a later, higher-authority policy class | A position policy is not an actuator command. Adding model torque or different gains changes its deployment dynamics and requires retraining or transfer requalification. |
| Hybrid/residual | Base controller owns the nominal reference; policy modifies one declared bounded channel | Exactly one combiner computes $\operatorname{sat}(\tau_{model}+\Delta\tau_{policy})$ when torque residuals are admitted | Base schedule unless learned gain authority is separately qualified | Residuals are added once, saturated once, and ablated against the unchanged base controller. |

Every lane must publish a complete, timestamped, sequenced, finite, joint-order-checked reference or plan. The sole 200 Hz controller still creates every all-joint tuple, and `SafetyKernel` still accepts or projects that tuple as one coupled object under ADR-002.

## Candidate toolchain and version pins

### Artifact-verified availability

The table records the smallest reproducible evidence set found in the signed Ubuntu Noble ROS snapshot dated 2026-08-24 and upstream artifacts checked on 2026-08-28. It is a candidate lock, not a claim that the stack has run on the project's Jetsons.

| Component | Candidate pin and channel | arm64 and platform status | License | Disposition and evidence confidence |
| --- | --- | --- | --- | --- |
| Base platform | JetPack 7.2.1; L4T 39.2.1; Ubuntu 24.04; CUDA 13.2.1; cuDNN 9.20.0 [T1] | Native Orin platform; Python 3.12 | NVIDIA and component-specific terms | Baseline image candidate. High artifact confidence; clean-flash reproduction remains required. |
| ROS control | `ros2_control` 4.45.2 and `ros2_controllers` 4.40.1 from ROS apt [T2] | Signed amd64 and arm64 packages | Apache-2.0 | Native plane. High artifact confidence. |
| Pinocchio | 4.0.0 from ROS apt [T3] | Signed arm64 package in the inspected Jazzy graph | BSD-2-Clause | Native rigid-body core candidate. High artifact confidence. Do not mix with conda Pinocchio 4.1.0 in one process. |
| TSID | 1.10.0 from ROS apt [T4] | Signed arm64 package | BSD-2-Clause | Native WBC candidate. High artifact confidence; allocation and latency audit still required. |
| ProxSuite | 0.6.5 from ROS apt [T5] | Signed arm64 package | BSD-2-Clause | Native dense/sparse QP candidate. High artifact confidence; no upstream hard-RT guarantee. |
| OSQP fallback | `osqp_vendor` 0.2.0 Bloom revision 4, embedding OSQP 0.6.2 [T6] | Signed arm64 native library | Apache-2.0 vendor package | Add only for a measured sparse-planner need; avoid a second solver in the first controller without evidence. |
| Lightweight SIL | `mujoco_ros2_control` 0.0.3, `mujoco_vendor` 0.0.8, MuJoCo 3.4.0 from ROS apt/upstream [T7, T8] | Signed arm64 bridge/vendor packages; no CUDA requirement | Apache-2.0 bridge; Apache-2.0 MuJoCo | Native deterministic-regression candidate. Keep this generation together rather than mixing newer source releases. |
| Deployed inference | TensorRT 10.16.2 from JetPack apt [T9] | Native aarch64 with the pinned CUDA/cuDNN platform | NVIDIA terms | Preferred production inference engine after per-profile engine build and numerical comparison. Platform support is not a latency result. |
| ONNX Runtime alternative | ONNX Runtime GPU 1.29.0 from PyPI [T10] | CPython 3.12 aarch64 wheels exist; GPU wheel targets CUDA 13/cuDNN 9; JetPack execution is unproved | MIT | Optional portability path. Medium artifact confidence until run on all target profiles. |
| Crocoddyl research island | Crocoddyl 3.2.1, Pinocchio 4.1.0, TSID 1.10.0, ProxSuite 0.7.3, OSQP 1.1.3 in a locked conda-forge Python 3.12 environment [T11] | Native conda `linux-aarch64` artifacts; the inspected ROS apt Crocoddyl artifact was amd64-only | BSD-3-Clause and dependency licenses | Non-RT planner process only. Medium confidence until the exact lock is reproduced; never load apt and conda copies into one process. |
| Isaac training plane | Isaac Sim 5.1.0 and Isaac Lab 2.3.2 [T12, T13] | Supported x86_64 RTX workstation path, not native Jetson deployment | NVIDIA terms; Isaac Lab BSD-3-Clause | Offboard training and large-batch randomization only. High confidence that it is workstation-only. |
| BLF challenger | Bipedal Locomotion Framework 0.27.0 in an isolated conda environment [T14] | C++ and Python 3.12 `linux-aarch64` artifacts; upstream documents ROS/Boost conflict risk | BSD-3-Clause | Challenger only, isolated from the ROS apt process. Medium artifact confidence. |
| mc_rtc/LIPM reference | mc_rtc 2.15.2 and LIPM Walking Controller 1.7.1 [T15] | Noble amd64 packages found; no arm64 package found in the inspected channel | BSD-2-Clause | Architecture/reference implementation, not initial Jetson dependency. Source port would be project-owned. |
| OCS2 reference | OCS2 tag 12.0 [T16] | Upstream release remains catkin/`roscpp`; no Jazzy-native release found | BSD-3-Clause | Algorithmic reference only unless a deliberate ROS 2 port is staffed. |

The proposed smallest native runtime plane is therefore ROS apt `ros2_control` 4.45.2, `ros2_controllers` 4.40.1, Pinocchio 4.0.0, TSID 1.10.0, ProxSuite 0.6.5, and the pinned MuJoCo ROS generation. TensorRT is a separate non-RT inference dependency. Crocoddyl and BLF remain isolated challenger processes, while Isaac stays offboard.

Availability must be promoted to a repository lock only after CI records the apt `InRelease`, full Debian versions and SHA-256 values, source commit hashes, conda lock, Python wheels, TensorRT engine build inputs, compiler, ABI, and target image digest.

## Minimum compute envelopes

The literature provides feasibility clues but no complete Orin timing result. The following are **project targets**, not sourced performance claims.

| Profile | Hardware role | Required isolation and invariant |
| --- | --- | --- |
| P0 Minimum | Jetson Orin Nano 8 GB | One isolated CPU core for the 200 Hz controller and `SafetyKernel`; a separate CPU/IRQ allocation for transport; CPU-only hard path; GPU work is optional and may never delay the hard path. This profile must always support deterministic stand, stop, brace, and the primary classical gait. |
| P1 Balanced | Jetson Orin NX 16 GB | P0 isolation plus dedicated asynchronous planner capacity and a bounded inference stream. This is the provisional minimum production profile for concurrent centroidal MPC or hybrid learning until P0 measurements disprove that conservatism. |
| P2 Research | Jetson AGX Orin | P0 isolation plus capacity for larger planners, trackers, and instrumentation. More compute does not relax the 5 ms actuator deadline, reaction deadlines, or minimum-profile compatibility of safety primitives. |

The shared admission envelope is:

$$
C_{read}+C_{estimate}+C_{realize}+C_{safety}+C_{write}+M \le 5\ \mathrm{ms},
$$

where $M$ is measured scheduler, transport, and jitter margin. The architecture proposal may allocate internal stage targets, but release evidence must report maximum observed time and distributions for the complete cycle. For asynchronous work with update period $T_u$, the initial admission rule is $C_{max}\le0.5T_u$ with one previously validated plan always available; this is a headroom rule, not a real-time guarantee.

| Candidate runtime | Minimum admission profile | Hard-loop work | Asynchronous envelope | Promotion condition |
| --- | --- | --- | --- | --- |
| Keyframe or analytical commissioning | P0 | Prevalidated interpolation, contact guard, gain schedule, tuple synthesis | Optional trajectory preparation only | Required on P0; zero dependence on optimizer, inference, middleware, or filesystem after activation. |
| Closed-loop LIPM/DCM plus IK/WBC | P0 | 200 Hz state/reference realization and bounded IK/WBC | Footstep/preview update selected by profiling, initially no faster than needed | Pass full P0 thermal/load cycle test with at least 40% measured CPU-time margin in each reserved execution partition. |
| Centroidal MPC plus WBC | P1 provisional; P0 evaluation allowed | Same bounded 200 Hz WBC; never waits for optimizer | Measured 20-50 Hz class is plausible from literature, but the project rate is selected only from target traces | Promote on P0 only if it beats the primary gait and preserves the same 40% resource headroom and all deadlines. |
| Whole-body DDP/MPC | P2 research only | Cached feedback policy or trajectory sampling only | Optimizer may overrun or skip publication without affecting the hard loop | Must show bounded plan age and outperform centroidal MPC before any lower-profile production claim. |
| Compact learned reference | P0 challenger | Validate, interpolate/hold, fill all joints, select qualified gains, synthesize tuple | Default experiment cadence 50 Hz because several cited systems use it; actual cadence must match training and profiling | Warmed inference, normalization, artifact, OOD, dual-simulator, and fallback gates pass under full P0 load with 40% partition headroom. |
| Hybrid/residual controller | P1 provisional | Deterministic base plus one bounded residual combiner | Base planner and policy run concurrently; neither can block realization | Advance only if ablation shows a material physical improvement over the unchanged base without extra safety interventions or deadline-tail regression. |

Training is outside every onboard profile. Isaac Lab training runs on a pinned x86_64 RTX workstation. MuJoCo regression, policy export checks, and warmed inference benchmarks run both in CI and on each target Jetson.

## Dual-simulator evidence and implications

- Isaac Lab provides the relevant high-throughput training, domain-randomization, and GPU-parallel environment on its supported workstation platform [T12, T13]. It is not a Jetson runtime dependency.
- MuJoCo has a lightweight native arm64 path and a Jazzy `ros2_control` bridge generation [T7, T8]. It is the better candidate for controller SIL, deterministic regression, and an independent dynamics/contact oracle.
- A simulator-native USD or MJCF file cannot be the independent physical truth. Both must be generated from one schema-validated robot model plus explicit simulator overlays.
- Cross-simulator agreement is evidence against conversion defects, not proof that either simulator matches hardware. Hardware identification and held-out correlation remain the authority.

## Falsifiable research hypotheses and qualification gates

These targets shape the Topic 3 proposal; they are not accepted decisions yet.

1. **Model gate:** no dynamic gait enters hardware until joint identity/sign/offset, topology, limits, frame transforms, sole geometry, and actuator command semantics are verified. Model-based dynamics and learning transfer wait for the later mass, actuator, contact, and correlation gates.
2. **Complete-cycle gate:** run at least $10^6$ consecutive 200 Hz cycles under representative concurrent load and thermal soak. Pass only with zero missing writes, partial tuples, stale fields, post-activation allocation, or maximum cycle above 5 ms. Report p50, p95, p99, p99.9, maximum, sample count, and test manifest.
3. **Artifact gate:** pin source, weights, checksums, exporter/opset, observation and joint order, normalization, action scaling, gain profile, simulator versions, and compiler/runtime. A clean machine must reproduce expected actions for a fixed observation corpus.
4. **Dual-simulator gate:** replay identical seeds, commands, perturbations, and controller binaries in Isaac Lab and MuJoCo. Compare action, contact sequence, state trajectory, termination, and recovery metrics against preregistered tolerances.
5. **Fault gate:** inject late, lost, duplicated, reordered, stale, non-finite, and infeasible plans or policy samples at every contact phase. The RT owner must reject them without waiting and preserve ADR-002 containment and reaction deadlines.
6. **Analytical-feedback hypothesis:** on normalized turf and disturbance trials, closed-loop feedback must reduce falls by at least 50% and peak base tilt by at least 25% versus its open-loop ablation. Otherwise the open-loop form remains commissioning-only.
7. **Model-based challenger hypothesis:** on identical physical trials, LIPM/DCM or centroidal MPC must reduce fall count or normalized DCM/CoP error by at least 30% over the simpler qualified baseline without more safety interventions or any deadline regression.
8. **Learning hypothesis:** a learned or residual challenger must materially improve a preregistered soccer metric over its unchanged deterministic base, survive OOD and ablation tests, and fall back deterministically. Simulated reward or team-level match outcome alone cannot satisfy this gate.
9. **Target-compute gate:** repeat deployment, numerical, latency, memory-pressure, power-mode, thermal, eight-hour soak, and failure-injection tests on P0, P1, and P2. A package existing for arm64 is not evidence that this gate passed.

## Open questions and evidence gaps

- The production joint tree, motor map, and mechanism type do not yet exist.
- The physical and electrical robot envelope is not measured.
- Team capacity and a dated competition milestone are not committed.
- No locomotion candidate has been benchmarked on the pinned Orin Nano 8 GB image under concurrent robot load.
- No actuator, contact, or cross-simulator system-identification data exists for this robot.
- No source establishes a complete 5 ms bound for Pinocchio, TSID, a solver, estimation, safety, and `Stm32SerialTransport` on any target profile.
- The required estimator state, contact-sensing hardware, timing synchronization, and observability are not yet defined.
- The production sole material, turf friction distribution, compliance, backlash, thermal limits, battery sag, and impact loads are unknown.
- The 2026 Rhoban RL-walk TDP lacks a public, pinned runtime artifact and isolated performance telemetry.
- Bit-Bots' public 2026 integration history postdates parts of its TDP; repository integration and match deployment must remain separate claims.
- The inspected NimbRo public control repository is older than the 2023 competition software, so it is an architectural reference rather than a reproducible release image.
- Crocoddyl, BLF, ONNX Runtime GPU, and all mixed apt/conda boundaries still require ABI and process-isolation proof on Jetson.
- No finding materially contradicts ADR-001, ADR-002, or ADR-003. The evidence instead reinforces multirate planning above one 200 Hz owner, independent safety, and exclusion of middleware from the hard path.

## References

### Controller and learning literature

- **C1:** S. Kajita et al., "Biped Walking Pattern Generation by Using Preview Control of Zero-Moment Point," ICRA 2003. [DOI](https://doi.org/10.1109/ROBOT.2003.1241826)
- **C2:** P. Allgeuer and S. Behnke, "Omnidirectional Bipedal Walking with Direct Fused Angle Feedback Mechanisms," 2018. [arXiv](https://arxiv.org/abs/1809.10712)
- **C3:** C. Graf and T. Roefer, "A Closed-loop 3D-LIPM Gait for the RoboCup Standard Platform League Humanoid," 2012. [Paper](https://www.informatik.uni-bremen.de/kogrob/papers/RC-Graf-Roefer-11.pdf)
- **C4:** A. Herzog et al., "Momentum Control with Hierarchical Inverse Dynamics on a Torque-Controlled Humanoid," Autonomous Robots, 2016. [arXiv](https://arxiv.org/abs/1410.7284)
- **C5:** S. Caron, A. Kheddar, and O. Tempier, "Stair Climbing Stabilization of the HRP-4 Humanoid Robot using Whole-body Admittance Control," ICRA 2019. [DOI](https://doi.org/10.1109/ICRA.2019.8794348) [arXiv](https://arxiv.org/abs/1809.07073)
- **C6:** J. Koenemann et al., "Whole-body Model-predictive Control Applied to the HRP-2 Humanoid," IROS 2015. [DOI](https://doi.org/10.1109/IROS.2015.7353843)
- **C7:** R. Grandia et al., "Feedback MPC for Torque-Controlled Legged Robots," IROS 2019. [DOI](https://doi.org/10.1109/IROS40897.2019.8968251) [arXiv](https://arxiv.org/abs/1905.06144)
- **C8:** E. Dantec et al., "Whole-Body Model Predictive Control for Biped Locomotion on a Torque-Controlled Humanoid Robot," Humanoids 2022. [DOI](https://doi.org/10.1109/Humanoids53995.2022.10000129) [Manuscript](https://hal.science/hal-03724019v2)
- **C9:** C. Mastalli et al., "Inverse-Dynamics MPC via Nullspace Resolution," IEEE Transactions on Robotics 39(4), 2023. [DOI](https://doi.org/10.1109/TRO.2023.3262186) [arXiv](https://arxiv.org/abs/2209.05375)
- **C10:** C. S. Wang et al., "Berkeley Humanoid: A Research Platform for Learning-based Control," 2024. [arXiv](https://arxiv.org/abs/2407.21781)
- **C11:** T. Haarnoja et al., "Learning Agile Soccer Skills for a Bipedal Robot with Deep Reinforcement Learning," Science Robotics, 2024. [arXiv](https://arxiv.org/abs/2304.13653)
- **C12:** J. F. Lafleche et al., "FRASA: An End-to-End Reinforcement Learning Agent for Fall Recovery and Stand-up of Humanoid Robots," 2024/2025. [arXiv](https://arxiv.org/abs/2410.08655) [Repository](https://github.com/Rhoban/frasa)
- **C13:** G. Margolis and P. Agrawal, "Walk These Ways: Tuning Robot Control for Generalization with Multiplicity of Behavior," CoRL 2022. [arXiv](https://arxiv.org/abs/2212.03238) [Repository](https://github.com/Improbable-AI/walk-these-ways)
- **C14:** T. He et al., "ASAP: Aligning Simulation and Real-World Physics for Learning Agile Humanoid Whole-Body Skills," 2025. [arXiv](https://arxiv.org/abs/2502.01143) [Repository](https://github.com/LeCAR-Lab/ASAP)
- **C15:** M. Farshidian et al., "Real-Time Motion Planning of Legged Robots: A Model Predictive Control Approach," 2017. [arXiv](https://arxiv.org/abs/1710.04029)
- **C16:** R. Grandia et al., "Frequency-Aware Model Predictive Control," 2018. [arXiv](https://arxiv.org/abs/1809.04539)
- **C17:** C. Mastalli et al., "Crocoddyl: An Efficient and Versatile Framework for Multi-Contact Optimal Control," ICRA 2020. [Repository](https://github.com/loco-3d/crocoddyl)
- **C18:** J. Englsberger et al., "Three-Dimensional Bipedal Walking Control Based on Divergent Component of Motion," IEEE Transactions on Robotics, 2015. [DOI](https://doi.org/10.1109/TRO.2015.2405592)

### League and implementation sources

- **L1:** P. Ficht et al., NimbRo AdultSize 2023 competition system, published 2024. [arXiv](https://arxiv.org/abs/2401.05909) [Control repository](https://github.com/AIS-Bonn/humanoid_op_ros)
- **L2:** NimbRo direct centroidal and push-recovery work. [arXiv](https://arxiv.org/abs/2208.04757) [arXiv](https://arxiv.org/abs/2312.11019)
- **L3:** Rhoban 2023 walking architecture. [arXiv](https://arxiv.org/abs/2402.00612) [FootstepNet repository](https://github.com/Rhoban/footstepnet_envs) [PlaCo repository](https://github.com/Rhoban/placo)
- **L4:** Rhoban, RoboCup Humanoid League 2026 Team Description Paper. [Official TDP](https://hsl.robocup.org/wp-content/uploads/2026/03/Rhoban-tdp-697b1d1fd9897.pdf)
- **L5:** Hamburg Bit-Bots, RoboCup Humanoid League 2026 Team Description Paper. [Official TDP](https://hsl.robocup.org/wp-content/uploads/2026/03/Hamburg_Bit_Bots-tdp-697e116dbb78d.pdf)
- **L6:** Hamburg Bit-Bots motion stack and audited 2026 integration. [Repository](https://github.com/bit-bots/bitbots_main/tree/main/src/bitbots_motion/bitbots_rl_motion) [Final-match integration commit](https://github.com/bit-bots/bitbots_main/commit/79410acf2c8534b97ab2e34df316789645fb6f65)
- **L7:** B-Human 2025 code release and keyframe engine. [Repository](https://github.com/bhuman/BHumanCodeRelease) [Keyframe engine](https://github.com/bhuman/BHumanCodeRelease/tree/master/Src/Modules/MotionControl/KeyframeMotionEngine)

### Toolchain and platform sources

- **T1:** NVIDIA, JetPack 7.2.1 release page. [Documentation](https://developer.nvidia.com/embedded/jetpack/downloads/archive-7.2.1)
- **T2:** ROS Controls release sources. [`ros2_control` 4.45.2](https://github.com/ros-controls/ros2_control/tree/4.45.2) [`ros2_controllers` 4.40.1](https://github.com/ros-controls/ros2_controllers/tree/4.40.1)
- **T3:** Pinocchio 4.0.0. [Source](https://github.com/stack-of-tasks/pinocchio/tree/v4.0.0)
- **T4:** TSID 1.10.0. [Source](https://github.com/stack-of-tasks/tsid/tree/v1.10.0)
- **T5:** ProxSuite 0.6.5. [Source](https://github.com/Simple-Robotics/proxsuite/tree/v0.6.5)
- **T6:** Jazzy OSQP vendor release source. [Release repository](https://github.com/ros2-gbp/osqp_vendor-release/tree/581a58b5467b5dcdca551e613b4bb1e4d47e30e0)
- **T7:** ROS Controls MuJoCo bridge. [Repository](https://github.com/ros-controls/mujoco_ros2_control)
- **T8:** MuJoCo 3.4.0. [Release](https://github.com/google-deepmind/mujoco/releases/tag/3.4.0)
- **T9:** NVIDIA TensorRT support matrix. [Documentation](https://docs.nvidia.com/deeplearning/tensorrt/latest/getting-started/support-matrix.html)
- **T10:** ONNX Runtime GPU 1.29.0. [PyPI](https://pypi.org/project/onnxruntime-gpu/1.29.0/) [CUDA execution provider](https://onnxruntime.ai/docs/execution-providers/CUDA-ExecutionProvider.html)
- **T11:** Crocoddyl conda-forge package. [Package](https://anaconda.org/conda-forge/crocoddyl) [Source](https://github.com/loco-3d/crocoddyl/tree/v3.2.1)
- **T12:** Isaac Sim 5.1.0 system requirements. [Documentation](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/requirements.html)
- **T13:** Isaac Lab 2.3.2. [Release](https://github.com/isaac-sim/IsaacLab/releases/tag/v2.3.2)
- **T14:** Bipedal Locomotion Framework 0.27.0 source pin. [Source](https://github.com/ami-iit/bipedal-locomotion-framework/tree/7e0ee4dcc45ac4a31b9ab2616d59073f50937e8b)
- **T15:** mc_rtc and LIPM Walking Controller. [mc_rtc 2.15.2](https://github.com/jrl-umi3218/mc_rtc/tree/v2.15.2) [LIPM 1.7.1](https://github.com/jrl-umi3218/lipm_walking_controller/tree/v1.7.1)
- **T16:** OCS2 12.0. [Source](https://github.com/leggedrobotics/ocs2/tree/12.0)
- **T17:** ROS Jazzy release manifest. [rosdistro](https://raw.githubusercontent.com/ros/rosdistro/master/jazzy/distribution.yaml)
