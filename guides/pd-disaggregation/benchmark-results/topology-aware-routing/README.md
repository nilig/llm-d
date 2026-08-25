# Topology-aware P/D routing benchmark

Date: 2026-08-24

Cluster and namespace: `kermit_US-EAST-01A`, `nilig-topology-aware`

The `configs` directory contains the deployment, router, workload, and run
inputs used for this evaluation. The `artifacts` directory contains every
valid aggregate report, stage and summary metric file, harness log, and
generated plot. Generated kubeconfigs and setup command logs are omitted; the
latter embed cluster credentials. Per-request lifecycle traces are also
omitted because the approximately 30 GB corpus contains individual files over
GitHub's 100 MB limit; the traces remain in the local benchmark workspace. Run
`python3 analyze.py` from this directory to regenerate the paired 64K summary
and confidence intervals.

## Deployment

- Model: `openai/gpt-oss-120b`
- Router: llm-d Router `v0.10.0`
- Model server: vLLM `v0.23.0`
- Node `g11bab6`: four TP1 prefills and one TP4 decoder
- Node `gf2ac9a`: four TP1 prefills and one TP4 decoder
- Routing order: decode first, then prefill
- Workload: `guide_pd-disaggregation_2.yaml`; 120 seconds at 1 request/s,
  1024 input tokens and 1024 output tokens per request

The topology extractor reads `llm-d.ai/topology-slice`, whose value is `0` on
all model pods on `g11bab6` and `1` on all model pods on `gf2ac9a`.

## Results

| Variant | Local P/D | Cross-node P/D | Mean TTFT | p99 TTFT | Mean request latency | p99 request latency | Mean TPOT | Failures |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline, first run | 62 (51.7%) | 58 (48.3%) | 149.55 ms | 799.17 ms | 4.202 s | 5.359 s | 4.041 ms | 0/120 |
| Topology filter | 120 (100%) | 0 | 96.01 ms | 107.19 ms | 4.010 s | 4.517 s | 3.919 ms | 0/120 |
| Topology scorer, weight 1 | 120 (100%) | 0 | 96.42 ms | 113.27 ms | 4.048 s | 4.413 s | 3.962 ms | 0/120 |
| Baseline, warmed order control | 66 (55.0%) | 54 (45.0%) | 96.03 ms | 114.59 ms | 4.030 s | 4.594 s | 3.932 ms | 0/120 |

The first baseline includes model-startup outliers, so the warmed baseline is
the appropriate latency control. Relative to that control, the topology filter
changed mean TTFT by -0.02% and the topology scorer changed it by +0.41%.
Those differences are noise at this workload level. The measured improvement is
therefore routing correctness: both topology variants eliminated all cross-node
P/D pairings, while the two baselines sent 45-48% of transfers across nodes.

## Routing evidence

Decode proxy `sending prefill request` entries were counted during each exact
inference-perf stage and the selected prefill IP was mapped to its Kubernetes
node.

- Baseline first run, `2026-08-24T16:39:56Z`: 62 local, 58 cross-node
- Filter, `2026-08-24T16:49:09Z`: 120 local, 0 cross-node
- Scorer, `2026-08-24T16:54:50Z`: 120 local, 0 cross-node
- Warmed baseline, `2026-08-24T17:00:21Z`: 66 local, 54 cross-node

## Interpretation

At low request rate, Kermit handles the cross-node KV transfers without a
measurable latency penalty for this workload. A follow-up saturation run is
needed to evaluate throughput and tail-latency benefits under network or queue
pressure. The filter is the strict behavior: it removes remote prefills. The
scorer kept every request local in this balanced run, but it can still select a
remote prefill when prefix-cache or queue scores outweigh topology.

## Saturation follow-up

The follow-up used 8192 input tokens, 256 requested output tokens, streaming
completions, and a 120-second constant-rate stage at each offered load. Pod
placement and model processes stayed fixed. For the forced-remote control, only
the live prefill `llm-d.ai/topology-slice` labels were inverted; a decoder proxy
trace confirmed that the selected prefill was physically on the other node.

### Forced controls

