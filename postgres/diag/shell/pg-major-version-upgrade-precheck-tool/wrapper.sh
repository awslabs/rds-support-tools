#!/bin/bash

#/
 #  Copyright 2016-2026 Amazon.com, Inc. or its affiliates. 
 #  All Rights Reserved.
 #
 #  Licensed under the Apache License, Version 2.0 (the "License"). 
 #  You may not use this file except in compliance with the License. 
 #  A copy of the License is located at
 # 
 #      http://aws.amazon.com/apache2.0/
 # 
 # or in the "license" file accompanying this file. 
 # This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
 # either express or implied. See the License for the specific language governing permissions 
 # and limitations under the License.
#/

################################################################################
# PostgreSQL MVU Pre-Check Wrapper Script - UNIFIED
################################################################################
# Purpose: Batch execution wrapper for pg-major-version-upgrade-precheck.sh
# Features:
#   - Generate CSV file with RDS instance details
#   - Execute preupgrade checks against multiple instances from CSV
#   - Support for blue/green deployment mode flag
#   - Interactive menu-driven interface
################################################################################

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
CSV_FILE="rds_instances.csv"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREUPGRADE_SCRIPT="${SCRIPT_DIR}/pg-major-version-upgrade-precheck.sh"

################################################################################
# Function: display_banner
# Description: Displays the script banner
################################################################################
display_banner() {
    clear
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}    PostgreSQL MVU Pre-Check - Batch Execution Wrapper (UNIFIED)${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo ""
}

################################################################################
# Function: display_menu
# Description: Displays the main menu options
################################################################################
display_menu() {
    echo -e "${BLUE}Main Menu:${NC}"
    echo ""
    echo "  1. Generate CSV file with RDS and Aurora instance details"
    echo "  2. Run preupgrade checks from CSV file"
    echo "  3. Exit"
    echo ""
}

################################################################################
# Function: validate_preupgrade_script
# Description: Checks if pg-major-version-upgrade-precheck.sh exists
################################################################################
validate_preupgrade_script() {
    if [ ! -f "${PREUPGRADE_SCRIPT}" ]; then
        echo -e "${RED}✗ Error: pg-major-version-upgrade-precheck.sh not found in ${SCRIPT_DIR}${NC}"
        echo "Please ensure the script is in the same directory as this wrapper script."
        return 1
    fi
    
    if [ ! -x "${PREUPGRADE_SCRIPT}" ]; then
        echo -e "${YELLOW}⚠ Making pg-major-version-upgrade-precheck.sh executable...${NC}"
        chmod +x "${PREUPGRADE_SCRIPT}"
    fi
    
    return 0
}

################################################################################
# Function: get_user_input
# Description: Prompts user for input with a default value
################################################################################
get_user_input() {
    local prompt="$1"
    local default="$2"
    local user_input
    
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " user_input
        echo "${user_input:-$default}"
    else
        read -r -p "$prompt: " user_input
        echo "$user_input"
    fi
}

