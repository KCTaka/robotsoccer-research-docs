# Topic 12 Research: Development Workflow, CI/CD, and Release Management

- Status: Complete research baseline; update before any Topic 12 architecture revision
- Evidence last verified: 2026-09-01
- Scope: Research input for Topic 12; architecture proposal presented separately
- Canonical decisions: [ADR-001](../architecture/ADR-001-real-time-actuation-and-hardware-abstraction.md), [ADR-002](../architecture/ADR-002-safety-and-fault-management.md), [ADR-003](../architecture/ADR-003-zenoh-middleware.md), [ADR-005](../architecture/ADR-005-behavior-game-state-and-team-networking.md), [ADR-006](../architecture/ADR-006-runtime-and-containers.md), [ADR-007](../architecture/ADR-007-simulation-sil-hil.md), [ADR-008](../architecture/ADR-008-observability-and-operations.md)
- Related research: [Topic 9](topic-9-runtime-and-containers.md), [Topic 10](topic-10-simulation-sil-hil.md), [Topic 11](topic-11-observability-and-operations.md)

## Purpose and evidence policy

Eight ADRs now define what must be built, how it must behave, and what evidence must exist before it
ships. This topic establishes the machinery that produces that evidence, and — more usefully —
establishes what the available machinery **cannot** produce, so that no gate is written against a
capability the project does not have.

Evidence tags follow the Topic 4-11 convention:

| Tag            | Meaning                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------- |
| **[Primary]**  | Read directly from a source file, documentation file, manifest, or API response at a named URL. |
| **[Upstream]** | Stated by the maintainer or vendor in their own documentation.                                  |
| **[Derived]**  | Computed or concluded here from tagged inputs. Reasoning shown.                                 |
| **[Project]**  | A target or constraint set by this project, including the answers recorded below.               |
| **NR**         | **Not reported.** Never means zero, and never means "safe to assume".                           |

## Confirmed project inputs

Three inputs were resolved before research began, because each of them changes the answer rather than
colouring it.

| Input                     | Value                                                                                                       | Consequence                                                                                           |
| ------------------------- | ----------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| **Repository hosting**    | **GitHub, public repositories**                                                                             | Free unlimited hosted runners, including arm64. See §1.                                               |
| **Team size**             | **5-10 developers**                                                                                         | Package boundaries need enforcement, but not repository separation. See §2.                           |
| **Dedicated CI hardware** | **None. Hardware is shared and borrowed.**                                                                  | No self-hosted runner, no Jetson in CI, no permanently wired HIL rig. This is the binding constraint. |
| Native arm64 requirement  | CUDA, TensorRT, and ZED SDK layers must be built natively; emulation only for cheap layers                  | ADR-006-11                                                                                            |
| Digest pinning            | Every image and base image referenced by digest, participating in the startup interlock                     | ADR-006-10                                                                                            |
| One protocol definition   | Drives the production transport, both HIL emulators, and the firmware tests                                 | ADR-007-07                                                                                            |
| Binary identity           | The tested binary must be the shipped binary; no test flags in production components                        | ADR-007-08                                                                                            |
| Release contents          | Image digests, safety manifest, calibration digests, configuration digests, simulator version, model digest | ADR-006, ADR-007, ADR-008                                                                             |
| Licensing                 | AGPL and GPL excluded for distributed application code                                                      | Topic 5 §4.1.1                                                                                        |
| Robot model               | **Not designed.** Topic 3 Model Gate 0 is open.                                                             | Topic 3                                                                                               |

---

## 1. The CI platform, and the four limits that shape everything else

### 1.1 Native arm64 CI is available at zero cost

From GitHub's own documentation, verbatim [Primary, `github/docs`
`data/reusables/actions/supported-github-runners.md`]:

> "For public repositories, jobs using the workflow labels shown in the table below will run with the
> associated specifications. ... **Use of the standard GitHub-hosted runners is free and unlimited on
> public repositories.**"

The table's Linux rows:

