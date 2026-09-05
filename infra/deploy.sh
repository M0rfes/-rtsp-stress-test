#!/usr/bin/env bash
# deploy.sh — upload source, launch 1 server + 10 clients, start the 6h clock,
# arm S3 log snapshots, 6-hour terminate, 90-minute failed-setup fuse, and a $95 budget stop.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"
STACK_NAME="rtsp-benchmark-infra"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUDGET_NAME="rtsp-benchmark-95usd"
BUDGET_LIMIT_USD="95"
BUDGET_EMAIL="${BUDGET_EMAIL:-}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
CPU_BASELINE="${CPU_BASELINE:-0}"
FLEET_HOURLY_USD="13.0"
SETUP_PLUS_RUN_HOURS="7"
NEED_STD_VCPU="164"
NEED_G_VCPU="20"
if [[ "$CPU_BASELINE" == "1" ]]; then
  FLEET_HOURLY_USD="0.15"
  SETUP_PLUS_RUN_HOURS="14"
  NEED_STD_VCPU="4"
  NEED_G_VCPU="0"
  INSTANCE_TYPE_OVERRIDE="m7i-flex.large"
  STREAM_COUNT_OVERRIDE="8"
fi
AWS_DEFAULT_REGION="$REGION"
export AWS_DEFAULT_REGION REGION

CPU_FRAMEWORKS=(
  "cpu-csharp|cpu/C#|c7i-8xlarge-cpu-csharp"
  "cpu-cpp|cpu/CPP|c7i-8xlarge-cpu-cpp"
  "cpu-iced|cpu/Rust-Iced|c7i-8xlarge-cpu-iced"
  "cpu-tauri|cpu/Rust-Tauri|c7i-8xlarge-cpu-tauri"
  "cpu-electron|cpu/Electron|c7i-8xlarge-cpu-electron"
)
GPU_FRAMEWORKS=(
  "gpu-csharp|gpu/C#|g4dn-xlarge-gpu-csharp"
  "gpu-cpp|gpu/CPP|g4dn-xlarge-gpu-cpp"
  "gpu-iced|gpu/Rust-Iced|g4dn-xlarge-gpu-iced"
  "gpu-tauri|gpu/Rust-Tauri|g4dn-xlarge-gpu-tauri"
  "gpu-electron|gpu/Electron|g4dn-xlarge-gpu-electron"
)

INSTANCE_IDS=()
SERVER_ID=""
BEFORE_GO=1

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

die() { log "ERROR: $*"; exit 1; }

utc_plus() {
  local hours="$1"
  local minutes="${2:-0}"
  if date -u -v+0H >/dev/null 2>&1; then
    date -u -v+"${hours}H" -v+"${minutes}M" +%Y-%m-%dT%H:%M:%S
  else
    date -u -d "+${hours} hours +${minutes} minutes" +%Y-%m-%dT%H:%M:%S
  fi
}

month_start_today() {
  if date -u -v+0H >/dev/null 2>&1; then
    date -u +%Y-%m-01
  else
    date -u +%Y-%m-01
  fi
}

tomorrow_utc() {
  if date -u -v+1d >/dev/null 2>&1; then
    date -u -v+1d +%Y-%m-%d
  else
    date -u -d tomorrow +%Y-%m-%d
  fi
}