################################################################################
# Function: generate_csv
# Description: Generates CSV file with RDS instance details
################################################################################
generate_csv() {
    echo ""
    echo -e "${GREEN}=== Generate CSV File with RDS and Aurora Instance Details ===${NC}"
    echo ""
    
    # Collect user inputs
    echo "Please provide the following information:"
    echo ""
    
    local aws_profile
    aws_profile=$(get_user_input "AWS CLI Profile" "default")
    local aws_region
    aws_region=$(get_user_input "AWS Region" "us-east-1")
    
    if [ -z "$aws_region" ]; then
        echo -e "${RED}✗ AWS Region is required${NC}"
        return 1
    fi
    
    local run_mode
    run_mode=$(get_user_input "Run Mode (rds/sql/both)" "both")
    local create_baseline
    create_baseline=$(get_user_input "Create Baseline Stats (yes/no)" "no")
    local source_version
    source_version=$(get_user_input "Source PostgreSQL Version (e.g., 13)" "13")
    local blue_green
    blue_green=$(get_user_input "Use Blue/Green Deployment Checks? (Y/N)" "N")
    
    # Normalize blue_green to uppercase
    blue_green=$(echo "$blue_green" | tr '[:lower:]' '[:upper:]')
    
    if [ -z "$source_version" ]; then
        echo -e "${RED}✗ Source PostgreSQL Version is required${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${YELLOW}Fetching PostgreSQL instances from AWS...${NC}"
    
    # Fetch RDS PostgreSQL instances matching the source version
    local rds_instances
    if ! rds_instances=$(aws rds describe-db-instances \
        --region "${aws_region}" \
        --profile "${aws_profile}" \
        --query "DBInstances[?Engine=='postgres' && starts_with(EngineVersion, '${source_version}.')].{
            Identifier:DBInstanceIdentifier,
            Endpoint:Endpoint.Address,
            Port:Endpoint.Port,
            MasterUsername:MasterUsername,
            DBName:DBName,
            EngineVersion:EngineVersion,
            Engine:'postgres',
            InstanceClass:DBInstanceClass
        }" \
        --output json 2>&1); then
        echo -e "${RED}✗ Failed to fetch RDS instances${NC}"
        echo "Error: ${rds_instances}"
        return 1
    fi
    
    # Fetch Aurora PostgreSQL clusters matching the source version
    local aurora_clusters
    if ! aurora_clusters=$(aws rds describe-db-clusters \
        --region "${aws_region}" \
        --profile "${aws_profile}" \
        --query "DBClusters[?Engine=='aurora-postgresql' && starts_with(EngineVersion, '${source_version}.')].{
            ClusterIdentifier:DBClusterIdentifier,
            Endpoint:Endpoint,
            Port:Port,
            MasterUsername:MasterUsername,
            DatabaseName:DatabaseName,
            EngineVersion:EngineVersion,
            Engine:'aurora-postgresql',
            EngineMode:EngineMode,
            ServerlessV2ScalingConfiguration:ServerlessV2ScalingConfiguration
        }" \
        --output json 2>&1); then
        echo -e "${RED}✗ Failed to fetch Aurora clusters${NC}"
        echo "Error: ${aurora_clusters}"
        return 1
    fi
    
    local rds_count
    rds_count=$(echo "$rds_instances" | jq -r 'length')
    local aurora_count
    aurora_count=$(echo "$aurora_clusters" | jq -r 'length')
    local total_count=$((rds_count + aurora_count))
    
    if [ "$total_count" -eq 0 ]; then
        echo -e "${YELLOW}⚠ No PostgreSQL ${source_version}.x instances or clusters found in ${aws_region}${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Found ${rds_count} RDS PostgreSQL instance(s) and ${aurora_count} Aurora PostgreSQL cluster(s)${NC}"
    echo ""
    
    # Create CSV file with engine, blue_green, and secrets manager columns
    echo "mode,region,identifier,profile,host,port,database,username,password,secret_arn,secret_key,baseline,engine,blue_green,format" > "${CSV_FILE}"
    
    # Add RDS instances to CSV
    local identifier endpoint port master_user db_name engine_version instance_class
    for i in $(seq 0 $((rds_count - 1))); do
        identifier=$(echo "$rds_instances" | jq -r ".[$i].Identifier")
        endpoint=$(echo "$rds_instances" | jq -r ".[$i].Endpoint")
        port=$(echo "$rds_instances" | jq -r ".[$i].Port")
        master_user=$(echo "$rds_instances" | jq -r ".[$i].MasterUsername")
        db_name=$(echo "$rds_instances" | jq -r ".[$i].DBName // \"postgres\"")
        engine_version=$(echo "$rds_instances" | jq -r ".[$i].EngineVersion")
        instance_class=$(echo "$rds_instances" | jq -r ".[$i].InstanceClass")
        
        # Add row to CSV
        echo "${run_mode},${aws_region},${identifier},${aws_profile},${endpoint},${port},${db_name},${master_user},,,password,${create_baseline},postgres,${blue_green},html" >> "${CSV_FILE}"
        
        echo -e "  ${CYAN}[RDS]${NC} ${identifier} (${engine_version}, ${instance_class}) - ${endpoint}:${port}"
    done
    
    # Add Aurora clusters to CSV
    local engine_mode min_capacity max_capacity capacity_info
    for i in $(seq 0 $((aurora_count - 1))); do
        identifier=$(echo "$aurora_clusters" | jq -r ".[$i].ClusterIdentifier")
        endpoint=$(echo "$aurora_clusters" | jq -r ".[$i].Endpoint")
        port=$(echo "$aurora_clusters" | jq -r ".[$i].Port")
        master_user=$(echo "$aurora_clusters" | jq -r ".[$i].MasterUsername")
        db_name=$(echo "$aurora_clusters" | jq -r ".[$i].DatabaseName // \"postgres\"")
        engine_version=$(echo "$aurora_clusters" | jq -r ".[$i].EngineVersion")
        engine_mode=$(echo "$aurora_clusters" | jq -r ".[$i].EngineMode // \"provisioned\"")
        
        # Check if serverless v2
        min_capacity=$(echo "$aurora_clusters" | jq -r ".[$i].ServerlessV2ScalingConfiguration.MinCapacity // \"N/A\"")
        max_capacity=$(echo "$aurora_clusters" | jq -r ".[$i].ServerlessV2ScalingConfiguration.MaxCapacity // \"N/A\"")
        
        capacity_info=""
        if [ "$min_capacity" != "N/A" ] && [ "$max_capacity" != "N/A" ]; then
            capacity_info=" (Serverless v2: ${min_capacity}-${max_capacity} ACU)"
        elif [ "$engine_mode" == "serverless" ]; then
            capacity_info=" (Serverless v1)"
        else
            capacity_info=" (Provisioned)"
        fi
        
        # Add row to CSV
        echo "${run_mode},${aws_region},${identifier},${aws_profile},${endpoint},${port},${db_name},${master_user},,,password,${create_baseline},aurora-postgresql,${blue_green},html" >> "${CSV_FILE}"
        
        echo -e "  ${CYAN}[Aurora]${NC} ${identifier} (${engine_version}${capacity_info}) - ${endpoint}:${port}"
    done
    
    echo ""
    echo -e "${GREEN}✓ CSV file generated: ${CSV_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}⚠ IMPORTANT: Please update the password/secret columns in ${CSV_FILE} before running option 2${NC}"
    echo ""
    echo "CSV Format:"
    echo "  mode,region,identifier,profile,host,port,database,username,password,secret_arn,secret_key,baseline,engine,blue_green,format"
    echo ""
    echo "Password Options (choose one per row):"
    echo "  1. Direct password: Fill 'password' column, leave 'secret_arn' and 'secret_key' empty"
    echo "  2. Secrets Manager: Fill 'secret_arn' column, optionally set 'secret_key' (default: password)"
    echo ""
    echo "Format Column:"
    echo "  html = Interactive HTML report with expandable sections (default)"
    echo "  text = Plain text report suitable for logging or CI/CD pipelines"
    echo ""
    echo "Blue/Green Column:"
    echo "  Y = includes blue/green deployment checks"
    echo "  N = standard checks only"
    echo ""
    echo "You can also manually add or remove instances from the CSV file."
    echo ""
}