| Virtual machine | CPU | Memory | Storage | Architecture | Workflow label                                                            |
| --------------- | --- | ------ | ------- | ------------ | ------------------------------------------------------------------------- |
| Linux           | 4   | 16 GB  | 14 GB   | x64          | `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-22.04`, `ubuntu-26.04` (preview) |
| Linux           | 4   | 16 GB  | 14 GB   | **arm64**    | **`ubuntu-24.04-arm`**, `ubuntu-22.04-arm`, `ubuntu-26.04-arm` (preview)  |

`ubuntu-24.04-arm` carries no preview marking, unlike `ubuntu-26.04-arm` [Primary,
`actions/runner-images` `README.md`].

**[Derived] This is the single most consequential finding in the topic.** ADR-006-11 required native
arm64 builds because QEMU emulation of CUDA, TensorRT, and ZED SDK layers is prohibitively slow. The
project has no dedicated hardware. `ubuntu-24.04-arm` is Ubuntu 24.04 Noble on arm64 — precisely the
ADR-006 target platform — and it is free and unlimited because the repositories are public. **The
constraint that would normally force a self-hosted runner does not apply.**

### 1.2 The disk, not the CPU, is the binding limit

The runner offers **14 GB of storage**, shared with the runner image's own preinstalled toolchains.

**[Derived]** Topic 9 recorded published JetPack-based Jazzy images at 5.1 GB (`ros-base`) and 5.9 GB
(`desktop`) as distributed. Container registries distribute compressed layers; the local layer store
holds them uncompressed, which is materially larger. A single job that pulls a CUDA base, adds
TensorRT and the ZED SDK, and materialises a final image holds base layers, intermediate layers, and
the output simultaneously.

**14 GB is therefore a real risk of failure for a monolithic image build, and the usable free space
must be measured before the pipeline is designed around it.** It is not a reason to abandon hosted
runners; it is a reason to split the image build so that the expensive vendor layers are built once,
on a schedule, and consumed by digest thereafter.

### 1.3 Six hours per job, hard

[Primary, `github/docs` `content/actions/reference/limits.md`]:

> GitHub-hosted runners, Job execution time, 6 hours: "Each job in a workflow can run for up to 6 hours
> of execution time. If a job reaches this limit, the job is terminated and fails."

Also: workflow run time is capped at 35 days per run, gate approval at 30 days, and self-hosted job
execution at 5 days with a 24-hour queue limit.

**[Derived]** Four vCPU compiling a ROS 2 workspace plus vendor SDK layers can approach six hours.
Combined with §1.2, the conclusion is the same: the heavy, rarely changing layers belong in a
separately versioned base image with its own schedule, not in the per-pull-request path.

### 1.4 No runner has a GPU

Every standard hosted runner in the table above is a CPU-only virtual machine. There is no NVIDIA GPU
and, obviously, no Jetson.

**[Derived] Three consequences, in increasing order of severity.**

1. **Isaac Lab cannot run in CI.** Topic 10 verified that it requires an RTX 4080 / A40 / L40S-class
   discrete GPU. Learning workloads are a manual, borrowed-hardware activity.
2. **MuJoCo SIL can run in CI, on both architectures, free.** Topic 10 selected MuJoCo as the primary
   SIL environment and regression oracle precisely because it is CPU-only. **ADR-007's primary
   verification environment is CI-compatible at zero cost.** This is a direct payoff from a decision
   made for unrelated reasons.
3. **TensorRT engines cannot be built in CI.** Engine construction requires the target GPU. With no
   dedicated Jetson runner, there is no automated path to a built engine. §3.4 addresses this.

---

## 2. Repository organisation

### 2.1 The decisive argument is ADR-007-07, not team size

The usual monorepo-versus-polyrepo debate turns on team size and build times. Here it is settled by an
accepted decision that predates the question.

