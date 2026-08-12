# GLM-5.2 Approximate Versus Precise Routing Without P2P

This benchmark compares approximate prefix-cache routing with DP-aware precise
prefix-cache routing. Peer-to-peer KV transfer is disabled in both arms. Reuse
is local to the selected worker, including its local CPU offload tier; the
router does not direct either worker to fetch KV blocks from a peer.

## Result

DP-aware precise routing improves time to first token (TTFT), but it does not
materially increase request throughput for this workload. Across two
counterbalanced repetitions, precise reduces mean TTFT by 17.0% and p90 TTFT
by 26.4%. Throughput is effectively tied, and mean request latency improves by
1.7%.

Run-level values are averaged so each repetition has equal weight. The reported
percentiles are averages of the two run percentiles, not pooled percentiles.

| policy | throughput (req/s) | mean TTFT (ms) | p50 TTFT (ms) | p90 TTFT (ms) | p99 TTFT (ms) | mean request latency (ms) | p99 request latency (ms) | mean ITL (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| approximate | 1.154 | 4,963.967 | 1,181.516 | 13,850.820 | 46,218.178 | 58,396.879 | 371,635.003 | 100.439 |
| precise | 1.155 | 4,120.188 | 1,189.137 | 10,188.115 | 42,561.979 | 57,434.368 | 362,840.858 | 101.473 |
| precise change | +0.06% | -17.00% | +0.64% | -26.44% | -7.91% | -1.65% | -2.37% | +1.03% |

Higher throughput is better. Lower latency is better.

### Per-repetition results

| arm | requests | throughput (req/s) | mean input tokens | mean output tokens | mean TTFT (ms) | p50 TTFT (ms) | p90 TTFT (ms) | p99 TTFT (ms) | mean request latency (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| approximate-r1 | 1,085 | 1.167 | 37,851.1 | 551.6 | 4,713.801 | 1,158.099 | 13,234.106 | 44,638.830 | 58,190.597 |
| precise-r1 | 1,045 | 1.112 | 37,122.2 | 544.4 | 4,705.369 | 1,261.057 | 11,406.953 | 45,659.783 | 59,567.335 |
| approximate-r2 | 1,073 | 1.141 | 36,739.3 | 560.0 | 5,214.133 | 1,204.933 | 14,467.534 | 47,797.526 | 58,603.161 |
| precise-r2 | 1,126 | 1.198 | 38,302.0 | 556.4 | 3,535.007 | 1,117.217 | 8,969.276 | 39,464.175 | 55,301.401 |

The first repetition runs precise before approximate; the second runs
approximate before precise. This controls for a simple arm-order effect. The
variation between the two precise repetitions is large enough that the result
should be treated as directional rather than a production SLO guarantee.

## Workload

The test uses the AIPerf `inferencex-agentx-mvp` scenario and the
`semianalysis_cc_traces_weka_with_subagents` loader. The source is the `train`
split of `semianalysisai/cc-traces-weka-062126`. This is a trace-driven agentic
workload with parent and subagent trajectories, not a synthetic fixed-length
prompt workload.

| setting | value |
|---|---|
| endpoint | streaming Chat Completions through the llm-d EPP |
| model | `zai-org/GLM-5.2-FP8` |
| maximum context | 120,000 tokens |
| concurrency | 64 |
| random seed | 42 |
| arrival timing | trace end-to-start delays; idle gaps capped at 10 seconds |
| output behavior | trace-requested output length with `ignore_eos=true` |
| cache busting | `first-turn-prefix` |
| warmup | 120 seconds |
| measured window | 900 seconds, followed by completion grace |
| repetitions | 2, counterbalanced |

The request distribution is long-context and highly cache-reusable. Across
the measured arms, mean input length ranges from 36.7K to 38.3K tokens and
mean output length ranges from 544 to 560 tokens. In the first approximate
run, the median input is 39,014 tokens, p90 input is 77,848 tokens, maximum
input is 112,240 tokens, and the theoretical prefix-cache hit rate is 93.7%.

The workload is duration-limited and concurrency-driven. A faster policy can
complete more trajectories during the measurement window, so the final set of
completed requests is not identical across arms. The fixed seed and
counterbalanced order make arrival generation comparable, but this is not a
request-for-request replay.

The AIPerf command is:

```shell
aiperf profile \
  --scenario inferencex-agentx-mvp \
  --url http://agentx-slo-epp.nilig-agentx-slo:8081/v1 \
  --model zai-org/GLM-5.2-FP8 \
  --max-context-length 120000 \
  --endpoint-type chat \
  --streaming \
  --use-server-token-count \
  --public-dataset semianalysis_cc_traces_weka_with_subagents \
  --concurrency 64 \
  --random-seed 42 \
  --cache-bust first-turn-prefix \
  --warmup-duration 120 \
  --benchmark-duration 900
```

## Serving topology

The model runs on two prefill pods with eight local data-parallel ranks per
pod, for 16 ranks total. There are no separate decode pods; each selected rank
handles the complete streaming request. Each rank uses tensor parallelism 1,
FP8 KV cache, a 64-token vLLM block size, and a 100 GiB CPU offload tier.

CPU offloading is enabled identically in both arms. It is not a routing signal
for precise placement because the precise index uses GPU weight 1 and CPU
weight 0. Neither arm emits a P2P source header: the captured path contains
zero source headers, zero sidecar source injections, and zero correlated
successful peer-transfer rounds. Generic engine offload-load counters are not
evidence of P2P because they also count local CPU-tier loads.

## Router configurations

Both configurations use the vLLM tokenizer renderer at
`http://glm-5-2-render:8000`, the same metrics source, the same endpoint set,
and the same model-server configuration.

### Approximate

The approximate producer estimates reusable prefixes from requests observed by
the router. It maintains an LRU-style model of cache contents rather than
consuming live KV allocation and eviction events for placement.

```yaml
- type: approx-prefix-cache-producer
  name: approx-prefix-cache-producer
  parameters:
    autoTune: false
    blockSizeTokens: 64
    lruCapacityPerServer: 3780
    maxPrefixTokensToMatch: 120000

schedulingProfiles:
- name: default
  plugins:
  - pluginRef: approx-prefix-scorer
    weight: 5
  - pluginRef: precise-prefix-scorer
    weight: 0
  - pluginRef: active-request-scorer
    weight: 1
```

The precise producer remains instantiated for instrumentation in this arm, but
its scorer weight is zero and it cannot affect endpoint selection.

### Precise

The precise producer consumes live, DP-aware KV events from each vLLM rank.
The `kv@` topic filter and pod discovery on base port 5557 are required so the
index preserves rank identity instead of collapsing all events onto rank 0.

```yaml
- type: precise-prefix-cache-producer
  name: precise-prefix-cache-producer
  parameters:
    speculativeIndexing: false
    indexerConfig:
      kvBlockIndexConfig:
        inMemoryConfig:
          podCacheSize: 128
      kvCacheBackendConfigs:
      - name: gpu
        weight: 1.0
      - name: cpu
        weight: 0.0
    tokenProcessorConfig:
      blockSize: 64
    kvEventsConfig:
      topicFilter: "kv@"
      discoverPods: true
      podDiscoveryConfig:
        socketPort: 5557
- type: inflight-load-producer
  parameters:
    prefixMatchInfoProducerName: precise-prefix-cache-producer
- type: prefix-cache-affinity-filter
  parameters:
    prefixMatchInfoProducerName: precise-prefix-cache-producer
    inFlightLoadProducerName: inflight-load-producer
    affinityThreshold: 0.80
    explorationProbability: 0.0
    maxTTFTPenaltyMs: 18000
    ttftSource: prefillThroughput
    peakPrefillThroughput: 3585
- type: token-load-scorer
- type: max-score-picker
```

The affinity filter retains a cache holder only when its prefix affinity is at
least 0.80 and the predicted queue penalty remains within the configured TTFT
budget. Requests that fail that gate proceed to token-load scoring.

## Interpretation

Precise routing improves TTFT because its cache view follows actual GPU block
allocation and eviction. Approximate routing can overestimate reuse after an
eviction or miss reuse that was populated outside its request history. Those
errors matter most in the TTFT tail for long prompts, which is consistent with
the larger p90 improvement than p50 improvement.

Throughput remains tied because the cache decision primarily changes prefill.
This workload also generates an average of roughly 550 output tokens per
request, so streaming decode occupies most of the approximately 57-58 second
total request lifetime. Precise improves the initial prefill wait, but its mean
inter-token latency is 1.0% higher and offsets most of the end-to-end gain.

The corrected DP-aware precise configuration does not collapse traffic onto
rank 0. Fifteen of 16 ranks receive queued work in each precise repetition.
Average queue-depth standard deviation falls from 0.537 with approximate to
0.474 with precise, an 11.8% reduction. Precise still has a higher average
top-two-rank queue share, 43.6% versus 39.9%, because exact affinity naturally
concentrates related sessions on their cache holders. The affinity filter and
TTFT gate limit that concentration; they do not eliminate it.

## Limitations

- The result has two repetitions per policy.
- One precise repetition has recovered full model-server logs but no complete
  EPP affinity-decision trace. AIPerf latency metrics and engine counters are
  present; detailed filter-decision analysis is incomplete for that arm.
- The duration-limited trace produces small differences in completed request
  shape across arms.
- CPU offloading remains enabled in both arms. This isolates prefix-routing
  policy, not CPU offloading itself.
- The result applies to this long-context agentic trace, model, concurrency,
  cache size, and 16-rank topology. It does not establish that precise routing
  wins for every workload.
