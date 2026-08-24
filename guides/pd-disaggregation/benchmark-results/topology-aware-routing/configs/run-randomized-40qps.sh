#!/usr/bin/env bash

set -euo pipefail

CONTEXT="kermit_US-EAST-01A"
NAMESPACE="nilig-topology-aware"
ROOT="/Users/niliguy/github.com/llm-d/tmp/topology-aware-benchmark"
ROUTER_DIR="${ROOT}/router"
OUTPUT_ROOT="${ROOT}/results/randomized-40qps"
BENCH_ROOT="/tmp/nilig-topology-benchmark-client/llm-d-benchmark"
BENCH="${BENCH_ROOT}/.venv/bin/llmdbenchmark"
ENDPOINT="http://10.16.3.183"
SUMMARY="${OUTPUT_ROOT}/summary.tsv"
START_RUN="${1:-1}"

DECODE_0="pd-topology-0-0f1f2f53-decode-0"
DECODE_1="pd-topology-1-f1e9cdaa-decode-0"

RUN_ORDER=(
  "1 1 filter"
  "1 2 scorer"
  "1 3 baseline"
  "2 1 baseline"
  "2 2 filter"
  "2 3 scorer"
  "3 1 baseline"
  "3 2 scorer"
  "3 3 filter"
  "4 1 baseline"
  "4 2 filter"
  "4 3 scorer"
  "5 1 scorer"
  "5 2 baseline"
  "5 3 filter"
)

apply_policy() {
  local policy="$1"
  local config
  local patch

  config="$(yq -r '.router.epp.pluginsCustomConfig."topology-config.yaml"' "${ROUTER_DIR}/${policy}.values.yaml")"
  if [[ -z "${config}" || "${config}" == "null" ]]; then
    echo "Policy ${policy} rendered an empty router configuration" >&2
    return 1
  fi

  patch="$(jq -n --arg config "${config}" '[{"op":"replace","path":"/data/topology-config.yaml","value":$config}]')"
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" patch configmap topology-router-epp --type=json -p="${patch}"
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout restart deployment/topology-router-epp
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout status deployment/topology-router-epp --timeout=180s

  case "${policy}" in
    filter)
      kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get configmap topology-router-epp -o jsonpath='{.data.topology-config\.yaml}' | rg -q 'topology-affinity-filter'
      ;;
    scorer)
      kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get configmap topology-router-epp -o jsonpath='{.data.topology-config\.yaml}' | rg -q 'topology-affinity-scorer'
      ;;
    baseline)
      if kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get configmap topology-router-epp -o jsonpath='{.data.topology-config\.yaml}' | rg -q 'topology-affinity-(filter|scorer)'; then
        echo "Baseline unexpectedly contains a topology-affinity plugin" >&2
        return 1
      fi
      ;;
  esac
}

restore_filter() {
  set +e
  echo "RESTORE policy=filter"
  apply_policy filter
}

count_routes() {
  local stage_start="$1"
  local decoder_0_counts
  local decoder_1_counts
  local local_0
  local remote_0
  local local_1
  local remote_1

  decoder_0_counts="$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" logs "${DECODE_0}" -c routing-proxy --since-time="${stage_start}" \
    | jq -r 'select(.msg=="sending prefill request") | .to' \
    | awk '{if ($0 ~ /^10\.0\.7\./) l++; else if ($0 ~ /^10\.0\.8\./) r++} END {print l+0, r+0}')"
  decoder_1_counts="$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" logs "${DECODE_1}" -c routing-proxy --since-time="${stage_start}" \
    | jq -r 'select(.msg=="sending prefill request") | .to' \
    | awk '{if ($0 ~ /^10\.0\.8\./) l++; else if ($0 ~ /^10\.0\.7\./) r++} END {print l+0, r+0}')"

  read -r local_0 remote_0 <<<"${decoder_0_counts}"
  read -r local_1 remote_1 <<<"${decoder_1_counts}"
  echo "$((local_0 + local_1)) $((remote_0 + remote_1))"
}