ADR-007-07 requires that **one machine-readable protocol definition drives the production transport,
the Jetson-side HIL emulator, the firmware-side emulator, and the firmware tests.** ADR-002 requires a
versioned safety manifest **shared by the Jetson and the STM32**. ADR-001 requires joint identity,
units, and sign conventions to be driven by one generated artifact.

**[Derived]** Each of those is a single source of truth with consumers on both sides of the
host/firmware boundary. In a polyrepo, changing the protocol is an atomic change across four
repositories, and git provides no atomic multi-repository commit. The failure mode is not
inconvenience; it is a merged protocol change whose firmware side landed separately, which is exactly
the drift ADR-002's identity interlock exists to catch at runtime. **Catching it at runtime is a
worse outcome than not creating it.**

At 5-10 developers there is also no team boundary that repository separation would protect. The
boundary that does need protecting is the package boundary, and `CODEOWNERS` protects that inside one
repository.

**Conclusion: one repository containing the ROS 2 workspace, the STM32 firmware, the protocol and
safety manifest definitions, the generated model pipeline, and the configuration.**

### 2.2 `vcstool` has a reproducibility trap

`vcstool` is the standard mechanism for assembling a workspace from external sources. Its own
documentation states the trap, verbatim [Primary, `dirk-thomas/vcstool` `README.rst`]:

> "If the repository is currently on the tip of a branch the branch is followed. **This implies that a
> later import might fetch a newer revision if the branch has evolved in the meantime.** Furthermore if
> the local branch has evolved from the remote repository an import might not result in the exact same
> state. To make sure to store the exact revision in the exported data use the command line argument
> `--exact`."

**[Derived]** A `.repos` file whose `version` keys name branches is not a pin. It is a moving
reference that will silently produce a different workspace on a later build — the same class of defect
as an unpinned container tag, which ADR-006-10 already prohibits. **Every `.repos` file that
participates in a release must be produced with `vcs export --exact`, so that `version` holds a commit
hash.**

With §2.1's monorepo, `vcstool` is used only for genuinely external sources that are not available as
binary packages. It is not the mechanism for internal structure.

### 2.3 The build tools are not pinned by choosing a ROS distribution

Searching the Jazzy distribution manifest for the build toolchain returns released versions for the
ROS-side packages:

| Package           | Jazzy release | Package           | Jazzy release |
| ----------------- | ------------- | ----------------- | ------------- |
| `ament_cmake`     | 2.5.6-2       | `pluginlib`       | 5.4.6-1       |
| `ament_cmake_ros` | 0.12.1-1      | `rcpputils`       | 2.11.4-1      |
| `ament_lint`      | 0.17.5-1      | `ros2_control`    | 4.47.0-1      |
| `ament_package`   | 0.16.5-1      | `ros2cli`         | 0.32.12-1     |
| `launch`          | 3.4.11-1      | `ros_environment` | 4.2.1-1       |
| `osrf_pycommon`   | 2.1.7-1       | `ros_testing`     | 0.6.1-1       |

[Primary, `ros/rosdistro` `jazzy/distribution.yaml`, `release:` blocks]

**`colcon`, `rosdep`, and `vcstool` are absent from the manifest.** They are distribution-independent
tools delivered through PyPI and the ROS apt repository.

**[Derived]** Choosing Jazzy pins the ROS packages and pins nothing about the tools that build them. A
`colcon` or `rosdep` upgrade can change build behaviour without any change to the workspace or the ROS
distribution. **The build tool versions must be pinned explicitly, inside the builder image, which is
itself digest-pinned by ADR-006-10.** This is not a new mechanism; it is the existing mechanism
applied to a place nobody was looking.

---

## 3. Build, test, and the cross-compilation question

### 3.1 The official ROS cross-compilation tool is dead

`ros-tooling/cross_compile`, described as "A tool to build ROS and ROS2 workspaces for various
targets", reports `archived: true` with a last push of **2022-12-14** [Primary, GitHub repository API].

