#!/usr/bin/env bash
#
#  Copyright 2016 Amazon.com, Inc. or its affiliates.
#  All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at
#
#      http://aws.amazon.com/apache2.0/
#
#  or in the "license" file accompanying this file.
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
#  CONDITIONS OF ANY KIND, either express or implied. See the License
#  for the specific language governing permissions and limitations
#  under the License.
#
# migrate_param_group.sh
#
# Usage:
#   ./migrate_param_group.sh -s <source_group> -t <target_group> -f <target_family> [-S source_region] [-T target_region] [-b batch_size] [-n]
#
# Options:
#   -s  Source parameter group name   (required)
#   -t  Target parameter group name   (required)
#   -f  Target parameter group family (required)
#   -S  Source AWS region             (default: AWS CLI configured region)
#   -T  Target AWS region             (default: AWS CLI configured region)
#   -b  Batch size                    (default: 20)
#   -n  Dry run
#
# Examples:
#   ./migrate_param_group.sh -s my-rds-pg15 -t my-aurora-pg15 -f aurora-postgresql15
#   ./migrate_param_group.sh -s my-rds-mysql80 -t my-aurora-mysql80 -f aurora-mysql8.0
#   ./migrate_param_group.sh -s my-rds-pg15 -t my-rds-pg15-copy -f postgres15 -S us-east-1 -T ap-southeast-1
#   ./migrate_param_group.sh -s my-rds-pg15 -t my-aurora-pg15 -f aurora-postgresql15 -n

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────
CLI_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
SOURCE_REGION="${CLI_REGION}"
TARGET_REGION="${CLI_REGION}"
BATCH_SIZE=20
DRY_RUN=false

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}=== $* ===${NC}"; }

# ── Parse Args ────────────────────────────────────────────
while getopts "s:t:f:S:T:b:nh" opt; do
  case ${opt} in
    s) SOURCE_PARAM_GROUP="${OPTARG}" ;;
    t) TARGET_PARAM_GROUP="${OPTARG}" ;;
    f) TARGET_FAMILY="${OPTARG}"      ;;
    S) SOURCE_REGION="${OPTARG}"      ;;
    T) TARGET_REGION="${OPTARG}"      ;;
    b) BATCH_SIZE="${OPTARG}"         ;;
    n) DRY_RUN=true                   ;;
    *) grep "^#" "$0" | sed 's/^# \?//'; exit 1 ;;
  esac
done

if [[ -z "${SOURCE_PARAM_GROUP:-}" || \
      -z "${TARGET_PARAM_GROUP:-}" || \
      -z "${TARGET_FAMILY:-}" ]]; then
  log_error "Missing required arguments: -s, -t, -f"
  exit 1
fi

# ── Working Directory ─────────────────────────────────────
WORK_DIR="migration_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${WORK_DIR}"
EXPORT_FILE="${WORK_DIR}/source_params.json"
TARGET_VALID_FILE="${WORK_DIR}/target_valid_params.json"
APPLICABLE_FILE="${WORK_DIR}/params_applicable.json"
SKIPPED_FILE="${WORK_DIR}/params_skipped.json"
INCOMPATIBLE_FILE="${WORK_DIR}/params_incompatible.json"
FAILED_FILE="${WORK_DIR}/params_failed.json"
REPORT_FILE="${WORK_DIR}/migration_report.txt"
FAILED_TMP="${WORK_DIR}/.params_failed_tmp.json"
echo '[]' > "${FAILED_TMP}"

# ── Parameter Prerequisites ───────────────────────────────
# Format: "param_name:condition:prereq_name:prereq_value:prereq_method:override_value"
#
# param_name    : parameter to check
# condition     : "ne1" = apply only when source value != 1
# prereq_name   : prerequisite parameter to apply first
# prereq_value  : prerequisite parameter value
# prereq_method : apply method for prerequisite
# override_value: value to use instead of original source value
#
# innodb_flush_log_at_trx_commit:
#   - If source value != 1 (e.g. 0 or 2 from standard MySQL)
#   - Aurora MySQL 3 only supports 0 or 1 (not 2)
#   - Step 1: set innodb_trx_commit_allow_data_loss = 1
#   - Step 2: set innodb_flush_log_at_trx_commit = 0

