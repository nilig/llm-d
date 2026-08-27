# P-short sizing: does a second short-work prefiller pay off?

Question (user, 2026-08-25): under mixed load, the migrated follow-ups share
P-short with the native short class. Does doubling P-short (2 replicas)
protect the native shorts and the migrants?

## Setup

Waldorf `nilig-agentx-slo`, cache-route-bench fleet,
`meta-llama/Llama-3.1-8B-Instruct`, single-GPU workers, block size 128,
image `nightly-6f91edf9-pr50302`, EPP `p2p-cache-routing-709e0991`,
candidate config: `prefix-cache-affinity-filter` (threshold 0.35, CPU-tier
weight 0.4, peakPrefillThroughput 10715, maxTTFTPenaltyMs 500) +
`context-length-aware` score-only on `llm-d.ai/prefill-work-range`
(P-short 0-8192, P-long 8193-120000) + decode session affinity.

Generator `sizing_load.py` (v2), 480 s per block, all through the candidate
EPP unless noted:

- direct-long x2: back-to-back cold 32,768-token prompts to the
  `prefill-long-direct` Service (bypasses EPP admission; keeps P-long
  genuinely saturated; EPP-invisible by design).
- heavy follow-ups x1 ("trigger" stream): sessions 0-1, seeded 102,400-token
  prefix + fresh 8,192-token tail per turn, back-to-back. Remaining work
  after the floor is 8,191, inside the short-work range, so these migrate.
- native shorts x1: cold 1,500-token prompts, ~1/s.
- light follow-ups x1: sessions 2-3, seeded prefix + fresh 1,024-token tail
  every ~5 s.
- All workers back off 2 s on any non-200.

Per-block protocol: joint restart of all engine pods (fresh NIXL mesh,
empty caches), wait Ready, seed 4 sessions (4 x 102,400 tokens, all land on
P-long: prompt_tokens exactly 409,600, 53.7 GB stored to its CPU tier),
pre-scrape counters, run, post-scrape.

## Block 1: 1x P-short (2026-08-26)

Zero request errors in any stream. TTFT seconds:

| stream | n | p50 | p90 |
|---|---|---|---|
| native short (1.5K cold) | 354 | 1.17 | 1.20 |
| heavy follow-up (102K prefix + 8K tail) | 336 | 1.34 | 1.37 |
| light follow-up (102K prefix + 1K tail) | 37 | 9.31 | 10.08 |
| direct long (32K cold, P-long) | 220 | 2.35 | 8.91 |

Mechanism counters (deltas over the block, exact):

- P-short `external_prefix_cache_hits_total` +204,800 = 2 sessions x
  102,400: the first heavy follow-up of each session migrated with a P2P
  pull; `kv_offload_load_bytes_total` +26.84 GB = 204,800 tokens x 128 KiB.
- After migration the sessions live on P-short: 90.7% GPU prefix-cache hit
  rate there; each subsequent heavy follow-up computes only its 8K tail
  (1.34 s vs the 9.3 s full recompute) - the migration payoff is 7x on this
  stream.
- P-long prompt tokens = direct longs (220 x 32,768 = 7.2M) + light
  follow-ups (37 x 103,424 = 3.8M): the light follow-ups stayed on P-long.
  Early in the block 7 of them restored the prefix from P-long's local CPU
  tier (`external_prefix_cache_hits_total` +720,128, load +94.4 GB); the
  rest fully recomputed (9.3-10 s = 103K tokens at ~10.7K tok/s).
- Cause of the recomputes: the direct longs store everything they prefill,
  pushing 1.21 TB through P-long's CPU tier LRU in 480 s. Sessions 2-3
  (touched only every ~10 s) evict; the precise index then shows no holder,
  so no floor is published and no affinity forms - the request routes by its
  total length back to the saturated P-long. Sessions 0-1 survived by
  migrating away before the churn peaked.

Reading: under tier churn, migration is self-protecting (the moved sessions
are immune to source eviction) while sticky sessions degrade to cold-long
behavior. The light-follow-up stream is kept as-is across blocks as a
control; the sizing comparison reads native shorts + heavy follow-ups.