**[Derived]** Combined with §1.1, the cross-compilation lane resolves without argument: there is no
maintained ROS 2 cross-compilation tooling, and native arm64 compilation is free. **Do not
cross-compile. Build natively on `ubuntu-24.04-arm`.** This is also exactly what ADR-006-11 already
decided, for independent reasons.

QEMU emulation remains available through `docker/setup-qemu-action`, which the Docker action
documentation describes as useful "if you want to add emulation support with QEMU to be able to build
against more platforms" [Primary, `docker/build-push-action` `README.md`]. Under ADR-006-11 it is
permitted only for cheap layers.

### 3.2 The ROS CI actions do not document arm64

| Action                           | Jazzy support                                                                                  | arm64 mentions |
| -------------------------------- | ---------------------------------------------------------------------------------------------- | -------------- |
| `ros-tooling/action-ros-ci@v0.4` | Yes: `target-ros2-distro: jazzy`, base image `rostooling/setup-ros-docker:ubuntu-noble-latest` | **0**          |
| `ros-tooling/setup-ros@v0.7`     | Yes: `required-ros-distributions: jazzy`; "Jazzy requires `noble`"                             | **0**          |
| `ros-industrial/industrial_ci`   | **0 mentions of Jazzy in its README**                                                          | **0**          |

[Primary — README search across all three repositories]

**[Derived]** Neither ROS CI action documents arm64 support, and the recommended
`rostooling/setup-ros-docker` base image has no documented arm64 variant. This is **NR**, not a denial,
but it is not something to build a pipeline on.

The alternative is better anyway. ADR-006 already requires a digest-pinned builder image to exist, and
ADR-007 §8 requires the tested binary to be the shipped binary. **Running the CI build inside the
project's own builder container removes the third-party action from the critical path and makes CI and
local development byte-identical environments.** The GitHub Action layer then does only what it is
good at: checkout, container invocation, artifact handling, and caching.

### 3.3 What can be a merge gate, and what cannot

| Activity                               | Runs on hosted runners?    | Gate type                                     |
| -------------------------------------- | -------------------------- | --------------------------------------------- |
| Compile, arm64 and amd64               | Yes                        | Merge gate                                    |
| Unit and property tests                | Yes                        | Merge gate                                    |
| Lint, format, `ament_lint` 0.17.5-1    | Yes                        | Merge gate                                    |
| Generated-artifact drift check (§5.2)  | Yes                        | Merge gate                                    |
| **MuJoCo SIL regression**              | **Yes, CPU-only**          | **Merge gate**                                |
| `ReplayTransport` bit-identical replay | Yes, same architecture     | Merge gate                                    |
| Container image build                  | Yes, with §1.2 care        | Merge gate on PR, publish on release          |
| Firmware compile and unit tests        | Yes, cross toolchain       | Merge gate                                    |
| **TensorRT engine build**              | **No — no GPU**            | Not automatable. See §3.4.                    |
| **Isaac Lab training**                 | **No — no GPU**            | Manual, borrowed hardware                     |
| **HIL configurations H1, H2, H3**      | **No — no rig**            | Evidence-record gate. See §6.                 |
| Timing qualification                   | **No — not real hardware** | ADR-007-05 already forbids quoting SIL timing |

**[Derived]** The important structural point is that ADR-007's primary regression oracle lands in the
"merge gate" column. The environments that cannot be automated are the ones ADR-007 already restricted
to wall-clock evidence, which no CI runner could have provided regardless.

### 3.4 TensorRT engines have no automated path, and that is an architectural problem

With no GPU on any hosted runner and no dedicated Jetson, an engine cannot be produced by CI. Three
options exist, and two of them break accepted decisions.

| Option                                                                                                                               | Assessment                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Build the engine into the container image                                                                                            | Impossible without a GPU builder. Rejected on capability, not preference.                                                                                                                         |
| Build silently on the robot at first run                                                                                             | Produces a device-local artifact that is not in the image digest and not in the ADR-002 startup interlock. A robot could play with an engine nobody recorded. **Rejected.**                       |
| **Build on the robot in a gated commissioning step, and record the engine digest in the release manifest and the startup interlock** | Makes the non-reproducibility explicit and interlocked rather than silent. CI pins the ONNX or serialized network and the build recipe; the engine is a device-local, digest-identified artifact. |