PARAM_PREREQUISITES=(
  "innodb_flush_log_at_trx_commit:ne1:innodb_trx_commit_allow_data_loss:1:pending-reboot:0"
)

# ── Engine Helpers ────────────────────────────────────────

detect_group_type() {
  # $1 = group name, $2 = region
  aws rds describe-db-cluster-parameter-groups \
    --db-cluster-parameter-group-name "$1" \
    --region "$2" --output json > /dev/null 2>&1 \
    && echo "cluster" && return
  aws rds describe-db-parameter-groups \
    --db-parameter-group-name "$1" \
    --region "$2" --output json > /dev/null 2>&1 \
    && echo "instance" && return
  echo "not_found"
}

target_group_type_from_family() {
  case "$1" in
    aurora-postgresql*|aurora-mysql*) echo "cluster"  ;;
    *)                                echo "instance" ;;
  esac
}

get_source_family() {
  # $1 = group name, $2 = group type, $3 = region
  if [[ "$2" == "cluster" ]]; then
    aws rds describe-db-cluster-parameter-groups \
      --db-cluster-parameter-group-name "$1" --region "$3" \
      --query 'DBClusterParameterGroups[0].DBParameterGroupFamily' --output text
  else
    aws rds describe-db-parameter-groups \
      --db-parameter-group-name "$1" --region "$3" \
      --query 'DBParameterGroups[0].DBParameterGroupFamily' --output text
  fi
}

# ── Export / Fetch ────────────────────────────────────────

export_params() {
  # $1 = group name, $2 = group type, $3 = region
  if [[ "$2" == "cluster" ]]; then
    aws rds describe-db-cluster-parameters \
      --db-cluster-parameter-group-name "$1" --source user \
      --region "$3" --output json \
      | jq '[.Parameters[] | select(.ParameterValue != null)]' > "${EXPORT_FILE}"
  else
    aws rds describe-db-parameters \
      --db-parameter-group-name "$1" --source user \
      --region "$3" --output json \
      | jq '[.Parameters[] | select(.ParameterValue != null)]' > "${EXPORT_FILE}"
  fi
}

fetch_target_valid_params() {
  # $1 = group name, $2 = group type, $3 = region
  if [[ "$2" == "cluster" ]]; then
    aws rds describe-db-cluster-parameters \
      --db-cluster-parameter-group-name "$1" \
      --region "$3" --output json \
      | jq '[.Parameters[]]' > "${TARGET_VALID_FILE}"
  else
    aws rds describe-db-parameters \
      --db-parameter-group-name "$1" \
      --region "$3" --output json \
      | jq '[.Parameters[]]' > "${TARGET_VALID_FILE}"
  fi
}

# ── Create Target Group ───────────────────────────────────

create_target_group() {
  # $1 = group name, $2 = family, $3 = description, $4 = group type, $5 = region
  local group_name="$1" family="$2" description="$3"
  local group_type="$4" region="$5"
  local error_msg

  if [[ "${group_type}" == "cluster" ]]; then
    error_msg=$(
      aws rds create-db-cluster-parameter-group \
        --db-cluster-parameter-group-name "${group_name}" \
        --db-parameter-group-family "${family}" \
        --description "${description}" \
        --region "${region}" \
        --output json 2>&1
    ) && {
      log_info "Created cluster parameter group: ${group_name} (${region})"
      return 0
    }
  else
    error_msg=$(
      aws rds create-db-parameter-group \
        --db-parameter-group-name "${group_name}" \
        --db-parameter-group-family "${family}" \
        --description "${description}" \
        --region "${region}" \
        --output json 2>&1
    ) && {
      log_info "Created instance parameter group: ${group_name} (${region})"
      return 0
    }
  fi

  # Any failure — stop migration
  log_error "Failed to create parameter group: ${group_name}"
  log_error "Reason: $(echo "${error_msg}" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
  exit 1
}

