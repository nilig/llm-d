#!/usr/bin/env bash

set -euo pipefail

CONTEXT="waldorf_US-EAST-04A"
NAMESPACE="nilig-topology-prefill-first"
ROOT="/Users/niliguy/github.com/llm-d/tmp/topology-aware-prefill-first-waldorf"
ROUTER_DIR="${ROOT}/router"
OUTPUT_ROOT="${ROOT}/results/prefill-rdma-rerun-20260826"
BENCH_ROOT="/tmp/nilig-topology-benchmark-client/llm-d-benchmark"
BENCH="${BENCH_ROOT}/.venv/bin/llmdbenchmark"
KUBECONFIG_FILE="${ROOT}/results/stage-order-40qps-v2/block-2-2-decode-filter/niliguy-20260825-102029-600/environment/context.ctx"
SUMMARY="${OUTPUT_ROOT}/summary.tsv"
ATTEMPTS="${OUTPUT_ROOT}/attempts.tsv"
MAX_ATTEMPTS=2
START_RUN="${START_RUN:-1}"
ATTEMPT_OFFSET="${ATTEMPT_OFFSET:-0}"

RUN_ORDER=(
  "1 1 filter"
  "1 2 scorer"
  "1 3 baseline"
  "2 1 baseline"
  "2 2 filter"
  "2 3 scorer"
  "3 1 scorer"
  "3 2 baseline"
  "3 3 filter"
)

apply_policy() {
  local policy="$1"
  local config
  local live_config
  local patch

  config="$(yq -r '.router.epp.pluginsCustomConfig."topology-config.yaml"' "${ROUTER_DIR}/prefill-${policy}.values.yaml")"
  if [[ -z "${config}" || "${config}" == "null" ]]; then
    echo "Policy ${policy} rendered an empty router configuration" >&2
    return 1
  fi

  patch="$(jq -n --arg config "${config}" '[{"op":"replace","path":"/data/topology-config.yaml","value":$config}]')"
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" patch configmap topology-pfirst-epp --type=json -p="${patch}"
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout restart deployment/topology-pfirst-epp
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout status deployment/topology-pfirst-epp --timeout=180s

  live_config="$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get configmap topology-pfirst-epp -o jsonpath='{.data.topology-config\.yaml}')"
  rg -q 'stageOrder: prefill-first' <<<"${live_config}"
  case "${policy}" in
    filter)
      rg -q 'topology-affinity-filter' <<<"${live_config}"
      ;;
    scorer)
      rg -q 'topology-affinity-scorer' <<<"${live_config}"
      ;;
    baseline)
      if rg -q 'topology-affinity-(filter|scorer)' <<<"${live_config}"; then
        echo "Baseline unexpectedly contains a topology-affinity plugin" >&2
        return 1
      fi
      ;;
  esac
}

scale_down() {
  set +e
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" scale deployment \
    pd-pfirst-prefill-0 pd-pfirst-prefill-1 \
    pd-pfirst-decode-0 pd-pfirst-decode-1 \
    topology-pfirst-epp --replicas=0
}

cleanup() {
  set +e
  apply_policy filter
  scale_down
}