**NR:** NVIDIA's TensorRT hardware-compatibility documentation page returned 404 during verification,
and the TensorRT repository README contains no portability statement. **No claim is made here about
the precise rules governing engine portability across GPU architecture or TensorRT version.** The
architectural conclusion does not depend on it: with no GPU in CI, the engine cannot be built there
either way.

---

## 4. Container builds and release trains

### 4.1 Available mechanisms

`docker/build-push-action` provides, verbatim from its input table [Primary]:

| Input                    | Purpose                                                                                    |
| ------------------------ | ------------------------------------------------------------------------------------------ |
| `platforms`              | "List of target platforms for build"                                                       |
| `provenance`             | "Generate provenance attestation for the build (shorthand for `--attest=type=provenance`)" |
| `cache-from`, `cache-to` | External cache sources and export destinations                                             |
| `outputs`                | Output destinations                                                                        |
| `push`, `pull`           | Registry push; always re-pull referenced images                                            |

`docker/setup-buildx-action` is "not required but recommended ... to be able to build multi-platform
images, export cache".

**[Derived]** Registry-backed cache (`cache-to type=registry`) is the mitigation for §1.2's 14 GB
limit: expensive vendor layers are restored from a registry rather than rebuilt or held on the runner
alongside everything else.

### 4.2 The dual release train

The project ships two artifact families that must move together: Jetson container images and STM32
firmware binaries. They are already coupled by accepted decisions — ADR-002's shared safety manifest,
ADR-007-07's shared protocol definition, and ADR-008 §13's requirement that rollback reverts image,
safety manifest, calibration, and configuration together.

**[Derived] The release is therefore not an image and not a binary. It is a manifest** naming, by
digest: every container image, the firmware binary, the protocol version, the safety manifest, the
calibration set, the configuration set, the robot model, the simulator version, and the TensorRT
engine identity from §3.4. This is not new; it is the union of what ADR-003, ADR-006 §10, ADR-007 §11,
and ADR-008 §13 each already require, collected into one artifact that CI produces and signs.

### 4.3 A licensing question that a public repository makes urgent

Topic 5 established that the ZED SDK is closed-source, and Topic 5 §4.1.1 excluded AGPL and GPL
precisely because copyleft cannot be distributed linked against it.

**[Derived] The converse now matters and has not been examined.** The repositories are public, and a
CI pipeline that builds and pushes a perception image would be **redistributing the ZED SDK inside a
publicly pullable container image**. Freely downloadable is not the same permission as freely
redistributable, and a public registry push is redistribution.

**NR — the Stereolabs licence terms governing redistribution inside a container image were not
obtained.** This must be resolved before any image containing the SDK is pushed to a public registry.
If redistribution is not permitted, the perception image must be built from a recipe on the robot or
in a private registry, which changes the pipeline shape.

---

## 5. Interface governance and drift prevention

### 5.1 REP-2004 provides an external standard, so the project does not have to invent one

REP-2004 defines five quality levels addressing "versioning, change control, documentation, testing,
dependencies, platform support and security" [Primary].

Quality Level 1 is "the highest quality level ... packages that are needed for production systems",
exemplified by `rclcpp`, `urdf`, and `tf2`. Its requirements include, verbatim:

> "1. **Version Policy:** i. Must have a version policy (e.g. `semver`) ii. Must be at a stable version
> (e.g. for `semver` that means version >= 1.0.0) iii. **Must have a strictly declared public API**
> iv. Must have a policy for API stability v. Must have a policy for ABI stability vi. Must have a
> policy that keeps API and ABI stability within a release"