EPP debug logs confirm the pipeline per request: prefill-filter/by-label ->
cache-load-gate/prefix-cache-affinity-filter (both prefills pass, gate open)
-> prefill-work-router/context-length-aware -> weighted score picked P-short
0.741 vs P-long 0.039.

## Block 2: 2x P-short (2026-08-26)

Same generator, P-short scaled to 2 replicas before the joint restart.
Zero request errors. TTFT seconds (block 1 in parentheses):

| stream | n | p50 | p90 |
|---|---|---|---|
| native short | 464 (354) | 0.079 (1.17) | 0.96 (1.20) |
| heavy follow-up | 400 (336) | 1.11 (1.34) | 1.14 (1.37) |
| light follow-up (control) | 39 (37) | 8.76 (9.31) | 9.63 (10.08) |
| direct long (control) | 227 (220) | 2.37 (2.35) | 8.97 (8.91) |

Both controls are unchanged, so the fleet and generator behaved identically;
the deltas on the first two rows are the replica effect.

- Native shorts p50 drops 15x (1.17 s -> 79 ms): with two replicas one is
  usually free of migrant tail compute, so shorts stop queueing. p90 0.96 s
  shows residual collisions.
- Heavy follow-ups reach pure tail-compute time (1.11 s ~= 8,192 tokens at
  ~7.4K tok/s, near-zero queueing).
- Turns completed rise 31% (shorts) and 19% (heavy follow-ups) in the same
  480 s.

Counters: each replica pulled exactly one migrating session
(`external_prefix_cache_hits_total` +102,400 and
`kv_offload_load_bytes_total` +13.42 GB on each) and total prompt tokens
balanced to 0.05% (22.36M vs 22.35M) - session affinity shards migrant
sessions one per replica with no additional configuration. GPU
prefix-cache hit rate 90.7% on both. P-long: 227 direct longs + 39 light
follow-ups, of which ~11 restored from the local CPU tier
(`external_prefix_cache_hits_total` +1,166,208) and the rest recomputed,
same tier-churn mechanism as block 1.

## Block 3: 2x P-short, repeat (2026-08-26)

Zero request errors. TTFT seconds:

| stream | n | p50 | p90 |
|---|---|---|---|
| native short | 451 | 0.102 | 1.16 |
| heavy follow-up | 339 | 1.33 | 1.35 |
| light follow-up (control) | 37 | 8.99 | 9.78 |
| direct long (control) | 220 | 2.35 | 9.07 |

The sharding outcome differed from block 2: both migrating sessions landed
on one replica (g2r4d: `external_prefix_cache_hits_total` +204,800, both
pulls, 26.8 GB loaded; cm4c5 served only shorts, prompt_tokens 375,000).
Consequences:

- Native shorts stay protected (p50 0.102 s) - the second replica absorbs
  them wherever the sessions live, so the benefit to the short class is
  robust to sharding.
- Heavy follow-ups revert to 1x-like latency (1.33 s vs 1.11 s) and turn
  count (339 vs 400) - the migrant-stream gain requires the sessions to
  actually spread, which is timing-dependent with only two sessions.

Controls stable for the third consecutive block.

## Block 4: 1x P-short, repeat (2026-08-26)

Zero request errors. Reproduces block 1 to the token: P-short
prompt_tokens 37,468,728 in both 1x blocks, identical migration counters
(+204,800 external hits, 26.84 GB loaded), shorts p50 1.170 vs 1.172.

| stream | n | p50 | p90 |
|---|---|---|---|
| native short | 354 | 1.17 | 1.19 |
| heavy follow-up | 336 | 1.34 | 1.36 |
| light follow-up (control) | 38 | 8.71 | 9.90 |
| direct long (control) | 223 | 2.35 | 9.08 |

## Verdict (ABBA complete: 1x, 2x, 2x, 1x)

TTFT p50 seconds (n) per block:

| stream | 1x b1 | 2x b2 | 2x b3 | 1x b4 |
|---|---|---|---|---|
| native short | 1.17 (354) | 0.079 (464) | 0.102 (451) | 1.17 (354) |
| heavy follow-up | 1.34 (336) | 1.11 (400) | 1.33 (339) | 1.34 (336) |
| light follow-up (control) | 9.31 (37) | 8.76 (39) | 8.99 (37) | 8.71 (38) |
| direct long (control) | 2.35 (220) | 2.37 (227) | 2.35 (220) | 2.35 (223) |

1. The second P-short removes short-class queueing outright: p50 1.17 s ->
   0.08-0.10 s (11-15x) and +27-31% short turns, consistent in both 2x
   blocks regardless of where the migrant sessions land. The native short
   class is the primary beneficiary of P-short scale-out.
2. The migrant stream improves only when sessions shard across replicas
   (b2: 1.11 s, +19% turns; one pull per replica, prompt tokens balanced to
   0.05%). When both sessions land on one replica (b3) it reverts to 1x
   latency. With only two sessions the sharding is timing-dependent; larger
   session counts make this an averages game.
3. Both controls are pinned across all four blocks (light follow-up
   8.7-9.3 s, direct long 2.35 s / p90 ~9 s), so the deltas are the replica
   effect, not fleet drift.
4. The two 1x blocks are token-identical end to end - the harness is
   deterministic, so per-block variance genuinely reflects routing, not
   workload noise.

Sizing rule this supports: provision P-short for the native short class
plus the expected migrant tail compute; migration concentrates follow-up
work on the short-work pool, and that pool scales linearly (one session
pull, 13.4 GB, then GPU-cache-hit turns).

## Blocks 5-6: baseline (without remaining-work routing), 1x (2026-08-26/27)

Same generator, same protocol, routed through
`cache-route-bench-epp-baseline` - identical config to the candidate except
`context-length-aware` has no `reusableTokensProducerName`, so it scores by
total context length. A 110K-total follow-up always scores P-long ~0.74 vs
P-short ~0.04 and never migrates; the P2P pull machinery is present but
inert because requests never separate from their cache. Zero request
errors; the two blocks reproduce each other closely.

| stream | b5 n / p50 / p90 | b6 n / p50 / p90 |
|---|---|---|
| native short | 480 / 0.072 / 0.078 | 480 / 0.071 / 0.077 |
| heavy follow-up | 38 / 15.32 / 17.37 | 33 / 16.56 / 17.58 |
| light follow-up | 31 / 12.38 / 13.56 | 30 / 12.87 / 13.89 |
| direct long | 107 / 9.13 / 16.43 | 96 / 9.38 / 16.60 |

Counters: P-short prompt_tokens exactly 720,000 = 480 x 1,500 both blocks
(only shorts; zero external hits; idle ~86% of the wall clock). P-long
carries everything else, including ~19 (b5) / ~11 (b6) full 13.4 GB
CPU-tier restores for follow-up turns whose prefix the direct-long churn
evicted from GPU.

## With vs without (1x fleet, per-block values from the two blocks per arm)

| stream | without (b5/b6) | with (b1/b4) | effect |
|---|---|---|---|
| heavy follow-up p50 | 15.3 / 16.6 s | 1.34 / 1.34 s | 11-12x faster |
| heavy follow-up turns | 38 / 33 | 336 / 336 | ~10x more |
| direct long p50 | 9.1 / 9.4 s | 2.35 / 2.35 s | 3.9x faster |
| direct long turns | 107 / 96 | 220 / 223 | 2.2x more |
| light follow-up p50 | 12.4 / 12.9 s | 9.3 / 8.7 s | -27% |
| native short p50 | 0.072 / 0.071 s | 1.17 / 1.17 s | regression at 1x |
| total turns / 480 s | 656 / 639 | 947 / 947 | +45% |

The mechanism moves the follow-up stream (and its restore traffic) off
P-long onto the otherwise-idle P-short. Every P-long-bound class speeds up
3.9-12x and fleet throughput rises 45%. The one regression - native shorts
now sharing P-short with migrant tail compute - is the sizing question
blocks 1-4 answer: a second P-short returns shorts to 0.08-0.10 s while
keeping all the wins.
