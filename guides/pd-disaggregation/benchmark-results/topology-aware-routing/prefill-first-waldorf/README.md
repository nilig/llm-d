# Prefill-first topology-aware routing follow-up

Date: 2026-08-25

Cluster and namespace: `waldorf_US-EAST-04A`,
`nilig-topology-prefill-first`

Status: partial matrix. Seven of 18 planned runs completed before other
workloads consumed the decoder capacity. The completed aggregate reports are
valid, but the sample is too small for the planned paired confidence
intervals. All benchmark Deployments were scaled to zero after the
interruption.

## Deployment

- Model: `openai/gpt-oss-120b`
- GPUs: two 8x H200 nodes, `gd91fda` and `gf41fb2`
- Layout per node: four TP1 prefills and one TP4 decoder
- Router and sidecar: llm-d Router `v0.10.0`
- Model server: vLLM `v0.23.0`
- NIXL connector: CUDA buffers with the UCX backend explicitly selected
- Workload: 8192 input tokens, 256 requested output tokens, 40 offered QPS,
  120 seconds, and 4800 requests per run

The planned matrix compared `decode-first` and `prefill-first` stage order for
the no-topology baseline, topology filter, and topology scorer. Three balanced
blocks were intended to control for policy order and cluster drift.

## Results

| Run | Policy | Observed local / remote routing | Achieved QPS | Mean TTFT | p99 TTFT | Mean request latency | p99 request latency | Failures |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | Prefill-first filter | 4800 / 0 | 39.086 | 1.686 s | 4.604 s | 3.630 s | 6.608 s | 0/4800 |
| 2 | Decode-first scorer | 4795 / 5 | 38.558 | 2.144 s | 5.248 s | 4.099 s | 7.136 s | 0/4800 |
| 3 | Prefill-first baseline | 2342 / 2458 | 38.832 | 1.484 s | 4.766 s | 3.433 s | 7.015 s | 0/4800 |
| 4 | Decode-first filter | 4271 / 0, partial log coverage | 38.550 | 1.922 s | 4.949 s | 3.865 s | 7.038 s | 0/4800 |
| 5 | Prefill-first scorer | 3523 / 1277 | 38.933 | 1.393 s | 4.621 s | 3.348 s | 6.878 s | 0/4800 |
| 6 | Decode-first baseline | 2375 / 2425 | 39.192 | 1.834 s | 5.028 s | 3.801 s | 7.073 s | 0/4800 |
| 7 | Prefill-first baseline | unavailable | 39.075 | 1.818 s | 5.408 s | 3.785 s | 7.520 s | 0/4800 |

All six first-block variants completed without failures. In that block,
prefill-first had lower mean TTFT than decode-first for the baseline, filter,
and scorer by 19.1%, 12.3%, and 35.1%, respectively. These are single-block
differences, not replicated estimates. The second prefill-first baseline was
22.6% slower in mean TTFT than the first, which shows why the remaining
balanced blocks are required before attributing the first-block differences
to stage order.

Within the prefill-first runs, the strict filter made every observed route
local but increased mean TTFT by 13.7% and mean request latency by 5.7%
relative to the first baseline. The scorer was the fastest first-block policy,
but it allowed 26.6% remote routing. That is consistent with soft affinity
retaining useful queue-balancing freedom, but one block is not enough to claim
a performance improvement.

## Transport verification

The model-server logs confirm `NixlConnector`, `kv_buffer_device='cuda'`, the
UCX backend, and `use_host_buffer: False`. UCX exposed an intra-node endpoint
with `cuda_ipc/cuda` and `rc_mlx5` lanes, and the routing proxy used NIXL V2 for
a decoder and prefill placed on the same node.

During an all-local 8K filter run, vLLM reported four TP-rank transfers per
request. Each transfer contained 73.125 MiB and took 7.1-9.3 ms, or
approximately 7.9-10.3 GB/s per rank. The full TP4 payload was therefore
approximately 292.5 MiB per request. At 40 QPS, that is approximately 12.3
GB/s of aggregate KV traffic. With approximately half the baseline routes
crossing nodes, the inter-node payload was approximately 6.1 GB/s: about 1.8%
of the estimated 340-GB/s application bandwidth across eight 400-Gb/s ports,
or a conservative 14% if all remote traffic shares one such port.

The endpoint log proves that CUDA IPC was available; it does not prove that
every payload selected the CUDA IPC lane. There was no evidence of a TCP-only
fallback, but the measured connector throughput still did not create a large
local-transfer benefit for the router to exploit.

See `transport-evidence.md` for the curated log excerpts.

## Interruption

Run 7's 120-second load stage and all 4800 requests completed before the
capacity change. At `2026-08-25T07:18:20Z`, a ten-replica 2-GPU nightly
Deployment began occupying Waldorf. The old decoder pods disappeared and
their replacements remained Pending. As a result, the aggregate metrics for
run 7 are complete, but its route logs were unavailable when the post-run
counter executed. Run 8 was stopped before producing a valid report.

A live capacity scan found no two whole non-Kermit H200 nodes on the configured
clusters, so the matrix was not resumed elsewhere. The remaining repeats
should start from run 8 only after the original two-node layout can be restored
and warmed.

## Artifacts

- `summary.tsv` contains the seven valid aggregate rows with relative report
  paths and route-evidence status.
- `artifacts/reports` contains the aggregate v0.2 report for every valid run.
- `artifacts/harness-logs` contains the corresponding benchmark-driver log.
- `configs` contains the deployment, router, workload, load, and run inputs.
- Per-request traces and credential-bearing setup logs are intentionally
  omitted.