> "4. **Testing:** i. Must have system tests which cover all items in the 'feature' documentation
> ii. Must have system, integration, and/or unit tests which cover all of the public API
> iii. Code Coverage: a. _Must have code coverage tracking for the package_ b. _Must have and enforce a
> code coverage policy for new changes_"

**[Derived]** Applying one standard uniformly across a 5-10 person project would be theatre. Applying
it **selectively, by declared level per package**, is not. The packages carrying safety authority —
`HumanoidActuatorSystem`, the `SafetyKernel`, the `ActuatorTransport` interface, the protocol
definition, and the safety manifest schema — are exactly the ones for which "strictly declared public
API", API and ABI stability policies, and enforced coverage are worth the cost. A behaviour tree node
is not.

Declaring the level in the package manifest makes the boundary visible in code review rather than in
convention, and it uses a ROS-native standard rather than a house rule.

### 5.2 Drift is prevented by regenerating and diffing, not by discipline

Three artifacts are generated and consumed across the host/firmware boundary: the protocol definition
(ADR-007-07), the safety manifest (ADR-002), and the robot model (Topic 3, blocked at Model Gate 0).

**[Derived]** The cheapest possible enforcement is also the strongest: **CI regenerates every derived
artifact from its source and fails if the result differs from what is committed.** It costs seconds,
requires no reviewer vigilance, and makes it impossible to hand-edit generated output. It is the same
mechanism as a formatting check, applied to a much more dangerous class of file.

The complement is a conformance check: the ADR-001 transport conformance suite must pass against every
transport, and ADR-007 gate 2 already requires that a deliberate sign flip in the manifest, the
simulator model, or the firmware is detected. That suite is CPU-only and therefore a merge gate.

---

## 6. HIL in a pipeline with no dedicated hardware

This is where the third project input binds hardest. ADR-007 defines three HIL configurations, and
none of them can run on a hosted runner. There is no rig to attach to a self-hosted runner either.

**[Derived] The honest resolution is to change what the gate checks, not to pretend the gate runs.**

A HIL campaign produces evidence: a dated record naming the release digest under test, the
configuration (H1, H2, or H3), the fault campaign enumerated from the ADR-002 product, the results, and
the operator. CI cannot produce that record. CI can, cheaply and reliably, **verify that such a record
exists, is signed, and names the exact digest being released.**

| Gate                          | Enforced by                                                                                           |
| ----------------------------- | ----------------------------------------------------------------------------------------------------- |
| HIL campaign performed        | A signed evidence artifact naming the release digest, checked by CI at release time                   |
| Campaign is current           | The evidence names a digest; a rebuild produces a new digest and therefore invalidates stale evidence |
| Campaign coverage is complete | Every ADR-002 fault class has a result or a written exclusion, checked structurally                   |
| Timing evidence provenance    | ADR-007-05 already forbids SIL-derived timing; the evidence must name real hardware                   |

**[Derived]** Tying the evidence to the digest is what makes this rigorous rather than decorative. It
is impossible to ship a binary that no campaign covered, because the digest would not match, and the
digest is already the release identity under ADR-006-10. The cost is that HIL becomes a deliberate,
scheduled human activity — which, with borrowed hardware, it was always going to be.

---

## 7. Supply chain and CI security

A public repository with 5-10 contributors and a safety-critical output has a materially different
threat model from a private one.

GitHub's own guidance, verbatim [Primary, `github/docs`
`content/actions/reference/security/secure-use.md`]:

> "**Pin actions to a full-length commit SHA.** Pinning an action to a full-length commit SHA is
> currently the only way to use an action as an immutable release. Pinning to a particular SHA helps
> mitigate the risk of a bad actor adding a backdoor to the action's repository, as they would need to
> generate a SHA-1 collision for a valid Git object payload."

> "a compromise of a single action within a workflow can be very significant, as that compromised action
> would have access to all secrets configured in your repository"

> "It's good security practice to set the default permission for the `GITHUB_TOKEN` to read access only
> for repository contents. The permissions can then be increased, as required, for individual jobs."

