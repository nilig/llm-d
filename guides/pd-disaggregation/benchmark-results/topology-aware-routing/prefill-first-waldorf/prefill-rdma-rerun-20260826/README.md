# Prefill-first topology-aware P/D routing over RDMA

Date: 2026-08-26

Cluster and namespace: `waldorf_US-EAST-04A`,
`nilig-topology-prefill-first`

Status: complete. Three balanced blocks compared the no-topology baseline,
the strict topology filter, and the topology scorer. All nine accepted runs
completed 4,800 requests without inference failures, for 43,200 successful
requests in total.

## Result

The scorer changed routing without a measurable performance change. It
reduced cross-node P/D pairings from 50.1% in the baseline to 27.0%, while
its paired mean-latency and achieved-QPS confidence intervals included zero.

The strict filter selected no remote route in 13,999 observed routing events,
but it reduced load-balancing freedom and consistently regressed mean
latency. Relative to the baseline in the same block, it added 110.7 ms to
mean TTFT (95% CI: 59.0 to 162.5 ms) and 98.9 ms to mean request latency
(95% CI: 36.8 to 161.0 ms). Neither topology policy improved tail latency.

The transport gate did not demonstrate a faster same-node KV data path. UCX
selected `rc_mlx5` for the large CUDA-to-CUDA `ucp_get` payload on both
same-node and cross-node P/D routes. The result therefore evaluates topology
routing over RDMA; it does not evaluate a CUDA IPC or NVLink fast path.

## Deployment

- Model: `openai/gpt-oss-120b`
- Model server: vLLM `v0.23.0`
- Router and sidecar: llm-d Router `v0.10.0`
- GPUs: two 8 x H200 nodes, `gd91fda` and `gf41fb2`
- Layout per node: four TP1 prefill pods and one TP4 decode pod
- Stage order: `prefill-first`
- KV connector: NIXL with CUDA buffers and the UCX backend selected explicitly
- UCX transports: `rc,sm,cuda_ipc,cuda_copy,tcp`
- Workload: 8,192 input tokens, 256 requested output tokens, 40 offered QPS,
  120 seconds, and 4,800 requests per run

Within each uninterrupted segment, model pods stayed fixed and warm and only
the router was restarted between policies. A full workload PVC required a
controlled scale-down and warm restart before the final block-3 baseline and
filter cells. The same manifests, model-weight PVC, and persistent vLLM
compile cache were used, and all ten model pods had zero restarts before
traffic resumed. No model pod changed during an accepted run.

With `stageOrder: prefill-first`, the router chooses a prefill worker first.
The topology plugin therefore runs in the decode scheduling profile and uses
the chosen prefill's `llm-d.ai/topology-slice` value:

- Baseline: prefix and queue scorers, without a topology plugin
- Filter: `topology-affinity-filter` with `minAffinity: host`
- Scorer: `topology-affinity-scorer` with weight 1

## Method

The three blocks used balanced policy orders to limit order and cluster-drift
effects:

1. Filter, scorer, baseline
2. Baseline, filter, scorer
3. Scorer, baseline, filter

An accepted run required a successful benchmark command, 4,800 completed
requests, zero inference failures, at least 38 achieved QPS, no unresolved
routes, no model-pod restart or UID change, and at least 90% route-log
coverage. Two harness attempts exited nonzero and were excluded before
acceptance; they are recorded in `attempts.tsv`.

## Per-run results

