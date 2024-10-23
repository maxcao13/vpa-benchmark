#!/bin/bash
set -euo pipefail

# optional dependency: kube-capacity from krew
# This script builds off of benchmark.sh but adds larger scale tests (64 deployments -> 1024 deployments as last stage)

# Warning: Don't delete any VPA pods during the test. The outputted data will not display correctly.
# If that happens, you can deploy Grafana to visualize the data through the configured dashboards.
DIR="$(dirname "$(readlink -f "$0")")"
NS=vpa-benchmark
VPA_NS=openshift-vertical-pod-autoscaler
OUTPUT_DIR="$DIR/output"
test="${1:-all}"

case "$test" in
    idle|deployment|deployments|deployment-pods-1|deployment-pods-2|deployment-containers-1|deployment-containers-2|rate|all|debug)
        ;;
    *)
        echo "Invalid test option: [$test]. Exiting..."
        exit 1
        ;;
esac

function checkdep() {
	if ! command -v "$1" &> /dev/null; then
		echo "$1 is not installed. Exiting..."
		exit 1
	fi
}

function init() {
	for cmd in oc jq https numfmt; do
		checkdep "$cmd"
	done

	rm -rf "$DIR/output"
	mkdir -p "$DIR/output"

	# Redirect stdout and stderr to a log file but also print to stdout
	echo "Log location: $OUTPUT_DIR/benchmark.log"
	exec > >(tee -i "$OUTPUT_DIR/benchmark.log")
	exec 2>&1

	echo "Time now: $(date --iso-8601=s)"

	# Useful cluster info
	if oc cluster-info &> /dev/null; then
		worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker -o json)
		num_nodes=$(echo "${worker_nodes}" | jq -r '.items | length')

		aggregated_cpu=$(echo "${worker_nodes}" | jq -r '[.items[].status.capacity.cpu | tonumber] | add')
		# convert to from Ki to GiB
		aggregated_memory=$(echo "${worker_nodes}" | jq -r '[.items[].status.capacity.memory | sub("Ki$"; "") | tonumber] | add')
		aggregated_memory_formatted="$(numfmt --to=iec --suffix=i --format="%.0f" --from-unit=1024 "$aggregated_memory")"
		
		# if CPU less than 80 cores, and memory is less than 300GiB, then exit
		if [[ "$aggregated_cpu" -lt 80 ]] || [[ ${aggregated_memory_formatted//[^0-9]/} -lt 300 ]]; then
			echo "Cluster does not meet the minimum requirements. Exiting..."
			exit 1
		fi
		# if VPA operator is not installed, exit
		if ! oc explain verticalpodautoscalercontrollers &> /dev/null; then
			echo "VPA operator is not installed. Exiting..."
			exit 1
		fi

		# output number of pods in cluster
		num_pods=$(oc get pods --all-namespaces --no-headers | wc -l)

		echo "Cluster info: $num_nodes worker node(s) with a total of $aggregated_cpu CPU cores and $aggregated_memory_formatted memory. $num_pods total pods."

		# only output if kube-capacity is installed
		if command -v kube-capacity &> /dev/null; then
			kube-capacity
		elif command -v oc resource-capacity &> /dev/null; then
			echo "--- Resource Capacity ---"
			oc resource-capacity --node-labels=node-role.kubernetes.io/worker
			printf "\n"
		fi
	else
		echo "No cluster detected. Exiting..."
		exit 1
	fi

	prom_token=$(oc whoami --show-token)
	prom_host=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

	oc create ns "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null

	reset_vpacontroller
}

# Delete VPAs to reset the state
# Make sure old pods are deleted and new ones are ready
function restart_vpa() {
	local deployments
	deployments=$(oc get deploy -n "$VPA_NS" -o json | jq -r '.items[].metadata.name' | grep -E 'vpa-admission-plugin-default|vpa-recommender-default|vpa-updater-default')

	for deploy in $deployments; do
		oc delete deploy "$deploy" -n "$VPA_NS" --ignore-not-found >/dev/null
	done

	oc rollout status deploy/vpa-admission-plugin-default -n "$VPA_NS"
	oc rollout status deploy/vpa-recommender-default -n "$VPA_NS"
	oc rollout status deploy/vpa-updater-default -n "$VPA_NS"

	export_pod_names
	# wait until metrics are ready to be scraped
	retries=18 # sleep is 5s -> 18*5 = ~90s
	echo -n "Waiting for VPA pods to be ready for scraping... Retries left:"
	while [ "$retries" -gt 0 ]; do
		if is_component_ready "$cur_admission_pod" && is_component_ready "$cur_recommender_pod" && is_component_ready "$cur_updater_pod"; then
			break
		fi
		echo -n " $retries"
		sleep 5
		retries=$((retries - 1))
	done
	printf "\n"
}

function export_pod_names() {
	cur_admission_pod=$(oc get pods -n "$VPA_NS" -l app=vpa-admission-controller -o json | jq -r '.items[0].metadata.name')
	cur_recommender_pod=$(oc get pods -n "$VPA_NS" -l app=vpa-recommender -o json | jq -r '.items[0].metadata.name')
	cur_updater_pod=$(oc get pods -n "$VPA_NS" -l app=vpa-updater -o json | jq -r '.items[0].metadata.name')
	cur_operator_pod=$(oc get pods -n "$VPA_NS" -l app.kubernetes.io/name=vertical-pod-autoscaler-operator -o json | jq -r '.items[0].metadata.name')
}

function cleanup() {
	echo "Cleaning up..."
	delete_hamster_deployment_and_vpa
}

function query_prometheus_range() {
	local query=$1
	local start=$2
	local end=$3
	local step=$4

	https --verify=no "https://$prom_host/api/v1/query" \
    	query=="$query" \
    	"start==$start" \
    	"end==$end" \
    	"step==$step" \
    	-A bearer -a "$prom_token"
}

function query_prometheus_instant() {
	local query=$1
	local time=$2

	https --verify=no "https://$prom_host/api/v1/query" \
    	query=="$query" \
		"time==$time" \
    	-A bearer -a "$prom_token"
}

# Sends 4 instant PromQL queries to Prometheus HTTP API and returns in this format: <operator metric> | <admission metric> | <recommender metric> | <updater metric>
# Uses HTTPie to send requests to the Prometheus HTTP API
# - Instant query: Average <metric> usage over the last <duration> minutes
# - Instant query: Median <metric> usage over the last <duration>  minutes
# - Instant query: Max <metric> usage over the last <duration>  minutes
# - Instant query: Min <metric> usage over the last <duration>  minutes
function query_past_metrics() {
	local metric_type=$1
	local agg_type=$2 # avg, median, max, min
	local date_now=$3
	local duration=${4:-5} # Default: 5 minutes

	local query

	# only use the VPA pods with cur_pod_<component> names (terminated pods still show metrics for some time)
	if [ "$metric_type" == "memory" ]; then
    	if [ "$agg_type" == "avg" ]; then
        	query="sum by (pod)(avg_over_time(container_memory_working_set_bytes{namespace=\"$VPA_NS\",container!=\"\",image=~\".*vertical-pod-autoscaler.*\",pod=~\"${cur_operator_pod}|${cur_admission_pod}|${cur_recommender_pod}|${cur_updater_pod}\"}[${duration}m:]))"
    	elif [ "$agg_type" == "median" ]; then
        	query="sum by (pod)(quantile_over_time(0.5, container_memory_working_set_bytes{namespace=\"$VPA_NS\",container!=\"\",image=~\".*vertical-pod-autoscaler.*\",pod=~\"${cur_operator_pod}|${cur_admission_pod}|${cur_recommender_pod}|${cur_updater_pod}\"}[${duration}m:]))"
    	elif [ "$agg_type" == "max" ]; then
        	query="sum by (pod)(max_over_time(container_memory_working_set_bytes{namespace=\"$VPA_NS\",container!=\"\",image=~\".*vertical-pod-autoscaler.*\",pod=~\"${cur_operator_pod}|${cur_admission_pod}|${cur_recommender_pod}|${cur_updater_pod}\"}[${duration}m:]))"
    	elif [ "$agg_type" == "min" ]; then
        	query="sum by (pod)(min_over_time(container_memory_working_set_bytes{namespace=\"$VPA_NS\",container!=\"\",image=~\".*vertical-pod-autoscaler.*\",pod=~\"${cur_operator_pod}|${cur_admission_pod}|${cur_recommender_pod}|${cur_updater_pod}\"}[${duration}m:]))"
    	fi
	elif [ "$metric_type" == "cpu" ]; then
    	if [ "$agg_type" == "avg" ]; then
			query="sum by (pod)(avg_over_time(irate(container_cpu_usage_seconds_total{namespace=\"$VPA_NS\",container!=\"\",image=~\".*vertical-pod-autoscaler.*\",pod=~\"${cur_operator_pod}|${cur_admission_pod}|${cur_recommender_pod}|${cur_updater_pod}\"}[${duration}m])[${duration}m:]))"
		elif [ "$agg_type" == "median" ]; then
			query="sum by (pod)(quantile_over_time(0.5, irate(container_cpu_usage_seconds_total{namespace=\"$VPA_NS\",container!=\"\",image=~\".*vertical-pod-autoscaler.*\",pod=~\"${cur_operator_pod}|${cur_admission_pod}|${cur_recommender_pod}|${cur_updater_pod}\"}[${duration}m])[${duration}m:]))"
		elif [ "$agg_type" == "max" ]; then
			query="sum by (pod)(max_over_time(irate(container_cpu_usage_seconds_total{namespace=\"$VPA_NS\",container!=\"\",image=~\".*vertical-pod-autoscaler.*\",pod=~\"${cur_operator_pod}|${cur_admission_pod}|${cur_recommender_pod}|${cur_updater_pod}\"}[${duration}m])[${duration}m:]))"
		elif [ "$agg_type" == "min" ]; then
			query="sum by (pod)(min_over_time(irate(container_cpu_usage_seconds_total{namespace=\"$VPA_NS\",container!=\"\",image=~\".*vertical-pod-autoscaler.*\",pod=~\"${cur_operator_pod}|${cur_admission_pod}|${cur_recommender_pod}|${cur_updater_pod}\"}[${duration}m])[${duration}m:]))"
		fi
	elif [ "$metric_type" == "api" ]; then
		if [ "$agg_type" == "req" ]; then
			query="avg_over_time(sum(irate(apiserver_request_total[${duration}m]))[${duration}m:])"
		elif [ "$agg_type" == "webhook" ]; then
			query="avg_over_time(sum(rate(apiserver_admission_webhook_admission_duration_seconds_count{name=\"vpa.k8s.io\", type=\"admit\"}[${duration}m]))[${duration}m:])"
		elif [ "$agg_type" == "reqlatency" ]; then
			query="histogram_quantile(0.95, sum(resource_verb:apiserver_request_duration_seconds_bucket:rate:5m) by (le))"
		else
			echo "Unexpected aggregation type: [$agg_type]. Exiting..." && exit 1
		fi
	else
		echo "Unexpected metric type: [$metric_type]. Exiting..." && exit 1
	fi

	result=$(query_prometheus_instant "$query" "$date_now" | jq -r '.data.result | sort_by(.metric.pod)')

	num_pods=$(echo "$result" | jq -r 'length') # should be 4

	for i in $(seq 0 $((num_pods - 1))); do
    	value=$(echo "$result" | jq -r ".[$i].value[1]")
		if [ "$metric_type" == "cpu" ]; then
			value=$(printf "%.2fm\n" "$(echo "$value * 1000" | bc -l )") # always convert cores to millicores
		elif [ "$metric_type" == "memory" ]; then
			value=$(numfmt --to=iec-i --suffix=B --format="%.2f" "$value")
		elif [ "$metric_type" == "api" ]; then
			if [ "$agg_type" == "req" ]; then
				value=$(printf "%.2freq/s\n" "$value")
			elif [ "$agg_type" == "webhook" ] || [ "$agg_type" == "reqlatency" ]; then
				value=$(printf "%.2fms/req\n" "$(echo "$value * 1000" | bc -l )") # always convert seconds to milliseconds
			else 
				echo "Unexpected aggregation type: [$agg_type]. Exiting..." && exit 1
			fi
		else
			echo "Unexpected metric type: [$metric_type]. Exiting..." && exit 1
		fi
		echo -n "$value "
	done
}

# Formats the query_past_metrics results in a readable format
function format_results() {
	local results=$1
	local type=${2:-readable}
	local spacing=${3:-12}
	ret_results=""
	# shellcheck disable=SC2068
	for res in ${results[@]}; do
		if [ "$type" == "readable" ]; then
			# right pad the value with spaces to fit the table cells
			ret_results+="$(printf "%-${spacing}s| " "$res")"
		elif [ "$type" == "csv" ]; then
			ret_results+="$res;"
		fi
	done
	echo "$ret_results"
}

function display_metrics_table() {
	local metric_type=$1
	local min=${2:-5}
	local file=$3
	local step=$4
	local date_now=$5
	date_min_ago=$((date_now - min * 60))
	avg_results="$(query_past_metrics "$metric_type" "avg" "$date_now" "$min")"
	median_results="$(query_past_metrics "$metric_type" "median" "$date_now" "$min")"
	max_results="$(query_past_metrics "$metric_type" "max" "$date_now" "$min")"
	min_results="$(query_past_metrics "$metric_type" "min" "$date_now" "$min")"

	formatted_date=$(date -d @"$date_now" +%Y-%m-%dT%H:%M:%S)
	formatted_date_min_ago=$(date -d @"$date_min_ago" +%Y-%m-%dT%H:%M:%S)

	# Save results to csv; check if file exists, if not append the header
	if [ ! -f "$OUTPUT_DIR/$file.csv" ]; then
		printf "Step;Operator;Admission;Recommender;Updater\n" >"$OUTPUT_DIR/$file.csv"
	fi
	if [ "$metric_type" == "cpu" ]; then
		printf "%s;%s\n" "$step" "$(format_results "$avg_results" "csv")" >>"$OUTPUT_DIR/$file.csv"
	elif [ "$metric_type" == "memory" ]; then
		printf "%s;%s\n" "$step" "$(format_results "$avg_results" "csv")" >>"$OUTPUT_DIR/$file.csv"
	fi

	avg_result=$(format_results "$avg_results")
	median_result=$(format_results "$median_results")
	max_result=$(format_results "$max_results")
	min_result=$(format_results "$min_results")

	# from formatted date, to <min> minutes ago
	echo "Last ${min}m of $metric_type usage from $formatted_date_min_ago" to "$formatted_date"
	printf "+--------+-------------+-------------+-------------+-------------+\n"
	printf "| Type   | Operator    | Admission   | Recommender | Updater     |\n"
	printf "+--------+-------------+-------------+-------------+-------------+\n"
	printf "| %-6s | %0s \n" "mean" "${avg_result}"
	printf "| %-6s | %0s \n" "median" "${median_result}"
	printf "| %-6s | %0s \n" "max" "${max_result}"
	printf "| %-6s | %0s \n" "min" "${min_result}"
	printf "+--------+-------------+-------------+-------------+-------------+\n"
}

function display_api_table() {
	local min=${1:-5}
	local file=$2
	local step=$3
	local date_now=$4
	date_min_ago=$((date_now - min * 60))
	req_results="$(query_past_metrics "api" "req" "$date_now" "$min")"
	webhook_results="$(query_past_metrics "api" "webhook" "$date_now" "$min")"
	reqlatency_results="$(query_past_metrics "api" "reqlatency" "$date_now" "$min")"

	formatted_date=$(date -d @"$date_now" +%Y-%m-%dT%H:%M:%S)
	formatted_date_min_ago=$(date -d @"$date_min_ago" +%Y-%m-%dT%H:%M:%S)

	# Save results to csv; check if file exists, if not append the header
	if [ ! -f "$OUTPUT_DIR/$file.csv" ]; then
		printf "Step;APIPerformance;Webhook;RequestLatency\n" >"$OUTPUT_DIR/$file.csv"
	fi
	printf "%s;%s%s%s\n" "$step" "$(format_results "$req_results" "csv")" "$(format_results "$webhook_results" "csv")" "$(format_results "$reqlatency_results" "csv")" >>"$OUTPUT_DIR/$file.csv"

	req_result=$(format_results "$req_results" "readable" 13)
	webhook_result=$(format_results "$webhook_results" "readable" 13)
	reqlatency=$(format_results "$reqlatency_results" "readable" 13)

	echo "Last ${min}m of API usage from $formatted_date_min_ago to $formatted_date"
	printf "+------------+--------------+\n"
	printf "| Type       | Value        |\n"
	printf "+------------+--------------+\n"
	printf "| %-10s | %s \n" "apiperf" "${req_result}"
	printf "| %-10s | %s \n" "webhook" "${webhook_result}"
	printf "| %-10s | %s \n" "reqlatency" "${reqlatency}"
	printf "+------------+--------------+\n"
}

function display_tables() {
	local min=$1
	local phase=$2
	local title=$3

	date_now=$(date +%s)
	display_metrics_table memory "$min" "$phase"_memory_results "$title" "$date_now"
	display_metrics_table cpu "$min" "$phase"_cpu_results "$title" "$date_now"
	display_api_table "$min" "$phase"_api_results "$title" "$date_now"
}

function echol() {
	echo "----------------------------------------------------------------"
	echo "| $1"
	echo "----------------------------------------------------------------"
}

function echoh() {
	echo "################################################################"
	echo "# $1"
	echo "################################################################"
}

# If scale is set, the function will scale the hamster deployment to double the replicas
# num_resources: number of hamster deployments to create
# filename: the filename of the VPA yaml file to use
# replicas: the number of replicas to scale each hamster deployment to
function create_hamster_deployment_and_vpa() {
    local num_resources=$1
    local filename=${2:-hamster_vpa.yaml}
    local replicas=${3:-}
    local batch_limit=64
    local pids=()

    echo "Waiting for hamsters to roll out..."

    # Apply deployments in batches
    for i in $(seq 1 "$num_resources"); do
        (
            if [ -z "$replicas" ]; then
                sed "s/{{index}}/$i/g" "$DIR/performance/$filename" | oc apply -n "$NS" -f - >/dev/null
            else
                sed "s/{{index}}/$i/g" "$DIR/performance/$filename" | sed -r "s|^(\s*)replicas(.*)$|\1replicas: $replicas|" | oc apply -n "$NS" -f - >/dev/null
            fi
        ) & pids+=($!)

        # Wait for the batch to complete
        if (( ${#pids[@]} >= batch_limit )); then
            wait "${pids[@]}"
            pids=()
        fi
    done

	if (( ${#pids[@]} > 0 )); then
		wait "${pids[@]}"
		pids=()
	fi
}

function delete_hamster_deployment_and_vpa() {
	echo "Deleting hamster deployments..."
	oc delete vpacheckpoint -n "$NS" --all --grace-period=0 --force --wait=false >/dev/null
	oc delete vpa -n "$NS" --all --grace-period=0 --force --wait=false >/dev/null
	oc delete deploy -n "$NS" --all --grace-period=0 --force >/dev/null
}

function patch_vpa_rates() {
	local component=$1
	local qps=$2
	local burst=$3
	local memory_saver=${4:-"false"}

	if [ "$memory_saver" == "true" ] && [ "$component" != "recommender" ]; then
		echo "Memory saver can only be enabled for the recommender. Exiting..."
		exit 1
	fi
	if [ "$component" == "admission" ]; then
		deploy_name="vpa-admission-plugin-default"
	else 
		deploy_name="vpa-$component-default"
	fi
	# check if already paused
	paused=$(oc get deployment/vpa-admission-plugin-default -n openshift-vertical-pod-autoscaler -o jsonpath='{.status.conditions[0].reason}')
	if [ "$paused" != "DeploymentPaused" ]; then
		oc rollout pause deployment/"$deploy_name" -n "$VPA_NS" 2>/dev/null
	fi

	if [ "$memory_saver" == "true" ]; then
		oc patch verticalpodautoscalercontrollers -n "$VPA_NS" default -p "{\"spec\":{\"deploymentOverrides\":{\"${component}\":{\"container\":{\"args\":[\"--memory-saver=true\", \"--kube-api-qps=${qps}\",\"--kube-api-burst=${burst}\"]}}}}}" --type=merge
	else
		oc patch verticalpodautoscalercontrollers -n "$VPA_NS" default -p "{\"spec\":{\"deploymentOverrides\":{\"${component}\":{\"container\":{\"args\":[\"--kube-api-qps=${qps}\",\"--kube-api-burst=${burst}\"]}}}}}" --type=merge
	fi
}

function reset_vpacontroller() {
	oc patch verticalpodautoscalercontrollers -n "$VPA_NS" default -p '[{"op":"remove","path":"/spec/deploymentOverrides"}]' --type=json 2>/dev/null || true
}

function wait_metrics() {
	local min=$1
	echo "Waiting ${min}m for metrics data..."
	sleep "${min}m"
}

function is_component_ready() {
	local pod_name=$1
	local cur_mem
	local cur_cpu
	local ret
	mem_query=$(query_prometheus_instant "sum by (pod)(container_memory_working_set_bytes{pod=\"$pod_name\",namespace=\"$VPA_NS\",container!=\"\"})" "$(date +%s)")
	ret=$?
	if [ "$ret" -ne 0 ]; then
		return 1
	fi
	cpu_query=$(query_prometheus_instant "sum by (pod)(container_cpu_usage_seconds_total{pod=\"$pod_name\",namespace=\"$VPA_NS\",container!=\"\"})" "$(date +%s)")
	ret=$?
	if [ "$ret" -ne 0 ]; then
		return 1
	fi
	cur_mem=$(echo "$mem_query" | jq -r '.data.result[0].value[1]')
	ret=$?
	if [ "$ret" -ne 0 ]; then
		return 1
	fi
	cur_cpu=$(echo "$cpu_query" | jq -r '.data.result[0].value[1]')
	ret=$?
	if [ "$ret" -ne 0 ]; then
		return 1
	fi
	# make sure they are non zero and non null, otherwise return false
	if [ -z "$cur_mem" ] || [ -z "$cur_cpu" ] || [ "$cur_mem" == "null" ] || [ "$cur_cpu" == "null" ] || [ "$cur_mem" == "0" ] || [ "$cur_cpu" == "0" ]; then
		return 1
	else
		return 0
	fi
}

## ------------------- Test Phases ------------------- ##

function test_idle() {
	## ----- Test Phase (Idle) (0 deployments | 0 pods | 0 containers) ----- ##
	echoh "TEST PHASE (Idle) Starting at $(date --iso-8601=s)."
	restart_vpa
	## --- Test 1 --- ##
	echol "Testing with no hamster deployments (0 pods, 0 deployments, 0 VPAs)... $(date --iso-8601=s)"
	wait_metrics 10
	date_now=$(date +%s)
	display_tables 10 idle idle

	echoh "TEST PHASE (Idle): Completed at $(date --iso-8601=s)."
}

function test_deployment_step() {
	local workload=$1

	echol "Testing with $workload hamster deployments (1 pod each, 1 container each pod, $workload VPAs)... $(date --iso-8601=s)"
	create_hamster_deployment_and_vpa "$workload"

	wait_metrics 5
	date_now=$(date +%s)
	display_tables 5 deployment "$workload deployments"

	delete_hamster_deployment_and_vpa
}

function test_deployments() {
	restart_vpa
	echoh "TEST PHASE (Deployments): Starting at $(date --iso-8601=s)."
	test_deployment_step 64
	test_deployment_step 256
	test_deployment_step 640
	test_deployment_step 1024
	echoh "TEST PHASE (Deployments): Completed at $(date --iso-8601=s)."
}

function test_deployments_increased_pods_step() {
	local deployments=$1
	local replicas=$2

	echol "Testing with $deployments hamster deployments ($replicas pods each, 1 container each pod, $deployments VPAs)... $(date --iso-8601=s)"
	create_hamster_deployment_and_vpa "$deployments" "" "$replicas"

	wait_metrics 5
	display_tables 5 deployment-pods "$deployments deployments $replicas pods"
	
	delete_hamster_deployment_and_vpa
}

function test_deployments_increased_pods_1() {
	restart_vpa
	echoh "TEST PHASE (Deployment w/ Scaling Pods PART 1): Starting at $(date --iso-8601=s)."
	test_deployments_increased_pods_step 64 2
	test_deployments_increased_pods_step 256 2
	test_deployments_increased_pods_step 640 2
	test_deployments_increased_pods_step 1024 2
	echoh "TEST PHASE (Deployments w/ Scaling Pods PART 2): Completed at $(date --iso-8601=s)."
}

function test_deployments_increased_pods_2() {
	restart_vpa
	echoh "TEST PHASE (Deployment w/ Scaling Pods PART 2): Starting at $(date --iso-8601=s)."
	test_deployments_increased_pods_step 64 4
	test_deployments_increased_pods_step 256 4
	test_deployments_increased_pods_step 640 4
	test_deployments_increased_pods_step 1024 4
	echoh "TEST PHASE (Deployment w/ Scaling Pods PART 2): Completed at $(date --iso-8601=s)."
}

function test_deployments_increased_containers_step() {
	local deployments=$1
	local containers=$2

	echol "Testing with $deployments hamster deployments (1 pod each, $containers containers each pod, $deployments VPAs)... $(date --iso-8601=s)"
	create_hamster_deployment_and_vpa "$deployments" "hamster_vpa$containers.yaml"

	wait_metrics 5
	display_tables 5 deployment-containers "$deployments deployments $containers containers"

	delete_hamster_deployment_and_vpa
}

function test_deployments_increased_containers_1() {
	restart_vpa
	echoh "TEST PHASE (Deployments w/ Added Containers PART 1): Starting at $(date --iso-8601=s)."
	test_deployments_increased_containers_step 64 2
	test_deployments_increased_containers_step 256 2
	test_deployments_increased_containers_step 640 2
	test_deployments_increased_containers_step 1024 2
	echoh "TEST PHASE (Deployments w/ Added Containers PART 1): Completed at $(date --iso-8601=s)."
}

function test_deployments_increased_containers_2() {
	restart_vpa
	echoh "TEST PHASE (Deployments w/ Added Containers PART 2): Starting at $(date --iso-8601=s)."
	test_deployments_increased_containers_step 64 4
	test_deployments_increased_containers_step 256 4
	test_deployments_increased_containers_step 640 4
	test_deployments_increased_containers_step 1024 4
	echoh "TEST PHASE (Deployments w/ Added Containers PART 2): Completed at $(date --iso-8601=s)."
}

function test_rate_limiters_step() {
	local component=$1
	local qps=$2
	local burst=$3
	local containers=${4:-"1"}
	local memory_saver=${5:-"false"}

	local deployments=640

	echol "Testing with $deployments hamster deployments (1 pod each, $containers containers each pod, $deployments VPAs) with $qps QPS for $component... $(date --iso-8601=s)"
	if [ "$component" == "all" ]; then
		patch_vpa_rates "admission" "$qps" "$burst"
		patch_vpa_rates "recommender" "$qps" "$burst" "$memory_saver"
		patch_vpa_rates "updater" "$qps" "$burst"
	else
		patch_vpa_rates "$component" "$qps" "$burst" "$memory_saver"
	fi
	restart_vpa
	if [ "$containers" == "1" ]; then
		create_hamster_deployment_and_vpa "$deployments"
	else
		create_hamster_deployment_and_vpa "$deployments" "hamster_vpa$containers.yaml"
	fi

	wait_metrics 5
	if [ "$memory_saver" == "true" ]; then
		display_tables 5 rate-limiters "$deployments deployments|$containers containers|$component|$qps|Memory Saver"
	else
		display_tables 5 rate-limiters "$deployments deployments|$containers containers|$component|$qps"
	fi

	delete_hamster_deployment_and_vpa
	reset_vpacontroller
}

function test_rate_limiters() {
	# Test Phase (Rate Limiters) (640 deployments | 1 pod | 1 container)
	echoh "TEST PHASE (Rate Limiters): Starting at $(date --iso-8601=s)."
	## --- Test 1 --- ##
	test_rate_limiters_step "admission" 40 80 1
	## --- Test 3 --- ##
	test_rate_limiters_step "recommender" 40 80 1
	## --- Test 5 --- ##
	test_rate_limiters_step "updater" 40 80 1
	## --- Test 7 --- ##
	test_rate_limiters_step "all" 40 80 1
	## --- Test 9 --- ##
	test_rate_limiters_step "all" 80 160 1
	## --- Test 11 --- ##
	test_rate_limiters_step "all" 80 160 1 "true"

	echoh "TEST PHASE (Rate Limiters): Completed at $(date --iso-8601=s)."
}

init

trap cleanup EXIT ERR

if [[ "${test}" == "idle" ]]; then
	test_idle
elif [[ "${test}" == "deployments" ]] || [[ "${test}" == "deployment" ]]; then
	test_deployments
elif [[ "${test}" == "deployment-pods-1" ]]; then
	test_deployments
	test_deployments_increased_pods_1
	test_deployments_increased_pods_2
elif [[ "${test}" == "deployment-containers-1" ]]; then
	test_deployments
	test_deployments_increased_containers_1
	test_deployments_increased_containers_2
elif [[ "${test}" == "rate" ]]; then
	test_rate_limiters
elif [[ "${test}" == "all" ]]; then
	# Total time: ~2h
	echo "Running all tests..."
	test_idle
	echo

	test_deployments # ~25m
	echo

	test_deployments_increased_pods_1 # ~25m
	echo

	test_deployments_increased_pods_2 # ~25m
	echo

	test_deployments_increased_containers_1 # ~25m
	echo

	test_deployments_increased_containers_2 # ~25m
	echo

	test_rate_limiters # ~55m
	echo
elif [[ "${test}" == "debug" ]]; then
	echo "Debugging... at $(date --iso-8601=s)"
	export_pod_names
	# wait_metrics 5
	# display_metrics_table memory 5 debug_memory_results debug
	# display_metrics_table cpu 5 debug_cpu_results debug
	# display_api_table 5 debug_api_results debug
else
	echo "Unexpected arugment: [${test}]. Exiting..."
	exit 1
fi

echo "Benchmark completed."

# total time: ~3h20m
