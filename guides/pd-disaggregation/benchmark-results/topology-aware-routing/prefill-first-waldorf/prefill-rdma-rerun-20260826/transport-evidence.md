# UCX payload transport evidence

Date: 2026-08-25

The transport gate used the same vLLM image, NIXL configuration, CUDA KV
buffers, TP layout, and model as the policy matrix. It enabled:

```text
UCX_LOG_LEVEL=info
UCX_PROTO_INFO=y
UCX_PROTO_ENABLE=y
UCX_TLS=rc,sm,cuda_ipc,cuda_copy,tcp
```

## Same-node payload

The router trace mapped the selected prefill and decoder to the same physical
node. The decoder UCX table classified the connection as `intra-node`, then
selected `rc_mlx5` for the large CUDA-to-CUDA read on every TP rank. One rank
reported:

```text
[1787639312.152701] | ucp_context_0 intra-node cfg#2 | remote memory read by ucp_get*(multi) into cuda/GPU3 from cuda/dev[0]
[1787639312.152721] |                              0 | copy-out           | rc_mlx5/ibp3:1/path0
[1787639312.152721] |                          1..64 | software emulation | rc_mlx5/ibp3:1/path0
[1787639312.152722] |                        65..inf | zero-copy          | rc_mlx5/ibp3:1 50% on path0 and 50% on path1
```

The endpoint summary also contained:

```text
ucp_context_0 intra-node cfg#3 ... device(cuda_ipc/cuda) ...
```

That line advertises an available device lane. It does not override the
operation-specific table above, which records the payload protocol.

Source: local
`tmp/topology-aware-prefill-first-waldorf/transport-logs/decode-0-modelserver.log`,
lines 4,841-4,849.

## Cross-node payload

Forced-remote requests mapped the selected prefill to the other physical
node. Each TP rank reported an `inter-node` CUDA-to-CUDA `ucp_get` and selected
`rc_mlx5` for the large payload. No payload table selected TCP, POSIX shared
memory, sockets, or CUDA IPC. One rank reported:

```text
[1787640283.679660] | ucp_context_0 inter-node cfg#6 | remote memory read by ucp_get*(multi) into cuda/GPU1 from cuda/dev[0]
[1787640283.679672] |                              0 | copy-out           | rc_mlx5/ibp1:1/path0
[1787640283.679673] |                          1..64 | software emulation | rc_mlx5/ibp1:1/path0
[1787640283.679673] |                        65..inf | zero-copy          | rc_mlx5/ibp1:1 50% on path0 and 50% on path1
```

Source: local
`tmp/topology-aware-prefill-first-waldorf/transport-logs/decode-0-modelserver.log`,
lines 20,619-20,624.

The 30-request forced-local and forced-remote gates both completed without an
inference failure or model-pod change. Their aggregate request-latency reports
are stored in `artifacts/transport-gate`. These low-rate gates validate route
placement and protocol selection; their request latencies are not used as a
performance comparison.

## CUDA IPC diagnostic

A separate NIXL 512-MiB tensor probe produced:

| Pod configuration | Peer GPUs visible | Payload transport | Median GiB/s |
| --- | --- | --- | ---: |
| Standard separate pods | No | Two-rail `rc_mlx5` | 44.876 |
| Shared host IPC/PID and `/dev/shm` | No | Two-rail `rc_mlx5` | 44.831 |
| Diagnostic peer-visible arm | Yes | `cuda_ipc/cuda` | 185.977 |

The peer-visible arm excluded RDMA from `UCX_TLS`, so it demonstrates that the
hardware and runtime can transfer through CUDA IPC when peer access is
available. It does not show that UCX auto-selection would choose CUDA IPC with
the production transport set. The standard Kubernetes device allocation did
not grant peer-GPU access, and sharing host namespaces did not change that.

See `artifacts/cuda-ipc-microprobe.md` for the complete probe description.