| Offered QPS | Routing | Achieved QPS | Mean TTFT | p99 TTFT | Mean request latency | p99 request latency | Failures |
|---:|---|---:|---:|---:|---:|---:|---:|
| 10 | Forced local | 9.907 | 0.429 s | 2.703 s | 1.637 s | 4.043 s | 0/1200 |
| 10 | Forced remote | 9.921 | 0.439 s | 2.957 s | 1.635 s | 3.988 s | 0/1200 |
| 20 | Forced local | 19.752 | 0.554 s | 2.921 s | 1.999 s | 4.762 s | 0/2400 |
| 20 | Forced remote | 19.677 | 0.546 s | 3.146 s | 1.991 s | 4.819 s | 0/2400 |
| 40 | Forced local | 38.960 | 1.744 s | 4.882 s | 3.693 s | 7.062 s | 0/4800 |
| 40 | Forced remote | 38.591 | 1.857 s | 4.494 s | 3.805 s | 6.512 s | 0/4800 |

At 10 and 20 QPS, local and remote means are indistinguishable. At 40 QPS,
forced remote increased mean TTFT by 6.5% and mean request latency by 3.0%, and
reduced achieved QPS by 0.9%. The p99 values did not move in the same direction,
so this is a modest mean-latency signal rather than a replicated result.

### Real policies at 40 QPS

| Policy | Observed routing | Achieved QPS | Mean TTFT | p99 TTFT | Mean request latency | p99 request latency | Failures |
|---|---|---:|---:|---:|---:|---:|---:|
| Topology filter | 0% remote | 38.960 | 1.744 s | 4.882 s | 3.693 s | 7.062 s | 0/4800 |
| Topology scorer, weight 1 | 0% remote in 1999-request sample | 38.890 | 1.801 s | 4.262 s | 3.741 s | 6.238 s | 0/4800 |
| No-topology baseline | 49.0% remote in 2132-request sample | 38.871 | 1.718 s | 5.234 s | 3.695 s | 7.358 s | 0/4800 |
| Forced remote control | 100% remote | 38.591 | 1.857 s | 4.494 s | 3.805 s | 6.512 s | 0/4800 |

The filter and scorer eliminated cross-node routing. They did not improve mean
latency or throughput over the no-topology baseline in this single run. Both
topology policies had better p99 latency than the baseline, with the scorer's
p99 request latency 15.2% lower, but the forced-remote control also had a lower
p99 than the baseline. Run-to-run variance is therefore large enough that no
tail-latency improvement should be claimed from this matrix alone.

## Randomized 40-QPS policy replication

Five blocks each ran baseline, topology filter, and topology scorer in a
randomized order. Every run offered 40 QPS for 120 seconds with 8192 input
tokens and 256 requested output tokens. All 72,000 requests completed without
an inference failure.

| Policy | Runs | Achieved QPS, mean | Mean TTFT | p99 TTFT | Mean request latency | p99 request latency | Observed remote routing |
|---|---:|---:|---:|---:|---:|---:|---:|
| No-topology baseline | 5 | 39.061 | 1.395 s | 4.427 s | 3.371 s | 6.517 s | 49.62% |
| Topology filter | 5 | 38.942 | 1.912 s | 4.889 s | 3.864 s | 6.929 s | 0% |
| Topology scorer, weight 1 | 5 | 38.870 | 1.746 s | 4.735 s | 3.696 s | 6.788 s | 0.02% |

Paired block differences, policy minus baseline:

| Comparison | Metric | Mean difference | 95% confidence interval |
|---|---|---:|---:|
| Filter - baseline | Achieved QPS | -0.118 (-0.30%) | [-0.237, +0.001] |
| Filter - baseline | Mean TTFT | +0.517 s (+37.08%) | [+0.309, +0.725] s |
| Filter - baseline | p99 TTFT | +0.462 s (+10.45%) | [-0.353, +1.278] s |
| Filter - baseline | Mean request latency | +0.493 s (+14.62%) | [+0.288, +0.697] s |
| Filter - baseline | p99 request latency | +0.413 s (+6.33%) | [-0.283, +1.109] s |
| Scorer - baseline | Achieved QPS | -0.191 (-0.49%) | [-0.546, +0.164] |
| Scorer - baseline | Mean TTFT | +0.351 s (+25.15%) | [-0.095, +0.796] s |
| Scorer - baseline | p99 TTFT | +0.308 s (+6.97%) | [-1.211, +1.828] s |
| Scorer - baseline | Mean request latency | +0.325 s (+9.63%) | [-0.114, +0.763] s |
| Scorer - baseline | p99 request latency | +0.271 s (+4.16%) | [-1.148, +1.690] s |

