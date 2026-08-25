# NIXL and UCX transport evidence

The snippets below are curated from model-server and routing-proxy logs. Full
logs are omitted because UCX protocol tables and request traces are several
megabytes.

## Placement and route

The decoder and selected prefills were on `gf41fb2`:

```text
pd-pfirst-decode-1-86448f7d6f-qjz5z  10.0.3.87   gf41fb2
pd-pfirst-prefill-1-7644cf59c7-66dzl  10.0.3.66   gf41fb2
pd-pfirst-prefill-1-7644cf59c7-vwglw  10.0.3.92   gf41fb2
```

The decode proxy used NIXL V2 and sent the prefill request to a same-node
prefill:

```text
running NIXL protocol V2 url=10.0.3.66:8000
sending prefill request to=10.0.3.66:8000
```

## vLLM and NIXL configuration

vLLM parsed the explicit connector settings:

```text
kv_transfer_config=KVTransferConfig(
  kv_connector='NixlConnector',
  kv_buffer_device='cuda',
  kv_role='kv_both',
  kv_connector_extra_config={'backends': ['UCX']})
```

NIXL and vLLM reported:

```text
Backend UCX was instantiated
Registering KV_Caches. use_mla: False, kv_buffer_device: cuda, use_host_buffer: False
```

UCX received the requested diagnostic configuration:

```text
UCX_TLS=rc,sm,cuda_ipc,cuda_copy,tcp
UCX_LOG_LEVEL=info
UCX_NET_DEVICES=all
UCX_SOCKADDR_TLS_PRIORITY=tcp
UCX_PROTO_INFO=y
UCX_PROTO_ENABLE=y
```

## Intra-node endpoint

A representative worker endpoint exposed CUDA IPC together with RDMA lanes:

```text
ucp_context_0 intra-node cfg#1
rma(rc_mlx5/ibp6:1)
device(cuda_ipc/cuda)
am(rc_mlx5/... cuda_ipc/cuda)
```

This establishes CUDA IPC availability. It does not establish which lane was
selected for every KV payload.

## Transfer telemetry

Representative samples from an all-local 8K filter run:

```text
Avg xfer time (ms)=9.291, Avg MB per transfer=73.125, Throughput (MB/s)=7870.414
Avg xfer time (ms)=7.845, Avg MB per transfer=73.125, Throughput (MB/s)=9321.193
Avg xfer time (ms)=7.119, Avg MB per transfer=73.125, Throughput (MB/s)=10271.392
```

The observed range is approximately 7.9-10.3 GB/s. The logs do not show a
TCP-only fallback, but this throughput is still far below an expected
NVLink-class same-node path.