The documentation additionally notes that a tag "can be moved or deleted if a bad actor gains access to
the repository storing the action", even for verified creators, and points to OpenSSF Scorecards for
workflow dependency analysis. A dedicated documentation page exists for the hazards of
`pull_request_target`.

**[Derived] One rule, three places.** ADR-006-10 already established digest pinning for images. §2.2
established commit pinning for `.repos`. GitHub establishes SHA pinning for actions. These are the same
control applied to three different supply chains, and stating them as one invariant is both simpler and
harder to forget than three separate conventions.

**[Derived] The public-repository specific hazards** are that workflow logs and artifacts are publicly
readable, and that pull requests from forks must never receive write permissions or secrets. For this
project the second matters concretely: a fork PR that could push an image or a release manifest would
be able to reach the robot's startup interlock through the front door.

---

## 8. Falsifiable gates

| #   | Gate                                                                                                                                             | Pass condition                                                                                                                                                              |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Native arm64 build succeeds on a hosted runner.** Build the full workspace on `ubuntu-24.04-arm`.                                              | Completes within the 6-hour job limit, with measured usable disk headroom on a 14 GB runner.                                                                                |
| 2   | **Image build fits.** Build the perception image with CUDA, TensorRT, and ZED SDK layers.                                                        | Completes without exhausting runner storage, using registry-backed cache. If not, the layer split is redesigned.                                                            |
| 3   | **CI and local builds are the same environment.** Compare a CI-produced binary with one built locally in the same builder image digest.          | Identical, or every difference explained and recorded.                                                                                                                      |
| 4   | **Generated artifacts cannot drift.** Hand-edit a generated protocol or manifest file and open a pull request.                                   | CI regenerates, diffs, and fails.                                                                                                                                           |
| 5   | **Sign-flip detection.** Introduce a deliberate joint sign inversion in the manifest, the simulator model, and the firmware, one at a time.      | Each is detected by the conformance suite in CI. This is ADR-007 gate 2 executed as a merge gate.                                                                           |
| 6   | **MuJoCo SIL regression is a merge gate.** Introduce a behavioural regression against a stored trajectory.                                       | Detected on a hosted runner without hardware, on both architectures.                                                                                                        |
| 7   | **Replay determinism.** Re-run a recorded control-loop log in CI on the same architecture and build.                                             | Bit-identical, per ADR-007 gate 4. Cross-architecture comparison reported separately and by tolerance.                                                                      |
| 8   | **`.repos` files are pinned.** Inspect every `.repos` file that participates in a release.                                                       | Every `version` key is a commit hash, produced by `vcs export --exact`. No branch names.                                                                                    |
| 9   | **Build tools are pinned.** Inspect the builder image.                                                                                           | `colcon`, `rosdep`, and `vcstool` versions are explicit, and the builder image is referenced by digest.                                                                     |
| 10  | **Actions are pinned.** Inspect every workflow.                                                                                                  | Every third-party action is referenced by full-length commit SHA. No tags, no branches.                                                                                     |
| 11  | **Token privilege is minimal.** Inspect repository and workflow settings.                                                                        | Default `GITHUB_TOKEN` permission is read-only; elevations are per-job and justified.                                                                                       |
| 12  | **Fork pull requests are powerless.** Open a pull request from a fork that attempts to publish an artifact.                                      | No secrets, no registry write, no release manifest write. `pull_request_target` is absent or provably safe.                                                                 |
| 13  | **HIL evidence binds to a digest.** Attempt to release a digest with no HIL campaign record, and a digest whose record names a different digest. | Both are rejected at release time.                                                                                                                                          |
| 14  | **The release manifest is complete.** Produce a release and inspect the manifest.                                                                | Names every container digest, firmware digest, protocol version, safety manifest, calibration set, configuration set, model digest, simulator version, and engine identity. |
| 15  | **Rollback works from the manifest alone.** Execute the ADR-008 §13 rollback drill using only the previous release manifest.                     | The robot reaches a passing pre-match check state within the between-matches window.                                                                                        |
| 16  | **No timing claim originates in CI.** Audit every timing figure in release evidence.                                                             | Each names real hardware. No hosted-runner or SIL figure appears, per ADR-007-05.                                                                                           |