cleanup_if_failed() {
  if [[ "$BEFORE_GO" == 1 && ${#INSTANCE_IDS[@]} -gt 0 ]]; then
    log "Setup failed; terminating ${#INSTANCE_IDS[@]} instances"
    aws ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}" --region "$REGION" >/dev/null || true
  fi
}
trap cleanup_if_failed EXIT

cfn_output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

launch_one() {
  local template_id="$1"
  local name="$2"
  local role="$3"
  local framework="$4"
  local userdata_file="$5"
  local type_args=()
  if [[ -n "${INSTANCE_TYPE_OVERRIDE:-}" ]]; then
    type_args=(--instance-type "$INSTANCE_TYPE_OVERRIDE")
  fi
  local id
  if [[ ${#type_args[@]} -gt 0 ]]; then
    id="$(aws ec2 run-instances \
      --region "$REGION" \
      --launch-template "LaunchTemplateId=${template_id}" \
      "${type_args[@]}" \
      --subnet-id "$SUBNET_ID" \
      --user-data "file://${userdata_file}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=rtsp-stress-test},{Key=ManagedBy,Value=rtsp-benchmark-infra},{Key=BenchmarkRun,Value=${RUN_ID}},{Key=Role,Value=${role}},{Key=Framework,Value=${framework}}]" \
      --query 'Instances[0].InstanceId' --output text)"
  else
    id="$(aws ec2 run-instances \
      --region "$REGION" \
      --launch-template "LaunchTemplateId=${template_id}" \
      --subnet-id "$SUBNET_ID" \
      --user-data "file://${userdata_file}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=rtsp-stress-test},{Key=ManagedBy,Value=rtsp-benchmark-infra},{Key=BenchmarkRun,Value=${RUN_ID}},{Key=Role,Value=${role}},{Key=Framework,Value=${framework}}]" \
      --query 'Instances[0].InstanceId' --output text)"
  fi
  INSTANCE_IDS+=("$id")
  LAST_INSTANCE_ID="$id"
  echo "$id"
}

write_cloud_init() {
  local out="$1"
  local role="$2"
  local extra="$3"
  cat >"$out" <<EOF
#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/rtsp-benchmark-userdata.log) 2>&1
export AWS_DEFAULT_REGION=${REGION}
export BENCHMARK_S3_BUCKET=${BUCKET}
export BENCHMARK_RUN_ID=${RUN_ID}
export BENCHMARK_ROLE=${role}
${extra}
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y awscli unzip || snap install aws-cli --classic
mkdir -p /opt/rtsp-stress-test
aws s3 cp "s3://${BUCKET}/code/${RUN_ID}/src.tar.gz" /tmp/src.tar.gz
tar -xzf /tmp/src.tar.gz -C /opt/rtsp-stress-test
chmod +x /opt/rtsp-stress-test/infra/*.sh
if [ "${role}" = "server" ]; then
  bash /opt/rtsp-stress-test/infra/userdata-server.sh
else
  bash /opt/rtsp-stress-test/infra/userdata-client.sh
fi
EOF
}

wait_ssm() {
  local expected="$1"
  local i
  for i in $(seq 1 80); do
    local count
    count="$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=tag:BenchmarkRun,Values=${RUN_ID}" \
      --query 'length(InstanceInformationList)' --output text)"
    log "SSM online: ${count}/${expected}"
    if [[ "$count" == "$expected" ]]; then
      return 0
    fi
    sleep 15
  done
  die "Timed out waiting for SSM (${expected} instances)"
}

wait_file_on_tag() {
  local tag_key="$1"
  local tag_val="$2"
  local path="$3"
  local tries="$4"
  local i cmd
  for i in $(seq 1 "$tries"); do
    cmd="$(aws ssm send-command --region "$REGION" \
      --document-name AWS-RunShellScript \
      --targets "Key=tag:${tag_key},Values=${tag_val}" \
      --parameters "commands=[\"test -f ${path}\"]" \
      --comment "wait ${path}" \
      --query 'Command.CommandId' --output text)"
    sleep 8
    local pending failed success
    pending="$(aws ssm list-command-invocations --region "$REGION" --command-id "$cmd" --query 'length(CommandInvocations[?Status==`Pending` || Status==`InProgress` || Status==`Delayed`])' --output text)"
    failed="$(aws ssm list-command-invocations --region "$REGION" --command-id "$cmd" --query 'length(CommandInvocations[?Status==`Failed` || Status==`Cancelled` || Status==`TimedOut`])' --output text)"
    success="$(aws ssm list-command-invocations --region "$REGION" --command-id "$cmd" --query 'length(CommandInvocations[?Status==`Success`])' --output text)"
    log "wait ${path}: success=${success} failed=${failed} pending=${pending}"
    if [[ "$pending" == "0" && "$failed" == "0" && "$success" != "0" ]]; then
      return 0
    fi
    sleep 20
  done
  die "Timed out waiting for ${path} on ${tag_key}=${tag_val}"
}

create_schedule() {
  local name="$1"
  local when="$2"
  local target_json="$3"
  aws scheduler delete-schedule --region "$REGION" --name "$name" >/dev/null 2>&1 || true
  aws scheduler create-schedule \
    --region "$REGION" \
    --name "$name" \
    --schedule-expression "at(${when})" \
    --schedule-expression-timezone UTC \
    --flexible-time-window '{"Mode":"OFF"}' \
    --action-after-completion DELETE \
    --target "$target_json" >/dev/null
  log "Schedule ${name} at ${when}Z"
}

arm_budget_stop() {
  local ids_csv="$1"
  [[ -n "$BUDGET_EMAIL" ]] || { log "BUDGET_EMAIL unset; \$95 budget is monitoring-only (no EC2 stop action)"; return 0; }
  local role_arn account_id
  role_arn="$(cfn_output BudgetActionsRoleArn)"
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  local actions
  actions="$(aws budgets describe-budget-actions-for-budget --region us-east-1 --account-id "$account_id" --budget-name "$BUDGET_NAME" \
    --query 'Actions[?ActionType==`RUN_SSM_DOCUMENTS`].ActionId' --output text 2>/dev/null || true)"
  local action_id
  for action_id in $actions; do
    aws budgets delete-budget-action --region us-east-1 --account-id "$account_id" --budget-name "$BUDGET_NAME" --action-id "$action_id" >/dev/null || true
  done
  local ids_json
  ids_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split(",")))' "$ids_csv")"
  aws budgets create-budget-action \
    --region us-east-1 \
    --account-id "$account_id" \
    --budget-name "$BUDGET_NAME" \
    --notification-type ACTUAL \
    --action-type RUN_SSM_DOCUMENTS \
    --action-threshold ActionThresholdType=PERCENTAGE,ActionThresholdValue=95 \
    --approval-model AUTOMATIC \
    --execution-role-arn "$role_arn" \
    --definition "$(python3 -c 'import json,sys; ids=sys.argv[1].split(","); print(json.dumps({"SsmActionDefinition":{"ActionSubType":"STOP_EC2_INSTANCES","Region":sys.argv[2],"InstanceIds":ids}}))' "$ids_csv" "$REGION")" \
    --subscribers "SubscriptionType=EMAIL,Address=${BUDGET_EMAIL}" >/dev/null
  log "Budget stop action armed at 95% of \$${BUDGET_LIMIT_USD}"
}

log "Region ${REGION}  run ${RUN_ID}"
log "Confirm this matches AWS Settings → View all projects → Overview → Additional Info → Region"

IDENTITY="$(aws sts get-caller-identity --output json)"
ACCOUNT_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<<"$IDENTITY")"
log "Account ${ACCOUNT_ID}"

if aws freetier get-account-plan-state >/dev/null 2>&1; then
  PLAN="$(aws freetier get-account-plan-state --query 'accountPlanType' --output text 2>/dev/null || echo UNKNOWN)"
  log "Account plan: ${PLAN}"
fi

STD_VCPU="$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-1216C47A --query Quota.Value --output text)"
G_VCPU="$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-DB2E81BA --query Quota.Value --output text)"
log "On-Demand vCPU quota  Standard=${STD_VCPU} (need ${NEED_STD_VCPU})  G/VT=${G_VCPU} (need ${NEED_G_VCPU})"
python3 - "$STD_VCPU" "$G_VCPU" "$NEED_STD_VCPU" "$NEED_G_VCPU" <<'PY'
import sys
std, g, need_std, need_g = map(float, sys.argv[1:])
errs = []
if std < need_std:
    errs.append(f"Standard On-Demand vCPU {std:.0f} < {need_std:.0f} (5×c7i.8xlarge + c7i.xlarge)")
if g < need_g:
    errs.append(f"G/VT On-Demand vCPU {g:.0f} < {need_g:.0f} (5×g4dn.xlarge)")
if errs:
    raise SystemExit("Quota too low for an official un-constrained run: " + "; ".join(errs))
PY

MTD="$(aws ce get-cost-and-usage \
  --time-period "Start=$(month_start_today),End=$(tomorrow_utc)" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter '{"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund"]}}}' \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text 2>/dev/null || echo 0)"
if [[ -z "$MTD" || "$MTD" == "None" || "$MTD" == "null" ]]; then
  MTD=0
fi
python3 - "$MTD" "$FLEET_HOURLY_USD" "$SETUP_PLUS_RUN_HOURS" "$BUDGET_LIMIT_USD" <<'PY'
import sys
mtd, hourly, hours, limit = map(float, sys.argv[1:])
projected = mtd + hourly * hours
print(f"MTD spend {mtd:.2f} + fleet {hourly:.2f}/h * {hours:.0f}h = {projected:.2f} (cap {limit:.0f})")
if projected > limit:
    raise SystemExit(f"Projected {projected:.2f} USD exceeds {limit:.0f} USD budget; aborting launch")
PY

VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" != "None" && -n "$VPC_ID" ]] || die "No default VPC in ${REGION}"
SUBNET_ID="$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'sort_by(Subnets,&AvailableIpAddressCount)[-1].SubnetId' --output text)"
log "VPC ${VPC_ID} subnet ${SUBNET_ID}"

UBUNTU_AMI="$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
GPU_AMI="$(aws ec2 describe-images --region "$REGION" --owners amazon \
  --filters 'Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*' 'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
[[ -n "$UBUNTU_AMI" && "$UBUNTU_AMI" != "None" ]] || die "Ubuntu 24.04 AMI not found"
[[ -n "$GPU_AMI" && "$GPU_AMI" != "None" ]] || die "Deep Learning GPU AMI not found"
log "Ubuntu AMI ${UBUNTU_AMI}"
log "GPU AMI ${GPU_AMI}"

CFN_PARAMS=(
  "UbuntuAmiId=${UBUNTU_AMI}"
  "GpuAmiId=${GPU_AMI}"
  "VpcId=${VPC_ID}"
  "BudgetLimitUsd=${BUDGET_LIMIT_USD}"
)
if [[ -n "$BUDGET_EMAIL" ]]; then
  CFN_PARAMS+=("BudgetNotificationEmail=${BUDGET_EMAIL}")
fi
if [[ "$CPU_BASELINE" == "1" ]]; then
  CFN_PARAMS+=("CpuVolumeSize=80")
fi

log "Deploying CloudFormation ${STACK_NAME} (includes \$${BUDGET_LIMIT_USD} monthly budget)"
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "${REPO_ROOT}/infra/cloudformation.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "${CFN_PARAMS[@]}"

BUCKET="$(cfn_output BucketName)"
SERVER_LT="$(cfn_output ServerLaunchTemplateId)"
CPU_LT="$(cfn_output CpuLaunchTemplateId)"
GPU_LT="$(cfn_output GpuLaunchTemplateId)"
SCHEDULER_ROLE="$(cfn_output SchedulerRoleArn)"
log "Bucket ${BUCKET}"

log "Uploading source tarball"
TARBALL="$(mktemp /tmp/rtsp-src.XXXXXX).tar.gz"
(
  cd "$REPO_ROOT"
  COPYFILE_DISABLE=1 tar -czf "$TARBALL" \
    --exclude='.git' \
    --exclude='.cursor' \
    --exclude='node_modules' \
    --exclude='dist' \
    --exclude='dist-electron' \
    --exclude='target' \
    --exclude='bin' \
    --exclude='obj' \
    --exclude='build' \
    --exclude='*.log' \
    .
)
aws s3 cp "$TARBALL" "s3://${BUCKET}/code/${RUN_ID}/src.tar.gz" --sse AES256 --region "$REGION"
rm -f "$TARBALL"

WORKDIR="$(mktemp -d /tmp/rtsp-deploy.XXXXXX)"
write_cloud_init "${WORKDIR}/server.sh" server ""

log "Launching RTSP server"
launch_one "$SERVER_LT" "rtsp-server-${RUN_ID}" server server "${WORKDIR}/server.sh" >/dev/null
SERVER_ID="$LAST_INSTANCE_ID"
log "Server ${SERVER_ID}"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$SERVER_ID"
SERVER_IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$SERVER_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
log "Server private IP ${SERVER_IP}"

if [[ "$CPU_BASELINE" == "1" ]]; then
  log "CPU baseline: Free Tier m7i-flex.large (2 vCPU/8GiB) + STREAM_COUNT=8"
  extra=$(cat <<E
export CPU_BASELINE=1
export STREAM_COUNT=${STREAM_COUNT_OVERRIDE:-8}
export BENCHMARK_FRAMEWORK=cpu-csharp
export BENCHMARK_FRAMEWORK_DIR='cpu/C#'
export RTSP_SERVER_IP=${SERVER_IP}
export RTSP_SERVER_INSTANCE_ID=${SERVER_ID}
export MACHINE_ID=m7i-flex-large-cpu-csharp
E
)
  write_cloud_init "${WORKDIR}/cpu-baseline.sh" client "$extra"
  launch_one "$CPU_LT" "cpu-baseline-${RUN_ID}" client cpu-baseline "${WORKDIR}/cpu-baseline.sh" >/dev/null
  log "Launched cpu-baseline client"
  EXPECTED_SSM=2
  FUSE_HOURS=4
  FUSE_MINUTES=0
  RUN_HOURS=12
else
  log "Launching 10 clients"
  for spec in "${CPU_FRAMEWORKS[@]}"; do
    IFS='|' read -r fw dir machine <<<"$spec"
    extra=$(cat <<E
export BENCHMARK_FRAMEWORK=${fw}
export BENCHMARK_FRAMEWORK_DIR='${dir}'
export RTSP_SERVER_IP=${SERVER_IP}
export MACHINE_ID=${machine}
E
)
    write_cloud_init "${WORKDIR}/${fw}.sh" client "$extra"
    launch_one "$CPU_LT" "${fw}-${RUN_ID}" client "$fw" "${WORKDIR}/${fw}.sh" >/dev/null
    log "Launched ${fw}"
  done
  for spec in "${GPU_FRAMEWORKS[@]}"; do
    IFS='|' read -r fw dir machine <<<"$spec"
    extra=$(cat <<E
export BENCHMARK_FRAMEWORK=${fw}
export BENCHMARK_FRAMEWORK_DIR='${dir}'
export RTSP_SERVER_IP=${SERVER_IP}
export MACHINE_ID=${machine}
E
)
    write_cloud_init "${WORKDIR}/${fw}.sh" client "$extra"
    launch_one "$GPU_LT" "${fw}-${RUN_ID}" client "$fw" "${WORKDIR}/${fw}.sh" >/dev/null
    log "Launched ${fw}"
  done
  EXPECTED_SSM=11
  FUSE_HOURS=1
  FUSE_MINUTES=30
  RUN_HOURS=6
fi

IDS_CSV="$(IFS=,; echo "${INSTANCE_IDS[*]}")"
IDS_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split(",")))' "$IDS_CSV")"
EC2_TERMINATE_TARGET="$(python3 -c 'import json,sys; ids=json.loads(sys.argv[1]); print(json.dumps({"RoleArn":sys.argv[2],"Arn":"arn:aws:scheduler:::aws-sdk:ec2:terminateInstances","Input":json.dumps({"InstanceIds":ids})}))' "$IDS_JSON" "$SCHEDULER_ROLE")"

FUSE_AT="$(utc_plus "$FUSE_HOURS" "$FUSE_MINUTES")"
create_schedule "rtsp-bench-${RUN_ID}-fuse" "$FUSE_AT" "$EC2_TERMINATE_TARGET"

arm_budget_stop "$IDS_CSV"

log "Waiting for SSM + provisioning (builds may take a while)"
wait_ssm "$EXPECTED_SSM"
READY_TRIES=150
[[ "$CPU_BASELINE" == "1" ]] && READY_TRIES=500
wait_file_on_tag BenchmarkRun "$RUN_ID" /var/lib/rtsp-benchmark/ready "$READY_TRIES"
wait_file_on_tag Role client /var/log/benchmark/fps_metrics.log "$READY_TRIES"

if [[ "$CPU_BASELINE" == "1" ]]; then
  log "CPU baseline sequence will start each 6h clock via reset-clock.sh"
else
  log "Starting 6-hour clock on server"
  GO_CMD="$(aws ssm send-command --region "$REGION" --instance-ids "$SERVER_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["sudo /opt/rtsp-server/go.sh"]' \
    --query 'Command.CommandId' --output text)"
  sleep 5
  aws ssm get-command-invocation --region "$REGION" --command-id "$GO_CMD" --instance-id "$SERVER_ID" \
    --query '[Status,StandardOutputContent]' --output text
fi

aws scheduler delete-schedule --region "$REGION" --name "rtsp-bench-${RUN_ID}-fuse" >/dev/null 2>&1 || true
BEFORE_GO=0

PHASE1_AT="$(utc_plus 3 0)"
FINAL_AT="$(utc_plus "$RUN_HOURS" 0)"
KILL_AT="$(utc_plus "$RUN_HOURS" 5)"

SSM_SYNC_PHASE1="$(cat <<EOF
{"RoleArn":"${SCHEDULER_ROLE}","Arn":"arn:aws:scheduler:::aws-sdk:ssm:sendCommand","Input":"{\"DocumentName\":\"AWS-RunShellScript\",\"Targets\":[{\"Key\":\"tag:BenchmarkRun\",\"Values\":[\"${RUN_ID}\"]}],\"Parameters\":{\"commands\":[\"/opt/rtsp-stress-test/infra/sync-logs.sh phase1\"]}}"}
EOF
)"
SSM_FINAL="$(cat <<EOF
{"RoleArn":"${SCHEDULER_ROLE}","Arn":"arn:aws:scheduler:::aws-sdk:ssm:sendCommand","Input":"{\"DocumentName\":\"AWS-RunShellScript\",\"Targets\":[{\"Key\":\"tag:BenchmarkRun\",\"Values\":[\"${RUN_ID}\"]}],\"Parameters\":{\"commands\":[\"/opt/rtsp-stress-test/infra/sync-logs.sh final; shutdown -h now\"]}}"}
EOF
)"
KILL_TARGET="$EC2_TERMINATE_TARGET"

create_schedule "rtsp-bench-${RUN_ID}-phase1" "$PHASE1_AT" "$SSM_SYNC_PHASE1"
create_schedule "rtsp-bench-${RUN_ID}-final" "$FINAL_AT" "$SSM_FINAL"
create_schedule "rtsp-bench-${RUN_ID}-kill" "$KILL_AT" "$KILL_TARGET"

aws s3 cp --region "$REGION" --sse AES256 - "s3://${BUCKET}/runs/${RUN_ID}/meta.json" <<EOF
{"run_id":"${RUN_ID}","region":"${REGION}","server_id":"${SERVER_ID}","instance_ids":${IDS_JSON},"budget_usd":${BUDGET_LIMIT_USD}}
EOF

log "Clock started. Logs: s3://${BUCKET}/runs/${RUN_ID}/"
if [[ "$CPU_BASELINE" == "1" ]]; then
  log "CPU baseline: sequential 5×2h (1h+1h) on m7i-flex.large, STREAM_COUNT=8. Terminate at T+${RUN_HOURS}h"
fi
log "Monthly budget: ${BUDGET_NAME} = ${BUDGET_LIMIT_USD} USD (daily eval; EventBridge terminate is the live cap)"
log "Done."
