# Client, server and worker

Gday Meetings is one repository with three separately installed and deployed components. Component names describe their role; language and platform suffixes distinguish implementations. The native Rust implementation is client-macos-rust. A future client-macos-app can offer another UI without changing the server/worker contracts.

| Boundary | Client | Server | Worker |
| --- | --- | --- | --- |
| Runtime | Native Rust/macOS, embedded browser UI | Node.js, Next.js, Payload | Python, WhisperX/faster-whisper, PyTorch/pyannote |
| Location | User's machine, outside containers | Local or cloud; container optional | Local or cloud; container optional; CPU or NVIDIA GPU |
| Owns | OS capture permissions, local recording cache, user OAuth tokens | Users, files, meetings, durable tasks/results, MCP | Model cache, bounded execution queue and temporary processing files |
| Interface | Loopback browser/CLI API; OAuth client to server | Browser/admin, user-scoped HTTP API and HTTP MCP | Machine-authenticated asynchronous HTTP or RunPod transport |
| Does not require | Node/Python/model dependencies | GPU access or direct microphone access | Client login sessions or access to the CMS database |

## Main flow

1. The native client captures microphone/system audio and stores a local recording.
2. The client signs in to the server using standard OAuth/OIDC with PKCE. The server is the source of user management, with optional upstream identity providers.
3. The client uploads audio and creates a durable transcription task under its user grant.
4. The server submits the task to its configured local worker or RunPod endpoint. Worker credentials remain on the server.
5. The worker downloads the task's input URLs and processes audio. Local HTTP mode commits the output to its job database before attempting the task-scoped server callback, so polling can recover it after callback failure. RunPod mode requires the callback to succeed before reporting success.
6. The server also polls the provider and repairs interrupted result projections. The client retrieves results from the server; MCP searches the server under user OAuth.

The client can disconnect while the server and worker complete a submitted job. The worker's job database is execution/recovery state; the server's stored output is the durable meeting result. The direct RunPod workflow remains separately configured in the client for existing usage and uses apps/file-drop. It is not used by the standard client → server → worker deployment.

## Local networking and trust

SERVER_URL is the public browser/OAuth origin. The server and worker have independent Compose projects and may run on different hosts; no shared network or service DNS is assumed. A container's localhost refers to itself. SERVER_INTERNAL_URL optionally supplies an explicit server origin reachable from the worker. The server validates owned, signed input URLs against its public origin before rewriting only their origin for standalone HTTP execution. Callback URLs use the same internal origin. RunPod uses the reachable public server origin.

LOCAL_WORKER_API_TOKEN authenticates server-to-worker machine requests. It is not a client login token and grants no user access to CMS/MCP. The server passes a separate task-scoped callback token to the worker. Worker Compose publishes to host loopback by default; configure a reachable TLS endpoint or trusted private bind for remote deployment. The worker must also reach the server's download and callback origin.

## CPU and GPU

CPU mode uses int8 inference, a small default Whisper model, and batch size 1. GPU mode uses CUDA, float16, and a larger default batch/model. These are configurable presets, not different protocols. WhisperX explicitly documents [CPU/int8 operation](https://github.com/m-bain/whisperX#usage--command-line). CPU execution and diarization can be substantially slower; no throughput guarantee is made.

CPU mode does not require CUDA. Docker Desktop on a Mac does not provide the NVIDIA CUDA environment used by the GPU image; use the CPU image locally or an NVIDIA Linux worker remotely. Initial model downloads and gated diarization access still require network/authentication. “Fully local” means meeting processing/storage stay on local services, not that a fresh installation is immediately offline. Prefetch and cache all required models before offline use.

## Independent packaging

The root Makefile delegates to independent components. client-macos-rust owns its Cargo manifest/lockfile, scripts, macOS packaging and generated build directory. apps/server has its own pnpm lockfile, environment template and container configuration. worker-audio-extraction owns its Python package, environment template and CPU/GPU Compose files. The root has no language package manifest or Docker deployment files. Separate dependency trees avoid shipping the ML stack with a recorder or requiring a GPU to run the CMS.

Future server releases use server-vX.Y.Z tags and publish ghcr.io/rankun203/gday-meetings-server, with AMD64 and ARM64 manifests. Existing ghcr.io/rankun203/gday-meetings images are earlier standalone releases, not builds of uncommitted monorepo changes. The original external repository is retained as history; this repository is the source for ongoing component work. Worker deployment can build its own image or use RunPod's repository integration and the component-specific Docker context.

## Deferred data modeling

This architecture change does not implement the proposed new collections. Current shared-library authorization, archive import fields and task/result schema remain as documented by the server. The complete proposal and unresolved ownership decision are recorded in [the deferred modeling worklog](worklogs/2026-09-23-server-data-model-proposal.md).
