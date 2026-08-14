# Benchmarking P2P KV cache sharing

The runnable workflow below uses the llm-d benchmarking framework
(inference-perf) against the gateway; the canonical document-Q&A tables
were measured with the custom driver described under Running the
benchmark. Every scenario is preceded by the guide's verification gates; a run
where the mechanism is not provably engaged measures nothing.

## Running the benchmark

A document-Q&A workload profile for `llmdbenchmark` ships via
[llm-d-benchmark#1656](https://github.com/llm-d/llm-d-benchmark/pull/1656),
which is open, so `guide_p2p-kv-cache-sharing_1.yaml` is absent from `main`
and the PR branch lives on a fork rather than on `origin`. The profile is
an analogous synthetic workload, not the driver behind the canonical
tables: it holds 128 requests in flight rotated across 192 sessions with
1-2 s tool delays over the completions API, while the canonical
document-Q&A tables were measured with a custom driver that admits 128
whole six-turn conversations at once over chat completions with no tool
delay (archived with the measurement record). Expect the same regime, not
the same numbers, until the profile is measured on the fixed stack and
its results published. To run the profile, install the CLI, resolve your
endpoint, and run:

```bash
curl -sSL https://raw.githubusercontent.com/llm-d/llm-d-benchmark/main/install.sh | bash
cd llm-d-benchmark && source .venv/bin/activate
# Until llm-d-benchmark#1656 merges the profile comes from the PR fork at the
# pinned commit - `origin` has neither the branch nor the file.
git fetch https://github.com/nilig/llm-d-benchmark.git \
    960f55a910fc4c049428b820b54462227dfda510
git checkout 960f55a910fc4c049428b820b54462227dfda510

export ENDPOINT_URL="http://$(kubectl get service <your-epp-service> -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')"

llmdbenchmark \
    --spec           guides/p2p-kv-cache-sharing \
    run \
    --endpoint-url   "${ENDPOINT_URL}" \
    --model          "openai/gpt-oss-120b" \
    --namespace      "${NAMESPACE}" \
    --harness        inference-perf \
    --workload       guide_p2p-kv-cache-sharing_1.yaml \
    --analyze
```

Run the profile once per routing arm, switching only the EPP configuration
between runs. The three arm configs used for the gpt-oss tables below ship
next to this file:

* [`epp-affinity.yaml`](epp-affinity.yaml) - precise prefix-cache routing
  (the precise guide's configuration, complete).
* [`epp-load.yaml`](epp-load.yaml) - load-balanced placement, no pull (the
  recompute control).
* [`epp-load-p2p.yaml`](epp-load-p2p.yaml) - load-balanced placement + the
  P2P pull (`minCachedTokenDelta: 2048`, from the crossover below).

The wide-EP testbed (`GLM-5.2-FP8`, 753B) ships three arm sets:

* `epp-glm-c64-{approx,approx-p2p,precise,precise-p2p}.yaml` for the published
  C64 complete-policy comparison and four-arm diagnostic. The archived
  approximate+P2P arm has a documented load-accounting selector mismatch and
  is not a clean single-factor control.
* `epp-glm-loadfirst{,-p2p}.yaml` for the synthetic load-spill A/B; placement
  is identical across the pair, so it isolates the source producer.
* `epp-glm-precise{,-p2p}.yaml` for the fixed 1P1D precise-affinity check. It
  isolates the source producer and records the mechanism-verified null where
  every eligible cached-token delta is zero.

For a defensible A/B, run arm pairs in both orders. When arm switches reuse
engine pods, the second arm inherits warm CPU tiers, so alternation measures
that sensitivity. The C64 protocol assigns new engine pod UIDs to every arm;
its reversed order checks time drift rather than inherited cache state.

Model: `openai/gpt-oss-120b`, 16x TP=1 H200 (aggregated). Sizing inputs
measured on this rig: ~41.5 KB KV per token, ~1.22M tokens of GPU KV per pod
at `--gpu-memory-utilization=0.85` (from the engine startup log), CPU tier
sized to 88 GiB (~2.22M tokens, ~1.8x the GPU KV cache) so sources can
serve everything their GPU view advertises. Render service
sized for the peak stage rate (see the guide's best practices): one replica
saturates near 10 req/s on ~50K-token prompts and a saturated render stalls
every request for the token-producer timeout, flattening all arms to the
same false plateau; this rig runs 6 replicas (measured: 30 req/s at p50
82 ms direct).

## What each scenario isolates

Two of the scenarios below change placement and the pull together, so their
headline margin is not a P2P margin. Read them for what they are:

| Scenario | The pull-isolating pair | Isolates the pull? |
|---|---|---|
| Step 0 | recompute vs pull, same pod pair, no routing | **yes** |
| Wide-EP precise affinity (GLM) | `precise` vs `precise + pull` | **yes** - mechanism-verified null; no source delta reaches the threshold |
| Wide-EP load spill (GLM) | `load-first` vs `load-first + pull` | **yes** |
| Wide-EP C64 (GLM) | `approximate` vs `precise + pull` | **no** - complete-policy comparison; the published approximate+P2P diagnostic is confounded |
| Uniform pool | `load` vs `load + P2P` | **yes** |
| Hot set | `load` vs `load + P2P` | **yes** |
| Document Q&A | `affinity` vs `affinity + P2P` | partly - that pair isolates it, but the winning arm (`load + P2P`) also changes placement |

The C64 comparison and the document-Q&A headline compare complete policies.
The other scenarios carry a control arm with identical placement and no pull,
so their margins isolate the pull. Comparisons *across* placement policies
(`affinity` vs `load + P2P`) answer a different question - which deployment
to run - and should not be read as P2P deltas.

The isolating pairs are where the feature's value is established: Step 0
(-56% to -88% TTFT with RDMA), the uniform pool (+143% sustained rate at 24
req/s), the hot set (+224% and 274 client-timeout failures eliminated at
48 req/s), and GLM load spill (-67% mean TTFT and 2.7x throughput). The C64
comparison answers which complete deployment carries more successful work;
its margin cannot be assigned to P2P alone.

One result worth stating plainly because it recurs: **under affinity
placement the pull is a fallback, not an established throughput
feature.** Affinity keeps the KV local, so `minCachedTokenDelta` is
rarely met and there is little to fetch; on the document-Q&A rig the
`affinity + P2P` versus `affinity` throughput delta sits inside the
workload's run-to-run spread. That is the pull behaving correctly as a
recovery path, not a defect, but it does mean `affinity + P2P` should be
chosen for its placement behaviour and treated as a fallback for
externally inherited divergence (a cold engine replica behind an intact
router - plausible and unmeasured), not as a
throughput feature or router-restart insurance. See [When to use this path](../README.md#when-to-use-this-path).

## Step 0 - pull-versus-recompute crossover (single request)

This ladder was measured with `rdma/ib` on the model-server pods, and the
ladder is transport-dependent - so record which transport yours is on
before comparing against it. Without the IB device exposed to the container
NIXL/UCX falls back to TCP, the pull leg inflates while recompute is
unchanged, and the crossover moves from below 2K out to ~29K (measured:
+26.7% / +20.2% / +10.9% / +6.7% / -4.9% / -15.3% at
2K/8K/16K/24K/32K/48K). That is a different `minCachedTokenDelta`, not a
broken feature, but reading this table while running on TCP will mis-set it.
`ls /dev/infiniband` in the container tells you which case you are in. See
[Supported Hardware Backends](../README.md#supported-hardware-backends).

Seed a fresh prefix on one pod; measure single-request prefill latency on a
cold pod with and without the pull, at prefix lengths 2K/8K/16K/32K/48K.
The crossover sets the router's `minCachedTokenDelta`: below it a pull costs
more than recomputing. This measurement is automated as a
[calibration recipe](../../recipes/router/calibration/README.md#calibrating-mincachedtokendelta)
that runs against two live pods and prints the recommended value. Calibrate on a *warmed* pod pair - the first pull
between two peers pays a one-time session-establishment cost (~6 s measured
on the wide-EP testbed) that steady-state pulls never see, so a single cold
probe reads the transient, not the pull.

gpt-oss-120b note: with ~5.1B active parameters recompute is fast
(~29K tokens/s prefill on H200), but the compact hybrid-attention KV
(41.5 KB/token) makes the transfer cheaper still - the pull wins on latency
at every measured length, and additionally removes the prefill work from
the fleet, which the pool scenarios measure directly.

The measured ladder is canonical in
[the gpt-oss results page](../benchmark-results/gpt-oss-120b-h200.md#pull-versus-recompute-single-request)
(fixed stack, 5-rep medians, warm mesh, unique prefixes per repetition):
the pull wins at every measured length, -55.8% at 2K widening to -88.2%
at 48K - gpt-oss's compact KV (41.5 KB/token) makes the transfer cheap
enough to beat even this model's fast MoE prefill.
`minCachedTokenDelta: 2048` (the smallest measured winning length).

## Uniform shared-prefix pool (three routing arms)

128 shared prefixes x 48K tokens (~6M-token working set, ~5x one pod's GPU
cache), 256-token questions, 64 output tokens, streaming, constant-rate
stages ramped past saturation. `load.request_timeout` set explicitly.

Arms (identical workload, identical pods; only the router config changes):

1. `epp-affinity.yaml` - precise prefix-cache affinity. Uniform pools are
   affinity's best case; this arm is the reference ceiling.
2. `epp-load.yaml` - load-balanced placement, no p2p. Every cross-pod
   request recomputes its prefix: the recompute floor.
3. `epp-load-p2p.yaml` - load-balanced placement + pull.

Metrics per arm: achieved vs offered rate, TTFT and request latency
p50/p95, established P2P session counts (pull evidence),
`vllm:external_prefix_cache_hits_total` deltas (offload-tier activity, which
is not the same thing - see below), per-pod served counts (placement
evidence), restarts (must be 0).

Measured (16x gpt-oss-120b, H200, `rdma/ib` on every pod; achieved req/s /
TTFT p50 / request latency p50 per stage):

| offered | affinity | load, no P2P | load + P2P |
|---|---|---|---|
| 6 req/s | 5.97 / 207 ms / 0.50 s | 5.59 / 2.5 s / 5.6 s | 5.96 / 342 ms / 0.64 s |
| 12 req/s | 11.92 / 200 ms / 0.49 s | 9.02 / 8.6 s / 26.2 s | 11.49 / 460 ms / 0.98 s |
| 18 req/s | 17.87 / 192 ms / 0.48 s | 8.58 / 26.0 s / 45.7 s | 17.46 / 341 ms / 0.67 s |
| 24 req/s | 23.82 / 191 ms / 0.48 s | 9.01 / 43.8 s / 63.4 s | 21.93 / 344 ms / 0.70 s |
| 30 req/s | 29.76 / 184 ms / 0.48 s | 9.21 / 61.3 s / 81.2 s | 29.19 / 342 ms / 0.73 s |

Zero failures and zero restarts in all arms (16,200 requests). Pull evidence
in the `load + P2P` arm: **120 established P2P sessions**, against 0 in the
arms without the producer - that is what shows the path engaged.

Alongside it the tier served 210M external-hit tokens and 7.8 TB (GPU hit
rate 17.3% - scattered placement misses locally and the tier covers it).
Read those two as **offload-tier activity, not pull volume**:
`vllm:external_prefix_cache_hits_total` and `vllm:kv_offload_load_bytes_total`
count every restore into GPU, including a pod reloading from its own CPU
tier, so they cannot be attributed to peer transfers on a workload with
repeated prefixes. Session counts prove the path engaged but are reusable
peer connections and do not measure request or byte volume either. To
attribute bytes to a peer the consumer must hold no local copy - which is
what the [calibration
recipe](../../recipes/router/calibration/calibrate-min-cached-token-delta.sh)
arranges with fresh token IDs and a no-pull control, and why its byte column
is trustworthy where these fleet-level counters are not.

Reading the arms: affinity is near-ideal on a uniform pool - each pod owns
~8 of the 128 prefixes (384K tokens, comfortably GPU-resident), so with a
working prefix index every request is a local hit; flat sub-half-second p50
through 30 req/s. `affinity + P2P` matches this ceiling within noise (the
pull is idle under affinity placement - see
[What each scenario isolates](#what-each-scenario-isolates)). The recompute
control saturates near 9 req/s: every cross-pod placement re-prefills 48K
tokens. **The pull sets load placement's floor**: `load + P2P` tracks
offered rate through 30 req/s at sub-second p50 - against the recompute
floor at rate 24 that is 9.01 -> 21.93 req/s (+143%) and 63.4 s -> 0.70 s
p50; at rate 30, +217%. Affinity remains the better arm on this workload
(0.48 s vs 0.73 s p50, slightly higher achieved) because scattering pays
transfer work affinity never pays - but the gap is a constant factor, not a
collapse. Uniform pools are where affinity-style placement wins; the
document-Q&A headline is where load-aware + P2P's spreading matters more -
see the [placement rule](../README.md#when-to-use-this-path) for when each
applies.

## Hot set larger than one pod's cache

A small hot set takes all traffic, decode-heavy requests (512 output
tokens), rates ramped past what the prefix owners alone can absorb.
Affinity concentrates each hot prefix's work on its owner pod; load-aware
placement plus the pull serves the same hot content from the whole fleet.

**Size the hot set against one pod's GPU KV capacity before running this -
that ratio decides the result, and nothing else about the scenario
matters if it is wrong.** Measured on 16x gpt-oss-120b (~1.22M tokens of
GPU KV per pod), walking 48K-token prefixes:

| hot set | vs one pod's cache | what happens |
|---|---|---|
| 8 prefixes (384K tok) | 0.31x | fits in every pod - after warmup every arm serves GPU hits, nothing is recomputed and the pull never fires. Measures headroom, not a pathology. |
| 32 prefixes (1.54M tok) | 1.26x | one stage of churn while placement redistributes, then replication absorbs it and the arms converge |
| **64 prefixes (3.07M tok)** | **2.5x** | **misses are permanent; this is the regime the scenario is about** |

Measured at 64 x 48K (achieved req/s / TTFT p50 / request latency p50):

| offered | `affinity` | `load` - no P2P | `load + P2P` |
|---|---|---|---|
| 12 req/s | 11.94 / 188 ms / 0.30 s | 9.31 / 7.9 s / 16.6 s | 11.84 / 310 ms / 0.42 s |
| 24 req/s | 23.04 / 183 ms / 0.31 s | 11.47 / 24.3 s / 34.5 s | 22.83 / 271 ms / 0.42 s |
| 36 req/s | 34.03 / 190 ms / 0.36 s | 11.77 / 47.0 s / 61.6 s | 34.34 / 249 ms / 0.45 s |
| 48 req/s | 46.03 / 196 ms / 0.38 s | 13.85 / 58.2 s / 72.5 s, **274 failures** | 44.93 / 254 ms / 0.48 s, **0 failures** |

Pull evidence: 120 P2P sessions, 204M external-hit tokens, 7.5 TB served
from the offload tier, GPU hit rate 43.2% (the set genuinely does not fit).

**The pull is the difference between a serving fleet and a shedding one.**
Same placement, pull as the only variable, at offered 48: 13.85 -> 44.93
req/s (+224%), TTFT p50 58.2 s -> 254 ms, and 274 client-timeout failures
-> zero. The recompute floor caps near 12-14 req/s at every rate above 24 -
each displaced request re-prefills 48K tokens - while the pull arm tracks
offered rate to 48 within 2% of affinity's throughput.

Affinity is not the arm that suffers here: with 64 prefixes over 16 pods
ownership spreads ~4 per pod, no owner is overloaded, and affinity holds
46 req/s at 196 ms. Owner concentration is a *separate* pathology that
needs a prefix count well below the pod count; at that count the set also
fits everywhere, so the two effects are hard to exhibit in one workload.
Choose which one you are testing and size accordingly.

## Document Q&A at session scale (the headline; shipped as the profile above)

The user-facing regime: each of 192 conversations carries a private
48K-token document prefix and asks 6 short questions (256-token answers),
128 conversations concurrent. Per-turn decode is small, so TTFT dominates
the experience. With ~9.2M tokens of document prefix spread across the
fleet and 128 sessions concurrently active against a fixed
per-document ownership rule, request placement - not aggregate GPU
capacity - decides whether a question is a cache hit, a 48K recompute, or
a wait behind someone else's document. This is the regime
`guide_p2p-kv-cache-sharing_1.yaml` approximates (an analogous profile,
not the canonical driver - see Running the benchmark); scale
`num_conversations` and `concurrency` relative to your fleet's pod count
so enough sessions contend for a limited set of owner pods.

Results are canonical in
[the gpt-oss results page](../benchmark-results/gpt-oss-120b-h200.md#document-qa-the-headline),
measured on the fixed stack at the shipped `podCacheSize: 32` with a
per-arm cold roll so arms cannot contaminate each other. Headline:
load-aware + P2P wins this scenario (1.5x better p99 TTFT and +35%
throughput than precise routing warm; cold, zero failures at 2.9x
throughput and 7.9x p99), the affinity arms are cold-start fragile (47-48
client timeouts on a cold fleet as placement collapses onto one pod), and
precise + P2P versus precise alone reads +17% throughput warm - inside
the workload's run-to-run spread, so not credited to the pull (affinity
keeps KV local, so the source delta is rarely met). Undersizing the
index exaggerates the arm separation without changing the ordering; the
results page records the default-`podCacheSize` figures alongside.

On this scenario alone, `epp-load-p2p` is the better arm - but see
[the uniform pool](#uniform-shared-prefix-pool-three-routing-arms), where
the result is reversed. The guide ships `epp-affinity-p2p` as the default
because it is the safer general-purpose choice across both regimes (see
the [README](../README.md#when-to-use-this-path)); reach for
`epp-load-p2p` specifically when your workload looks like this one -
many concurrent, multi-turn sessions each pinned to an owner pod.

## Wide-EP testbed (GLM-5.2-FP8)

The GLM tests use two distinct 32x H200 topologies. The crossover and
synthetic load-spill tests use one 16-way prefill instance and one 16-way
decode instance. The C64 policy comparison uses two prefill pods and two
decode pods, each with DP 8 and TP 1.

The published C64 campaign used these exact configurations:

* [`epp-glm-c64-approx.yaml`](epp-glm-c64-approx.yaml) - calibrated
  approximate routing without P2P.
* [`epp-glm-c64-approx-p2p.yaml`](epp-glm-c64-approx-p2p.yaml) - the archived
  approximate+P2P arm. Its renamed prefix producer is not selected by the
  parameterless in-flight load producer, so the published observation is
  confounded and retained only for provenance.
* [`epp-glm-c64-precise.yaml`](epp-glm-c64-precise.yaml) - DP-aware precise
  KV events without the source producer.
* [`epp-glm-c64-precise-p2p.yaml`](epp-glm-c64-precise-p2p.yaml) - the precise
  policy with the source producer.

Use
[`epp-glm-c64-approx-p2p-corrected.yaml`](epp-glm-c64-approx-p2p-corrected.yaml)
for a future clean approximate+P2P rerun. No published result uses it.

The precise arm URLs record the benchmark testbed's `glm-5-2-render` Service.
The runnable deployment in this guide names the equivalent Service `render`;
replace the URL when applying a benchmark arm to that deployment.

Each arm starts after all four engine pods receive new UIDs. Run AIPerf with
the same public trace, seed, admission window, and drain:

```bash
aiperf profile \
  --url "$EPP_URL" \
  --model zai-org/GLM-5.2-FP8 \
  --endpoint-type chat \
  --streaming \
  --public-dataset semianalysis_cc_traces_weka_062126 \
  --no-fixed-schedule \
  --concurrency 64 \
  --num-dataset-entries 48 \
  --synthesis-max-isl 115000 \
  --synthesis-max-osl 2048 \
  --benchmark-duration 300 \
  --benchmark-grace-period 120 \
  --random-seed 67 \
  --ui None \
  --output-artifact-dir "$ARTIFACT_DIR"
```

Count requests only if they reach a terminal state within the 300-second
admission window. Across three comparisons - two approximate-first and one
precise+P2P-first - precise+P2P improves successful throughput over
approximate without P2P by 5.18% to 13.77%, with a 9.97% paired median. The
p90 end-to-end latency improves in two windows and regresses by 1.17% in the
reversed-order window, so the repeatable result is capacity rather than a
latency guarantee. Latency percentiles include only successful terminal
requests inside the cutoff and therefore compare different-sized,
right-censored populations.

One DEBUG window includes all four intended combinations. Approximate+P2P is
-2.17%, but its in-flight load producer reads the wrong prefix-match data key,
so that cell does not isolate P2P. Precise without P2P is -2.71% relative to
approximate without P2P, while precise+P2P is +9.97%. The snapshot cannot
establish an interaction. Mechanism evidence for precise+P2P includes 12
peer-load submissions, 12 unique transfer IDs, 17 successful transfer rounds,
and 6,342 submitted KV blocks. Generic NIXL and offload counters are not
P2P-only byte counters.

The C64 configurations use `minCachedTokenDelta: 2048`, below the separate
upstream-tier crossover recommendation of 12,288 tokens. Use the crossover
recipe to calibrate production deployments. Full tables, mechanism evidence,
crossover sweep, and the quarantined overlay-era grid are in
[the GLM results page](../benchmark-results/glm-5.2-h200.md).

## Run hygiene

* Compare each stage's wall-clock to send-window + drain; a stretched wall
  with fast successes means hung requests, not slow serving.
* `report.request_lifecycle.per_request: true` - per-request records make
  hangs and tails attributable.
* Record pull evidence per arm. For a scenario preregistered to pull
  (load-first placement, fresh-source seeding, or the GLM C64 precise+P2P
  policy), zero engagement means a misconfigured run. For an affinity arm,
  zero engagement can be a legitimate result when source evaluations prove
  that no cached-token delta reaches the threshold; the fixed GLM 1P1D
  precise pair is that control. External-hit counters include local CPU
  restores, so they cannot prove peer transfers on their own.
* Diff engine-side timing sums (`vllm:request_queue_time_seconds`,
  `vllm:request_prefill_time_seconds`, `vllm:time_to_first_token_seconds`)
  across each stage and reconcile them with client-observed TTFT. Client
  latency the engines never saw lives in the gateway path (router, render,
  sidecar), not the serving fleet.
* Run a low-rate independent probe through the gateway during stages. A
  latency plateau that is flat across offered rates and identical across
  arms is a fixed timeout somewhere in the path, not saturation - queueing
  grows with rate; timeouts do not.