The filter's mean-latency regression is statistically clear in this topology.
It limits each decoder to the four prefills on its own node, whereas the
baseline can balance across all eight prefills. The scorer is functionally
soft: it selected four remote prefills in the sampled routing evidence, but its
latency confidence intervals include zero. Neither topology policy improved
throughput or tail latency.

## Larger-KV follow-up

Etai Lev-Ran's feedback was that topology affinity can help only when the KV
payload divided by inter-node bandwidth is material. A second sweep therefore
kept the offered input-token rate approximately constant while increasing the
prompt size: 16K at 20 QPS, 32K at 10 QPS, and 64K at 5 QPS. Prefill labels
were truthful for forced local and inverted for forced remote; the topology
filter remained enabled.

| Input / offered QPS | Routing | Achieved QPS | Mean TTFT | p99 TTFT | Mean request latency | p99 request latency | Failures |
|---|---|---:|---:|---:|---:|---:|---:|
| 16K / 20 | Local | 17.914 | 9.137 s | 14.580 s | 10.687 s | 16.023 s | 0/2400 |
| 16K / 20 | Remote | 17.854 | 8.472 s | 14.329 s | 10.004 s | 15.794 s | 0/2400 |
| 32K / 10 | Local | 7.460 | 21.470 s | 39.864 s | 22.850 s | 41.030 s | 0/1200 |
| 32K / 10 | Remote | 7.343 | 21.719 s | 42.815 s | 23.134 s | 44.018 s | 0/1200 |
| 64K / 5 | Local | 2.895 | 47.792 s | 87.555 s | 49.227 s | 88.682 s | 1/600 |
| 64K / 5 | Remote | 2.787 | 49.418 s | 95.774 s | 50.780 s | 96.889 s | 0/600 |

The 64K/5 point is beyond the sustainable throughput knee. Remote is worse in
the expected direction there, but queue amplification and the local timeout
make it unsuitable for estimating a link-only effect. The 16K pair moves in
the opposite direction; the 32K pair has a modest remote regression. These are
single-run results and show that queue variation is larger than the transfer
effect.

### Connector telemetry

The decoder's vLLM `KV Transfer metrics` expose the actual payload and transfer
time. The NIXL backend reported at startup is `UCX` with CUDA buffers. vLLM
aggregates these observations across workers. With the TP4 decoder, the logs
contain approximately four transfers per request, so each table row is a
per-TP-rank transfer rather than the full request payload.

| Input | Routing | KV per TP-rank transfer | Mean transfer time | Per-rank throughput |
|---:|---|---:|---:|---:|
| 8K | Local | 73.125 MB | 7.56-8.34 ms | 8.77-9.68 GB/s |
| 16K | Remote | 145.125 MB | 15.63-16.23 ms | 8.94-9.29 GB/s |
| 32K | Remote | 289.125 MB | 27.40-27.95 ms | 10.34-10.55 GB/s |
| 64K | Local | 577.125 MB | 49.83 ms | 11.58 GB/s |
| 64K | Remote | 577.125 MB | 50.12-51.01 ms | 11.31-11.52 GB/s |

At 8K, the full TP4 payload is approximately 292.5 MiB per request. At 40 QPS,
that is approximately 12.3 GB/s of aggregate KV traffic. The baseline sends
49.6% of requests across nodes, or approximately 6.1 GB/s of inter-node
payload. The live nodes expose eight active NDR ports at 400 Gb/s each. With a
15% protocol-overhead allowance, 6.1 GB/s is approximately 1.8% of the
estimated 340-GB/s application bandwidth. As a conservative upper bound, it
is approximately 14% even if all remote traffic shares one 400-Gb/s port.
More importantly, the measured end-to-end connector time for a 577-MB
per-rank transfer is effectively the same locally and remotely. This
deployment therefore does not realize a raw NVLink-versus-NDR gap in the
metric that matters to the router.