# ── Apply ─────────────────────────────────────────────────

apply_single_param() {
  # $1 = group name, $2 = param json array, $3 = group type, $4 = region
  if [[ "$3" == "cluster" ]]; then
    aws rds modify-db-cluster-parameter-group \
      --db-cluster-parameter-group-name "$1" \
      --parameters "$2" \
      --region "$4" --output json > /dev/null 2>&1
  else
    aws rds modify-db-parameter-group \
      --db-parameter-group-name "$1" \
      --parameters "$2" \
      --region "$4" --output json > /dev/null 2>&1
  fi
}

get_error_msg() {
  # $1 = group name, $2 = param json array, $3 = group type, $4 = region
  if [[ "$3" == "cluster" ]]; then
    aws rds modify-db-cluster-parameter-group \
      --db-cluster-parameter-group-name "$1" \
      --parameters "$2" \
      --region "$4" 2>&1 || true
  else
    aws rds modify-db-parameter-group \
      --db-parameter-group-name "$1" \
      --parameters "$2" \
      --region "$4" 2>&1 || true
  fi | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'
}

check_condition() {
  # $1 = condition, $2 = param value
  # Returns 0 (true) if condition is met
  local condition="$1" value="$2"
  case "${condition}" in
    ne1) [[ "${value}" != "1" ]] && return 0 || return 1 ;;
    *)   return 0 ;;
  esac
}

resolve_and_retry() {
  # Check if a known prerequisite exists for this parameter.
  # If condition is met, apply prerequisite then retry with override value.
  # Returns 0 if resolved successfully, 1 otherwise.
  local param_name="$1" single="$2" group_name="$3"
  local group_type="$4" region="$5"

  for prereq in "${PARAM_PREREQUISITES[@]}"; do
    local p condition prereq_name prereq_value prereq_method override_value
    p=$(echo "${prereq}"              | cut -d: -f1)
    condition=$(echo "${prereq}"      | cut -d: -f2)
    prereq_name=$(echo "${prereq}"    | cut -d: -f3)
    prereq_value=$(echo "${prereq}"   | cut -d: -f4)
    prereq_method=$(echo "${prereq}"  | cut -d: -f5)
    override_value=$(echo "${prereq}" | cut -d: -f6)

    if [[ "${param_name}" != "${p}" ]]; then continue; fi

    # Check if condition is met for this parameter value
    local orig_value
    orig_value=$(echo "${single}" | jq -r '.[0].ParameterValue')
    if ! check_condition "${condition}" "${orig_value}"; then
      return 1
    fi

    # Step 1: Apply prerequisite parameter
    local prereq_json
    prereq_json="[{
      \"ParameterName\":  \"${prereq_name}\",
      \"ParameterValue\": \"${prereq_value}\",
      \"ApplyMethod\":    \"${prereq_method}\"
    }]"

    log_warn "  Prerequisite required: ${prereq_name}=${prereq_value}"

    if ! apply_single_param "${group_name}" "${prereq_json}" "${group_type}" "${region}"; then
      log_error "  ❌ Failed to apply prerequisite: ${prereq_name}=${prereq_value}"
      return 1
    fi
    log_info "  ✅ Prerequisite applied: ${prereq_name}=${prereq_value}"

    # Step 2: Build override value json
    local apply_method final_single
    apply_method=$(echo "${single}" | jq -r '.[0].ApplyMethod')
    final_single="[{
      \"ParameterName\":  \"${param_name}\",
      \"ParameterValue\": \"${override_value}\",
      \"ApplyMethod\":    \"${apply_method}\"
    }]"
    log_warn "  Value overridden: ${param_name} ${orig_value} → ${override_value}"
    log_warn "  (Aurora MySQL supports 0 or 1 only, mapped to 0)"

    # Step 3: Apply parameter with override value
    if apply_single_param "${group_name}" "${final_single}" "${group_type}" "${region}"; then
      log_info "  ✅ ${param_name}=${override_value}: applied (after prerequisite)"
      TOTAL_APPLIED=$(( TOTAL_APPLIED + 1 ))
      return 0
    else
      log_error "  ❌ ${param_name}: still failed after prerequisite"
      return 1
    fi
  done

  return 1
}

