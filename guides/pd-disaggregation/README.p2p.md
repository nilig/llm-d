# P/D Disaggregation: P2P Connector (CPU-offload KV transfer)

This guide deploys `meta-llama/Llama-3.1-8B-Instruct` with prefill-decode disaggregation using vLLM's `OffloadingConnector` and a P2P (ZMQ/TCP) secondary tier for KV cache transfer. Unlike the [main guide](./README.md), this path does not require RDMA networking — KV blocks are staged in CPU memory on the prefill pod and transferred to the decode pod over TCP.

**When to use this path:**
- Your cluster does not have InfiniBand or RoCE networking between pods
- You want to evaluate P/D disaggregation before investing in RDMA hardware

**Trade-off:** CPU-offload KV transfer is slower than NIXL/RDMA. For latency-sensitive production deployments with high ISL, prefer the RDMA path in [README.md](./README.md).

## Prerequisites

- vLLM image that includes `OffloadingConnector` (vllm-project/vllm#42285, vLLM >= v0.24.0)
- llm-d routing sidecar >= v0.9.0 (llm-d/llm-d-router#1888)
- At least 3 GPUs (2 prefill + 1 decode). Adjust replicas to fit your cluster.
- Decode pod must use `--data-parallel-size=1`. Wide-EP (DP > 1) is not yet supported with this connector (llm-d/llm-d-router#1889).
- A valid HuggingFace token with access to `meta-llama/Llama-3.1-8B-Instruct`
- `PYTHONHASHSEED` set to the same value on every prefill and decode pod (the overlay sets `0`). vLLM seeds block hashes per process; without a pinned seed the decoder's block hashes never match the prefiller's and every KV transfer silently falls back to local recompute.

All other prerequisites (client tools, namespace, HF token secret) are the same as the [main guide](./README.md#prerequisites).

## How it works

The routing sidecar on the decode pod orchestrates KV transfer with two concurrent HTTP legs:

1. **Prefill leg** — sent to the prefill pod with `kv_transfer_params.decode.kv_request_id`. vLLM runs the prefill, stores KV blocks in CPU memory (the `TieringOffloadingSpec` tier), and returns after 1 output token.
2. **Decode leg** — sent to the local vLLM instance with `kv_transfer_params.prefill.{kv_request_id, remote_host, remote_port}`. vLLM fetches the KV blocks from the prefill pod over ZMQ/TCP (port 7777) and generates the full response.

Both pods run vLLM with `OffloadingConnector`, `kv_role=kv_both`, and a P2P secondary tier listening on port 7777.

## Installation

Follow steps 1 (Router) and 3 (optional Monitoring) from the [main guide](./README.md). For step 2, apply the P2P overlay instead:

```bash
export GUIDE_NAME="pd-disaggregation"
export NAMESPACE="llm-d-pd-disaggregation"

kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/gpu/vllm/p2p
```

## Verification

### Check that pods are running

```bash
kubectl get pods -n ${NAMESPACE} -l llm-d.ai/guide=pd-disaggregation
```

You should see 2 prefill pods (1/1 Ready) and 1 decode pod (2/2 Ready — vLLM + routing-proxy sidecar).

### Confirm the P2P connector is active

Check the routing-proxy sidecar log on the decode pod for the startup config and per-request protocol log:

```bash
kubectl logs -n ${NAMESPACE} \
    $(kubectl get pod -n ${NAMESPACE} -l llm-d.ai/role=decode -o name | head -1) \
    -c routing-proxy
```

Expected startup line:
```
{"msg":"Proxy configuration","config":"{\"KVConnector\":\"offloading\",\"P2PConnectorPort\":7777,...}"}
```

Expected per-request line (one per inference request):
```
{"msg":"running P2P protocol","prefill_host":"<prefill-pod-ip>","kv_request_id":"<uuid>","p2p_connector_port":7777}
```

### Send a test request

```bash
export IP=$(kubectl get service ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')

curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{
        "model": "meta-llama/Llama-3.1-8B-Instruct",
        "prompt": "The quick brown fox",
        "max_tokens": 20
    }' | jq
```

## Configuration notes

### CPU memory budget (`cpu_bytes_to_use`)

The `cpu_bytes_to_use` value (200 MiB in this overlay) is the CPU memory reserved per pod for KV staging. Set it to at least the KV cache footprint of your typical request. For longer sequences or larger models, increase this value. A rough estimate: `num_layers * num_kv_heads * head_dim * 2 * seq_len * 2 bytes` (fp16).

### P2P port

Both pods listen on port 7777 (the `TieringOffloadingSpec` P2P tier port). The routing sidecar defaults to the same port (`--p2p-connector-port=7777`). If you change the port in the `kv_connector_extra_config`, set `--p2p-connector-port` to match on the sidecar.

### Scaling replicas

Adjust `spec.replicas` in `patch-prefill.yaml` and `patch-decode.yaml` to fit your cluster. A 2P:1D ratio (the default here) works well for short-to-medium ISL workloads.
