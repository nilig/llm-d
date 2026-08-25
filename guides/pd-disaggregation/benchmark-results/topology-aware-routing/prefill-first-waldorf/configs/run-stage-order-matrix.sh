#!/usr/bin/env bash

set -euo pipefail

CONTEXT="waldorf_US-EAST-04A"
NAMESPACE="nilig-topology-prefill-first"
ROOT="/Users/niliguy/github.com/llm-d/tmp/topology-aware-prefill-first-waldorf"
ROUTER_DIR="${ROOT}/router"
OUTPUT_ROOT="${ROOT}/results/stage-order-40qps-v2"
BENCH_ROOT="/tmp/nilig-topology-benchmark-client/llm-d-benchmark"
BENCH="${BENCH_ROOT}/.venv/bin/llmdbenchmark"
KUBECONFIG_FILE="/private/tmp/nilig-waldorf-topology-kubeconfig"
ENDPOINT="http://10.16.2.164"
SUMMARY="${OUTPUT_ROOT}/summary.tsv"
START_RUN="${1:-1}"

# Three balanced blocks. Each policy occupies a different position in every
# block, limiting bias from cluster drift and policy order.
RUN_ORDER=(
  "1 1 prefill-filter"
  "1 2 decode-scorer"
  "1 3 prefill-baseline"
  "1 4 decode-filter"
  "1 5 prefill-scorer"
  "1 6 decode-baseline"
  "2 1 prefill-baseline"
  "2 2 decode-filter"
  "2 3 prefill-scorer"
  "2 4 decode-baseline"
  "2 5 prefill-filter"
  "2 6 decode-scorer"
  "3 1 prefill-scorer"
  "3 2 decode-baseline"
  "3 3 prefill-filter"
  "3 4 decode-scorer"
  "3 5 prefill-baseline"
  "3 6 decode-filter"
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
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" patch configmap topology-pfirst-epp --type=json -p="${patch}"
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout restart deployment/topology-pfirst-epp
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout status deployment/topology-pfirst-epp --timeout=180s

  live_config="$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get configmap topology-pfirst-epp -o jsonpath='{.data.topology-config\.yaml}')"
  case "${policy}" in
    *-filter)
      rg -q 'topology-affinity-filter' <<<"${live_config}"
      ;;
    *-scorer)
      rg -q 'topology-affinity-scorer' <<<"${live_config}"
      ;;
    *-baseline)
      if rg -q 'topology-affinity-(filter|scorer)' <<<"${live_config}"; then
        echo "Baseline unexpectedly contains a topology-affinity plugin" >&2
        return 1
      fi
      ;;
  esac
  if [[ "${policy}" == prefill-* ]]; then
    rg -q 'stageOrder: prefill-first' <<<"${live_config}"
  elif rg -q 'stageOrder: prefill-first' <<<"${live_config}"; then
    echo "Decode-first policy unexpectedly contains stageOrder: prefill-first" >&2
    return 1
  fi
}

restore_policy() {
  set +e
  echo "RESTORE policy=prefill-filter"
  apply_policy prefill-filter
}