apply_batch_with_retry() {
  # $1 = group name, $2 = batch json, $3 = group type, $4 = region
  # $5 = batch num,  $6 = total batches
  local group_name="$1" batch="$2" group_type="$3" region="$4"
  local batch_num="$5" total_batches="$6"
  local batch_count
  batch_count=$(echo "${batch}" | jq 'length')

  # Try applying the whole batch first
  if apply_single_param "${group_name}" "${batch}" "${group_type}" "${region}"; then
    log_info "✅ Batch ${batch_num}/${total_batches}: ${batch_count} params applied"
    TOTAL_APPLIED=$(( TOTAL_APPLIED + batch_count ))
    return
  fi

  # Batch failed — retry each parameter individually
  log_warn "Batch ${batch_num}/${total_batches} failed — retrying individually..."
  for (( j=0; j<batch_count; j++ )); do
    local single param_name error_msg
    single=$(echo "${batch}" | jq "[.[${j}]]")
    param_name=$(echo "${single}" | jq -r '.[0].ParameterName')

    if apply_single_param "${group_name}" "${single}" "${group_type}" "${region}"; then
      log_info "  ✅ ${param_name}: applied"
      TOTAL_APPLIED=$(( TOTAL_APPLIED + 1 ))
    else
      # Check if a prerequisite can resolve this failure
      if resolve_and_retry \
          "${param_name}" "${single}" \
          "${group_name}" "${group_type}" "${region}"; then
        continue
      fi

      # No prerequisite or prerequisite failed — record error
      error_msg=$(get_error_msg "${group_name}" "${single}" "${group_type}" "${region}")
      log_error "  ❌ ${param_name}: failed"
      log_warn  "     Reason: ${error_msg}"

      jq --argjson new \
        "$(echo "${single}" | jq \
          --arg reason "${error_msg}" \
          '.[0] + {FailReason: $reason}')" \
        '. + [$new]' "${FAILED_TMP}" > "${FAILED_TMP}.tmp" \
        && mv "${FAILED_TMP}.tmp" "${FAILED_TMP}"
    fi
  done
}

# ── Filter Parameters ─────────────────────────────────────
# APPLICABLE   : found in target engine AND IsModifiable = true
# SKIPPED      : found in target engine BUT IsModifiable = false
# INCOMPATIBLE : not found in target engine at all