| Block | Policy | Observed local / remote | Achieved QPS | Mean TTFT | p99 TTFT | Mean request latency | p99 request latency |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | Filter | 4,800 / 0 | 39.318 | 1.790 s | 5.940 s | 3.761 s | 7.961 s |
| 1 | Scorer | 3,530 / 1,270 | 39.261 | 1.578 s | 4.823 s | 3.551 s | 6.941 s |
| 1 | Baseline | 2,388 / 2,412 | 39.238 | 1.686 s | 4.929 s | 3.656 s | 7.011 s |
| 2 | Baseline | 2,431 / 2,369 | 39.140 | 1.495 s | 4.908 s | 3.461 s | 7.209 s |
| 2 | Filter | 4,399 / 0 | 39.273 | 1.630 s | 4.683 s | 3.581 s | 6.841 s |
| 2 | Scorer | 3,430 / 1,370 | 38.942 | 1.840 s | 5.170 s | 3.803 s | 7.322 s |
| 3 | Scorer | 3,558 / 1,242 | 39.043 | 1.480 s | 4.660 s | 3.439 s | 6.761 s |
| 3 | Baseline | 2,365 / 2,435 | 39.025 | 1.583 s | 4.399 s | 3.552 s | 6.576 s |
| 3 | Filter | 4,800 / 0 | 39.213 | 1.677 s | 4.949 s | 3.623 s | 6.885 s |

Only 4,399 routing events were retained for the block-2 filter row. Its
aggregate report still contains all 4,800 successful requests. Route coverage
across the three filter runs is 97.2%, and none of the observed events is
remote.

## Policy means

The latency percentiles below are arithmetic means of the three run-level
percentiles, not percentiles pooled across 14,400 requests.

| Policy | Observed remote routes | Achieved QPS | Mean / p50 / p90 / p99 TTFT | Mean / p50 / p90 / p99 request latency | Mean TPOT |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline | 7,216 / 14,400 (50.1%) | 39.134 | 1.588 / 1.332 / 2.923 / 4.746 s | 3.556 / 3.309 / 4.968 / 6.932 s | 7.470 ms/token |
| Scorer | 3,882 / 14,400 (27.0%) | 39.082 | 1.633 / 1.390 / 3.050 / 4.884 s | 3.598 / 3.359 / 5.087 / 7.008 s | 7.460 ms/token |
| Filter | 0 / 13,999 observed (0%) | 39.268 | 1.699 / 1.429 / 3.113 / 5.190 s | 3.655 / 3.402 / 5.140 / 7.229 s | 7.407 ms/token |

## Paired inference

Differences are policy minus the baseline in the same block. The 95%
confidence intervals use a two-sided Student t interval across the three
paired blocks (`n=3`, 2 degrees of freedom).

| Comparison | Metric | Mean difference | 95% confidence interval |
| --- | --- | ---: | ---: |
| Scorer - baseline | Achieved QPS | -0.052 | [-0.366, +0.261] |
| Scorer - baseline | Mean TTFT | +0.045 s (+2.8%) | [-0.600, +0.689] s |
| Scorer - baseline | p99 TTFT | +0.139 s | [-0.387, +0.665] s |
| Scorer - baseline | Mean request latency | +0.041 s (+1.2%) | [-0.606, +0.689] s |
| Scorer - baseline | p99 request latency | +0.076 s | [-0.251, +0.403] s |
| Filter - baseline | Achieved QPS | +0.133 | [+0.0001, +0.2666] |
| Filter - baseline | Mean TTFT | +0.111 s (+7.0%) | [+0.059, +0.162] s |
| Filter - baseline | p99 TTFT | +0.445 s | [-1.106, +1.996] s |
| Filter - baseline | Mean request latency | +0.099 s (+2.8%) | [+0.037, +0.161] s |
| Filter - baseline | p99 request latency | +0.297 s | [-1.341, +1.934] s |

The scorer result is neutral, not a proof of non-inferiority: with only three
blocks, its confidence intervals are too wide to establish a tight no-harm
margin. The filter's small QPS increase is not operationally meaningful and
does not offset its consistent mean-latency regression.

The block-3 scorer ran before the controlled model scale-down; its baseline
and filter ran after the warm redeployment. The configuration and persistent
caches were identical, but the process UIDs were not. Together with `n=3`,
this makes the paired intervals low-power estimates rather than definitive
production bounds.

## Transport verification