count_routes() {
  local stage_start="$1"
  local pod_map_file
  local routes_file
  local decoder
  local decoder_node

  pod_map_file="$(mktemp)"
  routes_file="$(mktemp)"
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods \
    -l llm-d.ai/inference-serving=true \
    -o jsonpath='{range .items[*]}{.status.podIP}{" "}{.spec.nodeName}{"\n"}{end}' \
    >"${pod_map_file}"

  while read -r decoder decoder_node; do
    [[ -n "${decoder}" && -n "${decoder_node}" ]] || continue
    kubectl --context "${CONTEXT}" -n "${NAMESPACE}" logs "${decoder}" \
      -c routing-proxy --since-time="${stage_start}" \
      | jq -Rr 'fromjson? | select(.msg=="sending prefill request") | .to' \
      | awk -v decoder_node="${decoder_node}" '{sub(/:.*/, "", $0); print decoder_node, $0}' \
      >>"${routes_file}"
  done < <(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods \
    -l llm-d.ai/role=decode \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')

  awk '
    NR == FNR { node_by_ip[$1] = $2; next }
    !($2 in node_by_ip) { unresolved++; next }
    $1 == node_by_ip[$2] { local_routes++; next }
    { remote_routes++ }
    END { print local_routes + 0, remote_routes + 0, unresolved + 0 }
  ' "${pod_map_file}" "${routes_file}"
  rm -f "${pod_map_file}" "${routes_file}"
}

mkdir -p "${OUTPUT_ROOT}"
if [[ "${START_RUN}" == "1" ]]; then
  printf 'block\tposition\tpolicy\tstage_order\tplugin\tstage_start\tlocal_routes\tremote_routes\tunresolved_routes\trequest_qps\tttft_mean_s\tttft_p99_s\te2e_mean_s\te2e_p99_s\ttotal_requests\tfailures\treport\n' >"${SUMMARY}"
elif [[ ! -s "${SUMMARY}" ]]; then
  echo "Cannot resume without an existing summary: ${SUMMARY}" >&2
  exit 1
fi

trap restore_policy EXIT

run_number=0
for run_spec in "${RUN_ORDER[@]}"; do
  read -r block position policy <<<"${run_spec}"
  run_number=$((run_number + 1))
  if ((run_number < START_RUN)); then
    continue
  fi

  stage_order="${policy%%-*}"
  plugin="${policy#*-}"
  workspace="${OUTPUT_ROOT}/block-${block}-${position}-${policy}"
  run_log="${workspace}.log"

  echo "BEGIN run=${run_number}/18 block=${block} position=${position} policy=${policy}"
  apply_policy "${policy}"

  cd "${BENCH_ROOT}"
  "${BENCH}" run \
    --workspace "${workspace}" \
    --specification_file guides/pd-disaggregation \
    --kubeconfig "${KUBECONFIG_FILE}" \
    --endpoint-url "${ENDPOINT}" \
    --gateway-class epponly \
    --model openai/gpt-oss-120b \
    --namespace "${NAMESPACE}" \
    --harness inference-perf \
    --workload-file-path "${ROOT}/workload-8k-256.yaml" \
    --experiments "${ROOT}/load-40qps.yaml" \
    --wait-timeout 1800 \
    --pvc-bind-timeout 300 \
    --fast-collect \
    --analyze \
    --run-description "Stage-order block ${block}, position ${position}, ${policy}, 8K/256 at 40 QPS" \
    >"${run_log}" 2>&1 &
  bench_pid=$!

  while kill -0 "${bench_pid}" 2>/dev/null; do
    sleep 20
    echo "HEARTBEAT run=${run_number}/18 policy=${policy} $(tail -n 1 "${run_log}" | tr -d '\r')"
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
  read -r local_routes remote_routes unresolved_routes <<<"$(count_routes "${stage_start}")"

  metrics="$(yq -o=json '.' "${report}" | jq -r '.results.request_performance.aggregate | [.throughput.request_rate.mean,.latency.time_to_first_token.mean,.latency.time_to_first_token.p99,.latency.request_latency.mean,.latency.request_latency.p99,.requests.total,.requests.failures] | @tsv')"
  IFS=$'\t' read -r request_qps ttft_mean ttft_p99 e2e_mean e2e_p99 total_requests failures <<<"${metrics}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${block}" "${position}" "${policy}" "${stage_order}" "${plugin}" "${stage_start}" \
    "${local_routes}" "${remote_routes}" "${unresolved_routes}" \
    "${request_qps}" "${ttft_mean}" "${ttft_p99}" "${e2e_mean}" "${e2e_p99}" \
    "${total_requests}" "${failures}" "${report}" >>"${SUMMARY}"

  echo "RESULT run=${run_number}/18 policy=${policy} local=${local_routes} remote=${remote_routes} unresolved=${unresolved_routes} qps=${request_qps} ttft_mean=${ttft_mean} e2e_mean=${e2e_mean} failures=${failures}"
done

trap - EXIT
restore_policy
echo "COMPLETE summary=${SUMMARY}"