---

## 9. Open gaps

1. **ZED SDK redistribution rights inside a public container image are NR** (§4.3). This blocks
   publishing any perception image and must be resolved before the pipeline shape is fixed.
2. **Usable disk on a 14 GB runner is unmeasured.** The runner image's preinstalled toolchains consume
   an unknown fraction, and the whole container-build lane depends on the remainder.
3. **arm64 support in `action-ros-ci`, `setup-ros`, and `setup-ros-docker` is NR.** The proposed design
   avoids depending on it, but that avoidance should be a deliberate recorded choice, not an accident.
4. **TensorRT engine portability rules are NR.** NVIDIA's hardware-compatibility page 404'd during
   verification. The engine-identity design in §3.4 is deliberately conservative for that reason.
5. **The STM32 firmware toolchain is not selected**, so the firmware CI lane is specified only by what
   it must produce, not by how.
6. **The model generation pipeline is blocked at Model Gate 0.** Its CI lane can be designed but not
   populated.
7. **HIL evidence format, signing mechanism, and staleness policy are undefined.** §6's gate is only as
   strong as the artifact it checks.
8. **Free hosted arm64 runners are a vendor policy, not a contract.** The pipeline should degrade to a
   self-hosted runner without redesign if that policy changes.
9. **Code coverage tooling behaviour on arm64 runners is unverified**, which matters for the REP-2004
   Level 1 coverage requirement in §5.1.
10. **Queue times for `ubuntu-24.04-arm` under load are NR**, which affects whether SIL regression is
    tolerable as a blocking merge gate.

---

## References

- **[S-1]** `github/docs` `data/reusables/actions/supported-github-runners.md` — hosted runner specifications, arm64 labels, and the free-and-unlimited statement for public repositories.
- **[S-2]** `actions/runner-images` `README.md` — available images, workflow labels, and preview markings.
- **[S-3]** `github/docs` `content/actions/reference/limits.md` — job execution time, workflow run time, queue and approval limits.
- **[S-4]** `github/docs` `content/actions/reference/security/secure-use.md` — commit-SHA pinning, third-party action risk, `GITHUB_TOKEN` least privilege, OpenSSF Scorecards.
- **[S-5]** `ros-tooling/action-ros-ci` `README.md` and `ros-tooling/setup-ros` `README.md` — Jazzy support, recommended base images, and the absence of any arm64 statement.
- **[S-6]** `ros-industrial/industrial_ci` `README.rst` — no Jazzy or arm64 mention.
- **[S-7]** GitHub repository API for `ros-tooling/cross_compile` — `archived: true`, last push 2022-12-14.
- **[S-8]** `dirk-thomas/vcstool` `README.rst` — `.repos` format, branch-following behaviour on import, and the `--exact` export flag.
- **[S-9]** `ros/rosdistro` `jazzy/distribution.yaml` — released versions for the ament, launch, and ros2cli toolchain; absence of `colcon`, `rosdep`, and `vcstool`.
- **[S-10]** `ros-infrastructure/rep` `rep-2004.rst` — quality level definitions and Level 1 version-policy and testing requirements.
- **[S-11]** `docker/build-push-action` `README.md` — `platforms`, `provenance`, `cache-from`, `cache-to`, and the QEMU and buildx companion actions.
- **[D-1]** [ADR-006](../architecture/ADR-006-runtime-and-containers.md) — digest pinning and the native arm64 build requirement this topic implements.
- **[D-2]** [ADR-007](../architecture/ADR-007-simulation-sil-hil.md) — the single protocol definition, binary identity, and the HIL configurations this topic must gate.
- **[D-3]** [ADR-008](../architecture/ADR-008-observability-and-operations.md) — the release manifest contents and the rollback requirement.