filter_params() {
  jq --slurpfile target "${TARGET_VALID_FILE}" '
    . as $src |
    ($target[0] | map({(.ParameterName): .}) | add) as $tmap |
    $src | map(
      select(
        .ParameterValue != null and
        $tmap[.ParameterName] != null and
        $tmap[.ParameterName].IsModifiable == true
      ) | {
        ParameterName,
        ParameterValue,
        ApplyMethod: ($tmap[.ParameterName].ApplyMethod // "pending-reboot")
      }
    )
  ' "${EXPORT_FILE}" > "${APPLICABLE_FILE}"

  jq --slurpfile target "${TARGET_VALID_FILE}" '
    . as $src |
    ($target[0] | map({(.ParameterName): .}) | add) as $tmap |
    $src | map(
      select(
        .ParameterValue != null and
        $tmap[.ParameterName] != null and
        $tmap[.ParameterName].IsModifiable == false
      ) | {
        ParameterName,
        ParameterValue,
        SkipReason: "Not modifiable in target engine"
      }
    )
  ' "${EXPORT_FILE}" > "${SKIPPED_FILE}"

  jq --slurpfile target "${TARGET_VALID_FILE}" '
    . as $src |
    ($target[0] | map({(.ParameterName): .}) | add) as $tmap |
    $src | map(
      select(
        .ParameterValue != null and
        $tmap[.ParameterName] == null
      ) | {
        ParameterName,
        ParameterValue,
        SkipReason: "Not found in target engine"
      }
    )
  ' "${EXPORT_FILE}" > "${INCOMPATIBLE_FILE}"
}

# ── Report ────────────────────────────────────────────────

generate_report() {
  cp "${FAILED_TMP}" "${FAILED_FILE}"

  cat > "${REPORT_FILE}" << EOF
============================================================
  PARAMETER GROUP MIGRATION REPORT
  Date    : $(date)
  DryRun  : ${DRY_RUN}
============================================================
  Source  : ${SOURCE_PARAM_GROUP} [${SOURCE_FAMILY} | ${SOURCE_TYPE} | ${SOURCE_REGION}]
  Target  : ${TARGET_PARAM_GROUP} [${TARGET_FAMILY} | ${TARGET_TYPE} | ${TARGET_REGION}]
------------------------------------------------------------
  Total Exported  : $(jq 'length' "${EXPORT_FILE}")
  Applied         : ${TOTAL_APPLIED}
  Skipped         : $(jq 'length' "${SKIPPED_FILE}")
  Incompatible    : $(jq 'length' "${INCOMPATIBLE_FILE}")
  Failed          : $(jq 'length' "${FAILED_FILE}")
============================================================

=== APPLIED ===
$(jq -r '["Name","Value","ApplyMethod"],
         (.[] | [.ParameterName,.ParameterValue,.ApplyMethod]) | @tsv' \
  "${APPLICABLE_FILE}" | column -t)

=== SKIPPED (Not Modifiable in Target Engine) ===
$(jq -r '["Name","Value","Reason"],
         (.[] | [.ParameterName,.ParameterValue,.SkipReason]) | @tsv' \
  "${SKIPPED_FILE}" | column -t)

=== INCOMPATIBLE (Not Found in Target Engine) ===
$(jq -r '["Name","Value","Reason"],
         (.[] | [.ParameterName,.ParameterValue,.SkipReason]) | @tsv' \
  "${INCOMPATIBLE_FILE}" | column -t)

=== FAILED (API Rejected — Review Required) ===
$(jq -r '.[] | "  Name   : \(.ParameterName)\n  Value  : \(.ParameterValue)\n  Reason : \(.FailReason)\n"' \
  "${FAILED_FILE}")
EOF
  cat "${REPORT_FILE}"
}

# ── Main ──────────────────────────────────────────────────

main() {
  log_section "DB Parameter Group Migration Tool"
  [[ "${DRY_RUN}" == "true" ]] && log_warn "DRY RUN — no changes will be applied"

  log_section "Step 1: Detect Parameter Group Types"
  SOURCE_TYPE=$(detect_group_type "${SOURCE_PARAM_GROUP}" "${SOURCE_REGION}")
  [[ "${SOURCE_TYPE}" == "not_found" ]] && \
    log_error "Source group '${SOURCE_PARAM_GROUP}' not found in ${SOURCE_REGION}" && exit 1

  SOURCE_FAMILY=$(get_source_family "${SOURCE_PARAM_GROUP}" "${SOURCE_TYPE}" "${SOURCE_REGION}")
  TARGET_TYPE=$(target_group_type_from_family "${TARGET_FAMILY}")

  log_info "Source : ${SOURCE_PARAM_GROUP} | ${SOURCE_TYPE} | ${SOURCE_FAMILY} | ${SOURCE_REGION}"
  log_info "Target : ${TARGET_PARAM_GROUP} | ${TARGET_TYPE} | ${TARGET_FAMILY} | ${TARGET_REGION}"

  [[ "${SOURCE_REGION}" != "${TARGET_REGION}" ]] && \
    log_warn "Cross-region copy: ${SOURCE_REGION} → ${TARGET_REGION}"

  log_section "Step 2: Export Source Parameters"
  export_params "${SOURCE_PARAM_GROUP}" "${SOURCE_TYPE}" "${SOURCE_REGION}"
  log_info "Exported $(jq 'length' "${EXPORT_FILE}") modified parameters"
  jq -r '["Name","Value","ApplyType"],
          (.[] | [.ParameterName,.ParameterValue,.ApplyType]) | @tsv' \
    "${EXPORT_FILE}" | column -t

  log_section "Step 3: Create Target Parameter Group"
  if [[ "${DRY_RUN}" == "false" ]]; then
    create_target_group \
      "${TARGET_PARAM_GROUP}" "${TARGET_FAMILY}" \
      "Migrated from: ${SOURCE_PARAM_GROUP} (${SOURCE_REGION})" \
      "${TARGET_TYPE}" "${TARGET_REGION}"
  else
    log_warn "[DRY RUN] Would create ${TARGET_TYPE} group: ${TARGET_PARAM_GROUP} (${TARGET_FAMILY}) in ${TARGET_REGION}"
  fi

  log_section "Step 4: Fetch Target Valid Parameters"
  if [[ "${DRY_RUN}" == "false" ]]; then
    fetch_target_valid_params "${TARGET_PARAM_GROUP}" "${TARGET_TYPE}" "${TARGET_REGION}"
  else
    log_warn "[DRY RUN] Using source group for valid parameter lookup"
    fetch_target_valid_params "${SOURCE_PARAM_GROUP}" "${SOURCE_TYPE}" "${SOURCE_REGION}"
  fi
  log_info "Found $(jq 'length' "${TARGET_VALID_FILE}") valid parameters in target"

  log_section "Step 5: Filter Parameters"
  filter_params

  APPLICABLE_COUNT=$(jq 'length' "${APPLICABLE_FILE}")
  echo "--------------------------------------------"
  echo " Total Exported : $(jq 'length' "${EXPORT_FILE}")"
  echo " Applicable     : ${APPLICABLE_COUNT}"
  echo " Skipped        : $(jq 'length' "${SKIPPED_FILE}")"
  echo " Incompatible   : $(jq 'length' "${INCOMPATIBLE_FILE}")"
  echo "--------------------------------------------"

  log_section "Step 6: Apply Parameters"
  TOTAL_APPLIED=0

  if [[ "${APPLICABLE_COUNT}" -gt 0 ]]; then
    TOTAL_BATCHES=$(( (APPLICABLE_COUNT + BATCH_SIZE - 1) / BATCH_SIZE ))
    for (( i=0; i<APPLICABLE_COUNT; i+=BATCH_SIZE )); do
      BATCH_NUM=$(( i / BATCH_SIZE + 1 ))
      BATCH=$(jq ".[${i}:$(( i + BATCH_SIZE ))]" "${APPLICABLE_FILE}")

      if [[ "${DRY_RUN}" == "false" ]]; then
        apply_batch_with_retry \
          "${TARGET_PARAM_GROUP}" "${BATCH}" \
          "${TARGET_TYPE}" "${TARGET_REGION}" \
          "${BATCH_NUM}" "${TOTAL_BATCHES}"
        sleep 1
      else
        BATCH_COUNT=$(echo "${BATCH}" | jq 'length')
        log_warn "[DRY RUN] Batch ${BATCH_NUM}/${TOTAL_BATCHES}: ${BATCH_COUNT} params"
        TOTAL_APPLIED=$(( TOTAL_APPLIED + BATCH_COUNT ))
      fi
    done
  fi

  FAILED_COUNT=$(jq 'length' "${FAILED_TMP}")
  log_info "Applied  : ${TOTAL_APPLIED}/${APPLICABLE_COUNT} parameters"
  [[ "${FAILED_COUNT}" -gt 0 ]] && \
    log_warn "Failed   : ${FAILED_COUNT} parameters — check ${FAILED_FILE} for details"

  log_section "Step 7: Generate Report"
  generate_report
  log_info "Output: ${WORK_DIR}/"
}

main