# Precise KV-cache-aware routing for a wide-EP DP deployment

A validated example of precise (KV-event-fed) prefix-cache-aware routing on a
data-parallel, expert-parallel GLM-5.2-FP8 deployment with P/D
disaggregation. The EPP maintains an exact per-rank index of cached KV blocks
from the engines' ZMQ KV-event streams and routes each request to the
endpoint holding the longest cached prefix, balanced against in-flight load.
No KV offloading and no P2P transfer are involved.

## Deployment shape

| component | manifest | shape |
|---|---|---|
| prefill | `manifests/lws-prefill.yaml` | 2 x LWS, one pod each: DP=8, EP enabled, TP=1, 8 GPU + 8 IB per pod, MTP speculative decoding, `--block-size 64` |
| decode | `manifests/lws-decode.yaml` | 2 x LWS, same DP/EP shape, plus the `routing-proxy` sidecar that serves per-rank ports 8000-8007 and orchestrates the prefill call |
| EPP | `manifests/epp.yaml` + `manifests/precise-routing.yaml` | endpoint picker with `precise-prefix-cache-producer`, `prefix-cache-affinity-filter`, `token-load-scorer`; envoy front container |
| tokenizer render | `manifests/render.yaml` | pod-less Service fronting the prefill model servers' `/v1/*/render` endpoints for the EPP-side `token-producer` |
| pool / RBAC / SA | `manifests/inferencepool.yaml`, `manifests/epp-rbac.yaml`, `manifests/sa-engine.yaml` | InferencePool (`inference.networking.k8s.io/v1`), namespaced EPP RBAC, engine service account |
| envoy config | `manifests/envoy-config.yaml` | listener wiring for the EPP ext-proc |

Engines transfer prefill-to-decode KV over `NixlConnector`; requests enter
through envoy, the EPP picks the prefill and decode endpoints, and the decode
pod's routing proxy drives the prefill call.

## Prerequisites

- **EPP: a nightly build containing llm-d-router#2233.** Each engine pod
  serves DP ranks on distinct ports, and every rank publishes its own
  KV-event stream. Before #2233 the EPP attributed those per-rank streams to
  the wrong serving endpoint, leaving the precise index silently
  misattributed under exactly this deployment shape. Releases through
  v0.26.0 do not include it.
- **vLLM: a recent nightly.** The deployment relies on
  `--data-parallel-multi-port-external-lb`, per-rank ZMQ KV-event publishers,
  and `--data-parallel-start-rank` for multi-pod DP groups.
- **`--block-size 64` on every engine and `blockSize: 64` in the EPP's
  `tokenProcessorConfig`.** The index is keyed by block hashes; a mismatch
  leaves the index empty with no error anywhere.
- **Identical `PYTHONHASHSEED` on every engine pod** so block hashes agree
  across processes.
- **`podCacheSize` at least (endpoints x tiers).** The per-key LRU of block
  holders defaults small; undersizing silently evicts real holders on larger
  fleets. The config ships 128 for this 4-pod cell.

## Tokenizer render: served by the model servers

Every request is tokenized before it is routed, so the render call sits
inside TTFT. Following llm-d/llm-d#2188, the render Service owns no pods: it
fronts the prefill model servers, which expose vLLM's `/v1/*/render`
endpoints natively, so render capacity scales with the serving fleet instead
of saturating a separately-scheduled pool. Prefill pods are selected rather
than decode because the decode pods' port 8000 belongs to the routing-proxy
sidecar. Notes:

- Tokenization CPU competes with serving on the prefill pods; the render
  call is a synchronous hop to a serving pod on the request path.
- Until the first prefill is Ready the Service has no endpoints and
  `token-producer` calls fail - deploy order below accounts for this only
  at steady state, so expect routing to start working once prefills are up.
- A dedicated GPU-less `vllm launch render` pool remains an option when
  serving CPU is contended; if used, size it to the request rate - a
  saturated render stalls every request at the EPP's 5s render timeout and
  TTFT plateaus flat at that value while engines idle.

## CPU-tier weight in the precise index

The precise index scores endpoints by a device-tier-weighted block count:
blocks resident in GPU count 1.0 and blocks held only in the CPU tier count
0.8 by default, so the affinity scoring mildly prefers a GPU-resident holder
over one that must restore from CPU. The weights are configurable on the
producer:

```yaml
- type: precise-prefix-cache-producer
  parameters:
    indexerConfig:
      kvCacheBackendConfigs:
      - name: gpu
        weight: 1.0
      - name: cpu
        weight: 0.8
```

Raise the CPU weight toward 1.0 when CPU-tier restores are cheap relative
to recompute (large prefixes, fast host memory) so CPU-tier holders attract
their prefixes' requests; lower it when restores are expensive enough that
a marginally-shorter GPU-resident match should win.

## Data-parallel ranks and port binding

vLLM binds each rank-indexed auxiliary listener - the ZMQ KV-event publisher
here - at `configured base + global data-parallel rank`. On a single-pod DP
group the global rank equals the local rank and any base works. On multi-pod
DP groups (LWS wide-EP), every pod receives the same configured base while
its ranks carry a global-rank offset of `LWS_WORKER_INDEX * DP_SIZE_LOCAL`,
so an uncompensated base lands the publishers on the wrong ports and the EPP
subscribes to sockets nothing binds. See llm-d-router#2227 for the same
divergence on another rank-indexed listener.

Both engine manifests compensate in the launch script:

```bash
START_RANK=$(( ${LWS_WORKER_INDEX:-0} * DP_SIZE_LOCAL ))
KV_EVENTS_BASE=$((5557 - START_RANK))
```

so each pod's ranks publish on local ports `5557..5557+DP_SIZE_LOCAL-1`,
matching the EPP's `podDiscoveryConfig.socketPort: 5557`.

## Deploy

```bash
NS=<namespace>
kubectl create namespace $NS
kubectl -n $NS create secret generic llm-d-hf-token --from-literal=HF_TOKEN=<token>
kubectl -n $NS apply -f manifests/sa-engine.yaml
kubectl -n $NS create configmap epp-config --from-file=precise-routing.yaml=manifests/precise-routing.yaml
kubectl -n $NS apply -f manifests/envoy-config.yaml
kubectl -n $NS apply -f manifests/render.yaml
kubectl -n $NS apply -f manifests/epp-rbac.yaml
kubectl -n $NS apply -f manifests/epp.yaml        # set --pool-namespace to $NS first
kubectl -n $NS apply -f manifests/inferencepool.yaml
kubectl -n $NS apply -f manifests/lws-prefill.yaml
kubectl -n $NS apply -f manifests/lws-decode.yaml
```

Engine boot is roughly 15-25 minutes per pod (weights, DeepEP/NVSHMEM init,
CUDA graphs).

## Verify the precise index is live

Routing quality degrades silently when the event streams are not connected,
so verify the mechanism before trusting any behavior.

1. **Every rank's KV-event socket is subscribed.** The EPP should hold one
   ZMQ connection per rank per engine pod (32 for this 4-pod x DP8 cell):

   Check from the engine side (works with distroless EPP images), counting
   established connections from the EPP pod IP near the KV-events port range:

   ```bash
   EPP_IP=$(kubectl -n $NS get pod -l app=<epp-app-label> -o jsonpath='{.items[0].status.podIP}')
   kubectl -n $NS exec <engine-pod> -c vllm -- python3 -c "
   hx=''.join(f'{int(o):02X}' for o in reversed('$EPP_IP'.split('.')))
   print(sum(1 for l in open('/proc/net/tcp')
             if len(l.split())>3 and l.split()[3]=='01'
             and l.split()[2].split(':')[0]==hx))"
   # expect DP_SIZE_LOCAL KV-event connections per engine pod
   ```

   Poll it rather than sampling once - subscriptions are not established the
   moment engines report Ready, and a single early sample reads 0. A stable
   count below the expected total means a pod's publishers are on the wrong
   ports (see the ranks section above).

2. **The index scores real prefixes.** Send the same long prompt twice and
   watch the EPP debug logs score a non-zero prefix match on the second
   request, or compare `vllm:prefix_cache_hits` deltas on the routed pod.

3. **Affinity + load routing behaves.** Repeated distinct-session requests
   with a shared prefix should concentrate on the prefix holder until its
   modeled load (`token-load-scorer` with `peakPrefillThroughput`) pushes
   overflow to other pods.