model_fingerprint() {
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods \
    -l llm-d.ai/inference-serving=true -o json \
    | jq -r '.items[] | [.metadata.name,.metadata.uid,([.status.containerStatuses[]?.restartCount] | add // 0)] | @tsv' \
    | sort
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
  printf 'block\tposition\tpolicy\tattempt\tstage_start\tlocal_routes\tremote_routes\tunresolved_routes\trequest_qps\tttft_mean_s\tttft_p99_s\te2e_mean_s\te2e_p99_s\ttotal_requests\tfailures\treport\n' >"${SUMMARY}"
  printf 'block\tposition\tpolicy\tattempt\tstatus\treason\trequest_qps\ttotal_requests\tfailures\tworkspace\n' >"${ATTEMPTS}"
elif [[ ! -s "${SUMMARY}" || ! -s "${ATTEMPTS}" ]]; then
  echo "Cannot resume without existing summary and attempt logs" >&2
  exit 1
fi

ENDPOINT="http://$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get service topology-pfirst-epp -o jsonpath='{.spec.clusterIP}')"
INITIAL_MODELS="$(model_fingerprint)"
if [[ "$(wc -l <<<"${INITIAL_MODELS}" | tr -d ' ')" != "10" ]]; then
  echo "Expected 10 model pods before the matrix" >&2
  exit 1
fi

trap cleanup EXIT INT TERM

run_number=0
for run_spec in "${RUN_ORDER[@]}"; do
  read -r block position policy <<<"${run_spec}"
  run_number=$((run_number + 1))
  if (( run_number < START_RUN )); then
    continue
  fi
  valid_run=false
  for attempt_index in $(seq 1 "${MAX_ATTEMPTS}"); do
    attempt=$((attempt_index + ATTEMPT_OFFSET))
    workspace="${OUTPUT_ROOT}/block-${block}-${position}-${policy}-attempt-${attempt}"
    run_log="${workspace}.log"

    echo "BEGIN run=${run_number}/9 block=${block} position=${position} policy=${policy} attempt=${attempt} (resume try ${attempt_index}/${MAX_ATTEMPTS})"
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
      --run-description "Prefill-first RDMA rerun block ${block}, position ${position}, ${policy}, attempt ${attempt}, 8K/256 at 40 QPS" \
      >"${run_log}" 2>&1 &
    bench_pid=$!

    while kill -0 "${bench_pid}" 2>/dev/null; do
      sleep 20
      echo "HEARTBEAT run=${run_number}/9 policy=${policy} attempt=${attempt} $(tail -n 1 "${run_log}" | tr -d '\r')"
    done
    if ! wait "${bench_pid}"; then
      printf '%s\t%s\t%s\t%s\tinvalid\tbenchmark-command-failed\t\t\t\t%s\n' \
        "${block}" "${position}" "${policy}" "${attempt}" "${workspace}" >>"${ATTEMPTS}"
      echo "Invalid attempt: benchmark command failed" >&2
      continue
    fi

    instance="$(find "${workspace}" -mindepth 1 -maxdepth 1 -type d -name 'niliguy-*' -print | sort | tail -n 1)"
    report="$(find "${instance}/results" -type f -name 'benchmark_report_v0.2,*' -print -quit)"
    stdout_log="$(find "${instance}/results" -type f -name stdout.log -print -quit)"
    if [[ -z "${report}" || -z "${stdout_log}" ]]; then
      printf '%s\t%s\t%s\t%s\tinvalid\tmissing-report\t\t\t\t%s\n' \
        "${block}" "${position}" "${policy}" "${attempt}" "${workspace}" >>"${ATTEMPTS}"
      echo "Invalid attempt: missing report or stdout log" >&2
      continue
    fi

    stage_start="$(rg -m 1 'Stage 0 - run started' "${stdout_log}" | awk '{gsub(/,/,".",$2); print $1 "T" $2 "Z"}')"
    read -r local_routes remote_routes unresolved_routes <<<"$(count_routes "${stage_start}")"
    metrics="$(yq -o=json '.' "${report}" | jq -r '.results.request_performance.aggregate | [.throughput.request_rate.mean,.latency.time_to_first_token.mean,.latency.time_to_first_token.p99,.latency.request_latency.mean,.latency.request_latency.p99,.requests.total,.requests.failures] | @tsv')"
    IFS=$'\t' read -r request_qps ttft_mean ttft_p99 e2e_mean e2e_p99 total_requests failures <<<"${metrics}"

    if [[ "$(model_fingerprint)" != "${INITIAL_MODELS}" ]]; then
      echo "Invalid run: a model pod restarted or was replaced" >&2
      exit 1
    fi

    invalid_reason=""
    route_events=$((local_routes + remote_routes + unresolved_routes))
    if [[ "${unresolved_routes}" != "0" ]]; then
      invalid_reason="unresolved-routes-${unresolved_routes}"
    elif [[ "${failures}" != "0" ]]; then
      invalid_reason="request-failures-${failures}"
    elif [[ "${total_requests}" != "4800" ]]; then
      invalid_reason="request-total-${total_requests}"
    elif ! awk -v routed="${route_events}" -v total="${total_requests}" 'BEGIN { exit !(routed / total >= 0.90) }'; then
      invalid_reason="route-log-coverage-${route_events}-of-${total_requests}"
    elif ! awk -v qps="${request_qps}" 'BEGIN { exit !(qps >= 38.0) }'; then
      invalid_reason="achieved-qps-${request_qps}"
    fi

    if [[ -n "${invalid_reason}" ]]; then
      printf '%s\t%s\t%s\t%s\tinvalid\t%s\t%s\t%s\t%s\t%s\n' \
        "${block}" "${position}" "${policy}" "${attempt}" "${invalid_reason}" \
        "${request_qps}" "${total_requests}" "${failures}" "${workspace}" >>"${ATTEMPTS}"
      echo "Invalid attempt: ${invalid_reason}" >&2
      continue
    fi

    printf '%s\t%s\t%s\t%s\tvalid\t\t%s\t%s\t%s\t%s\n' \
      "${block}" "${position}" "${policy}" "${attempt}" \
      "${request_qps}" "${total_requests}" "${failures}" "${workspace}" >>"${ATTEMPTS}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${block}" "${position}" "${policy}" "${attempt}" "${stage_start}" \
      "${local_routes}" "${remote_routes}" "${unresolved_routes}" \
      "${request_qps}" "${ttft_mean}" "${ttft_p99}" "${e2e_mean}" "${e2e_p99}" \
      "${total_requests}" "${failures}" "${report}" >>"${SUMMARY}"

    echo "RESULT run=${run_number}/9 policy=${policy} attempt=${attempt} local=${local_routes} remote=${remote_routes} qps=${request_qps} ttft_mean=${ttft_mean} e2e_mean=${e2e_mean}"
    valid_run=true
    break
  done

  if [[ "${valid_run}" != "true" ]]; then
    echo "No valid attempt for run ${run_number}/9 policy=${policy}" >&2
    exit 1
  fi
done

trap - EXIT INT TERM
cleanup
echo "COMPLETE summary=${SUMMARY}"
