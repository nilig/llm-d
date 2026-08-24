#!/usr/bin/env bash
set -euo pipefail

context=kermit_US-EAST-01A
namespace=nilig-topology-aware
root=/Users/niliguy/github.com/llm-d/tmp/topology-aware-benchmark
benchmark=/tmp/nilig-topology-benchmark-client/llm-d-benchmark/.venv/bin/llmdbenchmark
benchmark_root=/tmp/nilig-topology-benchmark-client/llm-d-benchmark

node0_prefills=(
  pd-topology-0-0f1f2f53-prefill-0
  pd-topology-0-0f1f2f53-prefill-1
  pd-topology-0-0f1f2f53-prefill-2
  pd-topology-0-0f1f2f53-prefill-3
)
node1_prefills=(
  pd-topology-1-f1e9cdaa-prefill-0
  pd-topology-1-f1e9cdaa-prefill-1
  pd-topology-1-f1e9cdaa-prefill-2
  pd-topology-1-f1e9cdaa-prefill-3
)

set_topology() {
  local policy=$1
  local node0_slice=0
  local node1_slice=1
  if [[ "$policy" == remote ]]; then
    node0_slice=1
    node1_slice=0
  fi
  kubectl --context "$context" -n "$namespace" label pod "${node0_prefills[@]}" \
    "llm-d.ai/topology-slice=$node0_slice" --overwrite
  kubectl --context "$context" -n "$namespace" label pod "${node1_prefills[@]}" \
    "llm-d.ai/topology-slice=$node1_slice" --overwrite
}

restore_topology() {
  set_topology local
}
trap restore_topology EXIT

cd "$benchmark_root"
mkdir -p "$root/results/paired-64k"

# Balanced blocked order limits bias from monotonic cluster drift.
order=(local remote remote local local remote)
for index in "${!order[@]}"; do
  policy=${order[$index]}
  run=$((index + 1))
  set_topology "$policy"
  "$benchmark" run \
    --workspace "$root/results/paired-64k/run-${run}-${policy}" \
    --specification_file guides/pd-disaggregation \
    --endpoint-url http://10.16.3.183 \
    --gateway-class epponly \
    --model openai/gpt-oss-120b \
    --namespace "$namespace" \
    --harness inference-perf \
    --workload-file-path "$root/workload-8k-256.yaml" \
    --experiments "$root/payload-repeat-64k.yaml" \
    --wait-timeout 1800 \
    --pvc-bind-timeout 300 \
    --fast-collect \
    --analyze \
    --run-description "64K/2 QPS paired repeat: run $run, forced $policy"
done