## Sustainable 64K paired repeats

To retain the largest KV payload without overload, three local/remote blocks
ran at 64K input and 2 offered QPS. The order was local/remote, remote/local,
local/remote. All 1,440 requests succeeded.

| Run | Routing | Achieved QPS | Mean TTFT | p99 TTFT | Mean request latency | p99 request latency |
|---:|---|---:|---:|---:|---:|---:|
| 1 | Local | 1.924 | 4.700 s | 11.950 s | 5.810 s | 13.042 s |
| 2 | Remote | 1.921 | 5.144 s | 16.261 s | 6.270 s | 17.371 s |
| 3 | Remote | 1.855 | 4.879 s | 12.218 s | 6.030 s | 13.656 s |
| 4 | Local | 1.940 | 5.211 s | 12.880 s | 6.328 s | 13.999 s |
| 5 | Local | 1.940 | 5.361 s | 15.176 s | 6.534 s | 16.338 s |
| 6 | Remote | 2.064 | 4.777 s | 11.529 s | 5.896 s | 12.668 s |

Policy means and paired remote-minus-local inference:

| Metric | Local mean | Remote mean | Paired difference | 95% confidence interval |
|---|---:|---:|---:|---:|
| Achieved QPS | 1.935 | 1.947 | +0.011 | [-0.250, +0.273] |
| Mean TTFT | 5.090 s | 4.933 s | -0.157 s | [-1.489, +1.174] s |
| p99 TTFT | 13.3351 s | 13.3358 s | +0.0007 s | [-9.986, +9.988] s |
| Mean request latency | 6.224 s | 6.065 s | -0.159 s | [-1.555, +1.238] s |
| p99 request latency | 14.460 s | 14.565 s | +0.105 s | [-9.877, +10.088] s |

The request-level result is neutral. Local and remote p99 TTFT means differ by
less than one millisecond, but the confidence interval is wide because the
run-to-run tails vary substantially. Direct transfer telemetry is the clearer
mechanistic result: same-node and cross-node 64K transfers both take about 50
ms.

## Prefill-first follow-up

A completed Waldorf follow-up used `stageOrder: prefill-first` for three
balanced blocks of the baseline, topology filter, and topology scorer. All
43,200 requests succeeded. The baseline sent 50.1% of observed P/D pairs
across nodes. The scorer reduced that rate to 27.0% without a statistically
distinguishable latency or throughput change. The strict filter selected no
remote route in the observed logs, but added 110.7 ms to paired mean TTFT
(95% CI: 59.0 to 162.5 ms) and 98.9 ms to mean request latency (95% CI: 36.8
to 161.0 ms).

UCX protocol diagnostics showed that both same-node and cross-node CUDA KV
payloads selected `rc_mlx5`. The endpoint advertised `cuda_ipc/cuda`, but the
operation-specific payload table did not select it. This is therefore an RDMA
routing evaluation, not a CUDA IPC or NVLink evaluation. See the
[`prefill-first-waldorf` artifacts](prefill-first-waldorf/README.md) for the
partial stage-order matrix and the
[`completed RDMA rerun`](prefill-first-waldorf/prefill-rdma-rerun-20260826/README.md)
for the paired results and exact inputs.

## Conclusion

The topology plugins work functionally:

- The filter strictly eliminates cross-node P/D pairings.
- The scorer strongly prefers local pairings but can escape when other scores
  outweigh locality.

No performance improvement was measured in the tested Kermit or Waldorf
deployments. At 40 QPS the strict filter significantly worsened mean latency.
This is consistent with restricting the second-stage candidate pool and
reducing load-balancing freedom. The scorer increased locality without a
distinguishable performance change. Local and remote NIXL payloads used RDMA,
and no transfer-time gain was measured to trade against reduced
queue-balancing flexibility.

A performance-positive evaluation requires a deployment where the connector's
measured same-node transfer time is materially lower than its cross-node time,
or a controlled inter-node congestion experiment. Artificially congesting a
shared cluster fabric was intentionally not attempted because it could affect
other tenants.