mkdir -p "${OUTPUT_ROOT}"
if [[ "${START_RUN}" == "1" ]]; then
  printf 'block\tposition\tpolicy\tstage_start\tlocal_routes\tremote_routes\trequest_qps\tttft_mean_s\tttft_p99_s\te2e_mean_s\te2e_p99_s\ttotal_requests\tfailures\treport\n' >"${SUMMARY}"
elif [[ ! -s "${SUMMARY}" ]]; then
  echo "Cannot resume without an existing summary: ${SUMMARY}" >&2
  exit 1
fi

trap restore_filter EXIT

run_number=0
for run_spec in "${RUN_ORDER[@]}"; do
  read -r block position policy <<<"${run_spec}"
  run_number=$((run_number + 1))
  if ((run_number < START_RUN)); then
    continue
  fi
  workspace="${OUTPUT_ROOT}/block-${block}-${position}-${policy}"
  run_log="${workspace}.log"

  echo "BEGIN run=${run_number}/15 block=${block} position=${position} policy=${policy}"
  apply_policy "${policy}"

  cd "${BENCH_ROOT}"
  "${BENCH}" run \
    --workspace "${workspace}" \
    --specification_file guides/pd-disaggregation \
    --endpoint-url "${ENDPOINT}" \
    --gateway-class epponly \
    --model openai/gpt-oss-120b \
    --namespace "${NAMESPACE}" \
    --harness inference-perf \
    --workload-file-path "${ROOT}/workload-8k-256.yaml" \
    --experiments "${ROOT}/load-knee.yaml" \
    --wait-timeout 1800 \
    --pvc-bind-timeout 300 \
    --fast-collect \
    --analyze \
    --run-description "Randomized block ${block}, position ${position}, ${policy}, 8K/256 at 40 QPS" \
    >"${run_log}" 2>&1 &
  bench_pid=$!

  while kill -0 "${bench_pid}" 2>/dev/null; do
    sleep 20
    echo "HEARTBEAT run=${run_number}/15 policy=${policy} $(tail -n 1 "${run_log}" | tr -d '\r')"
  done
  wait "${bench_pid}"

  instance="$(find "${workspace}" -mindepth 1 -maxdepth 1 -type d -name 'niliguy-*' -print | sort | tail -n 1)"
  report="$(find "${instance}/results" -type f -name 'benchmark_report_v0.2,*' -print -quit)"
  stdout_log="$(find "${instance}/results" -type f -name stdout.log -print -quit)"
  if [[ -z "${report}" || -z "${stdout_log}" ]]; then
    echo "Missing collected report or stdout log for run ${run_number}" >&2
    exit 1
  fi

  stage_start="$(rg -m 1 'Stage 0 - run started' "${stdout_log}" | awk '{gsub(/,/,".",$2); print $1 "T" $2 "Z"}')"
  read -r local_routes remote_routes <<<"$(count_routes "${stage_start}")"

  metrics="$(yq -o=json '.' "${report}" | jq -r '.results.request_performance.aggregate | [.throughput.request_rate.mean,.latency.time_to_first_token.mean,.latency.time_to_first_token.p99,.latency.request_latency.mean,.latency.request_latency.p99,.requests.total,.requests.failures] | @tsv')"
  IFS=$'\t' read -r request_qps ttft_mean ttft_p99 e2e_mean e2e_p99 total_requests failures <<<"${metrics}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${block}" "${position}" "${policy}" "${stage_start}" "${local_routes}" "${remote_routes}" \
    "${request_qps}" "${ttft_mean}" "${ttft_p99}" "${e2e_mean}" "${e2e_p99}" \
    "${total_requests}" "${failures}" "${report}" >>"${SUMMARY}"

  echo "RESULT run=${run_number}/15 policy=${policy} local=${local_routes} remote=${remote_routes} qps=${request_qps} ttft_mean=${ttft_mean} e2e_mean=${e2e_mean} failures=${failures}"
done

trap - EXIT
restore_filter
echo "COMPLETE summary=${SUMMARY}"