################################################################################
# Function: validate_csv
# Description: Validates the CSV file exists and has required columns
################################################################################
validate_csv() {
    if [ ! -f "${CSV_FILE}" ]; then
        echo -e "${RED}✗ CSV file not found: ${CSV_FILE}${NC}"
        echo "Please run option 1 to generate the CSV file first."
        return 1
    fi
    
    # Check if CSV has header
    local header
    header=$(head -n 1 "${CSV_FILE}")
    if [[ ! "$header" =~ ^mode,region,identifier,profile,host,port,database,username,password ]]; then
        echo -e "${RED}✗ Invalid CSV format${NC}"
        echo "Expected header: mode,region,identifier,profile,host,port,database,username,password,secret_arn,secret_key,baseline[,engine][,blue_green]"
        echo "Note: 'secret_arn', 'secret_key', 'engine' and 'blue_green' columns are optional for backward compatibility"
        return 1
    fi
    
    # Count instances (excluding header)
    local instance_count=$(($(wc -l < "${CSV_FILE}") - 1))
    
    if [ "$instance_count" -eq 0 ]; then
        echo -e "${RED}✗ CSV file is empty (no instances found)${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ CSV file validated: ${instance_count} instance(s) found${NC}"
    return 0
}

################################################################################
# Function: check_empty_passwords
# Description: Checks if any passwords/secrets are empty in the CSV
################################################################################
check_empty_passwords() {
    local empty_count=0
    local line_num=1
    # shellcheck disable=SC2034
    local mode region identifier profile host port database username password secret_arn secret_key baseline engine blue_green format
    
    while IFS=',' read -r mode region identifier profile host port database username password secret_arn secret_key baseline engine blue_green format; do
        # Skip header
        if [ "$line_num" -eq 1 ]; then
            line_num=$((line_num + 1))
            continue
        fi
        
        # Check if both password and secret_arn are empty
        if [ -z "$password" ] && [ -z "$secret_arn" ]; then
            if [ "$empty_count" -eq 0 ]; then
                echo -e "${YELLOW}⚠ Warning: Empty passwords/secrets found in CSV:${NC}"
            fi
            echo -e "  Line ${line_num}: ${identifier} (no password or secret_arn)"
            empty_count=$((empty_count + 1))
        fi
        
        line_num=$((line_num + 1))
    done < <(tr -d '\r' < "${CSV_FILE}")
    
    if [ "$empty_count" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}${empty_count} instance(s) have empty passwords/secrets.${NC}"
        echo ""
        local continue_choice
        read -r -p "Do you want to continue anyway? (yes/no): " continue_choice
        
        if [[ ! "$continue_choice" =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Execution cancelled."
            return 1
        fi
    fi
    
    return 0
}

################################################################################
# Function: run_preupgrade_checks
# Description: Executes pg-major-version-upgrade-precheck.sh for each instance in CSV
################################################################################
run_preupgrade_checks() {
    echo ""
    echo -e "${GREEN}=== Run Preupgrade Checks from CSV ===${NC}"
    echo ""
    
    if ! validate_csv; then
        return 1
    fi
    
    if ! check_empty_passwords; then
        return 1
    fi
    
    echo ""
    echo -e "${BLUE}Starting batch execution...${NC}"
    echo ""
    
    local line_num=1
    local success_count=0
    local failure_count=0
    local skipped_count=0
    local mode region identifier profile host port database username password secret_arn secret_key baseline engine blue_green format
    
    # shellcheck disable=SC2034
    while IFS=',' read -r mode region identifier profile host port database username password secret_arn secret_key baseline engine blue_green format; do
        # Skip header
        if [ "$line_num" -eq 1 ]; then
            line_num=$((line_num + 1))
            continue
        fi
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}[${line_num}] Processing: ${identifier}${NC}"
        
        # Determine if blue/green mode should be enabled
        local blue_green_flag=""
        local script_type="Standard"
        
        if [[ "${blue_green}" =~ ^[Yy]$ ]]; then
            blue_green_flag="--blue-green"
            script_type="Blue/Green"
        fi
        
        echo -e "${CYAN}    Mode: ${script_type} Checks${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Validate required fields
        if [ -z "$mode" ] || [ -z "$region" ] || [ -z "$identifier" ]; then
            echo -e "${RED}✗ Skipping: Missing required fields (mode, region, or identifier)${NC}"
            skipped_count=$((skipped_count + 1))
            echo ""
            line_num=$((line_num + 1))
            continue
        fi
        
        # Build command arguments as array to avoid eval and command injection
        local cmd_args=("--non-interactive" "-m" "${mode}" "-r" "${region}" "-i" "${identifier}" "-p" "${profile}")
        
        # Add blue/green flag if enabled
        if [ -n "$blue_green_flag" ]; then
            cmd_args+=("${blue_green_flag}")
        fi
        
        # Add SQL mode arguments if needed
        if [[ "$mode" == "sql" ]] || [[ "$mode" == "both" ]]; then
            if [ -z "$host" ] || [ -z "$port" ] || [ -z "$database" ] || [ -z "$username" ]; then
                echo -e "${RED}✗ Skipping: Missing SQL connection parameters${NC}"
                skipped_count=$((skipped_count + 1))
                echo ""
                line_num=$((line_num + 1))
                continue
            fi
            
            cmd_args+=("-h" "${host}" "-P" "${port}" "-d" "${database}" "-u" "${username}")
            
            # Handle password or secret_arn
            if [ -n "$secret_arn" ]; then
                cmd_args+=("-s" "${secret_arn}")
                if [ -n "$secret_key" ]; then
                    cmd_args+=("--secret-key" "${secret_key}")
                fi
            elif [ -n "$password" ]; then
                cmd_args+=("-w" "${password}")
            else
                cmd_args+=("-w" "")
            fi
        fi
        
        # Add baseline argument
        if [ -n "$baseline" ]; then
            cmd_args+=("-b" "${baseline}")
        fi
        
        # Add format argument (default to html if not specified)
        # Strip trailing \r in case CSV was edited on Windows (\r\n line endings)
        format="${format%$'\r'}"
        # Only pass --format when non-default (text), for backward compatibility
        # with older versions of pg-major-version-upgrade-precheck.sh that don't support --format
        local report_format="${format:-html}"
        if [ "$report_format" = "text" ]; then
            cmd_args+=("--format" "${report_format}")
        fi
        
        # Build masked display string for logging
        local display_cmd=""
        local skip_next=false
        for arg in "${cmd_args[@]}"; do
            if [ "$skip_next" = true ]; then
                display_cmd="${display_cmd} ********"
                skip_next=false
                continue
            fi
            if [ "$arg" = "-w" ]; then
                display_cmd="${display_cmd} -w"
                skip_next=true
            elif [ "$arg" = "-s" ]; then
                display_cmd="${display_cmd} -s"
                skip_next=true
            else
                display_cmd="${display_cmd} ${arg}"
            fi
        done
        
        echo "Executing: ${PREUPGRADE_SCRIPT}${display_cmd}"
        echo ""
        
        # Execute preupgrade script using array (no eval needed)
        "${PREUPGRADE_SCRIPT}" "${cmd_args[@]}"
        local exit_code=$?
        
        echo ""
        
        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}✓ Successfully completed: ${identifier}${NC}"
            success_count=$((success_count + 1))
        else
            echo -e "${RED}✗ Failed: ${identifier} (exit code: ${exit_code})${NC}"
            failure_count=$((failure_count + 1))
        fi
        
        echo ""
        line_num=$((line_num + 1))
    done < <(tr -d '\r' < "${CSV_FILE}")
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Batch Execution Summary${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}✓ Successful:${NC} ${success_count}"
    echo -e "  ${RED}✗ Failed:${NC}     ${failure_count}"
    echo -e "  ${YELLOW}⊘ Skipped:${NC}    ${skipped_count}"
    echo -e "  ${BLUE}━ Total:${NC}      $((success_count + failure_count + skipped_count))"
    echo ""
}

################################################################################
# Function: main
# Description: Main script execution loop
################################################################################
main() {
    # Validate preupgrade script exists
    if ! validate_preupgrade_script; then
        exit 1
    fi
    
    local choice
    while true; do
        display_banner
        display_menu
        
        read -r -p "Select an option (1-3): " choice
        
        case $choice in
            1)
                generate_csv
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            2)
                run_preupgrade_checks
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            3)
                echo ""
                echo -e "${GREEN}Exiting...${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                echo -e "${RED}Invalid option. Please select 1, 2, or 3.${NC}"
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Execute main function
main