`UCX_LOG_LEVEL=info`, `UCX_PROTO_INFO=y`, and `UCX_PROTO_ENABLE=y` were
enabled for the transport gate. A representative same-node CUDA-to-CUDA KV
read was classified as `intra-node`, but its large-payload protocol table was:

```text
remote memory read by ucp_get*(multi) into cuda/GPU3 from cuda/dev[0]
65..inf | zero-copy | rc_mlx5/ibp3:1 50% on path0 and 50% on path1
```

The corresponding forced-remote requests were classified as `inter-node` and
also selected `rc_mlx5`. The endpoint advertised `cuda_ipc/cuda`, but endpoint
capabilities do not establish which lane carried the payload.

A separate 512-MiB NIXL microprobe measured 44.876 GiB/s with normal
cross-pod GPU isolation. Sharing host IPC/PID namespaces and host `/dev/shm`
alone remained on `rc_mlx5` at 44.831 GiB/s. A diagnostic-only peer-visible
arm selected `cuda_ipc/cuda` and reached 185.977 GiB/s, but that arm excluded
RDMA from `UCX_TLS` and bypassed normal Kubernetes GPU isolation. It is not a
production deployment or an auto-selection result.

NVIDIA's detailed
[Kubernetes disaggregated-communication guidance](https://docs.nvidia.com/dynamo/dev/knowledge-base/kubernetes/kubernetes-operator/disagg-communication)
recommends RDMA for separate-worker Kubernetes deployments, including
same-node cross-pod traffic, and scopes `cuda_ipc` to same-node, same-pod
communication. The peer-visible arm was a diagnostic that bypassed standard
GPU isolation, not a supported production exception. `hostIPC` alone is not
a CUDA IPC enablement switch.

The evidence supports the validation language in
[llm-d PR #2371](https://github.com/llm-d/llm-d/pull/2371): selecting CUDA
buffers and the UCX backend makes the intended configuration explicit, but it
does not enable cross-pod CUDA IPC. The base P/D manifests should remain
unprivileged; `hostIPC`, `hostPID`, host `/dev/shm`, and peer-GPU visibility
are not general-purpose YAML fixes for this deployment model.

## Interpretation

The routing behavior is established:

- The filter is strict and can reduce the usable candidate pool enough to
  regress latency.
- The scorer is soft. It substantially prefers local P/D placement while
  preserving the ability to escape for prefix and queue scores.

No topology-affinity performance gain was measured in this deployment. Both
same-node and cross-node routes selected `rc_mlx5`, and the test did not
demonstrate a faster local payload path. A performance-positive evaluation
requires a configuration where measured same-node payload time is materially
lower than cross-node payload time, or an inter-node link that is constrained
by the offered KV rate. Until that condition is verified, the scorer is the
safer policy; the strict filter should not be enabled by default.

The rare output-length maxima in the benchmark reports are approximately the
8,192-token prompt plus completion, while p50 is 251-252 tokens and p99 is
258-260. This indicates a lifecycle token-count parsing outlier, so TPOT
aggregates and tails should be interpreted cautiously. TTFT and
request-latency conclusions do not depend on that field.

## Artifacts

- `summary.tsv` contains the nine accepted runs and route counts.
- `attempts.tsv` records accepted and excluded harness attempts.
- `artifacts/reports` contains every accepted aggregate v0.2 report.
- `artifacts/harness-logs` contains the benchmark-driver log for every
  attempt, including excluded attempts.
- `artifacts/transport-gate` contains the forced-local and forced-remote
  aggregate reports.
- `artifacts/cuda-ipc-microprobe.md` contains the diagnostic transfer probe.
- `configs` contains the exact workload, load, router, deployment, and runner
  inputs.

Per-request lifecycle traces, generated kubeconfigs, and credential-bearing
setup logs are omitted. The raw traces remain in the local benchmark
workspace and exceed GitHub's per-file size limit.

## Cleanup

All four model deployments and the router deployment were scaled to zero.
The temporary PVC access pod was removed, the namespace had no remaining
pods, and both benchmark nodes were schedulable after the run.
