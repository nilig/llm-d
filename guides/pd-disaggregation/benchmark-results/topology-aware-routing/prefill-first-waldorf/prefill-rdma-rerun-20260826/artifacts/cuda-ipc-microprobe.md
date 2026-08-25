# Waldorf cross-pod CUDA IPC diagnostic

Date: 2026-08-25

Node: `gf41fb2` (`gd-8xh200ib-i128`, 8 x H200)

Image: `vllm/vllm-openai:v0.23.0`

Probe: NIXL 1.2.0 with the UCX backend, transferring a verified 512 MiB CUDA tensor. Each arm used one warm-up transfer followed by six measured transfers. `UCX_LOG_LEVEL=info`, `UCX_PROTO_INFO=y`, and `UCX_PROTO_ENABLE=y` were enabled so the selected data path was recorded.

| Arm | Pod configuration | Peer GPUs visible | Selected payload transport | Median GiB/s | Mean GiB/s |
| --- | --- | --- | --- | ---: | ---: |
| Control | Separate IPC/PID namespaces and separate `/dev/shm` | No | Two-rail `rc_mlx5` | 44.876 | 44.852 |
| Shared host namespaces | `hostIPC`, `hostPID`, and host `/dev/shm` | No | Two-rail `rc_mlx5` | 44.831 | 44.726 |
| Peer-visible | `hostIPC`, `hostPID`, host `/dev/shm`, and peer-GPU access | Yes | `cuda_ipc/cuda` | 185.977 | 186.932 |

The peer-visible CUDA IPC path was 4.14x the control median throughput. Data integrity passed in all arms.

The shared host namespaces alone did not cause UCX to select CUDA IPC. In this runtime configuration, the remote process also needed visibility of and access to the peer GPU. Once that was provided, UCX's protocol trace showed `cuda_ipc/cuda` for the 512 MiB payload rather than `rc_mlx5`.

This diagnostic shows that Waldorf has a materially faster same-node CUDA IPC
path when peer access is forced, and that the topology-aware routing deployment
did not exercise it. The peer-visible arm ran privileged with all node GPUs
visible while each pod requested four GPUs, bypassing the device isolation and
accounting of the standard separate-pod deployment. It is not a deployable
fast path.

The peer-visible arm deliberately omitted RDMA from `UCX_TLS` to test the CUDA
IPC path directly. It does not establish which transport UCX auto-selection
would choose when CUDA IPC and RDMA are both available. A full routing
benchmark requires a production-supported layout that preserves Kubernetes
GPU isolation and accounting, followed by proof that the real vLLM KV payload
selects `cuda_ipc/cuda` with the production transport set.
