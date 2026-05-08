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
# PostgreSQL Major Version Upgrade (MVU) Pre-Check Script - UNIFIED
################################################################################
# Purpose: Comprehensive pre-upgrade validation for PostgreSQL/RDS databases
#          with optional blue/green deployment specific checks
# Features:
#   - RDS configuration and CloudWatch metrics analysis
#   - 23 standard SQL-based pre-upgrade checks (always executed)
#   - 11 additional blue/green deployment checks (optional with --blue-green flag)
#   - 12 critical upgrade blocker checks (always executed, version-conditional)
#   - Interactive HTML report with expandable details and checkbox indicators
#   - Baseline statistics table creation
#   - Support for both interactive and non-interactive execution
#   - Version compatibility and upgrade path validation
#   - Version-specific check execution (skips checks not applicable to current PG version)
#
# Standard Checks (1-23): Always executed
#   - PostgreSQL version, database size, configuration parameters
#   - Table and index health, bloat analysis, vacuum status
#   - Replication status, extensions, transaction ID age
#   - And more...
#
# Blue/Green Specific Checks (24-34): Only with --blue-green flag
#   - Check 24: Version Compatibility and Upgrade Path
#   - Check 25: Parameter Group Configuration for Blue/Green
#   - Check 26: Table Requirements for Blue/Green Deployments
#   - Check 27: Foreign Tables Check for Blue/Green Deployments
#   - Check 28: Unlogged Tables Check for Blue/Green Deployments
#   - Check 29: Publications Check for Blue/Green Deployments
#   - Check 30: Subscriptions Check for Blue/Green Deployments
#   - Check 31: Foreign Data Wrapper Endpoint Check for Blue/Green Deployments
#   - Check 32: High Write Volume Tables Check for Blue/Green Deployments
#   - Check 33: Partitioned Tables Check for Blue/Green Deployments
#   - Check 34: Blue/Green Extension Compatibility Check
#   - Check 35: DDL Event Triggers Check for Blue/Green Deployments
#   - Check 35b: DTS Trigger Check for Blue/Green Deployments
#   - Check 35c: max_locks_per_transaction Validation for Blue/Green Deployments
#
# Critical Upgrade Blocker Checks (36-46): Always executed (version-conditional)
#   - Check 36: chkpass Extension (not supported in PG >= 11) - PG <= 11 only
#   - Check 37: tsearch2 Extension (not supported in PG >= 11) - PG <= 11 only
#   - Check 38: pg_repack Extension (must drop before PG >= 14) - PG <= 14 only
#   - Check 39: System-Defined Composite Types (unstable OIDs)
#   - Check 39b: reg* Data Types in User Tables (OIDs not preserved by pg_upgrade)
#   - Check 40: aclitem Data Type (format changed in PG 16)
#   - Check 41: sql_identifier Data Type (format changed in PG 12) - PG < 12 only
#   - Check 42: Removed Data Types (abstime, reltime, tinterval) - PG < 12 only
#   - Check 43: Tables WITH OIDS (not supported in PG >= 12) - PG < 12 only
#   - Check 44: User-Defined Encoding Conversions (not supported in PG >= 14) - PG <= 14 only
#   - Check 45: User-Defined Postfix Operators (not supported in PG >= 14) - PG <= 14 only
#   - Check 46: Incompatible Polymorphic Functions (changed in PG 14) - PG <= 14 only
#
# Version-Specific Checks: Automatically skipped when not applicable
#   - Check 44: User-Defined Encoding Conversions (PG <= 13 only)
#   - Check 45: User-Defined Postfix Operators (PG <= 13 only)
#   - Check 46: Incompatible Polymorphic Functions (PG <= 13 only)
#
# Based on: CDP Database Runbook, PostgreSQL Best Practices, and AWS pg_mvu_precheck
################################################################################

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Global variables
RUN_MODE=""
AWS_REGION=""
DB_IDENTIFIER=""
AWS_PROFILE=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_SECRET_ARN=""
DB_SECRET_KEY="password"
CREATE_BASELINE=""
NON_INTERACTIVE=false
BLUE_GREEN_MODE=false
REPORT_FORMAT="html"  # html or text
FORMAT_SET_BY_CLI=false

# Engine detection variables
ENGINE_TYPE=""
IS_AURORA_SERVERLESS="false"
CLUSTER_IDENTIFIER=""
PG_MAJOR_VERSION=""

# Cross-database check cache
ALL_DATABASES=""

################################################################################
# Function: usage
# Description: Display help information and usage examples
################################################################################
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

PostgreSQL Major Version Upgrade (MVU) Pre-Check Script - UNIFIED

This script performs comprehensive pre-upgrade validation including:
- Standard pre-upgrade checks (35 checks) - always executed
- Critical upgrade blocker checks (12 checks) - always executed
- Blue/Green deployment specific checks (11 checks) - optional with --blue-green flag

Blue/Green checks include:
  * Version compatibility and valid upgrade paths
  * Parameter group configuration for logical replication
  * Table replica identity verification (primary keys/REPLICA IDENTITY FULL)
  * Foreign tables, unlogged tables, publications, subscriptions
  * Foreign data wrapper endpoint check
  * High write volume tables, partitioned tables
  * Extension compatibility for blue/green deployments

OPTIONS:
    -m, --mode MODE              Run mode: rds, sql, or both (required)
    -r, --region REGION          AWS region (required for rds/both mode)
    -i, --identifier ID          RDS DB/Cluster identifier (required for rds/both mode)
    -p, --profile PROFILE        AWS profile (default: default)
    -h, --host HOST              Database/Cluster endpoint (required for sql/both mode)
    -P, --port PORT              Database port (default: 5432)
    -d, --database DATABASE      Database name (required for sql/both mode)
    -u, --user USER              Database username (required for sql/both mode)
    -w, --password PASSWORD      Database password (required for sql/both mode)
    -s, --secret-arn ARN         AWS Secrets Manager secret ARN or name (alternative to --password)
    --secret-key KEY             JSON key for password in secret (default: password)
    -b, --baseline yes|no        Create baseline stats table (default: no)
    --blue-green                 Enable blue/green deployment specific checks (11 additional checks)
    --format FORMAT              Report format: html or text (default: html)
    --non-interactive            Run in non-interactive mode (requires all parameters)
    --help                       Display this help message

EXAMPLES:
    # Interactive mode (prompts for all inputs)
    $0

    # Standard checks only (non-interactive with password)
    $0 --non-interactive -m sql -h localhost -P 5432 -d mydb -u postgres -w mypassword

    # Standard checks with AWS Secrets Manager
    $0 --non-interactive -m sql -h localhost -P 5432 -d mydb -u postgres -s my-db-secret

    # With Secrets Manager ARN and custom key
    $0 --non-interactive -m sql -h localhost -d mydb -u postgres \
       -s arn:aws:secretsmanager:us-east-1:123456789:secret:db-pass \
       --secret-key db_password

    # With blue/green checks (non-interactive)
    $0 --non-interactive --blue-green -m sql -h localhost -P 5432 -d mydb -u postgres -w mypassword

    # RDS mode with blue/green checks
    $0 -m rds -r us-east-1 -i my-db-instance -p default --blue-green

    # Both modes with Secrets Manager
    $0 -m both -r us-east-1 -i my-db -p default -h localhost -d mydb -u postgres -s my-db-secret --blue-green

ENVIRONMENT VARIABLES (alternative to arguments):
    RUN_MODE, AWS_REGION, DB_IDENTIFIER, AWS_PROFILE
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS, DB_SECRET_ARN, DB_SECRET_KEY
    CREATE_BASELINE, BLUE_GREEN_MODE

EOF
    exit 1
}

################################################################################
# Function: display_header
# Description: Displays the script banner/header in the terminal
################################################################################
display_header() {
    echo "========================================================"
    echo "PostgreSQL Major Version Upgrade (MVU) Pre-Check Script"
    if [ "$BLUE_GREEN_MODE" = true ]; then
        echo "Mode: Standard + Blue/Green Deployment Checks"
    else
        echo "Mode: Standard Checks Only"
    fi
    echo "========================================================"
    echo ""
}

################################################################################
# Function: parse_arguments
# Description: Parses command-line arguments for non-interactive execution
# Parameters: All command-line arguments passed to the script
# Sets: Global variables (RUN_MODE, AWS_REGION, DB_HOST, etc.)
# Notes: 
#   - Supports both short (-m) and long (--mode) option formats
#   - Sets NON_INTERACTIVE=true when any argument is provided
#   - Supports environment variable fallback for Kubernetes deployments
################################################################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mode)
                RUN_MODE="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -r|--region)
                AWS_REGION="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -i|--identifier)
                DB_IDENTIFIER="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -p|--profile)
                AWS_PROFILE="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -h|--host)
                DB_HOST="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -P|--port)
                DB_PORT="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -d|--database)
                DB_NAME="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -u|--user)
                DB_USER="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -w|--password)
                DB_PASS="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -s|--secret-arn)
                DB_SECRET_ARN="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            --secret-key)
                DB_SECRET_KEY="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            -b|--baseline)
                CREATE_BASELINE="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            --blue-green)
                BLUE_GREEN_MODE=true
                shift
                ;;
            --format)
                REPORT_FORMAT="$2"
                FORMAT_SET_BY_CLI=true
                shift 2
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --help)
                usage
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                ;;
        esac
    done
    
    # Load from environment variables if not set by arguments
    RUN_MODE=${RUN_MODE:-$RUN_MODE_ENV}
    AWS_REGION=${AWS_REGION:-$AWS_REGION_ENV}
    DB_IDENTIFIER=${DB_IDENTIFIER:-$DB_IDENTIFIER_ENV}
    AWS_PROFILE=${AWS_PROFILE:-${AWS_PROFILE_ENV:-default}}
    DB_HOST=${DB_HOST:-$DB_HOST_ENV}
    DB_PORT=${DB_PORT:-${DB_PORT_ENV:-5432}}
    DB_NAME=${DB_NAME:-$DB_NAME_ENV}
    DB_USER=${DB_USER:-$DB_USER_ENV}
    DB_PASS=${DB_PASS:-$DB_PASS_ENV}
    DB_SECRET_ARN=${DB_SECRET_ARN:-$DB_SECRET_ARN_ENV}
    DB_SECRET_KEY=${DB_SECRET_KEY:-${DB_SECRET_KEY_ENV:-password}}
    CREATE_BASELINE=${CREATE_BASELINE:-${CREATE_BASELINE_ENV:-no}}
    BLUE_GREEN_MODE=${BLUE_GREEN_MODE:-${BLUE_GREEN_MODE_ENV:-false}}
    # Apply env var for format only if not already set by CLI flag
    if [ "$FORMAT_SET_BY_CLI" != true ]; then
        REPORT_FORMAT=${REPORT_FORMAT_ENV:-html}
    fi
    
    # Check if we have environment variables set (and no CLI args)
    if [ "$NON_INTERACTIVE" != true ] && [ -n "$RUN_MODE_ENV" ]; then
        NON_INTERACTIVE=true
    fi
}

################################################################################
# Function: validate_parameters
# Description: Validates that required parameters are provided based on run mode
# Returns: 0 if validation passes, 1 if validation fails
# Validation Rules:
#   - Mode 'rds' or 'both': Requires AWS_REGION, DB_IDENTIFIER
#   - Mode 'sql' or 'both': Requires DB_HOST, DB_NAME, DB_USER, DB_PASS or DB_SECRET_ARN
#   - Displays specific error messages for missing parameters
################################################################################
validate_parameters() {
    local errors=0
    
    if [ -z "$RUN_MODE" ]; then
        echo -e "${RED}✗ Error: Run mode (-m/--mode) is required${NC}"
        errors=$((errors + 1))
    elif [[ ! "$RUN_MODE" =~ ^(rds|sql|both)$ ]]; then
        echo -e "${RED}✗ Error: Invalid run mode. Must be: rds, sql, or both${NC}"
        errors=$((errors + 1))
    fi
    
    if [ "$RUN_MODE" = "rds" ] || [ "$RUN_MODE" = "both" ]; then
        if [ -z "$AWS_REGION" ]; then
            echo -e "${RED}✗ Error: AWS region (-r/--region) is required for RDS mode${NC}"
            errors=$((errors + 1))
        fi
        if [ -z "$DB_IDENTIFIER" ]; then
            echo -e "${RED}✗ Error: DB/Cluster identifier (-i/--identifier) is required for RDS mode${NC}"
            errors=$((errors + 1))
        fi
    fi
    
    if [ "$RUN_MODE" = "sql" ] || [ "$RUN_MODE" = "both" ]; then
        if [ -z "$DB_HOST" ]; then
            echo -e "${RED}✗ Error: Database/Cluster endpoint (-h/--host) is required for SQL mode${NC}"
            errors=$((errors + 1))
        fi
        if [ -z "$DB_NAME" ]; then
            echo -e "${RED}✗ Error: Database name (-d/--database) is required for SQL mode${NC}"
            errors=$((errors + 1))
        fi
        if [ -z "$DB_USER" ]; then
            echo -e "${RED}✗ Error: Database user (-u/--user) is required for SQL mode${NC}"
            errors=$((errors + 1))
        fi
        if [ -z "$DB_PASS" ] && [ -z "$DB_SECRET_ARN" ]; then
            echo -e "${RED}✗ Error: Either database password (-w/--password) or secret ARN (-s/--secret-arn) is required for SQL mode${NC}"
            errors=$((errors + 1))
        fi
        if [ -n "$DB_PASS" ] && [ -n "$DB_SECRET_ARN" ]; then
            echo -e "${RED}✗ Error: Cannot specify both --password and --secret-arn. Choose one.${NC}"
            errors=$((errors + 1))
        fi
    fi
    
    if [ $errors -gt 0 ]; then
        echo ""
        echo "Run '$0 --help' for usage information"
        exit 1
    fi
    
    # Format validation
    if [[ ! "$REPORT_FORMAT" =~ ^(html|text)$ ]]; then
        echo -e "${RED}✗ Error: Invalid report format '${REPORT_FORMAT}'. Must be: html or text${NC}"
        exit 1
    fi
    
    # Input format validation for SQL parameters
    if [ "$RUN_MODE" = "sql" ] || [ "$RUN_MODE" = "both" ]; then
        validate_sql_inputs
    fi
}

################################################################################
# Function: validate_sql_inputs
# Description: Validates format of SQL connection parameters to prevent injection
#              and ensure values are well-formed before use in commands.
# Checks:
#   - DB_HOST: max 253 chars, valid hostname/IP characters only
#   - DB_PORT: numeric, 1-65535
#   - DB_USER: max 63 chars, alphanumeric/underscore/hyphen only
#   - DB_NAME: max 63 chars, alphanumeric/underscore/hyphen only
################################################################################

# Per-field validation helpers — single source of truth for each rule
_valid_hostname() { [ -n "$1" ] && [ ${#1} -le 253 ] && [[ "$1" =~ ^[a-zA-Z0-9._:-]+$ ]]; }
_valid_port()     { [[ "$1" =~ ^[0-9]+$ ]] && [ ${#1} -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
_valid_dbname()   { [ -n "$1" ] && [ ${#1} -le 63 ] && [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]; }
_valid_dbuser()   { [ -n "$1" ] && [ ${#1} -le 63 ] && [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]; }

validate_sql_inputs() {
    local errors=0
    
    # Validate hostname/endpoint
    if [ -n "$DB_HOST" ]; then
        if ! _valid_hostname "$DB_HOST"; then
            if [ ${#DB_HOST} -gt 253 ]; then
                echo -e "${RED}✗ Error: Hostname too long (max 253 characters)${NC}"
            else
                echo -e "${RED}✗ Error: Invalid hostname format '${DB_HOST}'${NC}"
                echo "  Hostname must contain only letters, digits, dots, hyphens, underscores, and colons (IPv6)"
            fi
            errors=$((errors + 1))
        fi
    fi
    
    # Validate port
    if [ -n "$DB_PORT" ]; then
        if ! _valid_port "$DB_PORT"; then
            echo -e "${RED}✗ Error: Invalid port '${DB_PORT}' (must be a number between 1 and 65535)${NC}"
            errors=$((errors + 1))
        fi
    fi
    
    # Validate username
    if [ -n "$DB_USER" ]; then
        if ! _valid_dbuser "$DB_USER"; then
            if [ ${#DB_USER} -gt 63 ]; then
                echo -e "${RED}✗ Error: Username too long (max 63 characters)${NC}"
            else
                echo -e "${RED}✗ Error: Invalid username format '${DB_USER}'${NC}"
                echo "  Username must contain only letters, digits, dots, underscores, and hyphens"
            fi
            errors=$((errors + 1))
        fi
    fi
    
    # Validate database name
    if [ -n "$DB_NAME" ]; then
        if ! _valid_dbname "$DB_NAME"; then
            if [ ${#DB_NAME} -gt 63 ]; then
                echo -e "${RED}✗ Error: Database name too long (max 63 characters)${NC}"
            else
                echo -e "${RED}✗ Error: Invalid database name format '${DB_NAME}'${NC}"
                echo "  Database name must contain only letters, digits, dots, underscores, and hyphens"
            fi
            errors=$((errors + 1))
        fi
    fi
    
    if [ $errors -gt 0 ]; then
        echo ""
        echo "Run '$0 --help' for usage information"
        exit 1
    fi
}

################################################################################
# Function: retrieve_password_from_secrets_manager
# Description: Retrieves database password from AWS Secrets Manager
# Parameters: None (uses global variables DB_SECRET_ARN, DB_SECRET_KEY, AWS_REGION, AWS_PROFILE)
# Sets: DB_PASS global variable with retrieved password
# Returns: 0 if successful, 1 if failed
################################################################################
retrieve_password_from_secrets_manager() {
    if [ -z "$DB_SECRET_ARN" ]; then
        return 0  # No secret ARN provided, skip
    fi
    
    echo "Retrieving password from AWS Secrets Manager..."
    
    # Verify AWS CLI is available
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}✗ AWS CLI is not installed${NC}"
        echo "Please install AWS CLI: https://aws.amazon.com/cli/"
        return 1
    fi
    
    # Determine region for secrets manager call
    local secret_region="${AWS_REGION}"
    
    # If secret ARN is provided, extract region from ARN
    if [[ "$DB_SECRET_ARN" =~ ^arn:aws:secretsmanager:([^:]+): ]]; then
        secret_region="${BASH_REMATCH[1]}"
    fi
    
    # If no region available, show error
    if [ -z "$secret_region" ]; then
        echo -e "${RED}✗ Cannot determine AWS region for Secrets Manager${NC}"
        echo "Please specify region with -r/--region or use full secret ARN"
        return 1
    fi
    
    # Retrieve secret value
    local secret_output
    secret_output=$(aws secretsmanager get-secret-value \
        --secret-id "${DB_SECRET_ARN}" \
        --region "${secret_region}" \
        --profile "${AWS_PROFILE}" \
        --query 'SecretString' \
        --output text 2>&1)
    
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}✗ Failed to retrieve secret from AWS Secrets Manager${NC}"
        echo ""
        echo "Error details:"
        echo "${secret_output}"
        echo ""
        echo "Please check:"
        echo "  1. Secret ARN/name is correct: ${DB_SECRET_ARN}"
        echo "  2. Secret exists in region: ${secret_region}"
        echo "  3. AWS profile has secretsmanager:GetSecretValue permission"
        echo "  4. AWS credentials are configured: aws configure --profile ${AWS_PROFILE}"
        return 1
    fi
    
    # Parse JSON and extract password using the specified key
    DB_PASS=$(echo "$secret_output" | jq -r ".${DB_SECRET_KEY} // empty" 2>/dev/null)
    
    if [ -z "$DB_PASS" ]; then
        echo -e "${RED}✗ Failed to extract password from secret${NC}"
        echo ""
        echo "Secret does not contain key: '${DB_SECRET_KEY}'"
        echo ""
        echo "Available keys in this secret:"
        echo "$secret_output" | jq -r 'keys[]' 2>/dev/null || echo "(Unable to parse secret as JSON)"
        echo ""
        echo "Common solutions:"
        echo "  1. If you see 'password' in the list above, press Enter at the prompt (use default)"
        echo "  2. If you see a different key (e.g., 'db_password'), specify it with --secret-key"
        echo "  3. Check your secret format in AWS Secrets Manager console"
        echo ""
        echo "Example secret formats:"
        echo '  Standard:        {"password": "your-password-here"}'
        echo '  Custom key:      {"db_password": "your-password-here"}  # Use --secret-key db_password'
        echo '  RDS-managed:     {"username": "admin", "password": "...", "host": "...", "port": 5432}'
        return 1
    fi
    
    echo -e "${GREEN}✓ Password retrieved successfully from Secrets Manager${NC}"
    return 0
}

################################################################################
# Function: display_menu
# Description: Displays interactive menu for mode selection
# Behavior:
#   - In non-interactive mode: Uses pre-set RUN_MODE
#   - In interactive mode: Prompts user to choose between:
#     1. RDS Config  (requires AWS CLI)
#     2. SQL pre-upgrade checks (requires database access)
#     3. Both
################################################################################
display_menu() {
    if [ "$NON_INTERACTIVE" = true ]; then
        echo "Running in non-interactive mode with mode: ${RUN_MODE}"
        return
    fi
    
    echo "Enter choice:"
    echo "1. RDS Config (needs aws cli configured)"
    echo "2. Pre upgrade checks SQL (needs postgres db access username and pwd)"
    echo "3. Both"
    echo ""
    read -r -p "Your choice [1-3]: " choice
    
    case $choice in
        1)
            RUN_MODE="rds"
            ;;
        2)
            RUN_MODE="sql"
            ;;
        3)
            RUN_MODE="both"
            ;;
        *)
            echo -e "${RED}Invalid choice. Please enter 1, 2, or 3.${NC}"
            exit 1
            ;;
    esac
    echo ""
    
    # Prompt for blue/green mode only when SQL checks will be run (options 2 or 3)
    if [ "$RUN_MODE" = "sql" ] || [ "$RUN_MODE" = "both" ]; then
        echo "Enable Blue/Green deployment specific checks?"
        echo "This will run 11 additional checks specific to blue/green deployments."
        echo ""
        read -r -p "Enable blue/green checks? (yes/no) [no]: " bg_choice
        bg_choice=${bg_choice:-no}
        
        if [[ "$bg_choice" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            BLUE_GREEN_MODE=true
            echo "Blue/Green checks enabled"
        else
            BLUE_GREEN_MODE=false
            echo "Blue/Green checks disabled (standard mode)"
        fi
        echo ""

        # Prompt for report format (skipped if --format was set via CLI)
        prompt_report_format
    else
        # RDS-only mode doesn't need blue/green checks
        BLUE_GREEN_MODE=false
    fi

    # Format prompt applies to all modes (prompt_report_format is a no-op if CLI set it)
    if [ "$RUN_MODE" = "rds" ]; then
        prompt_report_format
    fi
}

################################################################################
# Function: get_aws_details
# Description: Collects AWS configuration details for RDS access
# Behavior:
#   - Non-interactive: Uses pre-set environment variables
#   - Interactive: Prompts for AWS_PROFILE, AWS_REGION, DB_IDENTIFIER
# Validation:
#   - Tests AWS CLI credentials with 'aws sts get-caller-identity'
#   - Verifies RDS instance exists with 'aws rds describe-db-instances'
#   - Provides troubleshooting steps if validation fails
################################################################################
get_aws_details() {
    if [ "$NON_INTERACTIVE" = true ]; then
        echo "Using AWS configuration:"
        echo "  Profile: ${AWS_PROFILE}"
        echo "  Region: ${AWS_REGION}"
        echo "  DB/Cluster Identifier: ${DB_IDENTIFIER}"
        echo ""
    else
        echo "Please provide AWS RDS details:"
        echo ""
        
        read -r -p "AWS Profile [default]: " AWS_PROFILE
        AWS_PROFILE=${AWS_PROFILE:-default}
        
        # Validate AWS region format
        while true; do
            read -r -p "AWS Region [us-east-1]: " AWS_REGION
            AWS_REGION=${AWS_REGION:-us-east-1}
            if [[ ! "$AWS_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]]; then
                echo -e "${RED}✗ Invalid AWS region format (e.g. us-east-1, us-gov-west-1, eu-west-2)${NC}"
            else
                break
            fi
        done
        
        # Validate DB identifier format
        while true; do
            read -r -p "DB/Cluster Identifier: " DB_IDENTIFIER
            if [ -z "$DB_IDENTIFIER" ]; then
                echo -e "${RED}✗ DB/Cluster identifier is required${NC}"
            elif [ ${#DB_IDENTIFIER} -gt 63 ]; then
                echo -e "${RED}✗ Identifier too long (max 63 characters)${NC}"
            elif [[ ! "$DB_IDENTIFIER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo -e "${RED}✗ Invalid identifier. Use only letters, digits, underscores, hyphens${NC}"
            else
                break
            fi
        done
        echo ""
    fi
    
    # Verify AWS CLI is configured
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}✗ AWS CLI is not installed${NC}"
        echo "Please install AWS CLI: https://aws.amazon.com/cli/"
        exit 1
    fi
    
    # Test AWS CLI access with the specified profile
    echo "Verifying AWS credentials..."
    local aws_test_output
    aws_test_output=$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --region "${AWS_REGION}" 2>&1)
    local aws_test_exit_code=$?
    
    if [ $aws_test_exit_code -ne 0 ]; then
        echo -e "${RED}✗ AWS CLI authentication failed for profile '${AWS_PROFILE}'${NC}"
        echo ""
        echo "Error details:"
        echo "${aws_test_output}"
        echo ""
        echo -e "${YELLOW}Available profiles:${NC}"
        aws configure list-profiles 2>/dev/null || echo "  (unable to list profiles)"
        echo ""
        echo "Please check:"
        echo "  1. AWS credentials are configured: aws configure --profile ${AWS_PROFILE}"
        echo "  2. Profile has necessary permissions"
        echo "  3. Region is correct: ${AWS_REGION}"
        exit 1
    fi
    
    # Verify RDS instance or Aurora cluster exists
    echo "Verifying database instance/cluster exists..."
    
    # Try RDS instance first
    local rds_test_output
    rds_test_output=$(aws rds describe-db-instances \
        --db-instance-identifier "${DB_IDENTIFIER}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" 2>&1)
    local rds_test_exit_code=$?
    
    if [ $rds_test_exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ AWS CLI configured with profile '${AWS_PROFILE}'${NC}"
        echo -e "${GREEN}✓ RDS instance '${DB_IDENTIFIER}' found${NC}"
        return 0
    fi
    
    # Try Aurora cluster
    local cluster_test_output
    cluster_test_output=$(aws rds describe-db-clusters \
        --db-cluster-identifier "${DB_IDENTIFIER}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" 2>&1)
    local cluster_test_exit_code=$?
    
    if [ $cluster_test_exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ AWS CLI configured with profile '${AWS_PROFILE}'${NC}"
        echo -e "${GREEN}✓ Aurora cluster '${DB_IDENTIFIER}' found${NC}"
        return 0
    fi
    
    # Neither found - show error
    echo -e "${RED}✗ Failed to access database '${DB_IDENTIFIER}'${NC}"
    echo ""
    echo "Error details:"
    echo "RDS Instance check: ${rds_test_output}"
    echo "Aurora Cluster check: ${cluster_test_output}"
    echo ""
    echo "Please check:"
    echo "  1. DB/Cluster identifier is correct: ${DB_IDENTIFIER}"
    echo "  2. Instance/cluster exists in region: ${AWS_REGION}"
    echo "  3. IAM permissions include rds:DescribeDBInstances and rds:DescribeDBClusters"
    exit 1
}

################################################################################
# Function: get_connection_details
# Description: Collects PostgreSQL database connection details
# Behavior:
#   - Non-interactive: Uses pre-set environment variables
#   - Interactive: Prompts for DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS or DB_SECRET_ARN
# Notes:
#   - DB_PORT defaults to 5432 if not specified
#   - Password input is hidden in interactive mode
#   - Supports AWS Secrets Manager as alternative to direct password
################################################################################
get_connection_details() {
    if [ "$NON_INTERACTIVE" = true ]; then
        echo "Using database connection:"
        echo "  Host: ${DB_HOST}"
        echo "  Port: ${DB_PORT}"
        echo "  Database: ${DB_NAME}"
        echo "  User: ${DB_USER}"
        if [ -n "$DB_SECRET_ARN" ]; then
            echo "  Password Source: AWS Secrets Manager (${DB_SECRET_ARN})"
        fi
        echo ""
    else
        echo "Please provide PostgreSQL database connection details:"
        echo ""
        
        # Validate hostname with re-prompt loop
        while true; do
            read -r -p "Database/Cluster Endpoint: " DB_HOST
            if [ -z "$DB_HOST" ]; then
                echo -e "${RED}✗ Endpoint is required${NC}"
            elif ! _valid_hostname "$DB_HOST"; then
                echo -e "${RED}✗ Invalid hostname format. Use only letters, digits, dots, hyphens, underscores, colons (IPv6)${NC}"
            else
                break
            fi
        done
        
        # Validate port with re-prompt loop
        while true; do
            read -r -p "Database Port [5432]: " DB_PORT
            DB_PORT=${DB_PORT:-5432}
            if ! _valid_port "$DB_PORT"; then
                echo -e "${RED}✗ Invalid port. Must be a number between 1 and 65535${NC}"
            else
                break
            fi
        done
        
        # Validate database name with re-prompt loop
        while true; do
            read -r -p "Database Name: " DB_NAME
            if [ -z "$DB_NAME" ]; then
                echo -e "${RED}✗ Database name is required${NC}"
            elif ! _valid_dbname "$DB_NAME"; then
                echo -e "${RED}✗ Invalid database name. Use only letters, digits, dots, underscores, hyphens (max 63 chars)${NC}"
            else
                break
            fi
        done
        
        # Validate username with re-prompt loop
        while true; do
            read -r -p "Database Username: " DB_USER
            if [ -z "$DB_USER" ]; then
                echo -e "${RED}✗ Username is required${NC}"
            elif ! _valid_dbuser "$DB_USER"; then
                echo -e "${RED}✗ Invalid username. Use only letters, digits, dots, underscores, hyphens (max 63 chars)${NC}"
            else
                break
            fi
        done
        
        echo ""
        echo "Password Options:"
        echo "  1. Enter password directly"
        echo "  2. Use AWS Secrets Manager"
        echo ""
        read -r -p "Choose option (1 or 2) [1]: " password_option
        password_option=${password_option:-1}
        
        if [ "$password_option" = "2" ]; then
            echo ""
            read -r -p "AWS Secrets Manager Secret ARN or Name: " DB_SECRET_ARN
            echo ""
            echo "Most secrets use 'password' as the JSON key."
            echo "Press Enter to use the default, or specify a custom key if needed."
            echo ""
            read -r -p "JSON key for password in secret [password]: " DB_SECRET_KEY
            DB_SECRET_KEY=${DB_SECRET_KEY:-password}
            echo ""
        else
            echo ""
            read -r -sp "Database Password: " DB_PASS
            echo ""
            echo ""
        fi
    fi
}

################################################################################
# Function: test_connection
# Description: Tests PostgreSQL database connectivity
# Returns: 0 if connection succeeds, 1 if connection fails
# Test Query: SELECT version()
# Error Handling: Provides troubleshooting steps for common connection issues
################################################################################
test_connection() {
    echo "Testing database connection..."
    
    local test_output
    test_output=$(PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" 2>&1)
    local test_exit_code=$?
    
    if [ $test_exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ Connection successful${NC}"
        return 0
    else
        echo -e "${RED}✗ Connection failed${NC}"
        echo ""
        echo "Error details:"
        echo "${test_output}"
        echo ""
        echo "Please check:"
        echo "  1. Database/Cluster endpoint is reachable: ${DB_HOST}:${DB_PORT}"
        echo "  2. Database name is correct: ${DB_NAME}"
        echo "  3. Username and password are correct"
        echo "  4. User has necessary permissions"
        echo "  5. PostgreSQL client (psql) is installed"
        return 1
    fi
}

################################################################################
# Function: test_connection_or_exit
# Description: Tests database connection and exits script if connection fails
# Purpose: DRY helper to avoid repeating connection test + exit pattern
# Returns: Does not return if connection fails (exits with code 1)
################################################################################
test_connection_or_exit() {
    if ! test_connection; then
        echo "Exiting due to connection failure."
        exit 1
    fi
}

################################################################################
# Function: prompt_baseline_creation
# Description: Displays baseline statistics table creation prompt in interactive mode
# Purpose: DRY helper to avoid duplicating 80+ lines of baseline prompt code
# Features:
#   - Shows formatted explanation of baseline table purpose
#   - Displays complete SQL query that will be executed
#   - Prompts user for confirmation (yes/no)
#   - Sets CREATE_BASELINE global variable
# Global Variables Modified: CREATE_BASELINE
################################################################################
prompt_baseline_creation() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Baseline Statistics Table${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "This will create a table to capture current database statistics before upgrade."
    echo "The table can be used to compare pre and post-upgrade metrics."
    echo ""
    echo -e "${YELLOW}Query that will be executed:${NC}"
    echo ""
    cat <<'EOSQL'
-- Create baseline statistics table (run before upgrade)
DROP TABLE IF EXISTS preupgrade_baseline_stats;
CREATE TABLE preupgrade_baseline_stats (
    id SERIAL PRIMARY KEY,
    capture_time TIMESTAMP DEFAULT NOW(),
    database_name TEXT,
    table_count INTEGER,
    total_size_bytes BIGINT,
    total_index_size_bytes BIGINT,
    total_dead_tuples BIGINT,
    pg_version TEXT
);

-- Insert current statistics
INSERT INTO preupgrade_baseline_stats (
    database_name, table_count, total_size_bytes, 
    total_index_size_bytes, total_dead_tuples, pg_version
)
SELECT 
    current_database(),
    (SELECT COUNT(*) FROM pg_stat_user_tables),
    (SELECT pg_database_size(current_database())),
    (SELECT COALESCE(SUM(pg_indexes_size(relid)), 0) FROM pg_stat_user_tables),
    (SELECT COALESCE(SUM(n_dead_tup), 0) FROM pg_stat_user_tables),
    version();

-- Display the captured baseline
SELECT 
    id,
    capture_time,
    database_name,
    table_count,
    pg_size_pretty(total_size_bytes) as total_size,
    pg_size_pretty(total_index_size_bytes) as total_index_size,
    total_dead_tuples,
    pg_version
FROM preupgrade_baseline_stats 
ORDER BY capture_time DESC 
LIMIT 1;
EOSQL
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -r -p "Should we create baseline stats table before upgrade? (yes/no) [no]: " CREATE_BASELINE
    CREATE_BASELINE=${CREATE_BASELINE:-no}
    echo ""
}

################################################################################
# Function: get_instance_specs
# Description: Returns vCPU count and memory (GB) for AWS RDS instance classes
# Purpose: DRY helper to avoid duplicating 100+ lines of instance type mappings
# Parameters:
#   $1 - instance_class: RDS instance class (e.g., db.t3.micro, db.m5.large)
# Returns: Sets two variables in caller's scope:
#   - vcpu_count: Number of vCPUs for the instance
#   - memory_gb: Total memory in GB for the instance
# Usage:
#   get_instance_specs "db.m5.large"
#   echo "vCPUs: $vcpu_count, Memory: ${memory_gb}GB"
################################################################################
get_instance_specs() {
    local instance_class="$1"
    
    # Initialize defaults
    vcpu_count=2
    memory_gb=8
    
    case "$instance_class" in
        # T3 instances
        db.t3.micro) vcpu_count=2; memory_gb=1 ;;
        db.t3.small) vcpu_count=2; memory_gb=2 ;;
        db.t3.medium) vcpu_count=2; memory_gb=4 ;;
        db.t3.large) vcpu_count=2; memory_gb=8 ;;
        db.t3.xlarge) vcpu_count=4; memory_gb=16 ;;
        db.t3.2xlarge) vcpu_count=8; memory_gb=32 ;;
        # T4g instances (Graviton2)
        db.t4g.micro) vcpu_count=2; memory_gb=1 ;;
        db.t4g.small) vcpu_count=2; memory_gb=2 ;;
        db.t4g.medium) vcpu_count=2; memory_gb=4 ;;
        db.t4g.large) vcpu_count=2; memory_gb=8 ;;
        db.t4g.xlarge) vcpu_count=4; memory_gb=16 ;;
        db.t4g.2xlarge) vcpu_count=8; memory_gb=32 ;;
        # M5 instances
        db.m5.large) vcpu_count=2; memory_gb=8 ;;
        db.m5.xlarge) vcpu_count=4; memory_gb=16 ;;
        db.m5.2xlarge) vcpu_count=8; memory_gb=32 ;;
        db.m5.4xlarge) vcpu_count=16; memory_gb=64 ;;
        db.m5.8xlarge) vcpu_count=32; memory_gb=128 ;;
        db.m5.12xlarge) vcpu_count=48; memory_gb=192 ;;
        db.m5.16xlarge) vcpu_count=64; memory_gb=256 ;;
        db.m5.24xlarge) vcpu_count=96; memory_gb=384 ;;
        # M6i instances
        db.m6i.large) vcpu_count=2; memory_gb=8 ;;
        db.m6i.xlarge) vcpu_count=4; memory_gb=16 ;;
        db.m6i.2xlarge) vcpu_count=8; memory_gb=32 ;;
        db.m6i.4xlarge) vcpu_count=16; memory_gb=64 ;;
        db.m6i.8xlarge) vcpu_count=32; memory_gb=128 ;;
        db.m6i.12xlarge) vcpu_count=48; memory_gb=192 ;;
        db.m6i.16xlarge) vcpu_count=64; memory_gb=256 ;;
        db.m6i.24xlarge) vcpu_count=96; memory_gb=384 ;;
        db.m6i.32xlarge) vcpu_count=128; memory_gb=512 ;;
        # M6g instances (Graviton2)
        db.m6g.large) vcpu_count=2; memory_gb=8 ;;
        db.m6g.xlarge) vcpu_count=4; memory_gb=16 ;;
        db.m6g.2xlarge) vcpu_count=8; memory_gb=32 ;;
        db.m6g.4xlarge) vcpu_count=16; memory_gb=64 ;;
        db.m6g.8xlarge) vcpu_count=32; memory_gb=128 ;;
        db.m6g.12xlarge) vcpu_count=48; memory_gb=192 ;;
        db.m6g.16xlarge) vcpu_count=64; memory_gb=256 ;;
        # M7g instances (Graviton3)
        db.m7g.large) vcpu_count=2; memory_gb=8 ;;
        db.m7g.xlarge) vcpu_count=4; memory_gb=16 ;;
        db.m7g.2xlarge) vcpu_count=8; memory_gb=32 ;;
        db.m7g.4xlarge) vcpu_count=16; memory_gb=64 ;;
        db.m7g.8xlarge) vcpu_count=32; memory_gb=128 ;;
        db.m7g.12xlarge) vcpu_count=48; memory_gb=192 ;;
        db.m7g.16xlarge) vcpu_count=64; memory_gb=256 ;;
        # R5 instances
        db.r5.large) vcpu_count=2; memory_gb=16 ;;
        db.r5.xlarge) vcpu_count=4; memory_gb=32 ;;
        db.r5.2xlarge) vcpu_count=8; memory_gb=64 ;;
        db.r5.4xlarge) vcpu_count=16; memory_gb=128 ;;
        db.r5.8xlarge) vcpu_count=32; memory_gb=256 ;;
        db.r5.12xlarge) vcpu_count=48; memory_gb=384 ;;
        db.r5.16xlarge) vcpu_count=64; memory_gb=512 ;;
        db.r5.24xlarge) vcpu_count=96; memory_gb=768 ;;
        # R6i instances
        db.r6i.large) vcpu_count=2; memory_gb=16 ;;
        db.r6i.xlarge) vcpu_count=4; memory_gb=32 ;;
        db.r6i.2xlarge) vcpu_count=8; memory_gb=64 ;;
        db.r6i.4xlarge) vcpu_count=16; memory_gb=128 ;;
        db.r6i.8xlarge) vcpu_count=32; memory_gb=256 ;;
        db.r6i.12xlarge) vcpu_count=48; memory_gb=384 ;;
        db.r6i.16xlarge) vcpu_count=64; memory_gb=512 ;;
        db.r6i.24xlarge) vcpu_count=96; memory_gb=768 ;;
        db.r6i.32xlarge) vcpu_count=128; memory_gb=1024 ;;
        # R6g instances (Graviton2)
        db.r6g.large) vcpu_count=2; memory_gb=16 ;;
        db.r6g.xlarge) vcpu_count=4; memory_gb=32 ;;
        db.r6g.2xlarge) vcpu_count=8; memory_gb=64 ;;
        db.r6g.4xlarge) vcpu_count=16; memory_gb=128 ;;
        db.r6g.8xlarge) vcpu_count=32; memory_gb=256 ;;
        db.r6g.12xlarge) vcpu_count=48; memory_gb=384 ;;
        db.r6g.16xlarge) vcpu_count=64; memory_gb=512 ;;
        # R7g instances (Graviton3)
        db.r7g.large) vcpu_count=2; memory_gb=16 ;;
        db.r7g.xlarge) vcpu_count=4; memory_gb=32 ;;
        db.r7g.2xlarge) vcpu_count=8; memory_gb=64 ;;
        db.r7g.4xlarge) vcpu_count=16; memory_gb=128 ;;
        db.r7g.8xlarge) vcpu_count=32; memory_gb=256 ;;
        db.r7g.12xlarge) vcpu_count=48; memory_gb=384 ;;
        db.r7g.16xlarge) vcpu_count=64; memory_gb=512 ;;
        # X2iedn instances
        db.x2iedn.xlarge) vcpu_count=4; memory_gb=128 ;;
        db.x2iedn.2xlarge) vcpu_count=8; memory_gb=256 ;;
        db.x2iedn.4xlarge) vcpu_count=16; memory_gb=512 ;;
        db.x2iedn.8xlarge) vcpu_count=32; memory_gb=1024 ;;
        db.x2iedn.16xlarge) vcpu_count=64; memory_gb=2048 ;;
        db.x2iedn.24xlarge) vcpu_count=96; memory_gb=3072 ;;
        db.x2iedn.32xlarge) vcpu_count=128; memory_gb=4096 ;;
        # X2g instances (Graviton2)
        db.x2g.large) vcpu_count=2; memory_gb=16 ;;
        db.x2g.xlarge) vcpu_count=4; memory_gb=32 ;;
        db.x2g.2xlarge) vcpu_count=8; memory_gb=64 ;;
        db.x2g.4xlarge) vcpu_count=16; memory_gb=128 ;;
        db.x2g.8xlarge) vcpu_count=32; memory_gb=256 ;;
        db.x2g.12xlarge) vcpu_count=48; memory_gb=384 ;;
        db.x2g.16xlarge) vcpu_count=64; memory_gb=512 ;;
        # Default fallback for unknown instance types
        *) vcpu_count=2; memory_gb=8 ;;
    esac
}

################################################################################
# Function: init_html
# Description: Initializes HTML report with CSS styling and JavaScript
# Parameters:
#   $1 - output_file: Path to the HTML report file
# Features:
#   - Modern purple gradient theme (#667eea to #764ba2)
#   - Responsive card-based layout
#   - Collapsible sections with JavaScript toggle
#   - Status badges (OK, WARNING, CRITICAL)
#   - Progress bars for resource utilization
################################################################################
init_html() {
    local output_file=$1
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')    # report_type passed as $2 for future use
    
    cat > "${output_file}" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RDS Database Health & Pre-Upgrade Summary Report</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            line-height: 1.6;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        .header p {
            font-size: 1.1em;
            opacity: 0.9;
        }
        .content {
            padding: 30px;
        }
        .section {
            margin-bottom: 40px;
        }
        .section-title {
            font-size: 1.8em;
            color: #333;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 3px solid #667eea;
            display: flex;
            align-items: center;
        }
        .section-title .icon {
            margin-right: 10px;
            font-size: 1.2em;
        }
        h2 {
            color: #34495e;
            margin-top: 30px;
            padding-bottom: 10px;
            border-bottom: 2px solid #667eea;
        }
        h3 {
            color: #555;
            margin: 20px 0 15px 0;
        }
        .card-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .card {
            background: #f8f9fa;
            border-radius: 8px;
            padding: 20px;
            border-left: 4px solid #667eea;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        .card:hover {
            transform: translateY(-5px);
            box-shadow: 0 5px 20px rgba(0,0,0,0.1);
        }
        .card-title {
            font-size: 1.1em;
            color: #555;
            margin-bottom: 10px;
            font-weight: 600;
        }
        .card-value {
            font-size: 1.8em;
            color: #333;
            font-weight: bold;
        }
        .info-box {
            background-color: #e3f2fd;
            border-left: 4px solid #2196f3;
            padding: 15px;
            margin: 20px 0;
            border-radius: 4px;
        }
        .success {
            background-color: #d4edda;
            border-left: 4px solid #28a745;
            padding: 15px;
            margin: 10px 0;
            border-radius: 4px;
        }
        .warning {
            background-color: #fff3cd;
            border-left: 4px solid #ffc107;
            padding: 15px;
            margin: 10px 0;
            border-radius: 4px;
        }
        .error {
            background-color: #f8d7da;
            border-left: 4px solid #dc3545;
            padding: 15px;
            margin: 10px 0;
            border-radius: 4px;
        }
        .info {
            background-color: #d1ecf1;
            border-left: 4px solid #17a2b8;
            padding: 15px;
            margin: 10px 0;
            border-radius: 4px;
        }
        .status-badge {
            display: inline-block;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 0.9em;
            font-weight: bold;
            margin-top: 10px;
        }
        .status-critical {
            background: #ff4444;
            color: white;
        }
        .status-warning {
            background: #ffaa00;
            color: white;
        }
        .status-ok {
            background: #00C851;
            color: white;
        }
        .status-pass {
            background: #00C851;
            color: white;
        }
        .status-passed {
            background: #00C851;
            color: white;
        }
        .status-warn {
            background: #ffaa00;
            color: white;
        }
        .status-fail {
            background: #ff4444;
            color: white;
        }
        .status-failed {
            background: #ff4444;
            color: white;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
            background: white;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 10px rgba(0,0,0,0.05);
        }
        th {
            background: #667eea;
            color: white;
            padding: 15px;
            text-align: left;
            font-weight: 600;
        }
        td {
            padding: 12px 15px;
            border-bottom: 1px solid #eee;
        }
        tr:hover {
            background: #f0f4ff;
        }
        tr.clickable-row {
            cursor: pointer;
            transition: background-color 0.2s;
        }
        tr.clickable-row:hover {
            background: #f0f4ff;
        }
        .detail-row {
            display: none;
            background: #f8f9fa;
        }
        .detail-row.expanded {
            display: table-row;
        }
        .detail-content {
            padding: 20px;
            border-left: 4px solid #667eea;
        }
        .detail-section {
            margin-bottom: 15px;
        }
        .detail-section h4 {
            color: #667eea;
            margin-bottom: 8px;
            font-size: 1.1em;
        }
        .detail-section pre {
            background: #2d2d2d;
            color: #f8f8f2;
            padding: 15px;
            border-radius: 6px;
            overflow-x: auto;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            line-height: 1.5;
        }
        .detail-section .result-box {
            background: #fff;
            border: 1px solid #ddd;
            padding: 12px;
            border-radius: 6px;
            margin-top: 8px;
            overflow: visible;
        }
        .detail-section .result-box pre {
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        .expand-icon {
            float: right;
            transition: transform 0.3s;
            color: #667eea;
            font-weight: bold;
        }
        .expand-icon.rotated {
            transform: rotate(180deg);
        }
        pre {
            background: #2d2d2d;
            color: #f8f8f2;
            padding: 15px;
            border-radius: 6px;
            overflow-x: auto;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            line-height: 1.5;
        }
        .collapsible {
            cursor: pointer;
            padding: 10px;
            background-color: #667eea;
            color: white;
            border: none;
            text-align: left;
            width: 100%;
            font-size: 1em;
            border-radius: 4px;
            margin-top: 10px;
            font-weight: 600;
        }
        .collapsible:hover {
            background-color: #5568d3;
        }
        .collapsible-content {
            padding: 0 18px;
            display: none;
            overflow: hidden;
            background-color: #f9f9f9;
            border-radius: 4px;
            margin-bottom: 10px;
            padding: 15px;
        }
        .content-collapsible {
            padding: 0 18px;
            display: none;
            overflow: hidden;
            background-color: #f9f9f9;
            border-radius: 4px;
            margin-bottom: 10px;
            padding: 15px;
        }
        .config-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }
        .config-item {
            background-color: #f8f9fa;
            padding: 15px;
            border-radius: 4px;
            border-left: 3px solid #667eea;
        }
        .config-label {
            font-weight: bold;
            color: #555;
            font-size: 0.9em;
        }
        .config-value {
            color: #2c3e50;
            font-size: 1.1em;
            margin-top: 5px;
        }
        .chart-container {
            margin: 20px 0;
            padding: 15px;
            background-color: #f8f9fa;
            border-radius: 4px;
        }
        .footer {
            background: #f8f9fa;
            padding: 20px;
            text-align: center;
            color: #666;
            font-size: 0.9em;
        }
        .progress-bar {
            width: 100%;
            height: 25px;
            background: #e0e0e0;
            border-radius: 12px;
            overflow: visible;
            margin-top: 10px;
            position: relative;
        }
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #667eea 0%, #764ba2 100%);
            border-radius: 12px;
            min-width: 60px;
            position: relative;
        }
        .progress-text {
            position: absolute;
            top: 50%;
            left: 8px;
            transform: translateY(-50%);
            color: white;
            font-weight: bold;
            font-size: 0.9em;
            text-shadow: 0 1px 2px rgba(0,0,0,0.3);
        }
        @media (max-width: 768px) {
            .card-grid {
                grid-template-columns: 1fr;
            }
            .config-grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
    <script>
        function toggleContent(id) {
            var content = document.getElementById(id);
            if (content.style.display === "block" || content.style.display === "") {
                content.style.display = "none";
            } else {
                content.style.display = "block";
            }
        }
        
        function toggleDetails(id) {
            var detailRow = document.getElementById('detail-' + id);
            var icon = document.getElementById('icon-' + id);
            
            if (detailRow.classList.contains('expanded')) {
                detailRow.classList.remove('expanded');
                icon.classList.remove('rotated');
            } else {
                detailRow.classList.add('expanded');
                icon.classList.add('rotated');
            }
        }
    </script>
</head>
<body>
    <div class="container">
        <div class="header">
EOF

    # Add title based on blue/green mode
    if [ "$BLUE_GREEN_MODE" = true ]; then
        cat >> "${output_file}" <<EOF
            <h1>🔍 PostgreSQL MVU Pre-Check Report (Blue/Green Mode)</h1>
            <p>Comprehensive Analysis with Blue/Green Deployment Validation</p>
EOF
    else
        cat >> "${output_file}" <<EOF
            <h1>🔍 PostgreSQL MVU Pre-Check Report (Standard Mode)</h1>
            <p>Comprehensive Analysis of Database Health and Upgrade Readiness</p>
EOF
    fi

    cat >> "${output_file}" <<EOF
            <p style="margin-top: 10px; font-size: 0.95em;">Generated: ${timestamp}</p>
        </div>
        <div class="content">
EOF
}

################################################################################
# Function: add_check_result
# Description: Adds a SQL check result to the HTML report
# Parameters:
#   $1 - output_file: Path to HTML report
#   $2 - check_name: Name of the check
#   $3 - check_description: Description of what the check does
#   $4 - query_result: SQL query output
#   $5 - status: OK, WARNING, or CRITICAL
#   $6 - what_to_check: Guidance on interpreting results (optional)
#   $7 - recommendations: Extension-specific recommendations (optional)
# Features:
#   - Clickable table rows with expandable details
#   - Color-coded status badges
#   - Yellow warning boxes for "what to check" guidance
#   - Dark-themed code blocks for query results
################################################################################
add_check_result() {
    local output_file=$1
    local check_name=$2
    local check_description=$3
    local result=$4
    local status=$5
    local check_id=$6
    
    # Special handling for Check 26: Override status based on result content
    if [ "$check_id" = "26" ]; then
        if echo "${result}" | grep -q "CRITICAL"; then
            status="WARNING"
        elif echo "${result}" | grep -q "WARNING"; then
            status="WARNING"
        fi
    fi
    
    # Extract "what to check" from check_name if it exists
    local display_name="${check_name}"
    local what_to_check=""
    
    if [[ "${check_name}" == *" - what to check:"* ]]; then
        display_name="${check_name%% - what to check:*}"
        what_to_check="${check_name#*what to check: }"
        # Remove quotes from what_to_check
        what_to_check="${what_to_check//\"/}"
    fi
    
    local status_class="success"
    local status_text="PASSED"
    local status_badge="status-passed"
    local show_status=true
    local checkbox_icon="✓"  # Checked for success
    
    if [ "${status}" = "WARNING" ]; then
        status_class="warning"
        status_text="WARNING"
        status_badge="status-warning"
        checkbox_icon="✗"  # Unchecked for warning
    elif [ "${status}" = "ERROR" ]; then
        status_class="error"
        status_text="FAILED"
        status_badge="status-failed"
        checkbox_icon="✗"  # Unchecked for error
    elif [ "${status}" = "INFO" ]; then
        status_class="info"
        status_text="INFO"
        status_badge="status-ok"
        show_status=false
        checkbox_icon="—"  # Dash for info
    elif [ "${status}" = "SUCCESS" ]; then
        status_class="success"
        status_text="PASSED"
        status_badge="status-passed"
        checkbox_icon="✓"  # Checked for success
    fi
    
    # Escape special characters in result for HTML
    local escaped_result="${result//&/&amp;}"
    escaped_result="${escaped_result//</&lt;}"
    escaped_result="${escaped_result//>/&gt;}"
    
    # Get SQL query from check_description if it contains SQL
    local sql_query=""
    if [[ "${check_description}" =~ ^[[:space:]]*(SELECT|WITH)[[:space:]] ]]; then
        sql_query="${check_description}"
        check_description="Check for ${display_name}"
    fi
    
    # Build the table row with checkbox column - conditionally show status badge
    if [ "$show_status" = true ]; then
        cat >> "${output_file}" <<EOF
            <tr class="clickable-row" onclick="toggleDetails('${check_id}')">
                <td style="text-align: center; font-size: 1.5em; color: ${status_class};">${checkbox_icon}</td>
                <td><strong>${display_name}</strong></td>
                <td><span class="status-badge ${status_badge}">${status_text}</span></td>
                <td><span class="expand-icon" id="icon-${check_id}">▼</span></td>
            </tr>
EOF
    else
        cat >> "${output_file}" <<EOF
            <tr class="clickable-row" onclick="toggleDetails('${check_id}')">
                <td style="text-align: center; font-size: 1.5em; color: #999;">${checkbox_icon}</td>
                <td><strong>${display_name}</strong></td>
                <td><span style="color: #999; font-style: italic;">Informational</span></td>
                <td><span class="expand-icon" id="icon-${check_id}">▼</span></td>
            </tr>
EOF
    fi
    
    cat >> "${output_file}" <<EOF
            <tr class="detail-row" id="detail-${check_id}">
                <td colspan="4">
                    <div class="detail-content">
                        <div class="detail-section">
                            <h4>� Description</h4>
                            <p>${check_description}</p>
                        </div>
EOF
    
    if [ -n "${sql_query}" ]; then
        cat >> "${output_file}" <<EOF
                        <div class="detail-section">
                            <h4>🔍 SQL Query</h4>
                            <pre>${sql_query}</pre>
                        </div>
EOF
    fi
    
    if [ -n "${result}" ]; then
        cat >> "${output_file}" <<EOF
                        <div class="detail-section">
                            <h4>📊 Result</h4>
                            <div class="result-box">
                                <pre style="background: transparent; padding: 0; margin: 0; color: #333;">${escaped_result}</pre>
                            </div>
                        </div>
EOF
    fi
    
    # Add "what to check" section after the results
    if [ -n "${what_to_check}" ]; then
        cat >> "${output_file}" <<EOF
                        <div class="detail-section">
                            <h4>⚠️ What to Check</h4>
                            <div class="result-box" style="background: #fff3cd; border-left: 4px solid #ffc107;">
                                ${what_to_check}
                            </div>
                        </div>
EOF
    fi
    
    cat >> "${output_file}" <<EOF
                    </div>
                </td>
            </tr>
EOF
}

################################################################################
# Function: finalize_html
# Description: Closes HTML tags and completes the report
# Parameters:
#   $1 - output_file: Path to HTML report
################################################################################
finalize_html() {
    local output_file=$1
    
    cat >> "${output_file}" <<'EOF'
        <h2 style="margin-top: 40px;">PostgreSQL Upgrade Recommendations</h2>
        <p style="font-size: 1.1em; color: #555; margin-bottom: 30px;">Streamlined guide for successful database upgrades</p>
        
        <button class="collapsible" onclick="toggleCollapsible(this)">Pre-Upgrade Planning & Preparation ▼</button>
        <div class="collapsible-content" style="display: block;">
            <h3 style="color: #667eea; margin-top: 20px;">Backup & Risk Mitigation</h3>
            <ul style="line-height: 1.8;">
                <li>Take a pre-upgrade snapshot to reduce the time required for RDS automation's snapshot process. This significantly decreases overall upgrade time depending on your database size and enables quick rollback if needed.</li>
                <li>Keep database backups accessible for immediate restoration if needed.</li>
                <li>Test rollback procedures in staging before production upgrade.</li>
            </ul>
            
            <h3 style="color: #667eea; margin-top: 20px;">Environment Validation</h3>
            <ul style="line-height: 1.8;">
                <li>Test upgrades in non-production first to identify issues early.</li>
                <li>Verify target version compatibility with application drivers, connection poolers, and middleware.</li>
                <li>Review PostgreSQL release notes for breaking changes and new requirements between versions.</li>
            </ul>
            
            <h3 style="color: #667eea; margin-top: 20px;">Configuration Management</h3>
            <ul style="line-height: 1.8;">
                <li>Create custom parameter groups for target version before upgrading (required unless using defaults).</li>
                <li>Document current configuration parameters and compare with target version defaults.</li>
            </ul>
            
            <h3 style="color: #667eea; margin-top: 20px;">Planning & Communication</h3>
            <ul style="line-height: 1.8;">
                <li>Create detailed upgrade runbook with steps, rollback procedures, and stakeholder contacts.</li>
                <li>Estimate upgrade duration based on database size, object count, and upgrade method.</li>
                <li>Schedule during lowest traffic periods with 2-3x time buffer for unexpected issues.</li>
                <li>Notify stakeholders and application teams about upgrade timeline and expected downtime.</li>
            </ul>
            
            <h3 style="color: #667eea; margin-top: 20px;">Performance Baseline</h3>
            <ul style="line-height: 1.8;">
                <li>Establish performance baselines before upgrade for post-upgrade comparison.</li>
                <li>Configure monitoring alerts for CPU, memory, storage, and replication lag thresholds.</li>
            </ul>
        </div>
        
        <button class="collapsible" onclick="toggleCollapsible(this)">Post-Upgrade Validation & Optimization ▼</button>
        <div class="collapsible-content" style="display: block;">
            <h3 style="color: #667eea; margin-top: 20px;">System Verification</h3>
            <ul style="line-height: 1.8;">
                <li>Verify automated backups and point-in-time recovery function correctly after upgrade.</li>
                <li>Upgrade read replicas only after validating primary database performance.</li>
            </ul>
            
            <h3 style="color: #667eea; margin-top: 20px;">Performance Optimization</h3>
            <ul style="line-height: 1.8;">
                <li>Run VACUUM ANALYZE on entire database to update statistics and clean up after upgrade.</li>
                <li>Monitor query execution plans for performance regressions from optimizer changes.</li>
                <li>Rebuild indexes with REINDEX if query performance degrades significantly.</li>
                <li>Optimize slow queries using new version's enhanced query planner features.</li>
            </ul>
            
            <h3 style="color: #667eea; margin-top: 20px;">Monitoring & Documentation</h3>
            <ul style="line-height: 1.8;">
                <li>Reset pg_stat_statements to establish fresh performance baselines.</li>
                <li>Update monitoring dashboards to include new PostgreSQL version metrics.</li>
                <li>Document lessons learned and update runbook for future upgrades.</li>
            </ul>
        </div>
        
        <script>
        function toggleCollapsible(button) {
            button.classList.toggle("active");
            var content = button.nextElementSibling;
            if (content.style.display === "block") {
                content.style.display = "none";
                button.innerHTML = button.innerHTML.replace("▲", "▼");
            } else {
                content.style.display = "block";
                button.innerHTML = button.innerHTML.replace("▼", "▲");
            }
        }
        </script>
        
        <div class="footer">
            <p>PostgreSQL/RDS Pre-Upgrade Check Report</p>
            <p>Database Pre-Check Script - built by AWS CDP team</p>
        </div>
    </div>
</body>
</html>
EOF
}

################################################################################
# Function: init_text_report
# Description: Initializes a plain text report file with header
################################################################################
init_text_report() {
    local output_file=$1
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    cat > "${output_file}" <<EOF
================================================================================
PostgreSQL MVU Pre-Check Report
================================================================================
Generated: ${timestamp}
Host:      ${DB_HOST}
Database:  ${DB_NAME}
User:      ${DB_USER}
Mode:      $([ "${BLUE_GREEN_MODE}" = true ] && echo "Standard + Blue/Green" || echo "Standard")
================================================================================

EOF
}

################################################################################
# Function: add_text_check_result
# Description: Appends a single check result to the plain text report
# Parameters:
#   $1 - output_file
#   $2 - check_name
#   $3 - check_description
#   $4 - query_result
#   $5 - status (SUCCESS/WARNING/ERROR/INFO)
#   $6 - check_id
################################################################################
add_text_check_result() {
    local output_file=$1
    local check_name=$2
    local check_description=$3
    local query_result=$4
    local status=$5
    local check_id=$6
    
    local status_icon
    case "${status}" in
        SUCCESS) status_icon="✓ PASSED" ;;
        WARNING) status_icon="⚠ WARNING" ;;
        ERROR)   status_icon="✗ FAILED" ;;
        INFO)    status_icon="— INFO" ;;
        *)       status_icon="? UNKNOWN" ;;
    esac
    
    cat >> "${output_file}" <<EOF
--------------------------------------------------------------------------------
Check ${check_id}: ${check_name}
Status: ${status_icon}
Description: ${check_description}
EOF
    
    if [ -n "${query_result}" ]; then
        cat >> "${output_file}" <<EOF
Result:
${query_result}
EOF
    fi
    
    echo "" >> "${output_file}"
}

################################################################################
# Function: finalize_text_report
# Description: Appends summary footer to the plain text report
################################################################################
finalize_text_report() {
    local output_file=$1
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    cat >> "${output_file}" <<EOF
================================================================================
Report completed: ${timestamp}
================================================================================
EOF
}

################################################################################
# Function: get_all_databases
# Description: Returns a newline-separated list of all user databases in the
#              cluster, excluding templates and rdsadmin.
# Returns: Sets global ALL_DATABASES variable
################################################################################
get_all_databases() {
    # Return cached result if already populated
    if [ -n "${ALL_DATABASES}" ]; then
        return 0
    fi
    local psql_err
    psql_err=$(mktemp)
    ALL_DATABASES=$(echo "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true AND datname NOT IN ('rdsadmin') ORDER BY datname;" | \
        PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A 2>"${psql_err}")
    local _rc=$?
    if [ ${_rc} -ne 0 ]; then
        echo -e "${RED}ERROR: Failed to retrieve database list: $(cat "${psql_err}")${NC}" >&2
        rm -f "${psql_err}"
        ALL_DATABASES=""
        return 1
    fi
    rm -f "${psql_err}"
    if [ -z "${ALL_DATABASES}" ]; then
        echo -e "${RED}ERROR: No user databases found (all excluded by filter).${NC}" >&2
        return 1
    fi
}

################################################################################
# Function: execute_check_all_dbs
# Description: Runs a SQL check against every user database and aggregates
#              results. Each row in the output is prefixed with the database name.
#              Uses the same status logic and output path as execute_check.
# Parameters:
#   $1 - check_name
#   $2 - check_description
#   $3 - sql_query  (must return rows when issues found, 0 rows when clean)
#   $4 - output_file
#   $5 - check_id
################################################################################
execute_check_all_dbs() {
    local check_name=$1
    local check_description=$2
    local sql_query=$3
    local output_file=$4
    local check_id=$5

    echo "Running: ${check_name} (all databases)..."

    if ! get_all_databases; then
        write_check_result "${output_file}" "${check_name}" "${check_description}" \
            "ERROR: Could not retrieve database list. Check connection to ${DB_HOST}." "ERROR" "${check_id}"
        return
    fi

    local combined_result=""
    local any_rows=false
    local any_error=false

    while IFS= read -r db; do
        [ -z "$db" ] && continue
        local db_result
        local psql_err
        psql_err=$(mktemp)
        db_result=$(echo "${sql_query}" | PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${db}" -t -A 2>"${psql_err}")
        local _rc=$?

        if [ ${_rc} -ne 0 ]; then
            any_error=true
            combined_result="${combined_result}-- Database: ${db} (error)
$(cat "${psql_err}")

"
            rm -f "${psql_err}"
            continue
        fi
        rm -f "${psql_err}"

        # Count non-empty rows (-t -A output has no headers/separators)
        local row_count
        row_count=$(echo "${db_result}" | grep -c -v '^ *$' || true)

        if [ "${row_count}" -gt 0 ]; then
            any_rows=true
            combined_result="${combined_result}-- Database: ${db}
${db_result}

"
        fi
    done <<< "${ALL_DATABASES}"

    local status="SUCCESS"
    if [ "${any_error}" = true ]; then
        status="ERROR"
    elif [ "${any_rows}" = true ]; then
        status="WARNING"
    fi

    # Critical upgrade blockers should be ERROR, not WARNING, when issues are found
    local base_check="${check_name%% - what to check:*}"
    case "${base_check}" in
        "chkpass Extension Check"|"tsearch2 Extension Check"|"pg_repack Extension Check"|"System-Defined Composite Types in User Tables"|"aclitem Data Type Check (PostgreSQL 16+ Incompatibility)"|"sql_identifier Data Type Check (PostgreSQL 12+ Incompatibility)"|"Removed Data Types Check (abstime, reltime, tinterval)"|"Tables WITH OIDS Check"|"User-Defined Encoding Conversions Check"|"User-Defined Postfix Operators Check"|"Incompatible Polymorphic Functions Check"|"reg* Data Types in User Tables Check"|"Database Connection Settings Check")
            if [ "${status}" = "WARNING" ]; then
                status="ERROR"
            fi
            ;;
    esac

    # Informational checks are always INFO regardless of row count, but preserve ERROR
    case "${base_check}" in
        "Object Count Check"|"Top 20 Largest Tables"|"Unused Indexes Analysis"|"Schema Usage")
            if [ "${status}" != "ERROR" ]; then
                status="INFO"
            fi
            ;;
    esac

    local base_name="${check_name%% - what to check:*}"
    if [ "${REPORT_FORMAT}" != "text" ]; then
        echo "<!-- Check: '${base_name}' | All-DB | Status: ${status} | ID: ${check_id} -->" >> "${output_file}"
    fi
    write_check_result "${output_file}" "${check_name}" "${check_description}" "${combined_result}" "${status}" "${check_id}"
}

################################################################################
# Function: execute_max_locks_all_dbs
# Description: Calculates the instance-wide max_locks_per_transaction requirement
#              by summing table counts across ALL user databases.
#              Applies a 20% safety buffer per the calculate_max_locks script.
# Parameters:
#   $1 - output_file
#   $2 - check_id
################################################################################
execute_max_locks_all_dbs() {
    local output_file=$1
    local check_id=$2

    echo "Running: max_locks_per_transaction Check (all databases)..."

    if ! get_all_databases; then
        write_check_result "${output_file}" "max_locks_per_transaction Check" \
            "Validates max_locks_per_transaction is sufficient." \
            "ERROR: Could not retrieve database list. Check connection to ${DB_HOST}." "ERROR" "${check_id}"
        return
    fi

    # Get instance-level parameters (same across all DBs)
    local max_connections max_prepared current_max_locks
    local psql_err_params
    psql_err_params=$(mktemp)
    max_connections=$(echo "SHOW max_connections;" | PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A 2>"${psql_err_params}" | tr -d ' ')
    max_prepared=$(echo "SHOW max_prepared_transactions;" | PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A 2>>"${psql_err_params}" | tr -d ' ')
    current_max_locks=$(echo "SHOW max_locks_per_transaction;" | PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A 2>>"${psql_err_params}" | tr -d ' ')
    rm -f "${psql_err_params}"

    # Apply defaults and validate
    max_connections=${max_connections:-0}
    max_prepared=${max_prepared:-0}
    current_max_locks=${current_max_locks:-0}

    if [ "${max_connections}" -eq 0 ] || [ "${current_max_locks}" -eq 0 ]; then
        write_check_result "${output_file}" \
            "max_locks_per_transaction Check" \
            "Validates max_locks_per_transaction is sufficient for Blue/Green logical replication across ALL databases." \
            "ERROR: Could not retrieve instance parameters (max_connections or max_locks_per_transaction). Check database connectivity." \
            "ERROR" "${check_id}"
        return
    fi

    # Sum tables across all databases
    local total_tables=0
    local db_breakdown=""
    local table_count_status="SUCCESS"

    while IFS= read -r db; do
        [ -z "$db" ] && continue
        local count
        local psql_err_count
        psql_err_count=$(mktemp)
        count=$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema','pg_toast') AND table_type = 'BASE TABLE';" | \
            PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${db}" -t -A 2>"${psql_err_count}" | tr -d ' ')
        local _rc_count=$?
        if [ ${_rc_count} -ne 0 ] || ! [[ "${count}" =~ ^[0-9]+$ ]]; then
            db_breakdown="${db_breakdown}  ${db}: ERROR - could not query table count ($(cat "${psql_err_count}"))
"
            rm -f "${psql_err_count}"
            table_count_status="ERROR"
            continue
        fi
        rm -f "${psql_err_count}"
        total_tables=$((total_tables + count))
        db_breakdown="${db_breakdown}  ${db}: ${count} tables
"
    done <<< "${ALL_DATABASES}"

    # If any DB was unreachable, report error — undercounting is dangerous
    if [ "${table_count_status}" = "ERROR" ]; then
        write_check_result "${output_file}" \
            "max_locks_per_transaction Check" \
            "Validates that max_locks_per_transaction is sufficient for Blue/Green logical replication across ALL databases." \
            "ERROR: Could not query table count from one or more databases. Fix connectivity before relying on this check.
${db_breakdown}" \
            "ERROR" "${check_id}"
        return
    fi

    # Calculate recommended value with 20% safety buffer
    local denominator=$((max_connections + max_prepared))
    local recommended_min=0
    local recommended_buffered=0
    if [ "${denominator}" -le 0 ]; then
        write_check_result "${output_file}" \
            "max_locks_per_transaction Check" \
            "Validates that max_locks_per_transaction is sufficient for Blue/Green logical replication across ALL databases." \
            "ERROR: max_connections + max_prepared_transactions = 0. Cannot calculate recommendation." \
            "ERROR" "${check_id}"
        return
    fi
    # Ceiling division: (a + b - 1) / b
    recommended_min=$(( (total_tables + denominator - 1) / denominator ))
    # 20% buffer with ceiling: (total_tables * 12 + denominator*10 - 1) / (denominator * 10)
    recommended_buffered=$(( (total_tables * 12 + denominator * 10 - 1) / (denominator * 10) ))
    # Ensure minimum of 64 (PostgreSQL default)
    if [ "${recommended_buffered}" -lt 64 ]; then
        recommended_buffered=64
    fi

    local status_msg
    if [ "${current_max_locks}" -ge "${recommended_buffered}" ]; then
        status_msg="OK - current value (${current_max_locks}) meets recommended minimum with 20% buffer (${recommended_buffered})"
    elif [ "${current_max_locks}" -ge "${recommended_min}" ]; then
        status_msg="WARNING - current value (${current_max_locks}) meets bare minimum (${recommended_min}) but lacks 20% safety buffer. Recommended: ${recommended_buffered}. Set on SOURCE and TARGET cluster parameter group."
    else
        status_msg="WARNING - current value (${current_max_locks}) is below minimum required (${recommended_min}). Recommended with 20% buffer: ${recommended_buffered}. Set on SOURCE and TARGET cluster parameter group."
    fi

    local result
    result="Instance-wide max_locks_per_transaction Analysis
================================================
max_connections:            ${max_connections}
max_prepared_transactions:  ${max_prepared}
current max_locks_per_txn:  ${current_max_locks}

Table counts per database:
${db_breakdown}
Total tables (all databases): ${total_tables}

Formula: ceil(total_tables / (max_connections + max_prepared_transactions))
Minimum required:             ${recommended_min}
Recommended (with 20% buffer): ${recommended_buffered}

Status: ${status_msg}

AWS CLI command to update (replace <param-group> with your TARGET parameter group):
  aws rds modify-db-cluster-parameter-group \\
    --db-cluster-parameter-group-name <param-group> \\
    --parameters \"ParameterName=max_locks_per_transaction,ParameterValue=${recommended_buffered},ApplyMethod=pending-reboot\""

    local status="SUCCESS"
    if echo "${status_msg}" | grep -q "^WARNING"; then
        status="WARNING"
    fi

    local base_name="max_locks_per_transaction Check"
    if [ "${REPORT_FORMAT}" != "text" ]; then
        echo "<!-- Check: '${base_name}' | All-DB | Status: ${status} | ID: ${check_id} -->" >> "${output_file}"
    fi
    write_check_result "${output_file}" \
        "max_locks_per_transaction Check" \
        "Validates that max_locks_per_transaction is sufficient for Blue/Green logical replication across ALL databases. Formula: ceil(total_tables / (max_connections + max_prepared_transactions)) with 20% safety buffer. Set on SOURCE and TARGET cluster parameter group." \
        "${result}" \
        "${status}" \
        "${check_id}"
}

################################################################################
# Function: prompt_report_format
# Description: Interactively prompts the user to choose html or text report format.
#              Skipped if --format was already provided via CLI (FORMAT_SET_BY_CLI=true).
################################################################################
prompt_report_format() {
    if [ "${FORMAT_SET_BY_CLI}" = true ]; then
        return
    fi
    echo "Report format:"
    echo "  html - Interactive HTML report with expandable sections (default)"
    echo "  text - Plain text report suitable for logging or CI/CD pipelines"
    echo ""
    while true; do
        read -r -p "Report format (html/text) [html]: " format_choice
        format_choice=${format_choice:-html}
        if [[ "$format_choice" =~ ^[Hh][Tt][Mm][Ll]$ ]]; then
            REPORT_FORMAT="html"
            break
        elif [[ "$format_choice" =~ ^[Tt][Ee][Xx][Tt]$ ]]; then
            REPORT_FORMAT="text"
            break
        else
            echo -e "${RED}✗ Invalid format. Please choose html or text${NC}"
        fi
    done
    echo "Report format: $REPORT_FORMAT"
    echo ""
}

################################################################################
# Function: write_check_result
# Description: Single shared helper that dispatches to the correct output format.
#              Use this instead of calling add_check_result or add_text_check_result
#              directly, so format-dispatch logic lives in one place.
# Parameters:
#   $1 - output_file
#   $2 - check_name (full name including "what to check" suffix for HTML)
#   $3 - check_description
#   $4 - query_result
#   $5 - status
#   $6 - check_id
################################################################################
write_check_result() {
    local output_file=$1
    local check_name=$2
    local check_description=$3
    local query_result=$4
    local status=$5
    local check_id=$6
    local base_name="${check_name%% - what to check:*}"
    
    if [ "${REPORT_FORMAT}" = "text" ]; then
        add_text_check_result "${output_file}" "${base_name}" "${check_description}" "${query_result}" "${status}" "${check_id}"
    else
        add_check_result "${output_file}" "${check_name}" "${check_description}" "${query_result}" "${status}" "${check_id}"
    fi
}

################################################################################
# Function: detect_engine_type
# Description: Detects if the database is RDS PostgreSQL or Aurora PostgreSQL
# Parameters:
#   None (uses global variables DB_IDENTIFIER, AWS_REGION, AWS_PROFILE)
# Returns:
#   Sets global ENGINE_TYPE variable to "postgres", "aurora-postgresql", or "unknown"
#   Sets global IS_AURORA_SERVERLESS to "true" or "false"
#   Sets global CLUSTER_IDENTIFIER for Aurora instances
################################################################################
detect_engine_type() {
    echo "Detecting database engine type..."
    
    # Try Aurora cluster first (since cluster identifiers won't work with describe-db-instances)
    local cluster_info
    cluster_info=$(aws rds describe-db-clusters \
        --db-cluster-identifier "${DB_IDENTIFIER}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>/dev/null)
    
    local _rc=$?
    if [ $_rc -eq 0 ] && echo "$cluster_info" | jq empty 2>/dev/null; then
        ENGINE_TYPE=$(echo "$cluster_info" | jq -r '.DBClusters[0].Engine')
        CLUSTER_IDENTIFIER="${DB_IDENTIFIER}"
        echo "Detected: Aurora PostgreSQL Cluster (${CLUSTER_IDENTIFIER})"
        
        local engine_mode
        engine_mode=$(echo "$cluster_info" | jq -r '.DBClusters[0].EngineMode // "provisioned"')
        local serverless_v2
        serverless_v2=$(echo "$cluster_info" | jq -r '.DBClusters[0].ServerlessV2ScalingConfiguration.MinCapacity // "null"')        
        if [ "$serverless_v2" != "null" ]; then
            IS_AURORA_SERVERLESS="v2"
            echo "  Mode: Aurora Serverless v2"
        elif [ "$engine_mode" == "serverless" ]; then
            IS_AURORA_SERVERLESS="v1"
            echo "  Mode: Aurora Serverless v1"
        else
            IS_AURORA_SERVERLESS="false"
            echo "  Mode: Aurora Provisioned"
        fi
        return 0
    fi
    
    # Try RDS instance
    local rds_info
    rds_info=$(aws rds describe-db-instances \
        --db-instance-identifier "${DB_IDENTIFIER}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>/dev/null)
    
    local _rc=$?
    if [ $_rc -eq 0 ] && echo "$rds_info" | jq empty 2>/dev/null; then
        ENGINE_TYPE=$(echo "$rds_info" | jq -r '.DBInstances[0].Engine')
        
        if [ "$ENGINE_TYPE" == "aurora-postgresql" ]; then
            CLUSTER_IDENTIFIER=$(echo "$rds_info" | jq -r '.DBInstances[0].DBClusterIdentifier')
            echo "Detected: Aurora PostgreSQL (Instance: ${DB_IDENTIFIER}, Cluster: ${CLUSTER_IDENTIFIER})"
            
            # Check if serverless by querying cluster
            local cluster_info
            cluster_info=$(aws rds describe-db-clusters \
                --db-cluster-identifier "${CLUSTER_IDENTIFIER}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --output json 2>/dev/null)
            
            local engine_mode
            engine_mode=$(echo "$cluster_info" | jq -r '.DBClusters[0].EngineMode // "provisioned"')
            local serverless_v2
            serverless_v2=$(echo "$cluster_info" | jq -r '.DBClusters[0].ServerlessV2ScalingConfiguration.MinCapacity // "null"')            
            if [ "$serverless_v2" != "null" ]; then
                IS_AURORA_SERVERLESS="v2"
                echo "  Mode: Aurora Serverless v2"
            elif [ "$engine_mode" == "serverless" ]; then
                IS_AURORA_SERVERLESS="v1"
                echo "  Mode: Aurora Serverless v1"
            else
                IS_AURORA_SERVERLESS="false"
                echo "  Mode: Aurora Provisioned"
            fi
        else
            echo "Detected: RDS PostgreSQL"
            IS_AURORA_SERVERLESS="false"
        fi
        return 0
    fi
    
    echo -e "${RED}✗ Could not detect engine type${NC}"
    ENGINE_TYPE="unknown"
    IS_AURORA_SERVERLESS="false"
    return 1
}

################################################################################
# Function: get_pg_major_version
# Description: Detects PostgreSQL major version from database connection
# Returns: Major version number (e.g., 13, 14, 15, 16)
# Sets: PG_MAJOR_VERSION global variable
################################################################################
get_pg_major_version() {
    if [ -z "$PG_MAJOR_VERSION" ]; then
        local version_num
        version_num=$(PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SHOW server_version_num;" 2>/dev/null)
        if [ -n "$version_num" ]; then
            # Convert version number (e.g., 130012 -> 13, 150004 -> 15)
            PG_MAJOR_VERSION=$((version_num / 10000))
            echo "Detected PostgreSQL major version: $PG_MAJOR_VERSION"
        else
            PG_MAJOR_VERSION=0
            echo "Warning: Could not detect PostgreSQL version"
        fi
    fi
    return 0
}

################################################################################
# Function: add_rds_config
# Description: Adds RDS instance configuration details to HTML report
# Parameters:
#   $1 - output_file: Path to HTML report
# Data Retrieved:
#   - Instance identifier, class, engine version
#   - Storage (allocated, type, IOPS, throughput)
#   - Multi-AZ, backup retention, maintenance window
#   - Parameter group, option group, subnet group
#   - Endpoint, port, VPC security groups
#   - Latest snapshot information
#   - Pending maintenance actions
# API Calls:
#   - aws rds describe-db-instances
#   - aws rds describe-db-snapshots
#   - aws rds describe-pending-maintenance-actions
################################################################################
add_rds_config() {
    local output_file=$1
    
    # Route to appropriate function based on engine type
    if [ "$ENGINE_TYPE" == "aurora-postgresql" ]; then
        add_aurora_config "${output_file}"
    else
        add_rds_postgres_config "${output_file}"
    fi
}

################################################################################
# Function: add_rds_postgres_config
# Description: Adds RDS PostgreSQL configuration details to HTML report
################################################################################
add_rds_postgres_config() {
    local output_file=$1
    
    echo "Fetching RDS PostgreSQL configuration..."
    
    # Get RDS instance details with error handling
    local rds_info
    rds_info=$(aws rds describe-db-instances \
        --db-instance-identifier "${DB_IDENTIFIER}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    local rds_exit_code=$?
    
    if [ $rds_exit_code -ne 0 ]; then
        echo -e "${RED}✗ Failed to retrieve RDS instance information${NC}"
        echo "Error: ${rds_info}"
        cat >> "${output_file}" <<EOF
        <h2>RDS Configuration</h2>
        <div class="error">
            <p><strong>Error:</strong> Failed to retrieve RDS instance information</p>
            <pre>${rds_info}</pre>
        </div>
EOF
        return 1
    fi
    
    # Validate JSON response
    if ! echo "$rds_info" | jq empty 2>/dev/null; then
        echo -e "${RED}✗ Invalid JSON response from AWS CLI${NC}"
        cat >> "${output_file}" <<EOF
        <h2>RDS Configuration</h2>
        <div class="error">
            <p><strong>Error:</strong> Invalid response from AWS CLI</p>
            <pre>${rds_info}</pre>
        </div>
EOF
        return 1
    fi
    
    # Extract configuration details
    local instance_class
    instance_class=$(echo "$rds_info" | jq -r '.DBInstances[0].DBInstanceClass')
    local engine
    engine=$(echo "$rds_info" | jq -r '.DBInstances[0].Engine')
    local engine_version
    engine_version=$(echo "$rds_info" | jq -r '.DBInstances[0].EngineVersion')
    local monitoring_interval
    monitoring_interval=$(echo "$rds_info" | jq -r '.DBInstances[0].MonitoringInterval')
    local parameter_group
    parameter_group=$(echo "$rds_info" | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName')
    local parameter_group_status
    parameter_group_status=$(echo "$rds_info" | jq -r '.DBInstances[0].DBParameterGroups[0].ParameterApplyStatus')
    local maintenance_window
    maintenance_window=$(echo "$rds_info" | jq -r '.DBInstances[0].PreferredMaintenanceWindow')
    local pi_enabled
    pi_enabled=$(echo "$rds_info" | jq -r '.DBInstances[0].PerformanceInsightsEnabled')
    local pi_retention
    pi_retention=$(echo "$rds_info" | jq -r '.DBInstances[0].PerformanceInsightsRetentionPeriod // "N/A"')
    local storage_type
    storage_type=$(echo "$rds_info" | jq -r '.DBInstances[0].StorageType')
    local allocated_storage
    allocated_storage=$(echo "$rds_info" | jq -r '.DBInstances[0].AllocatedStorage')
    local iops
    iops=$(echo "$rds_info" | jq -r '.DBInstances[0].Iops // "N/A"')
    local multi_az
    multi_az=$(echo "$rds_info" | jq -r '.DBInstances[0].MultiAZ')
    local availability_zone
    availability_zone=$(echo "$rds_info" | jq -r '.DBInstances[0].AvailabilityZone')
    local endpoint
    endpoint=$(echo "$rds_info" | jq -r '.DBInstances[0].Endpoint.Address')
    local port
    port=$(echo "$rds_info" | jq -r '.DBInstances[0].Endpoint.Port')    
    # Get read replicas
    local read_replicas
    read_replicas=$(echo "$rds_info" | jq -r '.DBInstances[0].ReadReplicaDBInstanceIdentifiers | length')
    local read_replica_list
    read_replica_list=$(echo "$rds_info" | jq -r '.DBInstances[0].ReadReplicaDBInstanceIdentifiers | join(", ")' 2>/dev/null)    
    if [ -z "$read_replica_list" ] || [ "$read_replica_list" = "null" ]; then
        read_replica_list="None"
        read_replicas="0"
    fi
    
    # Get instance specs for vCPU count and memory
    get_instance_specs "$instance_class"
    local instance_memory_gb=$memory_gb
    
    cat >> "${output_file}" <<EOF
        <h2>RDS Configuration Details</h2>
        <div class="config-grid">
            <div class="config-item">
                <div class="config-label">DB Identifier</div>
                <div class="config-value">${DB_IDENTIFIER}</div>
            </div>
            <div class="config-item">
                <div class="config-label">AWS Region</div>
                <div class="config-value">${AWS_REGION}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Instance Class</div>
                <div class="config-value">${instance_class}</div>
            </div>
            <div class="config-item">
                <div class="config-label">vCPU Count</div>
                <div class="config-value">${vcpu_count}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Memory</div>
                <div class="config-value">${instance_memory_gb} GB</div>
            </div>
            <div class="config-item">
                <div class="config-label">Engine</div>
                <div class="config-value">${engine}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Engine Version</div>
                <div class="config-value">${engine_version}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Monitoring Interval</div>
                <div class="config-value">${monitoring_interval} seconds</div>
            </div>
            <div class="config-item">
                <div class="config-label">Parameter Group</div>
                <div class="config-value">${parameter_group}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Parameter Group Status</div>
                <div class="config-value">${parameter_group_status}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Maintenance Window</div>
                <div class="config-value">${maintenance_window}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Performance Insights Enabled</div>
                <div class="config-value">${pi_enabled}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Performance Insights Retention</div>
                <div class="config-value">${pi_retention} days</div>
            </div>
            <div class="config-item">
                <div class="config-label">Storage Type</div>
                <div class="config-value">${storage_type}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Allocated Storage</div>
                <div class="config-value">${allocated_storage} GB</div>
            </div>
            <div class="config-item">
                <div class="config-label">IOPS</div>
                <div class="config-value">${iops}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Multi-AZ</div>
                <div class="config-value">${multi_az}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Availability Zone</div>
                <div class="config-value">${availability_zone}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Endpoint</div>
                <div class="config-value">${endpoint}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Port</div>
                <div class="config-value">${port}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Read Replicas Count</div>
                <div class="config-value">${read_replicas}</div>
            </div>
        </div>
        
        <h3>Read Replicas</h3>
EOF
    
    if [ "$read_replicas" -gt 0 ]; then
        cat >> "${output_file}" <<EOF
        <table>
            <tr>
                <th>Replica Identifier</th>
                <th>Allocated Storage (GB)</th>
            </tr>
EOF
        
        # Get details for each read replica
        local replica_list_array
        replica_list_array=$(echo "$rds_info" | jq -r '.DBInstances[0].ReadReplicaDBInstanceIdentifiers[]')        
        for replica_id in $replica_list_array; do
            local replica_info
            replica_info=$(aws rds describe-db-instances \
                --db-instance-identifier "${replica_id}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --query 'DBInstances[0].AllocatedStorage' \
                --output text 2>&1)
            
            local _rc=$?
            if [ $_rc -eq 0 ]; then
                cat >> "${output_file}" <<EOF
            <tr>
                <td>${replica_id}</td>
                <td>${replica_info}</td>
            </tr>
EOF
            else
                cat >> "${output_file}" <<EOF
            <tr>
                <td>${replica_id}</td>
                <td>Unable to retrieve</td>
            </tr>
EOF
            fi
        done
        
        cat >> "${output_file}" <<EOF
        </table>
        <div class="info" style="margin-top: 15px; background-color: #fff3cd; border-left: 4px solid #ffc107;">
            <p><strong>⚠️ What to Check:</strong> Please make sure that the storage of all the corresponding read replicas is the same (or more) as that of the DB Instance.</p>
        </div>
EOF
    else
        cat >> "${output_file}" <<EOF
        <div class="info">
            <p><strong>Read Replica Instances:</strong> None</p>
        </div>
EOF
    fi
    
    # Get last two snapshots
    echo "Fetching snapshot information..."
    local snapshots
    snapshots=$(aws rds describe-db-snapshots \
        --db-instance-identifier "${DB_IDENTIFIER}" \
        --snapshot-type automated \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --query 'DBSnapshots | sort_by(@, &SnapshotCreateTime) | reverse(@) | [0:2]' \
        --output json 2>&1)
    
    local _rc=$?
    if [ $_rc -eq 0 ]; then
        local snapshot_count
        snapshot_count=$(echo "$snapshots" | jq -r 'length')        
        if [ "$snapshot_count" -gt 0 ]; then
            cat >> "${output_file}" <<EOF
        <h3>Recent Automated Snapshots</h3>
        <table>
            <tr>
                <th>Snapshot ID</th>
                <th>Create Time</th>
                <th>Status</th>
                <th>Size (GB)</th>
            </tr>
EOF
            
            for i in $(seq 0 $((snapshot_count - 1))); do
                local snapshot_id
                snapshot_id=$(echo "$snapshots" | jq -r ".[$i].DBSnapshotIdentifier")
                local create_time
                create_time=$(echo "$snapshots" | jq -r ".[$i].SnapshotCreateTime")
                local status
                status=$(echo "$snapshots" | jq -r ".[$i].Status")
                local allocated_storage
                allocated_storage=$(echo "$snapshots" | jq -r ".[$i].AllocatedStorage")                
                cat >> "${output_file}" <<EOF
            <tr>
                <td>${snapshot_id}</td>
                <td>${create_time}</td>
                <td>${status}</td>
                <td>${allocated_storage}</td>
            </tr>
EOF
            done
            
            cat >> "${output_file}" <<EOF
        </table>
EOF
        else
            cat >> "${output_file}" <<EOF
        <h3>Recent Automated Snapshots</h3>
        <div class="info">
            <p><strong>No automated snapshots found</strong></p>
        </div>
EOF
        fi
    else
        cat >> "${output_file}" <<EOF
        <h3>Recent Automated Snapshots</h3>
        <div class="warning">
            <p><strong>Unable to retrieve snapshot information</strong></p>
        </div>
EOF
    fi
    
    # Check for pending maintenance
    echo "Checking for pending maintenance..."
    local pending_maintenance
    pending_maintenance=$(echo "$rds_info" | jq -r '.DBInstances[0].PendingModifiedValues')
    local maintenance_actions
    maintenance_actions=$(aws rds describe-pending-maintenance-actions \
        --resource-identifier "arn:aws:rds:${AWS_REGION}:$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --query Account --output text):db:${DB_IDENTIFIER}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    
    local has_pending=false
    local pending_html=""
    
    # Check PendingModifiedValues
    if [ "$pending_maintenance" != "null" ] && [ "$pending_maintenance" != "{}" ]; then
        has_pending=true
        pending_html="${pending_html}<h4>Pending Configuration Changes</h4><pre>$(echo "$pending_maintenance" | jq -r '.')</pre>"
    fi
    
    # Check PendingMaintenanceActions
    local _rc=$?
    if [ $_rc -eq 0 ]; then
        local action_count
        action_count=$(echo "$maintenance_actions" | jq -r '.PendingMaintenanceActions[0].PendingMaintenanceActionDetails | length' 2>/dev/null || echo "0")        
        if [ "$action_count" -gt 0 ]; then
            has_pending=true
            pending_html="${pending_html}<h4>Pending Maintenance Actions</h4><table><tr><th>Action</th><th>Description</th><th>Auto Applied After</th><th>Current Apply Date</th></tr>"
            
            for i in $(seq 0 $((action_count - 1))); do
                local action
                action=$(echo "$maintenance_actions" | jq -r ".PendingMaintenanceActions[0].PendingMaintenanceActionDetails[$i].Action")
                local description
                description=$(echo "$maintenance_actions" | jq -r ".PendingMaintenanceActions[0].PendingMaintenanceActionDetails[$i].Description // \"N/A\"")
                local auto_applied_after
                auto_applied_after=$(echo "$maintenance_actions" | jq -r ".PendingMaintenanceActions[0].PendingMaintenanceActionDetails[$i].AutoAppliedAfterDate // \"N/A\"")
                local current_apply_date
                current_apply_date=$(echo "$maintenance_actions" | jq -r ".PendingMaintenanceActions[0].PendingMaintenanceActionDetails[$i].CurrentApplyDate // \"N/A\"")                
                pending_html="${pending_html}<tr><td>${action}</td><td>${description}</td><td>${auto_applied_after}</td><td>${current_apply_date}</td></tr>"
            done
            
            pending_html="${pending_html}</table>"
        fi
    fi
    
    if [ "$has_pending" = true ]; then
        cat >> "${output_file}" <<EOF
        <h3>Pending Maintenance</h3>
        <div class="warning">
            <p><strong>⚠️ There are pending maintenance actions or configuration changes</strong></p>
            ${pending_html}
        </div>
EOF
    else
        cat >> "${output_file}" <<EOF
        <h3>Pending Maintenance</h3>
        <div class="success">
            <p><strong>✓ No pending maintenance actions</strong></p>
        </div>
EOF
    fi
    
    # Add Parameter Group Details
    echo "Fetching parameter group details..."
    cat >> "${output_file}" <<EOF
        <h3>Parameter Group Details</h3>
        <button class="collapsible" onclick="toggleCollapsible(this)">View Parameter Group Configuration ▼</button>
        <div class="collapsible-content">
            <p><strong>Parameter Group:</strong> ${parameter_group}</p>
EOF
    
    local param_details
    # shellcheck disable=SC2016
    param_details=$(aws rds describe-db-parameters \
        --db-parameter-group-name "${parameter_group}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --query 'Parameters[?Source==`user`].[ParameterName,ParameterValue,ApplyType,IsModifiable]' \
        --output json 2>&1)
    
    local _rc=$?
    if [ $_rc -eq 0 ]; then
        local param_count
        param_count=$(echo "$param_details" | jq -r 'length')        
        if [ "$param_count" -gt 0 ]; then
            cat >> "${output_file}" <<EOF
            <p><strong>Custom Parameters (${param_count} modified):</strong></p>
            <table style="margin-top: 10px;">
                <tr>
                    <th>Parameter Name</th>
                    <th>Value</th>
                    <th>Apply Type</th>
                    <th>Modifiable</th>
                </tr>
EOF
            
            for i in $(seq 0 $((param_count - 1))); do
                local param_name
                param_name=$(echo "$param_details" | jq -r ".[$i][0]")
                local param_value
                param_value=$(echo "$param_details" | jq -r ".[$i][1] // \"N/A\"")
                local apply_type
                apply_type=$(echo "$param_details" | jq -r ".[$i][2]")
                local is_modifiable
                is_modifiable=$(echo "$param_details" | jq -r ".[$i][3]")                
                cat >> "${output_file}" <<EOF
                <tr>
                    <td>${param_name}</td>
                    <td>${param_value}</td>
                    <td>${apply_type}</td>
                    <td>${is_modifiable}</td>
                </tr>
EOF
            done
            
            cat >> "${output_file}" <<EOF
            </table>
EOF
        else
            cat >> "${output_file}" <<EOF
            <div class="info">
                <p>No custom parameters set - using default parameter group configuration</p>
            </div>
EOF
        fi
    else
        cat >> "${output_file}" <<EOF
            <div class="warning">
                <p>Unable to retrieve parameter group details</p>
            </div>
EOF
    fi
    
    cat >> "${output_file}" <<EOF
        </div>
EOF
    
    # Add Option Group Details
    echo "Fetching option group details..."
    local option_group
    option_group=$(echo "$rds_info" | jq -r '.DBInstances[0].OptionGroupMemberships[0].OptionGroupName')    
    cat >> "${output_file}" <<EOF
        <h3>Option Group Details</h3>
        <button class="collapsible" onclick="toggleCollapsible(this)">View Option Group Configuration ▼</button>
        <div class="collapsible-content">
            <p><strong>Option Group:</strong> ${option_group}</p>
EOF
    
    local option_details
    option_details=$(aws rds describe-option-groups \
        --option-group-name "${option_group}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    
    local _rc=$?
    if [ $_rc -eq 0 ]; then
        local options
        options=$(echo "$option_details" | jq -r '.OptionGroupsList[0].Options')
        local option_count
        option_count=$(echo "$options" | jq -r 'length')        
        if [ "$option_count" -gt 0 ]; then
            cat >> "${output_file}" <<EOF
            <table style="margin-top: 10px;">
                <tr>
                    <th>Option Name</th>
                    <th>Description</th>
                    <th>Persistent</th>
                    <th>Permanent</th>
                </tr>
EOF
            
            for i in $(seq 0 $((option_count - 1))); do
                local option_name
                option_name=$(echo "$options" | jq -r ".[$i].OptionName")
                local option_desc
                option_desc=$(echo "$options" | jq -r ".[$i].OptionDescription // \"N/A\"")
                local persistent
                persistent=$(echo "$options" | jq -r ".[$i].Persistent")
                local permanent
                permanent=$(echo "$options" | jq -r ".[$i].Permanent")                
                cat >> "${output_file}" <<EOF
                <tr>
                    <td>${option_name}</td>
                    <td>${option_desc}</td>
                    <td>${persistent}</td>
                    <td>${permanent}</td>
                </tr>
EOF
            done
            
            cat >> "${output_file}" <<EOF
            </table>
EOF
        else
            cat >> "${output_file}" <<EOF
            <div class="info">
                <p>No options configured in this option group</p>
            </div>
EOF
        fi
    else
        cat >> "${output_file}" <<EOF
            <div class="warning">
                <p>Unable to retrieve option group details</p>
            </div>
EOF
    fi
    
    cat >> "${output_file}" <<EOF
        </div>
EOF
}

################################################################################
# Function: add_aurora_config
# Description: Adds Aurora PostgreSQL configuration details to HTML report
# Handles: Aurora Provisioned, Serverless v1, and Serverless v2
################################################################################
add_aurora_config() {
    local output_file=$1
    
    echo "Fetching Aurora PostgreSQL configuration..."
    
    # Get cluster information
    local cluster_info
    cluster_info=$(aws rds describe-db-clusters \
        --db-cluster-identifier "${CLUSTER_IDENTIFIER}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    
    local _rc=$?
    if [ $_rc -ne 0 ] || ! echo "$cluster_info" | jq empty 2>/dev/null; then
        echo -e "${RED}✗ Failed to retrieve Aurora cluster information${NC}"
        echo "Error: $cluster_info"
        cat >> "${output_file}" <<EOF
        <h2>Aurora Configuration</h2>
        <div class="error">
            <p><strong>Error:</strong> Failed to retrieve Aurora cluster information</p>
            <pre>$cluster_info</pre>
        </div>
EOF
        return 1
    fi
    
    # Get instance information (if not serverless v1)
    local instance_info=""
    local instance_info_success=false
    local actual_instance_id="${DB_IDENTIFIER}"
    
    if [ "$IS_AURORA_SERVERLESS" != "v1" ]; then
        # First, try to get cluster members to find the writer instance
        local cluster_members
        cluster_members=$(echo "$cluster_info" | jq -r '.DBClusters[0].DBClusterMembers // []' 2>/dev/null || echo "[]")
        local writer_instance
        writer_instance=$(echo "$cluster_members" | jq -r '.[] | select(.IsClusterWriter == true) | .DBInstanceIdentifier' 2>/dev/null | head -1)        
        # If we found a writer instance, use that; otherwise try the DB_IDENTIFIER
        if [ -n "$writer_instance" ] && [ "$writer_instance" != "null" ]; then
            actual_instance_id="$writer_instance"
            echo "  Using writer instance: ${actual_instance_id}"
        fi
        
        instance_info=$(aws rds describe-db-instances \
            --db-instance-identifier "${actual_instance_id}" \
            --region "${AWS_REGION}" \
            --profile "${AWS_PROFILE}" \
            --output json 2>&1)
        
        local _rc=$?
        if [ $_rc -eq 0 ] && echo "$instance_info" | jq empty 2>/dev/null; then
            instance_info_success=true
        else
            echo -e "${YELLOW}⚠ Warning: Could not retrieve instance information for ${actual_instance_id}${NC}"
        fi
    fi
    
    # Extract cluster details with safe defaults
    local engine
    engine=$(echo "$cluster_info" | jq -r '.DBClusters[0].Engine // "N/A"' 2>/dev/null || echo "N/A")
    local engine_version
    engine_version=$(echo "$cluster_info" | jq -r '.DBClusters[0].EngineVersion // "N/A"' 2>/dev/null || echo "N/A")
    local engine_mode
    engine_mode=$(echo "$cluster_info" | jq -r '.DBClusters[0].EngineMode // "provisioned"' 2>/dev/null || echo "provisioned")
    local cluster_endpoint
    cluster_endpoint=$(echo "$cluster_info" | jq -r '.DBClusters[0].Endpoint // "N/A"' 2>/dev/null || echo "N/A")
    local reader_endpoint
    reader_endpoint=$(echo "$cluster_info" | jq -r '.DBClusters[0].ReaderEndpoint // "N/A"' 2>/dev/null || echo "N/A")
    local port
    port=$(echo "$cluster_info" | jq -r '.DBClusters[0].Port // "5432"' 2>/dev/null || echo "5432")
    local multi_az
    multi_az=$(echo "$cluster_info" | jq -r '.DBClusters[0].MultiAZ // "false"' 2>/dev/null || echo "false")
    local storage_encrypted
    storage_encrypted=$(echo "$cluster_info" | jq -r '.DBClusters[0].StorageEncrypted // "false"' 2>/dev/null || echo "false")
    local backup_retention
    backup_retention=$(echo "$cluster_info" | jq -r '.DBClusters[0].BackupRetentionPeriod // "N/A"' 2>/dev/null || echo "N/A")
    local maintenance_window
    maintenance_window=$(echo "$cluster_info" | jq -r '.DBClusters[0].PreferredMaintenanceWindow // "N/A"' 2>/dev/null || echo "N/A")
    local cluster_param_group
    cluster_param_group=$(echo "$cluster_info" | jq -r '.DBClusters[0].DBClusterParameterGroup // "N/A"' 2>/dev/null || echo "N/A")    
    # Get cluster members with safe extraction
    local cluster_members
    cluster_members=$(echo "$cluster_info" | jq -r '.DBClusters[0].DBClusterMembers // []' 2>/dev/null || echo "[]")
    local member_count
    member_count=$(echo "$cluster_members" | jq -r 'length' 2>/dev/null || echo "0")    
    # Capacity information
    local capacity_info=""
    local instance_class="N/A"
    local vcpu_count="N/A"
    local instance_memory_gb="N/A"
    
    if [ "$IS_AURORA_SERVERLESS" == "v2" ]; then
        local min_capacity
        min_capacity=$(echo "$cluster_info" | jq -r '.DBClusters[0].ServerlessV2ScalingConfiguration.MinCapacity // "N/A"' 2>/dev/null || echo "N/A")
        local max_capacity
        max_capacity=$(echo "$cluster_info" | jq -r '.DBClusters[0].ServerlessV2ScalingConfiguration.MaxCapacity // "N/A"' 2>/dev/null || echo "N/A")
        capacity_info="Serverless v2: ${min_capacity} - ${max_capacity} ACU"
        vcpu_count="Dynamic (${min_capacity}-${max_capacity} ACU)"
        instance_memory_gb="Dynamic (${min_capacity}-${max_capacity} ACU × 2 GB)"
    elif [ "$IS_AURORA_SERVERLESS" == "v1" ]; then
        local min_capacity
        min_capacity=$(echo "$cluster_info" | jq -r '.DBClusters[0].ScalingConfigurationInfo.MinCapacity // "N/A"' 2>/dev/null || echo "N/A")
        local max_capacity
        max_capacity=$(echo "$cluster_info" | jq -r '.DBClusters[0].ScalingConfigurationInfo.MaxCapacity // "N/A"' 2>/dev/null || echo "N/A")
        capacity_info="Serverless v1: ${min_capacity} - ${max_capacity} ACU"
        vcpu_count="Dynamic (${min_capacity}-${max_capacity} ACU)"
        instance_memory_gb="Dynamic (${min_capacity}-${max_capacity} ACU × 2 GB)"
    else
        # Provisioned - get instance class from instance info
        if [ "$instance_info_success" = true ]; then
            instance_class=$(echo "$instance_info" | jq -r '.DBInstances[0].DBInstanceClass // "N/A"')
            capacity_info="Provisioned: ${instance_class}"
        else
            instance_class="N/A"
            capacity_info="Provisioned (details unavailable)"
        fi
        
        # Get vCPU and memory from instance class (reuse same logic as RDS)
        case "$instance_class" in
            db.t3.medium) vcpu_count=2; instance_memory_gb=4 ;;
            db.t3.large) vcpu_count=2; instance_memory_gb=8 ;;
            db.t4g.medium) vcpu_count=2; instance_memory_gb=4 ;;
            db.t4g.large) vcpu_count=2; instance_memory_gb=8 ;;
            db.r5.large) vcpu_count=2; instance_memory_gb=16 ;;
            db.r5.xlarge) vcpu_count=4; instance_memory_gb=32 ;;
            db.r5.2xlarge) vcpu_count=8; instance_memory_gb=64 ;;
            db.r5.4xlarge) vcpu_count=16; instance_memory_gb=128 ;;
            db.r5.8xlarge) vcpu_count=32; instance_memory_gb=256 ;;
            db.r5.12xlarge) vcpu_count=48; instance_memory_gb=384 ;;
            db.r5.16xlarge) vcpu_count=64; instance_memory_gb=512 ;;
            db.r6g.large) vcpu_count=2; instance_memory_gb=16 ;;
            db.r6g.xlarge) vcpu_count=4; instance_memory_gb=32 ;;
            db.r6g.2xlarge) vcpu_count=8; instance_memory_gb=64 ;;
            db.r6g.4xlarge) vcpu_count=16; instance_memory_gb=128 ;;
            db.r6g.8xlarge) vcpu_count=32; instance_memory_gb=256 ;;
            db.r6g.12xlarge) vcpu_count=48; instance_memory_gb=384 ;;
            db.r6g.16xlarge) vcpu_count=64; instance_memory_gb=512 ;;
            *) vcpu_count=2; instance_memory_gb=16 ;;
        esac
    fi
    
    cat >> "${output_file}" <<EOF
        <h2>Aurora PostgreSQL Configuration Details</h2>
        <div class="config-grid">
            <div class="config-item">
                <div class="config-label">Cluster Identifier</div>
                <div class="config-value">${CLUSTER_IDENTIFIER}</div>
            </div>
            <div class="config-item">
                <div class="config-label">AWS Region</div>
                <div class="config-value">${AWS_REGION}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Engine Mode</div>
                <div class="config-value">${capacity_info}</div>
            </div>
            <div class="config-item">
                <div class="config-label">vCPU Count</div>
                <div class="config-value">${vcpu_count}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Memory</div>
                <div class="config-value">${instance_memory_gb}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Engine</div>
                <div class="config-value">${engine}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Engine Version</div>
                <div class="config-value">${engine_version}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Cluster Endpoint</div>
                <div class="config-value">${cluster_endpoint}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Reader Endpoint</div>
                <div class="config-value">${reader_endpoint}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Port</div>
                <div class="config-value">${port}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Multi-AZ</div>
                <div class="config-value">${multi_az}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Storage Encrypted</div>
                <div class="config-value">${storage_encrypted}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Backup Retention</div>
                <div class="config-value">${backup_retention} days</div>
            </div>
            <div class="config-item">
                <div class="config-label">Maintenance Window</div>
                <div class="config-value">${maintenance_window}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Cluster Parameter Group</div>
                <div class="config-value">${cluster_param_group}</div>
            </div>
            <div class="config-item">
                <div class="config-label">Cluster Members</div>
                <div class="config-value">${member_count}</div>
            </div>
        </div>
        
        <h3>Cluster Members</h3>
EOF
    
    if [ "$member_count" -gt 0 ]; then
        cat >> "${output_file}" <<EOF
        <table>
            <tr>
                <th>Instance Identifier</th>
                <th>Role</th>
                <th>Instance Class</th>
                <th>Availability Zone</th>
                <th>Instance Parameter Group</th>
                <th>Param Group Status</th>
            </tr>
EOF
        
        for i in $(seq 0 $((member_count - 1))); do
            local member_id
            member_id=$(echo "$cluster_members" | jq -r ".[$i].DBInstanceIdentifier")
            local is_writer
            is_writer=$(echo "$cluster_members" | jq -r ".[$i].IsClusterWriter")
            local role="Reader"
            if [ "$is_writer" == "true" ]; then
                role="Writer"
            fi
            
            # Get instance details for each member (skip for serverless v1)
            if [ "$IS_AURORA_SERVERLESS" != "v1" ]; then
                local member_info
                member_info=$(aws rds describe-db-instances \
                    --db-instance-identifier "${member_id}" \
                    --region "${AWS_REGION}" \
                    --profile "${AWS_PROFILE}" \
                    --output json 2>&1)
                
                local _rc=$?
                if [ $_rc -eq 0 ] && echo "$member_info" | jq empty 2>/dev/null; then
                    local member_class
                    member_class=$(echo "$member_info" | jq -r '.DBInstances[0].DBInstanceClass' 2>/dev/null || echo "N/A")
                    local member_az
                    member_az=$(echo "$member_info" | jq -r '.DBInstances[0].AvailabilityZone' 2>/dev/null || echo "N/A")
                    local member_param_group
                    member_param_group=$(echo "$member_info" | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName' 2>/dev/null || echo "N/A")
                    local member_param_status
                    member_param_status=$(echo "$member_info" | jq -r '.DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' 2>/dev/null || echo "N/A")                    
                    cat >> "${output_file}" <<EOF
            <tr>
                <td>${member_id}</td>
                <td>${role}</td>
                <td>${member_class}</td>
                <td>${member_az}</td>
                <td>${member_param_group}</td>
                <td>${member_param_status}</td>
            </tr>
EOF
                else
                    cat >> "${output_file}" <<EOF
            <tr>
                <td>${member_id}</td>
                <td>${role}</td>
                <td colspan="4">Unable to retrieve</td>
            </tr>
EOF
                fi
            else
                cat >> "${output_file}" <<EOF
            <tr>
                <td>${member_id}</td>
                <td>${role}</td>
                <td>Serverless v1</td>
                <td colspan="3">N/A</td>
            </tr>
EOF
            fi
        done
        
        cat >> "${output_file}" <<EOF
        </table>
EOF
    else
        cat >> "${output_file}" <<EOF
        <div class="info">
            <p><strong>No cluster members found</strong></p>
        </div>
EOF
    fi
    
    # Add Cluster Parameter Group Details
    echo "Fetching cluster parameter group details..."
    
    # Get cluster parameter group status from cluster info
    local cluster_param_group_status
    cluster_param_group_status=$(echo "$cluster_info" | jq -r '.DBClusters[0].DBClusterParameterGroup // "N/A"' 2>/dev/null || echo "N/A")    # Note: Cluster parameter groups don't have a direct status field like instance parameter groups
    # The status is implicitly "in-sync" unless there are pending modifications
    local pending_mods
    pending_mods=$(echo "$cluster_info" | jq -r '.DBClusters[0].PendingModifiedValues | length' 2>/dev/null || echo "0")
    if [ "$pending_mods" -gt 0 ]; then
        cluster_param_group_status="pending-reboot"
    else
        cluster_param_group_status="in-sync"
    fi
    
    cat >> "${output_file}" <<EOF
        <h3>Cluster Parameter Group Details</h3>
        <button class="collapsible" onclick="toggleCollapsible(this)">View Cluster Parameter Group Configuration ▼</button>
        <div class="collapsible-content">
            <p><strong>Cluster Parameter Group:</strong> ${cluster_param_group}</p>
            <p><strong>Status:</strong> ${cluster_param_group_status}</p>
EOF
    
    local param_details
    # shellcheck disable=SC2016
    param_details=$(aws rds describe-db-cluster-parameters \
        --db-cluster-parameter-group-name "${cluster_param_group}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --query 'Parameters[?Source==`user`].[ParameterName,ParameterValue,ApplyType,IsModifiable]' \
        --output json 2>&1)
    
    local _rc=$?
    if [ $_rc -eq 0 ] && echo "$param_details" | jq empty 2>/dev/null; then
        local param_count
        param_count=$(echo "$param_details" | jq -r 'length' 2>/dev/null || echo "0")        
        if [ "$param_count" -gt 0 ]; then
            cat >> "${output_file}" <<EOF
            <p><strong>Custom Parameters (${param_count} modified):</strong></p>
            <table style="margin-top: 10px;">
                <tr>
                    <th>Parameter Name</th>
                    <th>Value</th>
                    <th>Apply Type</th>
                    <th>Modifiable</th>
                </tr>
EOF
            
            for i in $(seq 0 $((param_count - 1))); do
                local param_name
                param_name=$(echo "$param_details" | jq -r ".[$i][0]")
                local param_value
                param_value=$(echo "$param_details" | jq -r ".[$i][1] // \"N/A\"")
                local apply_type
                apply_type=$(echo "$param_details" | jq -r ".[$i][2]")
                local is_modifiable
                is_modifiable=$(echo "$param_details" | jq -r ".[$i][3]")                
                cat >> "${output_file}" <<EOF
                <tr>
                    <td>${param_name}</td>
                    <td>${param_value}</td>
                    <td>${apply_type}</td>
                    <td>${is_modifiable}</td>
                </tr>
EOF
            done
            
            cat >> "${output_file}" <<EOF
            </table>
EOF
        else
            cat >> "${output_file}" <<EOF
            <div class="info">
                <p>No custom parameters set - using default cluster parameter group configuration</p>
            </div>
EOF
        fi
    else
        cat >> "${output_file}" <<EOF
            <div class="warning">
                <p>Unable to retrieve cluster parameter group details</p>
            </div>
EOF
    fi
    
    cat >> "${output_file}" <<EOF
        </div>
EOF
    
    # Add Instance Parameter Group Details (for provisioned Aurora)
    if [ "$IS_AURORA_SERVERLESS" != "v1" ]; then
        echo "Fetching instance parameter group details..."
        
        # Iterate through cluster members to get their parameter groups
        local has_custom_params=false
        local instance_param_html=""
        
        for i in $(seq 0 $((member_count - 1))); do
            local member_id
            member_id=$(echo "$cluster_members" | jq -r ".[$i].DBInstanceIdentifier")
            local is_writer
            is_writer=$(echo "$cluster_members" | jq -r ".[$i].IsClusterWriter")
            local role="Reader"
            if [ "$is_writer" == "true" ]; then
                role="Writer"
            fi
            
            # Get instance parameter group details
            local member_info
            member_info=$(aws rds describe-db-instances \
                --db-instance-identifier "${member_id}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --output json 2>&1)
            
            local _rc=$?
            if [ $_rc -eq 0 ] && echo "$member_info" | jq empty 2>/dev/null; then
                local member_param_group
                member_param_group=$(echo "$member_info" | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName' 2>/dev/null || echo "N/A")
                local member_param_status
                member_param_status=$(echo "$member_info" | jq -r '.DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' 2>/dev/null || echo "N/A")                
                # Skip default parameter groups
                if [[ "$member_param_group" == *"default"* ]] || [ "$member_param_group" == "N/A" ]; then
                    continue
                fi
                
                has_custom_params=true
                
                # Get custom parameters for this instance
                local instance_param_details
                # shellcheck disable=SC2016
                instance_param_details=$(aws rds describe-db-parameters \
                    --db-parameter-group-name "${member_param_group}" \
                    --region "${AWS_REGION}" \
                    --profile "${AWS_PROFILE}" \
                    --query 'Parameters[?Source==`user`].[ParameterName,ParameterValue,ApplyType,IsModifiable]' \
                    --output json 2>&1)
                
                local _rc=$?
                if [ $_rc -eq 0 ] && echo "$instance_param_details" | jq empty 2>/dev/null; then
                    local instance_param_count
                    instance_param_count=$(echo "$instance_param_details" | jq -r 'length' 2>/dev/null || echo "0")                    
                    instance_param_html="${instance_param_html}<button class=\"collapsible\" onclick=\"toggleCollapsible(this)\">Instance: ${member_id} (${role}) - ${member_param_group} [${member_param_status}] ▼</button>"
                    instance_param_html="${instance_param_html}<div class=\"collapsible-content\">"
                    
                    if [ "$instance_param_count" -gt 0 ]; then
                        instance_param_html="${instance_param_html}<p><strong>Custom Parameters (${instance_param_count} modified):</strong></p>"
                        instance_param_html="${instance_param_html}<table style=\"margin-top: 10px;\"><tr><th>Parameter Name</th><th>Value</th><th>Apply Type</th><th>Modifiable</th></tr>"
                        
                        for j in $(seq 0 $((instance_param_count - 1))); do
                            local param_name
                            param_name=$(echo "$instance_param_details" | jq -r ".[$j][0]")
                            local param_value
                            param_value=$(echo "$instance_param_details" | jq -r ".[$j][1] // \"N/A\"")
                            local apply_type
                            apply_type=$(echo "$instance_param_details" | jq -r ".[$j][2]")
                            local is_modifiable
                            is_modifiable=$(echo "$instance_param_details" | jq -r ".[$j][3]")                            
                            instance_param_html="${instance_param_html}<tr><td>${param_name}</td><td>${param_value}</td><td>${apply_type}</td><td>${is_modifiable}</td></tr>"
                        done
                        
                        instance_param_html="${instance_param_html}</table>"
                    else
                        instance_param_html="${instance_param_html}<div class=\"info\"><p>No custom parameters set - using default parameter group configuration</p></div>"
                    fi
                    
                    instance_param_html="${instance_param_html}</div>"
                fi
            fi
        done
        
        # Only add the section if we found custom parameter groups
        if [ "$has_custom_params" = true ]; then
            cat >> "${output_file}" <<EOF
        <h3>Instance Parameter Group Details</h3>
        <div style="margin-top: 10px;">
            ${instance_param_html}
        </div>
EOF
        fi
    fi
    
    # Add Instance-Level Option Groups (for provisioned Aurora)
    if [ "$IS_AURORA_SERVERLESS" == "false" ] && [ "$instance_info_success" = true ]; then
        echo "Fetching instance option group details..."
        local option_group
        option_group=$(echo "$instance_info" | jq -r '.DBInstances[0].OptionGroupMemberships[0].OptionGroupName // "N/A"' 2>/dev/null || echo "N/A")        
        cat >> "${output_file}" <<EOF
        <h3>Instance Option Group Details</h3>
        <button class="collapsible" onclick="toggleCollapsible(this)">View Instance Option Group Configuration ▼</button>
        <div class="collapsible-content">
            <p><strong>Option Group:</strong> ${option_group}</p>
EOF
        
        if [ "$option_group" != "N/A" ] && [ "$option_group" != "null" ]; then
            local option_details
            option_details=$(aws rds describe-option-groups \
                --option-group-name "${option_group}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --output json 2>&1)
            
            local _rc=$?
            if [ $_rc -eq 0 ] && echo "$option_details" | jq empty 2>/dev/null; then
                local options
                options=$(echo "$option_details" | jq -r '.OptionGroupsList[0].Options // []' 2>/dev/null || echo "[]")
                local option_count
                option_count=$(echo "$options" | jq -r 'length' 2>/dev/null || echo "0")                
                if [ "$option_count" -gt 0 ]; then
                    cat >> "${output_file}" <<EOF
            <table style="margin-top: 10px;">
                <tr>
                    <th>Option Name</th>
                    <th>Description</th>
                    <th>Persistent</th>
                    <th>Permanent</th>
                </tr>
EOF
                    
                    for i in $(seq 0 $((option_count - 1))); do
                        local option_name
                        option_name=$(echo "$options" | jq -r ".[$i].OptionName" 2>/dev/null || echo "N/A")
                        local option_desc
                        option_desc=$(echo "$options" | jq -r ".[$i].OptionDescription // \"N/A\"" 2>/dev/null || echo "N/A")
                        local persistent
                        persistent=$(echo "$options" | jq -r ".[$i].Persistent" 2>/dev/null || echo "N/A")
                        local permanent
                        permanent=$(echo "$options" | jq -r ".[$i].Permanent" 2>/dev/null || echo "N/A")                        
                        cat >> "${output_file}" <<EOF
                <tr>
                    <td>${option_name}</td>
                    <td>${option_desc}</td>
                    <td>${persistent}</td>
                    <td>${permanent}</td>
                </tr>
EOF
                    done
                    
                    cat >> "${output_file}" <<EOF
            </table>
EOF
                else
                    cat >> "${output_file}" <<EOF
            <div class="info">
                <p>No options configured in this option group</p>
            </div>
EOF
                fi
            else
                cat >> "${output_file}" <<EOF
            <div class="warning">
                <p>Unable to retrieve option group details</p>
            </div>
EOF
            fi
        else
            cat >> "${output_file}" <<EOF
            <div class="info">
                <p>No option group configured</p>
            </div>
EOF
        fi
        
        cat >> "${output_file}" <<EOF
        </div>
EOF
    fi
    
    # Check for pending maintenance at cluster level
    echo "Checking for pending maintenance..."
    local maintenance_actions
    maintenance_actions=$(aws rds describe-pending-maintenance-actions \
        --resource-identifier "arn:aws:rds:${AWS_REGION}:$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --query Account --output text 2>/dev/null):cluster:${CLUSTER_IDENTIFIER}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    
    local has_pending=false
    local pending_html=""
    
    # Check PendingMaintenanceActions
    local _rc=$?
    if [ $_rc -eq 0 ] && echo "$maintenance_actions" | jq empty 2>/dev/null; then
        local action_count
        action_count=$(echo "$maintenance_actions" | jq -r '.PendingMaintenanceActions[0].PendingMaintenanceActionDetails | length' 2>/dev/null || echo "0")        
        if [ "$action_count" -gt 0 ]; then
            has_pending=true
            pending_html="${pending_html}<h4>Pending Maintenance Actions</h4><table><tr><th>Action</th><th>Description</th><th>Auto Applied After</th><th>Current Apply Date</th></tr>"
            
            for i in $(seq 0 $((action_count - 1))); do
                local action
                action=$(echo "$maintenance_actions" | jq -r ".PendingMaintenanceActions[0].PendingMaintenanceActionDetails[$i].Action" 2>/dev/null || echo "N/A")
                local description
                description=$(echo "$maintenance_actions" | jq -r ".PendingMaintenanceActions[0].PendingMaintenanceActionDetails[$i].Description // \"N/A\"" 2>/dev/null || echo "N/A")
                local auto_applied_after
                auto_applied_after=$(echo "$maintenance_actions" | jq -r ".PendingMaintenanceActions[0].PendingMaintenanceActionDetails[$i].AutoAppliedAfterDate // \"N/A\"" 2>/dev/null || echo "N/A")
                local current_apply_date
                current_apply_date=$(echo "$maintenance_actions" | jq -r ".PendingMaintenanceActions[0].PendingMaintenanceActionDetails[$i].CurrentApplyDate // \"N/A\"" 2>/dev/null || echo "N/A")                
                pending_html="${pending_html}<tr><td>${action}</td><td>${description}</td><td>${auto_applied_after}</td><td>${current_apply_date}</td></tr>"
            done
            
            pending_html="${pending_html}</table>"
        fi
    fi
    
    if [ "$has_pending" = true ]; then
        cat >> "${output_file}" <<EOF
        <h3>Pending Maintenance</h3>
        <div class="warning">
            <p><strong>⚠️ There are pending maintenance actions</strong></p>
            ${pending_html}
        </div>
EOF
    else
        cat >> "${output_file}" <<EOF
        <h3>Pending Maintenance</h3>
        <div class="success">
            <p><strong>✓ No pending maintenance actions</strong></p>
        </div>
EOF
    fi
}


################################################################################
# Function: add_memory_storage_status
# Description: Adds resource status cards with CloudWatch metrics
# Parameters:
#   $1 - output_file: Path to HTML report
# Metrics Displayed:
#   - CPU Utilization (average and max with progress bar)
#   - Database Connections (average and max)
#   - Memory Status (free memory percentage)
#   - Storage Status (free storage percentage)
# Data Collection Strategy:
#   1. Tests for 15-day data availability (requires ≥10 datapoints)
#   2. If available: Uses 15-day range with 1-hour (3600s) period
#   3. If not: Falls back to 2-hour range with 5-minute (300s) period
# Calculation Logic:
#   - Attempts to use CloudWatch Average statistic
#   - Falls back to averaging Maximum values if Average unavailable
#   - This occurs when Enhanced Monitoring is not enabled
# Status Thresholds:
#   - CPU: WARNING >70%, CRITICAL >90%
#   - Memory: WARNING <20%, CRITICAL <5%
#   - Storage: WARNING <20%, CRITICAL <5%
# Instance Specs:
#   - Uses accurate vCPU and memory mapping for all RDS instance types
#   - Displays vCPU count and total memory (GB) from instance class
################################################################################
add_memory_storage_status() {
    local output_file=$1
    
    echo "Fetching memory and storage status..."
    
    # Get instance details based on engine type
    local rds_info
    local instance_class
    local allocated_storage
    local is_aurora=false
    
    if [ "$ENGINE_TYPE" == "aurora-postgresql" ]; then
        is_aurora=true
        
        # For Aurora, we need to get instance details differently
        if [ "$IS_AURORA_SERVERLESS" == "v1" ]; then
            # Serverless v1 has limited metrics
            instance_class="Serverless v1"
            allocated_storage="N/A"
        elif [ "$IS_AURORA_SERVERLESS" == "v2" ]; then
            # Serverless v2 - get instance details
            # First try to get the writer instance from cluster
            local cluster_info
            cluster_info=$(aws rds describe-db-clusters \
                --db-cluster-identifier "${CLUSTER_IDENTIFIER}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --output json 2>/dev/null)
            
            local actual_instance_id="${DB_IDENTIFIER}"
            local _rc=$?
            if [ $_rc -eq 0 ] && echo "$cluster_info" | jq empty 2>/dev/null; then
                local writer_instance
                writer_instance=$(echo "$cluster_info" | jq -r '.DBClusters[0].DBClusterMembers[] | select(.IsClusterWriter == true) | .DBInstanceIdentifier' 2>/dev/null | head -1)
                if [ -n "$writer_instance" ] && [ "$writer_instance" != "null" ]; then
                    actual_instance_id="$writer_instance"
                fi
            fi
            
            rds_info=$(aws rds describe-db-instances \
                --db-instance-identifier "${actual_instance_id}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --output json 2>&1)
            
            local _rc=$?
            if [ $_rc -ne 0 ]; then
                cat >> "${output_file}" <<EOF
        <h2>Resource Status</h2>
        <div class="error">
            <p><strong>Error:</strong> Failed to retrieve resource status</p>
        </div>
EOF
                return 1
            fi
            
            instance_class="Serverless v2"
            allocated_storage="N/A"
        else
            # Aurora Provisioned - get instance details
            # First try to get the writer instance from cluster
            local cluster_info
            cluster_info=$(aws rds describe-db-clusters \
                --db-cluster-identifier "${CLUSTER_IDENTIFIER}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --output json 2>/dev/null)
            
            local actual_instance_id="${DB_IDENTIFIER}"
            local _rc=$?
            if [ $_rc -eq 0 ] && echo "$cluster_info" | jq empty 2>/dev/null; then
                local writer_instance
                writer_instance=$(echo "$cluster_info" | jq -r '.DBClusters[0].DBClusterMembers[] | select(.IsClusterWriter == true) | .DBInstanceIdentifier' 2>/dev/null | head -1)
                if [ -n "$writer_instance" ] && [ "$writer_instance" != "null" ]; then
                    actual_instance_id="$writer_instance"
                fi
            fi
            
            rds_info=$(aws rds describe-db-instances \
                --db-instance-identifier "${actual_instance_id}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --output json 2>&1)
            
            local _rc=$?
            if [ $_rc -ne 0 ]; then
                cat >> "${output_file}" <<EOF
        <h2>Resource Status</h2>
        <div class="error">
            <p><strong>Error:</strong> Failed to retrieve resource status</p>
        </div>
EOF
                return 1
            fi
            
            instance_class=$(echo "$rds_info" | jq -r '.DBInstances[0].DBInstanceClass // "N/A"')
            # Aurora doesn't have AllocatedStorage at instance level
            allocated_storage="N/A"
        fi
    else
        # RDS PostgreSQL
        rds_info=$(aws rds describe-db-instances \
            --db-instance-identifier "${DB_IDENTIFIER}" \
            --region "${AWS_REGION}" \
            --profile "${AWS_PROFILE}" \
            --output json 2>&1)
        
        local _rc=$?
        if [ $_rc -ne 0 ]; then
            cat >> "${output_file}" <<EOF
        <h2>Resource Status</h2>
        <div class="error">
            <p><strong>Error:</strong> Failed to retrieve resource status</p>
        </div>
EOF
            return 1
        fi
        
        instance_class=$(echo "$rds_info" | jq -r '.DBInstances[0].DBInstanceClass')
        allocated_storage=$(echo "$rds_info" | jq -r '.DBInstances[0].AllocatedStorage')
    fi
    
    # Calculate time range with fallback logic
    local end_time
    end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time_15d
    start_time_15d=$(date -u -v-15d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '15 days ago' +"%Y-%m-%dT%H:%M:%SZ")
    local start_time_2h
    start_time_2h=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '2 hours ago' +"%Y-%m-%dT%H:%M:%SZ")    
    # Check if we have 15-day data available
    local test_metric_data
    test_metric_data=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name "CPUUtilization" \
        --dimensions Name=DBInstanceIdentifier,Value="${DB_IDENTIFIER}" \
        --start-time "${start_time_15d}" \
        --end-time "${end_time}" \
        --period 86400 \
        --statistics Average \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    
    local test_count
    test_count=$(echo "$test_metric_data" | jq -r '.Datapoints | length' 2>/dev/null || echo "0")    
    # Set time range and period based on data availability
    # Require at least 10 datapoints for 15-day range to ensure meaningful averages
    local start_time
    local period
    if [ "$test_count" -ge 10 ]; then
        start_time="${start_time_15d}"
        period=3600
    else
        start_time="${start_time_2h}"
        period=300
    fi
    
    # Get FreeableMemory average
    local memory_data
    memory_data=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name "FreeableMemory" \
        --dimensions Name=DBInstanceIdentifier,Value="${DB_IDENTIFIER}" \
        --start-time "${start_time}" \
        --end-time "${end_time}" \
        --period ${period} \
        --statistics Average \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    local memory_exit_code=$?
    
    local avg_freeable_memory=0
    if [ $memory_exit_code -eq 0 ]; then
        avg_freeable_memory=$(echo "$memory_data" | jq -r '[.Datapoints[].Average] | add / length' 2>/dev/null || echo "0")
    fi
    
    # Get storage metrics based on engine type
    local storage_data
    local avg_free_storage=0
    local avg_volume_bytes_used=0
    
    if [ "$is_aurora" = true ]; then
        # For Aurora, use VolumeBytesUsed metric
        storage_data=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/RDS \
            --metric-name "VolumeBytesUsed" \
            --dimensions Name=DBClusterIdentifier,Value="${CLUSTER_IDENTIFIER}" \
            --start-time "${start_time}" \
            --end-time "${end_time}" \
            --period ${period} \
            --statistics Average \
            --region "${AWS_REGION}" \
            --profile "${AWS_PROFILE}" \
            --output json 2>&1)
        local storage_exit_code=$?
        
        if [ $storage_exit_code -eq 0 ]; then
            avg_volume_bytes_used=$(echo "$storage_data" | jq -r '[.Datapoints[].Average] | add / length' 2>/dev/null || echo "0")
        fi
    else
        # For RDS PostgreSQL, use FreeStorageSpace
        storage_data=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/RDS \
            --metric-name "FreeStorageSpace" \
            --dimensions Name=DBInstanceIdentifier,Value="${DB_IDENTIFIER}" \
            --start-time "${start_time}" \
            --end-time "${end_time}" \
            --period ${period} \
            --statistics Average \
            --region "${AWS_REGION}" \
            --profile "${AWS_PROFILE}" \
            --output json 2>&1)
        local storage_exit_code=$?
        
        if [ $storage_exit_code -eq 0 ]; then
            avg_free_storage=$(echo "$storage_data" | jq -r '[.Datapoints[].Average] | add / length' 2>/dev/null || echo "0")
        fi
    fi
    
    # Get ACU utilization for Aurora Serverless
    local avg_acu=0
    local max_acu=0
    local min_acu=0
    local max_capacity=0
    
    if [ "$is_aurora" = true ] && [ "$IS_AURORA_SERVERLESS" != "false" ]; then
        # Get ServerlessDatabaseCapacity metric for serverless
        local acu_data
        acu_data=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/RDS \
            --metric-name "ServerlessDatabaseCapacity" \
            --dimensions Name=DBClusterIdentifier,Value="${CLUSTER_IDENTIFIER}" \
            --start-time "${start_time}" \
            --end-time "${end_time}" \
            --period ${period} \
            --statistics Average Maximum Minimum \
            --region "${AWS_REGION}" \
            --profile "${AWS_PROFILE}" \
            --output json 2>&1)
        local acu_exit_code=$?
        
        if [ $acu_exit_code -eq 0 ]; then
            avg_acu=$(echo "$acu_data" | jq -r '[.Datapoints[].Average] | map(select(. != null)) | if length > 0 then add / length else 0 end' 2>/dev/null || echo "0")
            max_acu=$(echo "$acu_data" | jq -r '[.Datapoints[].Maximum] | max' 2>/dev/null || echo "0")
            min_acu=$(echo "$acu_data" | jq -r '[.Datapoints[].Minimum] | min' 2>/dev/null || echo "0")
        fi
        
        # Get max capacity from cluster info
        local cluster_info
        cluster_info=$(aws rds describe-db-clusters \
            --db-cluster-identifier "${CLUSTER_IDENTIFIER}" \
            --region "${AWS_REGION}" \
            --profile "${AWS_PROFILE}" \
            --output json 2>/dev/null)
        
        local _rc=$?
        if [ $_rc -eq 0 ]; then
            if [ "$IS_AURORA_SERVERLESS" == "v2" ]; then
                max_capacity=$(echo "$cluster_info" | jq -r '.DBClusters[0].ServerlessV2ScalingConfiguration.MaxCapacity // "0"')
            elif [ "$IS_AURORA_SERVERLESS" == "v1" ]; then
                max_capacity=$(echo "$cluster_info" | jq -r '.DBClusters[0].ScalingConfigurationInfo.MaxCapacity // "0"')
            fi
        fi
    fi
    
    # Get CPUUtilization average and max
    local cpu_data
    cpu_data=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name "CPUUtilization" \
        --dimensions Name=DBInstanceIdentifier,Value="${DB_IDENTIFIER}" \
        --start-time "${start_time}" \
        --end-time "${end_time}" \
        --period ${period} \
        --statistics Average --statistics Maximum \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    local cpu_exit_code=$?
    
    local avg_cpu=0
    local max_cpu=0
    if [ $cpu_exit_code -eq 0 ]; then
        # Try to get Average first
        avg_cpu=$(echo "$cpu_data" | jq -r '[.Datapoints[].Average] | map(select(. != null)) | if length > 0 then add / length else null end' 2>/dev/null)
        # If no Average data, fall back to Maximum average
        if [ -z "$avg_cpu" ] || [ "$avg_cpu" = "null" ]; then
            avg_cpu=$(echo "$cpu_data" | jq -r '[.Datapoints[].Maximum] | map(select(. != null)) | if length > 0 then add / length else 0 end' 2>/dev/null)
        fi
        # Handle null or empty values
        if [ -z "$avg_cpu" ] || [ "$avg_cpu" = "null" ]; then
            avg_cpu=0
        fi
        max_cpu=$(echo "$cpu_data" | jq -r '[.Datapoints[].Maximum] | max' 2>/dev/null)
        if [ -z "$max_cpu" ] || [ "$max_cpu" = "null" ]; then
            max_cpu=0
        fi
    fi
    
    # Get DatabaseConnections average and max
    local conn_data
    conn_data=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name "DatabaseConnections" \
        --dimensions Name=DBInstanceIdentifier,Value="${DB_IDENTIFIER}" \
        --start-time "${start_time}" \
        --end-time "${end_time}" \
        --period ${period} \
        --statistics Average --statistics Maximum \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    local conn_exit_code=$?
    
    local avg_connections=0
    local max_connections=0
    if [ $conn_exit_code -eq 0 ]; then
        # Try to get Average first
        avg_connections=$(echo "$conn_data" | jq -r '[.Datapoints[].Average] | map(select(. != null)) | if length > 0 then add / length else null end' 2>/dev/null)
        # If no Average data, fall back to Maximum average
        if [ -z "$avg_connections" ] || [ "$avg_connections" = "null" ]; then
            avg_connections=$(echo "$conn_data" | jq -r '[.Datapoints[].Maximum] | map(select(. != null)) | if length > 0 then add / length else 0 end' 2>/dev/null)
        fi
        # Handle null or empty values
        if [ -z "$avg_connections" ] || [ "$avg_connections" = "null" ]; then
            avg_connections=0
        fi
        max_connections=$(echo "$conn_data" | jq -r '[.Datapoints[].Maximum] | max' 2>/dev/null)
        if [ -z "$max_connections" ] || [ "$max_connections" = "null" ]; then
            max_connections=0
        fi
    fi
    
    # Get instance specs based on instance class (accurate mapping)
    get_instance_specs "$instance_class"
    local total_memory_gb=$memory_gb
    
    # Convert bytes to GB
    local avg_freeable_memory_gb
    avg_freeable_memory_gb=$(echo "scale=2; $avg_freeable_memory / 1073741824" | bc 2>/dev/null || echo "0")
    local avg_free_storage_gb
    avg_free_storage_gb=$(echo "scale=2; $avg_free_storage / 1073741824" | bc 2>/dev/null || echo "0")
    local avg_volume_bytes_used_gb
    avg_volume_bytes_used_gb=$(echo "scale=2; $avg_volume_bytes_used / 1073741824" | bc 2>/dev/null || echo "0")    
    # Format CPU and connections
    local avg_cpu_formatted
    avg_cpu_formatted=$(printf "%.2f" "$avg_cpu" 2>/dev/null || echo "0.00")
    local max_cpu_formatted
    max_cpu_formatted=$(printf "%.2f" "$max_cpu" 2>/dev/null || echo "0.00")
    local avg_connections_formatted
    avg_connections_formatted=$(printf "%.2f" "$avg_connections" 2>/dev/null || echo "0.00")
    local max_connections_formatted
    max_connections_formatted=$(printf "%.0f" "$max_connections" 2>/dev/null || echo "0")    
    # Format ACU values
    local avg_acu_formatted
    avg_acu_formatted=$(printf "%.2f" "$avg_acu" 2>/dev/null || echo "0.00")
    local max_acu_formatted
    max_acu_formatted=$(printf "%.2f" "$max_acu" 2>/dev/null || echo "0.00")
    local min_acu_formatted
    min_acu_formatted=$(printf "%.2f" "$min_acu" 2>/dev/null || echo "0.00")    
    # Calculate percentages
    local memory_free_percent=0
    if [ "$total_memory_gb" -gt 0 ]; then
        memory_free_percent=$(echo "scale=2; ($avg_freeable_memory_gb / $total_memory_gb) * 100" | bc 2>/dev/null || echo "0")
    fi
    
    local storage_free_percent=0
    
    if [ "$is_aurora" = true ]; then
        # For Aurora, show volume bytes used (no percentage since Aurora auto-scales)
        storage_free_percent=0  # Not applicable for Aurora
    else
        # For RDS, calculate storage percentage
        if [ "$allocated_storage" != "N/A" ] && [ -n "$allocated_storage" ] && [ "$allocated_storage" -gt 0 ] 2>/dev/null; then
            storage_free_percent=$(echo "scale=2; ($avg_free_storage_gb / $allocated_storage) * 100" | bc 2>/dev/null || echo "0")
        fi
    fi
    
    # Calculate ACU utilization percentage for serverless
    local acu_utilization_percent=0
    if [ "$is_aurora" = true ] && [ "$IS_AURORA_SERVERLESS" != "false" ] && [ "$max_capacity" != "0" ] && [ "$max_capacity" != "null" ]; then
        acu_utilization_percent=$(echo "scale=2; ($avg_acu / $max_capacity) * 100" | bc 2>/dev/null || echo "0")
    fi
    
    # Determine memory status
    local memory_status="OK"
    local memory_badge="status-ok"
    if (( $(echo "$memory_free_percent < 5" | bc -l) )); then
        memory_status="CRITICAL"
        memory_badge="status-critical"
    elif (( $(echo "$memory_free_percent < 20" | bc -l) )); then
        memory_status="WARNING"
        memory_badge="status-warning"
    fi
    
    # Determine storage status
    local storage_status="OK"
    local storage_badge="status-ok"
    if [ "$is_aurora" = false ]; then
        # Only check storage status for RDS (not Aurora)
        if (( $(echo "$storage_free_percent < 5" | bc -l) )); then
            storage_status="CRITICAL"
            storage_badge="status-critical"
        elif (( $(echo "$storage_free_percent < 20" | bc -l) )); then
            storage_status="WARNING"
            storage_badge="status-warning"
        fi
    fi
    
    # Determine CPU status (warning if avg > 70%, critical if avg > 90%)
    local cpu_status="OK"
    local cpu_badge="status-ok"
    if (( $(echo "$avg_cpu > 90" | bc -l) )); then
        cpu_status="CRITICAL"
        cpu_badge="status-critical"
    elif (( $(echo "$avg_cpu > 70" | bc -l) )); then
        cpu_status="WARNING"
        cpu_badge="status-warning"
    fi
    
    # Determine ACU status for serverless (warning if > 70%, critical if > 90%)
    local acu_status="OK"
    local acu_badge="status-ok"
    if [ "$is_aurora" = true ] && [ "$IS_AURORA_SERVERLESS" != "false" ]; then
        if (( $(echo "$acu_utilization_percent > 90" | bc -l) )); then
            acu_status="CRITICAL"
            acu_badge="status-critical"
        elif (( $(echo "$acu_utilization_percent > 70" | bc -l) )); then
            acu_status="WARNING"
            acu_badge="status-warning"
        fi
    fi
    
    cat >> "${output_file}" <<EOF
        <h2>Resource Status</h2>
        <div class="card-grid">
EOF

    # CPU Card (skip for Aurora Serverless)
    if [ "$is_aurora" = false ] || [ "$IS_AURORA_SERVERLESS" = "false" ]; then
        cat >> "${output_file}" <<EOF
            <div class="card">
                <div class="card-title">🖥️ CPU Utilization</div>
                <div class="card-value">${avg_cpu_formatted}%</div>
                <span class="status-badge ${cpu_badge}">${cpu_status}</span>
                <div style="margin-top: 10px; font-size: 0.9em; color: #666;">
                    <div>vCPU Count: ${vcpu_count}</div>
                    <div>Max: ${max_cpu_formatted}%</div>
                </div>
                <div class="progress-bar">
                    <div class="progress-fill" style="width: ${avg_cpu_formatted}%"></div>
                    <div class="progress-text">${avg_cpu_formatted}%</div>
                </div>
            </div>
EOF
    fi

    # ACU Card (only for Aurora Serverless)
    if [ "$is_aurora" = true ] && [ "$IS_AURORA_SERVERLESS" != "false" ]; then
        local acu_utilization_formatted
        acu_utilization_formatted=$(printf "%.2f" "$acu_utilization_percent" 2>/dev/null || echo "0.00")
        cat >> "${output_file}" <<EOF
            <div class="card">
                <div class="card-title">⚡ ACU Utilization</div>
                <div class="card-value">${avg_acu_formatted} ACU</div>
                <span class="status-badge ${acu_badge}">${acu_status}</span>
                <div style="margin-top: 10px; font-size: 0.9em; color: #666;">
                    <div>Max Capacity: ${max_capacity} ACU</div>
                    <div>Peak: ${max_acu_formatted} ACU</div>
                    <div>Min: ${min_acu_formatted} ACU</div>
                </div>
                <div class="progress-bar">
                    <div class="progress-fill" style="width: ${acu_utilization_formatted}%"></div>
                    <div class="progress-text">${acu_utilization_formatted}%</div>
                </div>
            </div>
EOF
    fi

    # Connections Card (skip for Aurora Serverless)
    if [ "$is_aurora" = false ] || [ "$IS_AURORA_SERVERLESS" = "false" ]; then
        cat >> "${output_file}" <<EOF
            <div class="card">
                <div class="card-title">🔌 Database Connections</div>
                <div class="card-value">${avg_connections_formatted}</div>
                <span class="status-badge status-ok">OK</span>
                <div style="margin-top: 10px; font-size: 0.9em; color: #666;">
                    <div>Max: ${max_connections_formatted}</div>
                </div>
            </div>
EOF
    fi

    # Memory Card (skip for Aurora Serverless)
    if [ "$is_aurora" = false ] || [ "$IS_AURORA_SERVERLESS" = "false" ]; then
        cat >> "${output_file}" <<EOF
            <div class="card">
                <div class="card-title">💾 Memory Status</div>
                <div class="card-value">${memory_free_percent}%</div>
                <span class="status-badge ${memory_badge}">${memory_status}</span>
                <div style="margin-top: 10px; font-size: 0.9em; color: #666;">
                    <div>Total: ${total_memory_gb} GB</div>
                    <div>Avg Freeable: ${avg_freeable_memory_gb} GB</div>
                </div>
            </div>
EOF
    fi

    # Storage Card (different for Aurora vs RDS)
    if [ "$is_aurora" = true ]; then
        cat >> "${output_file}" <<EOF
            <div class="card">
                <div class="card-title">💿 Storage Status</div>
                <div class="card-value">${avg_volume_bytes_used_gb} GB</div>
                <span class="status-badge status-ok">OK</span>
                <div style="margin-top: 10px; font-size: 0.9em; color: #666;">
                    <div>Volume Used (Auto-scaling)</div>
                    <div>Aurora Storage</div>
                </div>
            </div>
EOF
    else
        cat >> "${output_file}" <<EOF
            <div class="card">
                <div class="card-title">💿 Storage Status</div>
                <div class="card-value">${storage_free_percent}%</div>
                <span class="status-badge ${storage_badge}">${storage_status}</span>
                <div style="margin-top: 10px; font-size: 0.9em; color: #666;">
                    <div>Allocated: ${allocated_storage} GB</div>
                    <div>Avg Free: ${avg_free_storage_gb} GB</div>
                </div>
            </div>
EOF
    fi

    cat >> "${output_file}" <<EOF
        </div>
EOF
}

################################################################################
# Function: add_cloudwatch_metrics
# Description: Adds detailed CloudWatch metrics section to HTML report
# Parameters:
#   $1 - output_file: Path to HTML report
# Metrics Collected:
#   - CPUUtilization (Percent)
#   - DatabaseConnections (Count)
#   - FreeableMemory (GB)
#   - ReadIOPS (Count/Second)
#   - WriteIOPS (Count/Second)
#   - FreeStorageSpace (GB)
# Time Range Logic:
#   1. Tests for 15-day data availability
#   2. If available: Uses 15-day range with 1-day (86400s) period
#   3. If not: Falls back to 2-hour range with 5-minute (300s) period
# Statistics: Average, Maximum, Minimum for each metric
# Display: Table format with formatted values and units
################################################################################
add_cloudwatch_metrics() {
    local output_file=$1
    
    echo "Fetching CloudWatch metrics for the last 15 days..."
    
    # Calculate time range (15 days)
    local end_time
    end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time_15d
    start_time_15d=$(date -u -v-15d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '15 days ago' +"%Y-%m-%dT%H:%M:%SZ")
    local start_time_2h
    start_time_2h=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '2 hours ago' +"%Y-%m-%dT%H:%M:%SZ")    
    # Define metrics to fetch (using parallel arrays instead of associative array)
    local metric_names=("CPUUtilization" "DatabaseConnections" "FreeableMemory" "ReadIOPS" "WriteIOPS" "FreeStorageSpace")
    local metric_units=("Percent" "Count" "Bytes" "Count/Second" "Count/Second" "Bytes")
    local display_units=("Percent" "Count" "GB" "Count/Second" "Count/Second" "GB")
    
    # First, check if we have any data for 15 days
    local test_metric_data
    test_metric_data=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name "CPUUtilization" \
        --dimensions Name=DBInstanceIdentifier,Value="${DB_IDENTIFIER}" \
        --start-time "${start_time_15d}" \
        --end-time "${end_time}" \
        --period 86400 \
        --statistics Average \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --output json 2>&1)
    
    local test_count
    test_count=$(echo "$test_metric_data" | jq -r '.Datapoints | length' 2>/dev/null || echo "0")    
    if [ "$test_count" -gt 0 ]; then
        local start_time="${start_time_15d}"
        local period=86400
        local time_range_label="Last 15 Days"
        echo "Using 15-day data range"
    else
        echo "No data for 15 days, using last 2 hours..."
        local start_time="${start_time_2h}"
        local period=300
        local time_range_label="Last 2 Hours"
    fi
    
    cat >> "${output_file}" <<EOF
        <h2>CloudWatch Metrics (${time_range_label})</h2>
EOF
    
    for i in "${!metric_names[@]}"; do
        local metric_name="${metric_names[$i]}"
        local unit="${metric_units[$i]}"
        local display_unit="${display_units[$i]}"
        
        echo "  Fetching ${metric_name}..."
        
        local metric_data
        metric_data=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/RDS \
            --metric-name "${metric_name}" \
            --dimensions Name=DBInstanceIdentifier,Value="${DB_IDENTIFIER}" \
            --start-time "${start_time}" \
            --end-time "${end_time}" \
            --period ${period} \
            --statistics Average Maximum Minimum \
            --region "${AWS_REGION}" \
            --profile "${AWS_PROFILE}" \
            --output json 2>&1)
        
        local _rc=$?
        if [ $_rc -eq 0 ]; then
            # Check if we have datapoints
            local datapoint_count
            datapoint_count=$(echo "$metric_data" | jq -r '.Datapoints | length' 2>/dev/null || echo "0")            
            if [ "$datapoint_count" -gt 0 ]; then
                # Calculate statistics
                local avg
                avg=$(echo "$metric_data" | jq -r '[.Datapoints[].Average] | add / length' 2>/dev/null || echo "N/A")
                local max
                max=$(echo "$metric_data" | jq -r '[.Datapoints[].Maximum] | max' 2>/dev/null || echo "N/A")
                local min
                min=$(echo "$metric_data" | jq -r '[.Datapoints[].Minimum] | min' 2>/dev/null || echo "N/A")                
                # Convert bytes to GB for storage metrics
                if [ "$unit" = "Bytes" ]; then
                    if [[ "$avg" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                        avg=$(echo "scale=2; $avg / 1073741824" | bc)
                    fi
                    if [[ "$max" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                        max=$(echo "scale=2; $max / 1073741824" | bc)
                    fi
                    if [[ "$min" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                        min=$(echo "scale=2; $min / 1073741824" | bc)
                    fi
                fi
                
                # Format numbers to 2 decimal places if they're valid numbers
                if [[ "$avg" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    avg=$(printf "%.2f" "$avg")
                fi
                if [[ "$max" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    max=$(printf "%.2f" "$max")
                fi
                if [[ "$min" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    min=$(printf "%.2f" "$min")
                fi
            else
                local avg="No data"
                local max="No data"
                local min="No data"
            fi
            
            cat >> "${output_file}" <<EOF
        <h3>${metric_name}</h3>
        <div class="chart-container">
            <table>
                <tr>
                    <th>Statistic</th>
                    <th>Value</th>
                    <th>Unit</th>
                </tr>
                <tr>
                    <td>Average</td>
                    <td>${avg}</td>
                    <td>${display_unit}</td>
                </tr>
                <tr>
                    <td>Maximum</td>
                    <td>${max}</td>
                    <td>${display_unit}</td>
                </tr>
                <tr>
                    <td>Minimum</td>
                    <td>${min}</td>
                    <td>${display_unit}</td>
                </tr>
            </table>
        </div>
EOF
        else
            cat >> "${output_file}" <<EOF
        <h3>${metric_name}</h3>
        <div class="warning">
            <p><strong>Unable to retrieve metric data</strong></p>
        </div>
EOF
        fi
    done
}

################################################################################
# Function: check_invalid_databases
# Description: Checks for invalid databases (datconnlimit = -2) and marks as WARNING if found
# Parameters:
#   $1 - Check name
#   $2 - Check description
#   $3 - SQL query
#   $4 - Output file path
#   $5 - Check ID
################################################################################
check_invalid_databases() {
    local check_name=$1
    local check_description=$2
    local sql_query=$3
    local output_file=$4
    local check_id=$5
    
    echo "Running: ${check_name}..."
    
    local result
    result=$(echo "${sql_query}" | PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" 2>&1 || echo "ERROR")    
    local status="SUCCESS"
    
    # Check for SQL errors first
    if echo "${result}" | grep -q "ERROR"; then
        status="ERROR"
    else
        # Count result rows (excluding header and footer lines)
        local row_count=0
        if [ -n "${result}" ]; then
            row_count=$(echo "${result}" | grep -v "^-" | grep -v "^(" | grep -v "^ *$" | tail -n +3 | wc -l | tr -d ' ')
        fi
        
        # If any invalid databases found, mark as WARNING
        if [ "$row_count" -gt 0 ]; then
            status="WARNING"
        else
            status="SUCCESS"
        fi
    fi
    
    write_check_result "${output_file}" "${check_name}" "${check_description}" "${result}" "${status}" "${check_id}"
}

################################################################################
# Function: check_database_age
# Description: Checks transaction ID age and marks as WARNING if any row has WARNING or CRITICAL status
# Parameters:
#   $1 - Check name
#   $2 - Check description
#   $3 - SQL query
#   $4 - Output file path
#   $5 - Check ID
################################################################################
check_database_age() {
    local check_name=$1
    local check_description=$2
    local sql_query=$3
    local output_file=$4
    local check_id=$5
    
    echo "Running: ${check_name}..."
    
    local result
    result=$(echo "${sql_query}" | PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" 2>&1 || echo "ERROR")    
    local status="SUCCESS"
    
    # Check for SQL errors first
    if echo "${result}" | grep -q "ERROR"; then
        status="ERROR"
    else
        # Check if any row contains WARNING or CRITICAL in the status column
        if echo "${result}" | grep -qE "WARNING|CRITICAL"; then
            status="WARNING"
        else
            status="SUCCESS"
        fi
    fi
    
    write_check_result "${output_file}" "${check_name}" "${check_description}" "${result}" "${status}" "${check_id}"
}

################################################################################
# Function: execute_check
# Description: Executes a SQL check and adds result to HTML report
# Parameters:
#   $1 - check_name: Name of the check
#   $2 - check_description: Description of what the check does
#   $3 - sql_query: SQL query to execute
#   $4 - what_to_check: Guidance on interpreting results (optional)
#   $5 - recommendations: Extension-specific recommendations (optional)
# Process:
#   1. Executes SQL query via psql
#   2. Determines status based on query result
#   3. Adds formatted result to HTML report
# Status Determination:
#   - Empty result or specific success patterns: OK
#   - Non-empty result: WARNING or CRITICAL based on check type
# Special Handling:
#   - Multi-query checks: Uses only first query result for status
#   - Extension checks: Includes pre/post-upgrade recommendations
################################################################################
execute_check() {
    local check_name=$1
    local check_description=$2
    local sql_query=$3
    local output_file=$4
    local check_id=$5
    
    echo "Running: ${check_name}..."
    # echo "FUNCTION ENTRY: execute_check called with check_id=${check_id}" >&2
    
    local result
    result=$(echo "${sql_query}" | PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" 2>&1 || echo "ERROR")    
    local status="SUCCESS"
    
    # Check for SQL errors first
    if echo "${result}" | grep -q "ERROR"; then
        status="ERROR"
    else
        # Extract just the check name without "what to check" suffix
        local base_check_name="${check_name%% - what to check:*}"
        
        # For multi-query checks, extract only the first query result
        local first_result="${result}"
        case "${base_check_name}" in
            "Replication Slots Check"|"Views Dependent on System Catalogs"|"Uncommitted Prepared Transactions"|"Unsupported Data Types Check (reg* Types)"|"Large Objects Check")
                # Extract only the first query result (up to the first row count line)
                first_result=$(echo "${result}" | awk '/^\([0-9]+ row/ {exit} {print}')
                ;;
        esac
        
        # Count result rows (excluding header and footer lines)
        local row_count=0
        if [ -n "${first_result}" ]; then
            # Count lines that are not headers, separators, or row count footer
            row_count=$(echo "${first_result}" | grep -v "^-" | grep -v "^(" | grep -v "^ *$" | tail -n +3 | wc -l | tr -d ' ')
        fi
        
        case "${base_check_name}" in
            "PostgreSQL Version Check"|"User Databases List"|"Database Size Analysis"|"Critical Configuration Parameters"|"Object Count Check"|"Top 20 Largest Tables"|"Unused Indexes Analysis"|"Transaction ID Age Check"|"Schema Usage")
                # No status needed - always INFO
                status="INFO"
                ;;
            
            "Foreign Tables Check for Blue/Green Deployments")
                # Warning if foreign tables exist (>0 rows), Success if none
                if [ "$row_count" -gt 0 ]; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "Partitioned Tables Check for Blue/Green Deployments")
                # Always SUCCESS - informational check about partitioned tables
                status="SUCCESS"
                ;;
            
            "High Write Volume Tables Check for Blue/Green Deployments")
                # Check if result contains WARNING text
                if echo "${result}" | grep -q "WARNING"; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "Blue/Green Extension Compatibility Check")
                # Check if result contains CRITICAL or WARNING text
                if echo "${result}" | grep -q "CRITICAL"; then
                    status="WARNING"
                elif echo "${result}" | grep -q "WARNING"; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "Template Database Verification")
                # Check if result contains both template0 and template1
                if echo "${result}" | grep -q "template0" && echo "${result}" | grep -q "template1"; then
                    status="SUCCESS"
                else
                    status="ERROR"
                fi
                ;;
            
            "Master Username Check")
                # Check for roles that can create roles/dbs and start with pg_
                # First check if there are any roles with can_create_role=t or can_create_db=t
                local has_creator_roles
                has_creator_roles=$(echo "${result}" | grep -c "| t" || true)
                if [ "$has_creator_roles" -gt 0 ]; then
                    # Now check if any of those start with pg_
                    if echo "${result}" | grep "| t" | grep -q "^ *pg_"; then
                        status="ERROR"
                    else
                        status="SUCCESS"
                    fi
                else
                    status="SUCCESS"
                fi
                ;;
            
            "Large Objects Check"|"Unknown Data Type Check (PostgreSQL 9.6 → 10+)"|"Views Dependent on System Catalogs")
                # These checks return a count in the first query
                # Extract the numeric value from the first result
                local count_value
                count_value=$(echo "${first_result}" | grep -E "^[[:space:]]*[0-9]+[[:space:]]*$" | tr -d ' ')
                if [ -n "$count_value" ] && [ "$count_value" -gt 0 ]; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "Replication Slots Check"|"Uncommitted Prepared Transactions"|"Unsupported Data Types Check (reg* Types)")
                # These are upgrade blockers — ERROR if count > 0
                local count_value
                count_value=$(echo "${first_result}" | grep -E "^[[:space:]]*[0-9]+[[:space:]]*$" | tr -d ' ')
                if [ -n "$count_value" ] && [ "$count_value" -gt 0 ]; then
                    status="ERROR"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "DDL Event Triggers Check")
                # Warning if DDL triggers found
                if [ "$row_count" -gt 0 ]; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "DTS Trigger Check")
                # Error if DTS trigger found - it will break Blue/Green
                if [ "$row_count" -gt 0 ]; then
                    status="ERROR"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "max_locks_per_transaction Check")
                # Warning if the result contains WARNING, success otherwise
                if echo "${result}" | grep -q "WARNING"; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "Database Connection Settings Check")
                # Error if databases don't allow connections - upgrade will fail
                if [ "$row_count" -gt 0 ]; then
                    status="ERROR"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "reg* Data Types in User Tables Check")
                # Error if reg* data types found - pg_upgrade will refuse to proceed
                if [ "$row_count" -gt 0 ]; then
                    status="ERROR"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "Invalid Indexes Check"|"Duplicate Indexes Detection"|"Table Bloat Analysis"|"Active Long Running Queries"|"Installed Extensions"|"Parameter Permissions Check"|"Table Requirements for Blue/Green Deployments"|"Outdated Extension Versions Check")
                # Warning if more than 0 rows, Success if 0 rows
                if [ "$row_count" -gt 0 ]; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
            
            "chkpass Extension Check"|"tsearch2 Extension Check"|"pg_repack Extension Check"|"System-Defined Composite Types in User Tables"|"aclitem Data Type Check (PostgreSQL 16+ Incompatibility)"|"sql_identifier Data Type Check (PostgreSQL 12+ Incompatibility)"|"Removed Data Types Check (abstime, reltime, tinterval)"|"Tables WITH OIDS Check"|"User-Defined Encoding Conversions Check"|"User-Defined Postfix Operators Check"|"Incompatible Polymorphic Functions Check")
                # These are critical upgrade blockers — ERROR if found
                if [ "$row_count" -gt 0 ]; then
                    status="ERROR"
                else
                    status="SUCCESS"
                fi
                ;;
            
            
            "Parameter Group Configuration for Blue/Green")
                # Check if any parameter has CRITICAL or WARNING status
                if echo "${result}" | grep -q "CRITICAL"; then
                    status="ERROR"
                elif echo "${result}" | grep -q "WARNING"; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
            
            *)
                # Default behavior for any other checks
                if [ "$row_count" -gt 0 ]; then
                    status="WARNING"
                else
                    status="SUCCESS"
                fi
                ;;
        esac
    fi
    
    
    # Informational checks are always INFO regardless of row count, but preserve ERROR
    local base_name="${check_name%% - what to check:*}"
    case "${base_name}" in
        "Database Size Analysis"|"PostgreSQL Version Check"|"User Databases List"|"Critical Configuration Parameters")
            if [ "${status}" != "ERROR" ]; then
                status="INFO"
            fi
            ;;
    esac

    # Dispatch to format-aware output helper
    if [ "${REPORT_FORMAT}" != "text" ]; then
        echo "<!-- Check: '${base_name}' | Row Count: ${row_count} | Status: ${status} | ID: ${check_id} -->" >> "${output_file}"
    fi
    write_check_result "${output_file}" "${check_name}" "${check_description}" "${result}" "${status}" "${check_id}"
}

################################################################################
# Function: main
# Description: Main execution flow of the script
# Execution Steps:
#   1. Parse command-line arguments (if provided)
#   2. Display script header
#   3. Display mode selection menu
#   4. Validate required parameters based on mode
#   5. Collect AWS details (for rds/both mode)
#   6. Collect database connection details (for sql/both mode)
#   7. Test database connection (for sql/both mode)
#   8. Prompt for baseline statistics table creation
#   9. Initialize HTML report
#   10. Execute RDS checks (for rds/both mode):
#       - RDS configuration
#       - Resource status (CPU, Memory, Storage, Connections)
#       - CloudWatch metrics
#   11. Execute SQL checks (for sql/both mode):
#       - 23 pre-upgrade validation checks
#   12. Finalize HTML report
#   13. Display completion message with report location
################################################################################
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    display_header
    
    # If non-interactive, validate all required parameters
    if [ "$NON_INTERACTIVE" = true ]; then
        validate_parameters
    else
        display_menu
    fi
    
    # Detect engine type early if we have DB_IDENTIFIER and AWS_REGION (for proper file naming)
    if [ -n "$DB_IDENTIFIER" ] && [ -n "$AWS_REGION" ]; then
        detect_engine_type
    fi
    
    # Generate output filename with timestamp and identifier
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local identifier_part=""
    if [ -n "$DB_IDENTIFIER" ]; then
        identifier_part="${DB_IDENTIFIER}_"
    elif [ -n "$DB_HOST" ]; then
        # Extract hostname without domain for cleaner filename
        identifier_part="$(echo "$DB_HOST" | cut -d'.' -f1)_"
    fi
    
    # Use consistent "rds" prefix for all PostgreSQL precheck reports
    local file_prefix="rds"
    
    # Set file extension based on report format
    local file_ext="html"
    if [ "${REPORT_FORMAT}" = "text" ]; then
        file_ext="txt"
    fi
    
    local output_file="${file_prefix}_precheck_report_${identifier_part}${timestamp}.${file_ext}"
    
    # Gather all inputs upfront for option 3
    if [ "$RUN_MODE" = "both" ]; then
        if [ "$NON_INTERACTIVE" = false ]; then
            echo "=== Gathering AWS RDS Details ==="
            get_aws_details
            echo ""
            echo "=== Gathering Database Connection Details ==="
            get_connection_details
            
            # Retrieve password from Secrets Manager if needed
            if [ -n "$DB_SECRET_ARN" ]; then
                if ! retrieve_password_from_secrets_manager; then
                    echo "Exiting due to Secrets Manager retrieval failure."
                    exit 1
                fi
            fi
            
            test_connection_or_exit
            
            # Prompt for baseline statistics table creation
            prompt_baseline_creation
        else
            # Non-interactive mode
            get_aws_details
            get_connection_details
            
            # Retrieve password from Secrets Manager if needed
            if [ -n "$DB_SECRET_ARN" ]; then
                if ! retrieve_password_from_secrets_manager; then
                    echo "Exiting due to Secrets Manager retrieval failure."
                    exit 1
                fi
            fi
            
            test_connection_or_exit
        fi
        
        echo ""
        echo "Generating combined RDS and SQL pre-upgrade report..."
        echo "Output file: ${output_file}"
        echo ""
    fi
    
    # Handle RDS mode
    if [ "$RUN_MODE" = "rds" ] || [ "$RUN_MODE" = "both" ]; then
        if [ "$RUN_MODE" = "rds" ]; then
            if [ "$NON_INTERACTIVE" = false ]; then
                get_aws_details
            else
                get_aws_details
            fi
            echo ""
            echo "Generating RDS configuration report..."
            echo "Output file: ${output_file}"
            echo ""
        fi
        
        # Initialize report
        if [ "${REPORT_FORMAT}" = "text" ]; then
            init_text_report "${output_file}"
        else
            init_html "${output_file}" "$RUN_MODE"
        fi
        
        # Add clear section marker for RDS config
        if [ "${REPORT_FORMAT}" = "text" ]; then
            cat >> "${output_file}" <<EOF
================================================================================
  RDS CONFIGURATION DETAILS
  AWS RDS Instance Configuration, Performance Insights & CloudWatch Metrics
================================================================================
EOF
        else
            cat >> "${output_file}" <<EOF
        <div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; margin: 30px 0; border-radius: 8px; text-align: center;">
            <h1 style="color: white; border: none; margin: 0; font-size: 2em;">📊 RDS CONFIGURATION DETAILS</h1>
            <p style="margin: 10px 0 0 0; font-size: 1.1em;">AWS RDS Instance Configuration, Performance Insights & CloudWatch Metrics</p>
        </div>
EOF
        fi
        
        # Detect engine type (RDS vs Aurora) - only if not already detected
        if [ -z "$ENGINE_TYPE" ]; then
            detect_engine_type
        fi
        
        # Add RDS configuration (HTML only — text mode gets the section header only)
        if [ "${REPORT_FORMAT}" != "text" ]; then
            add_rds_config "${output_file}"
        
            # Add Memory and Storage Status
            add_memory_storage_status "${output_file}"
        fi
    fi
    
    # Handle SQL mode
    if [ "$RUN_MODE" = "sql" ] || [ "$RUN_MODE" = "both" ]; then
        if [ "$RUN_MODE" = "sql" ]; then
            if [ "$NON_INTERACTIVE" = false ]; then
                get_connection_details
                
                # Retrieve password from Secrets Manager if needed
                if [ -n "$DB_SECRET_ARN" ]; then
                    if ! retrieve_password_from_secrets_manager; then
                        echo "Exiting due to Secrets Manager retrieval failure."
                        exit 1
                    fi
                fi
                
                test_connection_or_exit
                
                # Prompt for baseline statistics table creation
                prompt_baseline_creation
            else
                get_connection_details
                
                # Retrieve password from Secrets Manager if needed
                if [ -n "$DB_SECRET_ARN" ]; then
                    if ! retrieve_password_from_secrets_manager; then
                        echo "Exiting due to Secrets Manager retrieval failure."
                        exit 1
                    fi
                fi
                
                test_connection_or_exit
            fi
            
            echo ""
            echo "Generating pre-upgrade check report..."
            echo "Output file: ${output_file}"
            echo ""
            
            # Initialize report
            if [ "${REPORT_FORMAT}" = "text" ]; then
                init_text_report "${output_file}"
            else
                init_html "${output_file}" "$RUN_MODE"
            fi
        fi
        
        # Add clear section marker for SQL checks
        if [ "${REPORT_FORMAT}" = "text" ]; then
            cat >> "${output_file}" <<EOF
================================================================================
  PRE-UPGRADE SQL CHECKS
  Database Health, Performance & Compatibility Analysis
================================================================================
EOF
        else
            cat >> "${output_file}" <<EOF
        <div style="background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%); color: white; padding: 20px; margin: 30px 0; border-radius: 8px; text-align: center;">
            <h1 style="color: white; border: none; margin: 0; font-size: 2em;">🔍 PRE-UPGRADE SQL CHECKS</h1>
            <p style="margin: 10px 0 0 0; font-size: 1.1em;">Database Health, Performance & Compatibility Analysis</p>
        </div>
        
        <h3 style="color: #555; margin: 20px 0 15px 0;">Pre-Upgrade Check Results (Click rows for details)</h3>
        <table id="checksTable">
            <tr>
                <th style="width: 60px; text-align: center;">✓</th>
                <th>Check Category</th>
                <th>Status</th>
                <th style="width: 50px;"></th>
            </tr>
EOF
        fi
        
        # Create baseline statistics table if requested
        if [[ "$CREATE_BASELINE" =~ ^[Yy][Ee][Ss]$|^[Yy]$ ]]; then
            echo "Creating baseline statistics table..."
            
            # Create and populate baseline stats table
            local baseline_result
            baseline_result=$(PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" <<'EOSQL' 2>&1
-- Create baseline statistics table (run before upgrade)
DROP TABLE IF EXISTS preupgrade_baseline_stats;
CREATE TABLE preupgrade_baseline_stats (
    id SERIAL PRIMARY KEY,
    capture_time TIMESTAMP DEFAULT NOW(),
    database_name TEXT,
    table_count INTEGER,
    total_size_bytes BIGINT,
    total_index_size_bytes BIGINT,
    total_dead_tuples BIGINT,
    pg_version TEXT
);

-- Insert current statistics
INSERT INTO preupgrade_baseline_stats (database_name, table_count, total_size_bytes, total_index_size_bytes, total_dead_tuples, pg_version)
SELECT 
    current_database(),
    (SELECT COUNT(*) FROM pg_stat_user_tables),
    (SELECT pg_database_size(current_database())),
    (SELECT COALESCE(SUM(pg_indexes_size(relid)), 0) FROM pg_stat_user_tables),
    (SELECT COALESCE(SUM(n_dead_tup), 0) FROM pg_stat_user_tables),
    version();

-- Display the captured baseline
SELECT 
    id,
    capture_time,
    database_name,
    table_count,
    pg_size_pretty(total_size_bytes) as total_size,
    pg_size_pretty(total_index_size_bytes) as total_index_size,
    total_dead_tuples,
    pg_version
FROM preupgrade_baseline_stats 
ORDER BY capture_time DESC 
LIMIT 1;
EOSQL
)
            
            local _rc=$?
            if [ $_rc -eq 0 ]; then
                echo -e "${GREEN}✓ Baseline statistics table created and populated${NC}"
                
                # Add baseline stats to HTML report
                cat >> "${output_file}" <<EOF
        <h2>Baseline Statistics Captured</h2>
        <div class="success">
            <p><strong>Status:</strong> <span class="status-badge status-pass">CREATED</span></p>
            <p>Baseline statistics have been captured in the preupgrade_baseline_stats table.</p>
        </div>
        <button class="collapsible" onclick="toggleContent('content_baseline')">Show/Hide Baseline Statistics</button>
        <div id="content_baseline" class="content">
            <pre>${baseline_result}</pre>
        </div>
EOF
            else
                echo -e "${RED}✗ Failed to create baseline statistics table${NC}"
                
                # Add error to HTML report
                cat >> "${output_file}" <<EOF
        <h2>Baseline Statistics</h2>
        <div class="error">
            <p><strong>Status:</strong> <span class="status-badge status-fail">FAILED</span></p>
            <p>Failed to create baseline statistics table.</p>
        </div>
        <button class="collapsible" onclick="toggleContent('content_baseline_error')">Show/Hide Error Details</button>
        <div id="content_baseline_error" class="content">
            <pre>${baseline_result}</pre>
        </div>
EOF
            fi
            echo ""
        else
            echo "Skipping baseline statistics table creation."
            echo ""
        fi
        
        # Detect PostgreSQL major version for version-specific checks
        get_pg_major_version
        
        # Check 1: PostgreSQL Version
        execute_check \
            "PostgreSQL Version Check" \
            "Verify the current PostgreSQL version and ensure it's supported for upgrade" \
            "SELECT version();" \
            "${output_file}" \
            "1"
        
        # Check 2: Invalid Databases Check
        check_invalid_databases \
            "Invalid Databases Check - what to check: \"Databases with datconnlimit = -2 are marked as invalid and cannot be accessed. These must be dropped or fixed before upgrade.\"" \
            "Check for databases marked as invalid (datconnlimit = -2)" \
            "SELECT 
                datname AS database_name,
                datconnlimit,
                'CRITICAL - Invalid database must be dropped before upgrade' AS issue
            FROM pg_database 
            WHERE datconnlimit = -2
            ORDER BY datname;" \
            "${output_file}" \
            "2"
        
        # Check 2b: Databases Not Allowing Connections
        execute_check \
            "Database Connection Settings Check - what to check: \"All non-template0 databases must allow connections (datallowconn = true). Databases with datallowconn = false will cause the upgrade to fail.\"" \
            "Check for databases that do not allow connections" \
            "SELECT
                datname AS database_name,
                datallowconn AS allow_connections,
                'CRITICAL - Database must allow connections before upgrade' AS issue
            FROM pg_database
            WHERE datname != 'template0'
              AND datallowconn = false
            ORDER BY datname;" \
            "${output_file}" \
            "2b"
        
        # Check 3: Template Database Verification
        execute_check \
            "Template Database Verification - what to check: \"template0 and template1 must exist for successful upgrade\"" \
            "Verify template databases exist and are configured correctly" \
            "SELECT 
                datname AS database_name,
                datistemplate AS is_template,
                datallowconn AS allow_connections,
                pg_encoding_to_char(encoding) AS encoding,
                datcollate AS collation,
                datctype AS ctype
            FROM pg_database 
            WHERE datname IN ('template0', 'template1')
            ORDER BY datname;" \
            "${output_file}" \
            "3"
        
        # Check 4: Master Username Check
        execute_check \
            "Master Username Check - what to check: \"Master username cannot start with 'pg_'\"" \
            "Check all role names for invalid naming patterns" \
            "SELECT 
                rolname,
                CASE 
                    WHEN rolname LIKE 'pg_%' THEN 'INVALID - Cannot start with pg_'
                    ELSE 'OK'
                END AS status,
                rolsuper AS is_superuser,
                rolcreaterole AS can_create_role,
                rolcreatedb AS can_create_db
            FROM pg_roles
            WHERE (rolcreaterole = true OR rolcreatedb = true)
                AND rolname NOT IN ('rdsadmin', 'rds_superuser', 'rds_replication',
                                    'rds_password', 'rdsrepladmin')
            ORDER BY rolname;" \
            "${output_file}" \
            "4"
        
        # Check 5: Database Size and Growth (all databases via shared catalog)
        execute_check \
            "Database Size Analysis" \
            "Calculate total database size and identify largest databases in the cluster" \
            "SELECT
                datname AS database_name,
                pg_size_pretty(pg_database_size(datname)) AS size
            FROM pg_database
            WHERE datname NOT IN ('template0', 'template1', 'rdsadmin')
            ORDER BY pg_database_size(datname) DESC;" \
            "${output_file}" \
            "5"
        
        # Check 6: Object Count Check (all databases)
        execute_check_all_dbs \
            "Object Count Check - what to check: \"A large number of objects will increase upgrade time. Additionally, verify that all object types are supported in the target version.\"" \
            "Count database objects to assess upgrade complexity" \
            "SELECT 'Tables' AS object_type, COUNT(*) AS count 
            FROM pg_tables 
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            UNION ALL 
            SELECT 'Views', COUNT(*) 
            FROM pg_views 
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            UNION ALL 
            SELECT 'Materialized Views', COUNT(*) 
            FROM pg_matviews 
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            UNION ALL 
            SELECT 'Indexes', COUNT(*) 
            FROM pg_indexes 
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            UNION ALL 
            SELECT 'Sequences', COUNT(*) 
            FROM pg_sequences 
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            UNION ALL 
            SELECT 'Functions', COUNT(*) 
            FROM pg_proc p 
            JOIN pg_namespace n ON p.pronamespace = n.oid 
            WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
            UNION ALL 
            SELECT 'Triggers', COUNT(*) 
            FROM pg_trigger 
            WHERE NOT tgisinternal
            UNION ALL 
            SELECT 'Extensions', COUNT(*) 
            FROM pg_extension 
            WHERE extname != 'plpgsql'
            ORDER BY object_type;" \
            "${output_file}" \
            "6"
        
        # Check 7: Top 20 Largest Tables (all databases)
        execute_check_all_dbs \
            "Top 20 Largest Tables" \
            "Identify the largest tables in the database for capacity planning" \
            "SELECT
                schemaname AS schema_name,
                tablename AS table_name,
                pg_size_pretty(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename))) AS total_size,
                pg_size_pretty(pg_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename))) AS table_size,
                pg_size_pretty(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename)) - pg_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename))) AS index_size
            FROM pg_tables
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename)) DESC
            LIMIT 20;" \
            "${output_file}" \
            "7"
        
        
        # Check 8: Invalid Indexes
        execute_check \
            "Invalid Indexes Check - what to check: \"Invalid indexes are the indexes that are not currently being used by the query planner. Dropping the indexes will save disk space and reduce time during vacuum operations post upgrade.\"" \
            "Check for invalid or corrupted indexes that need to be rebuilt" \
            "SELECT 
                schemaname,
                tablename,
                indexname,
                indexdef
            FROM pg_indexes
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            AND indexname IN (
                SELECT indexrelid::regclass::text
                FROM pg_index
                WHERE NOT indisvalid
            );" \
            "${output_file}" \
            "8"
        
        # Check 9: Duplicate Indexes
        execute_check \
            "Duplicate Indexes Detection - what to check: \"Post-upgrade maintenance operations like VACUUM and ANALYZE take longer with duplicate indexes, as each index must be processed separately.\"" \
            "Find duplicate indexes that can be removed to improve performance" \
            "WITH index_details AS (
                SELECT 
                    schemaname,
                    tablename,
                    indexname,
                    indexdef
                FROM pg_indexes
                WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            )
            SELECT 
                tablename,
                array_agg(indexname) AS duplicate_indexes,
                indexdef AS index_definition,
                COUNT(*) AS duplicate_count
            FROM index_details
            GROUP BY tablename, indexdef
            HAVING COUNT(*) > 1
            ORDER BY tablename, duplicate_count DESC;" \
            "${output_file}" \
            "9"
        
        # Check 10: Unused Indexes (all databases)
        execute_check_all_dbs \
            "Unused Indexes Analysis - what to check: \"Unused indexes consume disk I/O during the upgrade process when they need to be rebuilt or validated\"" \
            "Identify indexes that have never been scanned and may be candidates for removal" \
            "SELECT 
                schemaname,
                relname,
                indexrelname,
                pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
                idx_scan AS index_scans
            FROM pg_stat_user_indexes
            WHERE idx_scan = 0
            AND pg_relation_size(indexrelid) > 10240
            ORDER BY pg_relation_size(indexrelid) DESC
            LIMIT 20;" \
            "${output_file}" \
            "10"
        
        # Check 11: Table Bloat Estimation
        execute_check \
            "Table Bloat Analysis" \
            "If a table is bloated, consider running VACUUM FULL or pg_repack, as bloated tables can significantly impact post-upgrade performance." \
            "SELECT 
                schemaname,
                relname,
                n_live_tup AS live_tuples,
                n_dead_tup AS dead_tuples,
                ROUND(100 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_tuple_percent,
                last_vacuum,
                last_autovacuum
            FROM pg_stat_user_tables
            WHERE n_dead_tup > 1000
            ORDER BY n_dead_tup DESC
            LIMIT 20;" \
            "${output_file}" \
            "11"
        
        # Check 12: Long Running Queries
        execute_check \
            "Active Long Running Queries - what to check: \"PostgreSQL upgrades require all database changes to be fully committed and written to disk to create a consistent snapshot. Open transactions violate this requirement by maintaining uncommitted changes in memory, generating incomplete Write-Ahead Log records, and leaving data files in an inconsistent state that cannot be safely migrated.\"" \
            "Identify queries that have been running for an extended period" \
            "SELECT 
                pid,
                usename,
                application_name,
                client_addr,
                state,
                NOW() - query_start AS duration,
                query
            FROM pg_stat_activity
            WHERE state != 'idle'
            AND query NOT LIKE '%pg_stat_activity%'
            AND NOW() - query_start > interval '5 minutes'
            ORDER BY duration DESC;" \
            "${output_file}" \
            "12"
        
        # Check 13: Replication Slots Check
        execute_check \
            "Replication Slots Check - what to check: \"Upgrade fails if logical replication slots exist. Drop logical slots before upgrade.\"" \
            "Check for existing replication slots" \
            "-- Count total slots
            SELECT COUNT(*) AS slot_count FROM pg_catalog.pg_replication_slots;
            -- Check for existing replication slots
            SELECT slot_name, plugin, slot_type, database, active, active_pid, xmin, catalog_xmin, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots;" \
            "${output_file}" \
            "13"
        
        # Check 14: Database Configuration Parameters
        execute_check \
            "Critical Configuration Parameters" \
            "Review important PostgreSQL configuration settings" \
            "SELECT 
                name,
                setting,
                unit,
                source,
                context
            FROM pg_settings
            WHERE name IN (
                'max_connections',
                'shared_buffers',
                'effective_cache_size',
                'maintenance_work_mem',
                'work_mem',
                'wal_level',
                'max_wal_senders',
                'max_replication_slots',
                'autovacuum',
                'log_statement'
            )
            ORDER BY name;" \
            "${output_file}" \
            "14"
        
        # Check 15: Extension Compatibility (all databases)
        echo "Running: Installed Extensions - what to check: \"Extensions must be updated before major version upgrade\"..."
        
        if ! get_all_databases; then
            write_check_result "${output_file}" \
                "Installed Extensions - what to check: \"Extensions must be updated before major version upgrade - https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.PostgreSQL.ExtensionUpgrades.html\"" \
                "List all installed extensions across all databases for upgrade compatibility check" \
                "ERROR: Could not retrieve database list. Check connection to ${DB_HOST}." \
                "ERROR" \
                "15"
        else
        
        # Define extension recommendations
        local PRE_UPGRADE_EXTENSIONS="
postgis|Must be upgraded to latest version before upgrade|pre
postgis_topology|Must be upgraded with PostGIS before upgrade|pre
postgis_tiger_geocoder|Must be upgraded with PostGIS before upgrade|pre
address_standardizer|Must be upgraded with PostGIS before upgrade|pre
address_standardizer_data_us|Must be upgraded with PostGIS before upgrade|pre
pg_repack|Must be upgraded before major version upgrade|pre
pglogical|Must be upgraded or removed before upgrade|pre
pg_hint_plan|Check compatibility with target version|pre
pg_stat_statements|Should be at latest version|pre
pgaudit|Must match target PostgreSQL version|pre
pg_cron|Must be upgraded before upgrade|pre
pg_partman|Should be upgraded before upgrade|pre
pg_tle|Must be upgraded before upgrade|pre
"
        local POST_UPGRADE_EXTENSIONS="
plpgsql|Automatically upgraded|post
uuid-ossp|Can be upgraded after|post
hstore|Can be upgraded after|post
citext|Can be upgraded after|post
ltree|Can be upgraded after|post
pg_trgm|Can be upgraded after|post
fuzzystrmatch|Can be upgraded after|post
tablefunc|Can be upgraded after|post
pgcrypto|Can be upgraded after|post
btree_gist|Can be upgraded after|post
btree_gin|Can be upgraded after|post
intarray|Can be upgraded after|post
earthdistance|Can be upgraded after|post
cube|Can be upgraded after|post
bloom|Can be upgraded after|post
pg_buffercache|Can be upgraded after|post
pg_prewarm|Can be upgraded after|post
"
        
        local ext_result=""
        local recommendations=""
        local has_pre_upgrade=false
        local has_post_upgrade=false
        
        while IFS= read -r db; do
            [ -z "$db" ] && continue
            local db_ext
            db_ext=$(echo "SELECT current_database() AS database_name, extname AS extension_name, extversion AS installed_version, a.default_version AS available_version, CASE WHEN a.default_version IS NULL THEN 'UNAVAILABLE' WHEN e.extversion <> a.default_version THEN 'UPDATE REQUIRED' ELSE 'OK' END AS status, nspname AS schema FROM pg_extension e LEFT JOIN pg_available_extensions a ON e.extname = a.name JOIN pg_namespace ON e.extnamespace = pg_namespace.oid WHERE nspname NOT IN ('pg_catalog','information_schema') ORDER BY CASE WHEN a.default_version IS NULL THEN 0 WHEN e.extversion <> a.default_version THEN 1 ELSE 2 END, extname;" | \
                PGPASSWORD="${DB_PASS}" psql -t -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${db}" 2>&1)
            
            if [ -n "${db_ext}" ]; then
                ext_result="${ext_result}-- Database: ${db}
${db_ext}

"
                # Check for pre-upgrade extensions in this DB
                while IFS='|' read -r ext_name ext_rec ext_type; do
                    if [ -n "$ext_name" ] && [ "$ext_type" = "pre" ]; then
                        if echo "${db_ext}" | grep -qi "[[:space:]]${ext_name}[[:space:]]"; then
                            recommendations="${recommendations}\n⚠️  [${db}] ${ext_name}: ${ext_rec}"
                            has_pre_upgrade=true
                        fi
                    fi
                done <<< "$PRE_UPGRADE_EXTENSIONS"
                
                # Check for post-upgrade extensions
                while IFS='|' read -r ext_name ext_rec ext_type; do
                    if [ -n "$ext_name" ] && [ "$ext_type" = "post" ]; then
                        if echo "${db_ext}" | grep -qi "[[:space:]]${ext_name}[[:space:]]"; then
                            recommendations="${recommendations}\n✓  [${db}] ${ext_name}: ${ext_rec}"
                            has_post_upgrade=true
                        fi
                    fi
                done <<< "$POST_UPGRADE_EXTENSIONS"
            fi
        done <<< "${ALL_DATABASES}"
        
        if [ "$has_pre_upgrade" = true ] || [ "$has_post_upgrade" = true ]; then
            ext_result="${ext_result}
=== EXTENSION UPGRADE RECOMMENDATIONS ===
$(echo -e "${recommendations}" | sed 's/^/  /')
"
        fi
        
        local status="SUCCESS"
        if echo "${ext_result}" | grep -q "^ERROR"; then
            status="ERROR"
        elif [ "$has_pre_upgrade" = true ]; then
            status="WARNING"
        fi
        
        write_check_result "${output_file}" \
            "Installed Extensions - what to check: \"Extensions must be updated before major version upgrade - https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.PostgreSQL.ExtensionUpgrades.html\"" \
            "List all installed extensions across all databases for upgrade compatibility check" \
            "${ext_result}" \
            "${status}" \
            "15"
        fi  # end get_all_databases guard
        
        # Check 15b: Outdated Extension Versions (all databases)
        execute_check_all_dbs \
            "Outdated Extension Versions Check - what to check: \"Extensions such as postgis, pgrouting, and rdkit may have newer versions available. Upgrading extensions before the major version upgrade reduces compatibility risk. Either upgrade the extension or drop and recreate it after upgrade.\"" \
            "Check for installed extensions that have a newer version available (across all databases)" \
            "SELECT
                current_database() AS database_name,
                name AS extension_name,
                installed_version,
                default_version AS available_version,
                'WARNING - Installed version differs from available version' AS recommendation
            FROM pg_available_extensions
            WHERE name IN (
                'postgis', 'pgrouting', 'postgis_raster',
                'postgis_tiger_geocoder', 'postgis_topology',
                'address_standardizer', 'address_standardizer_data_us', 'rdkit'
            )
              AND installed_version IS NOT NULL
              AND default_version != installed_version
            ORDER BY name;" \
            "${output_file}" \
            "15b"
        
        # Check 16: Views Dependent on System Catalogs
        execute_check \
            "Views Dependent on System Catalogs - what to check: \"PostgreSQL objects may malfunction or exhibit altered behavior following major version upgrades due to changes in internal system catalogs. As a precautionary measure, drop and recreate views dependent on system catalogs post-upgrade.\"" \
            "Check for views dependent on system catalogs that may have changed" \
            "-- Check for views dependent on pg_stat_activity
            SELECT 
                dependent_ns.nspname AS dependent_schema,
                dependent_view.relname AS dependent_view,
                source_ns.nspname AS source_schema,
                source_table.relname AS source_table
            FROM pg_depend
            JOIN pg_rewrite ON pg_depend.objid = pg_rewrite.oid
            JOIN pg_class AS dependent_view ON pg_rewrite.ev_class = dependent_view.oid
            JOIN pg_class AS source_table ON pg_depend.refobjid = source_table.oid
            JOIN pg_namespace AS dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
            JOIN pg_namespace AS source_ns ON source_ns.oid = source_table.relnamespace
            WHERE source_table.relname = 'pg_stat_activity'
                AND dependent_ns.nspname NOT IN ('pg_catalog', 'information_schema');
            -- Check for views dependent on pg_constraint (changed in PG 12)
            SELECT 
                dependent_ns.nspname AS dependent_schema,
                dependent_view.relname AS dependent_view
            FROM pg_depend
            JOIN pg_rewrite ON pg_depend.objid = pg_rewrite.oid
            JOIN pg_class AS dependent_view ON pg_rewrite.ev_class = dependent_view.oid
            JOIN pg_class AS source_table ON pg_depend.refobjid = source_table.oid
            JOIN pg_namespace AS dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
            WHERE source_table.relname = 'pg_constraint'
                AND dependent_ns.nspname NOT IN ('pg_catalog', 'information_schema');
            -- List all user-created views
            SELECT 
                schemaname,
                viewname,
                viewowner,
                LEFT(definition, 200) AS definition_preview
            FROM pg_views
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY schemaname, viewname;" \
            "${output_file}" \
            "16"
        
        # Check 17: Prepared Transactions
        execute_check \
            "Uncommitted Prepared Transactions - what to check: \"PostgreSQL upgrades will fail if uncommitted prepared transactions exist in the database. These transactions prevent the clean shutdown state required by pg_upgrade and contain version-specific data (transaction IDs, lock states, and WAL references) that cannot be preserved across different PostgreSQL versions.\"" \
            "Check for uncommitted prepared transactions that could block upgrade" \
            "-- Count prepared transactions
            SELECT COUNT(*) AS prepared_transaction_count 
            FROM pg_catalog.pg_prepared_xacts;
            -- Check for uncommitted prepared transactions
            SELECT 
                gid,
                prepared,
                owner,
                database
            FROM pg_prepared_xacts;" \
            "${output_file}" \
            "17"
        
        # Check 18: Database Age (Transaction ID Wraparound)
        check_database_age \
            "Transaction ID Age Check - what to check: \"PostgreSQL's 32-bit transaction counter has a 2 billion transaction limit that triggers transaction ID wraparound. This forces the database into read-only protective mode to prevent data corruption and visibility problems. Database upgrades are blocked during wraparound conditions because the upgrade process cannot operate on databases in protective or emergency states.\"" \
            "Check database transaction ID age for wraparound protection" \
            "-- Check database transaction ID age
            -- WARNING: If age > 200,000,000, manual VACUUM FREEZE required
            SELECT 
                datname AS database_name,
                age(datfrozenxid) AS xid_age,
                CASE 
                    WHEN age(datfrozenxid) > 200000000 THEN 'CRITICAL - VACUUM REQUIRED'
                    WHEN age(datfrozenxid) > 150000000 THEN 'WARNING - Plan VACUUM'
                    ELSE 'OK'
                END AS status
            FROM pg_database 
            ORDER BY age(datfrozenxid) DESC 
            LIMIT 20;" \
            "${output_file}" \
            "18"
        
        # Check 19: Unsupported Data Types (reg* Types)
        execute_check \
            "Unsupported Data Types Check (reg* Types) - what to check: \"Certain OID-referencing data types in the reg* family—excluding regclass, regrole, and regtype—prevent PostgreSQL upgrades from proceeding. Based on business requirements, you may need to drop and recreate objects using these types post-upgrade.\"" \
            "Check for unsupported reg* data types" \
            "-- Count unsupported types
            SELECT COUNT(*) AS unsupported_type_count 
            FROM pg_catalog.pg_class c 
            JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid 
            JOIN pg_catalog.pg_attribute a ON c.oid = a.attrelid 
            WHERE NOT a.attisdropped 
                AND a.atttypid IN ( 
                    'pg_catalog.regproc'::pg_catalog.regtype, 
                    'pg_catalog.regprocedure'::pg_catalog.regtype, 
                    'pg_catalog.regoper'::pg_catalog.regtype, 
                    'pg_catalog.regoperator'::pg_catalog.regtype, 
                    'pg_catalog.regconfig'::pg_catalog.regtype, 
                    'pg_catalog.regcollation'::pg_catalog.regtype, 
                    'pg_catalog.regnamespace'::pg_catalog.regtype, 
                    'pg_catalog.regdictionary'::pg_catalog.regtype 
                ) 
                AND n.nspname NOT IN ('pg_catalog', 'information_schema');
            -- Check for unsupported reg* data types 
            SELECT 
                n.nspname AS schema_name, 
                c.relname AS table_name, 
                a.attname AS column_name, 
                pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type 
            FROM pg_catalog.pg_class c 
            JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid 
            JOIN pg_catalog.pg_attribute a ON c.oid = a.attrelid 
            WHERE NOT a.attisdropped 
                AND a.atttypid IN ( 
                    'pg_catalog.regproc'::pg_catalog.regtype, 
                    'pg_catalog.regprocedure'::pg_catalog.regtype, 
                    'pg_catalog.regoper'::pg_catalog.regtype, 
                    'pg_catalog.regoperator'::pg_catalog.regtype, 
                    'pg_catalog.regconfig'::pg_catalog.regtype, 
                    'pg_catalog.regcollation'::pg_catalog.regtype, 
                    'pg_catalog.regnamespace'::pg_catalog.regtype, 
                    'pg_catalog.regdictionary'::pg_catalog.regtype 
                ) 
                AND n.nspname NOT IN ('pg_catalog', 'information_schema') 
            ORDER BY n.nspname, c.relname, a.attname;" \
            "${output_file}" \
            "19"
        
        # Check 20: Large Objects Check
        execute_check \
            "Large Objects Check - what to check: \"Excessive large objects can cause OOM during upgrade. For 100,000 - 1,000,000 objects, consider larger instance class. Test upgrade using snapshot first.\"" \
            "Check for large objects that may impact upgrade performance" \
            "-- Count large objects
            SELECT COUNT(*) AS large_object_count 
            FROM pg_largeobject_metadata;
            -- Check large object table size
            SELECT pg_size_pretty(pg_total_relation_size('pg_largeobject')) AS lo_table_size;
            -- Check for orphaned large objects
            SELECT lo.oid AS orphaned_lo
            FROM pg_largeobject_metadata lo
            WHERE NOT EXISTS (
                SELECT 1 FROM pg_depend d 
                WHERE d.objid = lo.oid
            );" \
            "${output_file}" \
            "20"
        
        # Check 21: Unknown Data Type Check (PostgreSQL 9.6 → 10+) - Only for PG < 10
        if [ "$PG_MAJOR_VERSION" -lt 10 ]; then
            execute_check \
                "Unknown Data Type Check (PostgreSQL 9.6 → 10+) - what to check: \"'unknown' data type not supported in PostgreSQL 10+\"" \
                "Check for columns with unknown data type" \
                "-- Find columns with unknown data type
                SELECT 
                    table_schema,
                    table_name,
                    column_name,
                    data_type
                FROM information_schema.columns 
                WHERE data_type ILIKE 'unknown';
                -- Alternative check
                SELECT DISTINCT data_type 
                FROM information_schema.columns 
                WHERE data_type ILIKE 'unknown';" \
                "${output_file}" \
                "21"
        else
            echo "Skipping Check 21 (Unknown Data Type) - Not applicable for PostgreSQL >= 10"
        fi
        
        # Check 22: Parameter Permissions Check (PostgreSQL 15+)
        # Get PostgreSQL version
        local pg_version
        pg_version=$(PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SHOW server_version;" 2>&1 | awk '{print $1}' | cut -d. -f1)        
        if [ "$pg_version" -ge 15 ] 2>/dev/null; then
            execute_check \
                "Parameter Permissions Check - what to check: \"Custom parameter permissions can cause upgrade failure\"" \
                "Check for custom parameter permissions (PostgreSQL 15+)" \
                "SELECT 
                    routine_name,
                    grantee,
                    privilege_type
                FROM information_schema.role_routine_grants
                WHERE routine_name LIKE '%parameter%';" \
                "${output_file}" \
                "22"
        else
            echo "Skipping Parameter Permissions Check (requires PostgreSQL 15+, current version: ${pg_version})"
        fi
        
        # Check 23: Schema Usage (all databases)
        execute_check_all_dbs \
            "Schema Usage" \
            "Review schema ownership, size, and object distribution" \
            "WITH schema_info AS (
                SELECT
                    n.nspname AS schema_name,
                    pg_catalog.pg_get_userbyid(n.nspowner) AS owner,
                    n.oid AS schema_oid,
                    COALESCE(pg_size_pretty(SUM(pg_total_relation_size(c.oid))), '0 bytes') AS size,
                    COALESCE(SUM(pg_total_relation_size(c.oid)), 0) AS size_bytes,
                    COUNT(DISTINCT CASE WHEN c.relkind = 'r' THEN c.oid END) AS table_count,
                    COUNT(DISTINCT CASE WHEN c.relkind = 'i' THEN c.oid END) AS index_count,
                    COUNT(DISTINCT CASE WHEN c.relkind = 'v' THEN c.oid END) AS view_count,
                    COUNT(DISTINCT CASE WHEN c.relkind = 'S' THEN c.oid END) AS sequence_count,
                    string_agg(DISTINCT CASE WHEN c.relkind = 'r' THEN c.relname END, ', ') AS tables,
                    string_agg(DISTINCT CASE WHEN c.relkind = 'v' THEN c.relname END, ', ') AS views,
                    string_agg(DISTINCT CASE WHEN c.relkind = 'S' THEN c.relname END, ', ') AS sequences
                FROM pg_catalog.pg_namespace n
                LEFT JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
                    AND n.nspname NOT LIKE 'pg_toast%'
                    AND n.nspname NOT LIKE 'pg_temp%'
                GROUP BY n.nspname, n.nspowner, n.oid
            ),
            function_info AS (
                SELECT
                    n.nspname AS schema_name,
                    COUNT(*) AS function_count,
                    string_agg(p.proname, ', ' ORDER BY p.proname) AS functions
                FROM pg_catalog.pg_proc p
                JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
                GROUP BY n.nspname
            ),
            privileges_info AS (
                SELECT
                    nspname AS schema_name,
                    pg_catalog.array_to_string(nspacl, '; ') AS privileges
                FROM pg_catalog.pg_namespace
                WHERE nspname NOT IN ('pg_catalog', 'information_schema')
                    AND nspname NOT LIKE 'pg_toast%'
                    AND nspname NOT LIKE 'pg_temp%'
            )
            SELECT
                s.schema_name,
                s.owner,
                s.size,
                s.size_bytes,
                s.table_count,
                s.index_count,
                s.view_count,
                s.sequence_count,
                COALESCE(f.function_count, 0) AS function_count,
                COALESCE(s.tables, '') AS tables,
                COALESCE(s.views, '') AS views,
                COALESCE(s.sequences, '') AS sequences,
                COALESCE(f.functions, '') AS functions,
                COALESCE(p.privileges, '') AS privileges
            FROM schema_info s
            LEFT JOIN function_info f ON s.schema_name = f.schema_name
            LEFT JOIN privileges_info p ON s.schema_name = p.schema_name
            ORDER BY s.size_bytes DESC;" \
            "${output_file}" \
            "23"
        
        # ===== BLUE/GREEN DEPLOYMENT SPECIFIC CHECKS =====
        # These checks are only executed when --blue-green flag is provided
        
        if [ "$BLUE_GREEN_MODE" = true ]; then
            echo ""
            echo -e "${YELLOW}Running Blue/Green Deployment Specific Checks (24-34)...${NC}"
            echo ""
        
        # Check 24: Version Compatibility and Upgrade Path
        echo "Checking version compatibility and valid upgrade targets..."
        local current_version
        current_version=$(PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SHOW server_version;" 2>/dev/null | xargs | cut -d' ' -f1)        
        local version_check_result=""
        local version_check_status="SUCCESS"
        
        if [ -n "$current_version" ]; then
            # Determine engine type for AWS CLI query
            local engine_param="postgres"
            if [ "$ENGINE_TYPE" == "aurora-postgresql" ]; then
                engine_param="aurora-postgresql"
            fi
            
            # Get valid upgrade targets from AWS
            local upgrade_targets
            upgrade_targets=$(aws rds describe-db-engine-versions \
                --engine "${engine_param}" \
                --engine-version "${current_version}" \
                --region "${AWS_REGION}" \
                --profile "${AWS_PROFILE}" \
                --query "DBEngineVersions[*].ValidUpgradeTarget[*].{EngineVersion:EngineVersion,AutoUpgrade:AutoUpgrade,IsMajorVersionUpgrade:IsMajorVersionUpgrade}" \
                --output json 2>&1)
            
            local _rc=$?
            if [ $_rc -eq 0 ] && echo "$upgrade_targets" | jq empty 2>/dev/null; then
                local target_count
                target_count=$(echo "$upgrade_targets" | jq -r '.[0] | length' 2>/dev/null || echo "0")                
                if [ "$target_count" -gt 0 ]; then
                    # Format the upgrade targets as text table with proper spacing
                    version_check_result="Current Version: ${current_version}

Valid Upgrade Targets (${target_count} available):

"
                    version_check_result="${version_check_result}$(printf '%-24s %-22s %s\n' 'Target Version' 'Major Version Upgrade' 'Auto Upgrade')"
                    version_check_result="${version_check_result}$(printf '%-24s %-22s %s\n' '------------------------' '----------------------' '-------------')"
                    
                    for i in $(seq 0 $((target_count - 1))); do
                        local target_version
                        target_version=$(echo "$upgrade_targets" | jq -r ".[0][$i].EngineVersion" 2>/dev/null || echo "N/A")
                        local is_major
                        is_major=$(echo "$upgrade_targets" | jq -r ".[0][$i].IsMajorVersionUpgrade" 2>/dev/null || echo "false")
                        local auto_upgrade
                        auto_upgrade=$(echo "$upgrade_targets" | jq -r ".[0][$i].AutoUpgrade" 2>/dev/null || echo "false")                        
                        version_check_result="${version_check_result}$(printf '%-24s %-22s %s\n' "${target_version}" "${is_major}" "${auto_upgrade}")"
                    done
                    
                    version_check_result="${version_check_result}

Recommendation: Review release notes for target version and all intermediate 
versions before proceeding with blue/green deployment."
                    version_check_status="SUCCESS"
                else
                    version_check_result="Current Version: ${current_version}

Warning: No valid upgrade targets found. This may indicate the version is 
already at the latest or requires manual verification."
                    version_check_status="WARNING"
                fi
            else
                version_check_result="Current Version: ${current_version}

Error: Unable to retrieve valid upgrade targets from AWS API

Details: ${upgrade_targets}"
                version_check_status="ERROR"
            fi
        else
            version_check_result="Error: Unable to retrieve current PostgreSQL version"
            version_check_status="ERROR"
        fi
        
        # Add the check result using standard function
        write_check_result "${output_file}" "Version Compatibility and Upgrade Path" "Valid upgrade targets for current version" "${version_check_result}" "${version_check_status}" "24"
        
        # Check 25: Parameter Group Configuration for Blue/Green
        execute_check \
            "Parameter Group Configuration for Blue/Green - what to check: \"The parameter rds.logical_replication should be On for logical replication. The parameters max_replication_slots and max_worker_processes should be at least one more than the number of user databases\"" \
            "Verify logical replication and replication parameters are properly configured for blue/green deployments" \
            "SELECT 
                name AS parameter_name,
                setting AS current_value,
                CASE 
                    WHEN name = 'rds.logical_replication' AND setting NOT IN ('on', '1') THEN 'CRITICAL - Must be enabled (on/1) for blue/green'
                    WHEN name = 'synchronous_commit' AND setting NOT IN ('on', '1') THEN 'WARNING - Should be ''on'' for data consistency'
                    WHEN name = 'max_replication_slots' AND setting::int < 10 THEN 'WARNING - Consider increasing for multiple databases'
                    WHEN name = 'max_wal_senders' AND setting::int < 10 THEN 'WARNING - Consider increasing for multiple databases'
                    WHEN name = 'max_logical_replication_workers' AND setting::int < 4 THEN 'WARNING - Consider increasing for better performance'
                    WHEN name = 'max_worker_processes' AND setting::int < 8 THEN 'WARNING - Consider increasing for parallel operations'
                    ELSE 'OK'
                END AS status,
                unit,
                context AS requires_restart
            FROM pg_settings 
            WHERE name IN (
                'rds.logical_replication',
                'synchronous_commit',
                'max_replication_slots',
                'max_wal_senders',
                'max_logical_replication_workers',
                'max_worker_processes'
            )
            ORDER BY 
                CASE 
                    WHEN name = 'rds.logical_replication' THEN 1
                    WHEN name = 'synchronous_commit' THEN 2
                    ELSE 3
                END;" \
            "${output_file}" \
            "25"
        
        # Check 26: Table Requirements for Blue/Green Deployments
        execute_check \
            "Table Requirements for Blue/Green Deployments - what to check: \"Tables without primary keys or REPLICA IDENTITY FULL cannot be replicated in blue/green deployments. Add primary keys or set REPLICA IDENTITY FULL for affected tables.\"" \
            "Verify all tables have primary keys or REPLICA IDENTITY FULL (required for logical replication)" \
            "WITH no_primary_key_or_replica_identity AS (
                SELECT 
                    n.nspname AS schema_name,
                    c.relname AS table_name,
                    CASE c.relreplident
                        WHEN 'd' THEN 'default (no replica identity)'
                        WHEN 'n' THEN 'nothing'
                        WHEN 'f' THEN 'full'
                        WHEN 'i' THEN 'index'
                    END AS replica_identity,
                    CASE 
                        WHEN i.indisprimary IS NULL THEN 'No primary key'
                        ELSE 'Has primary key'
                    END AS primary_key_status,
                    CASE 
                        WHEN i.indisprimary IS NULL AND c.relreplident = 'd' THEN 'CRITICAL - Missing primary key or replica identity'
                        WHEN i.indisprimary IS NULL AND c.relreplident != 'f' THEN 'WARNING - No primary key, replica identity not FULL'
                        ELSE 'OK'
                    END AS status,
                    pg_size_pretty(pg_total_relation_size(c.oid)) AS table_size
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
                WHERE c.relkind = 'r'
                    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                    AND n.nspname NOT LIKE 'pg_toast%'
                    AND n.nspname NOT LIKE 'pg_temp%'
            )
            SELECT 
                schema_name,
                table_name,
                replica_identity,
                primary_key_status,
                status,
                table_size
            FROM no_primary_key_or_replica_identity
            WHERE status != 'OK'
            ORDER BY 
                CASE 
                    WHEN status LIKE 'CRITICAL%' THEN 1
                    WHEN status LIKE 'WARNING%' THEN 2
                    ELSE 3
                END,
                schema_name,
                table_name;" \
            "${output_file}" \
            "26"
        
        # Check 27: Foreign Tables Check for Blue/Green Deployments
        execute_check \
            "Foreign Tables Check for Blue/Green Deployments - what to check: \"These tables will not be replicated using blue/green deployments but will not break replication.\"" \
            "List foreign tables that will not be replicated during blue/green deployment" \
            "SELECT 
                foreign_table_schema,
                foreign_table_name,
                foreign_server_name
            FROM information_schema.foreign_tables
            ORDER BY foreign_table_schema, foreign_table_name;" \
            "${output_file}" \
            "27"
        
        # Check 28: Unlogged Tables Check for Blue/Green Deployments
        execute_check \
            "Unlogged Tables Check for Blue/Green Deployments - what to check: \"Unlogged tables are not replicated to green environment\"" \
            "Check for unlogged tables that will not be replicated during blue/green deployment" \
            "SELECT 
                n.nspname AS schema_name,
                c.relname AS table_name,
                pg_size_pretty(pg_total_relation_size(c.oid)) AS table_size,
                'CRITICAL - Unlogged table will not be replicated' AS issue
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relpersistence = 'u'
                AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                AND n.nspname NOT LIKE 'pg_toast%'
            ORDER BY pg_total_relation_size(c.oid) DESC;" \
            "${output_file}" \
            "28"
        
        # Check 29: Publications Check for Blue/Green Deployments
        execute_check \
            "Publications Check for Blue/Green Deployments - what to check: \"The blue DB instance can't be a logical source (publisher) or replica (subscriber).\"" \
            "Check for publications - blue instance cannot be a logical publisher" \
            "SELECT 
                pubname AS publication_name,
                puballtables AS publishes_all_tables,
                pubinsert AS allows_insert,
                pubupdate AS allows_update,
                pubdelete AS allows_delete,
                pubtruncate AS allows_truncate,
                'CRITICAL - Instance is a logical publisher' AS issue
            FROM pg_publication;" \
            "${output_file}" \
            "29"
        
        # Check 30: Subscriptions Check for Blue/Green Deployments
        execute_check \
            "Subscriptions Check for Blue/Green Deployments - what to check: \"The blue DB instance can't be a logical source (publisher) or replica (subscriber).\"" \
            "Check for subscriptions - blue instance cannot be a logical subscriber" \
            "SELECT 
                subname AS subscription_name,
                subenabled AS enabled,
                'CRITICAL - Instance is a logical subscriber' AS issue
            FROM pg_subscription;" \
            "${output_file}" \
            "30"
        
        # Check 31: Foreign Data Wrapper Endpoint Check for Blue/Green Deployments
        execute_check \
            "Foreign Data Wrapper Endpoint Check for Blue/Green Deployments - what to check: \"If the blue DB instance is configured as the foreign server of a foreign data wrapper (FDW) extension, you must use the instance endpoint name instead of IP addresses. This allows the configuration to remain functional after switchover.\"" \
            "Check if FDW uses endpoint names instead of IP addresses" \
            "SELECT 
                srvname AS server_name,
                srvoptions AS options,
                CASE 
                    WHEN srvoptions::text ~ '\d+\.\d+\.\d+\.\d+' THEN 'WARNING - FDW may use IP address instead of endpoint name'
                    ELSE 'OK - No IP pattern detected'
                END AS issue
            FROM pg_foreign_server;" \
            "${output_file}" \
            "31"
        
        # Check 32: High Write Volume Tables Check for Blue/Green Deployments
        execute_check \
            "High Write Volume Tables Check for Blue/Green Deployments - what to check: \"The logical replication apply process in the green environment is single-threaded. If the blue environment generates a high volume of write traffic, the green environment might not be able to keep up. This can lead to replication lag or failure, especially for workloads that produce continuous high write throughput. Make sure to test your workloads thoroughly. For scenarios that require major version upgrades and handling high-volume write workloads, consider alternative approaches such as using AWS Database Migration Service (AWS DMS).\"" \
            "Check for tables with high write volume (>1,000,000 writes)" \
            "SELECT 
                schemaname,
                relname AS table_name,
                n_tup_ins + n_tup_upd + n_tup_del AS total_writes,
                n_tup_ins AS inserts,
                n_tup_upd AS updates,
                n_tup_del AS deletes,
                CASE 
                    WHEN (n_tup_ins + n_tup_upd + n_tup_del) > 1000000 THEN 'WARNING - High write volume table'
                    ELSE 'OK'
                END AS issue
            FROM pg_stat_user_tables
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY total_writes DESC
            LIMIT 20;" \
            "${output_file}" \
            "32"
        
        # Check 33: Partitioned Tables Check for Blue/Green Deployments
        execute_check \
            "Partitioned Tables Check for Blue/Green Deployments - what to check: \"Creating new partitions on partitioned tables isn't supported during blue/green deployments for RDS for PostgreSQL. Creating new partitions involves data definition language (DDL) operations such as CREATE TABLE, which aren't replicated from the blue environment to the green environment. However, existing partitioned tables and their data will be replicated to the green environment.\"" \
            "Check for partitioned tables - new partition creation not supported during deployment" \
            "SELECT 
                n.nspname AS schema_name,
                c.relname AS table_name,
                pg_get_partkeydef(c.oid) AS partition_key,
                CASE c.relkind
                    WHEN 'p' THEN 'Partitioned Table'
                    WHEN 'r' THEN 'Regular Table (Partition)'
                END AS table_type,
                (SELECT count(*) 
                 FROM pg_inherits i 
                 WHERE i.inhparent = c.oid) AS number_of_partitions
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'p'
                AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY n.nspname, c.relname;" \
            "${output_file}" \
            "33"
        
        # Check 34: Blue/Green Extension Compatibility Check
        execute_check \
            "Blue/Green Extension Compatibility Check - what to check: \"The following limitations apply to PostgreSQL extensions: The pg_partman extension must be disabled in the blue environment when you create a blue/green deployment. The extension performs DDL operations such as CREATE TABLE, which break logical replication from the blue environment to the green environment. The pg_cron extension must remain disabled on all green databases after the blue/green deployment is created. The extension has background workers that run as superuser and bypass the read-only setting of the green environment, which might cause replication conflicts. The pglogical and pgactive extensions must be disabled on the blue environment when you create a blue/green deployment. After you switch over the green environment to be the new production environment, you can enable the extensions again. In addition, the blue database can't be a logical subscriber of an external instance. If you're using the pgAudit extension, it must remain in the shared libraries (shared_preload_libraries) on the custom DB parameter groups for both the blue and the green DB instances.\"" \
            "Check for extensions with blue/green deployment limitations" \
            "SELECT 
                e.extname AS extension_name,
                n.nspname AS schema_name,
                CASE 
                    WHEN e.extname IN ('pg_partman', 'pglogical', 'pgactive') THEN 'CRITICAL - Must be disabled before blue/green deployment'
                    WHEN e.extname = 'pg_cron' THEN 'CRITICAL - Must remain disabled on green databases'
                    WHEN e.extname = 'pgaudit' THEN 'WARNING - Must remain in shared_preload_libraries'
                    ELSE 'OK'
                END AS issue
            FROM pg_extension e
            JOIN pg_namespace n ON n.oid = e.extnamespace
            WHERE e.extname IN ('pg_partman', 'pg_cron', 'pglogical', 'pgactive', 'pgaudit')
            ORDER BY 
                CASE 
                    WHEN e.extname IN ('pg_partman', 'pglogical', 'pgactive', 'pg_cron') THEN 1
                    ELSE 2
                END;
            
            -- Check shared_preload_libraries for pgaudit
            SELECT 
                name,
                setting,
                CASE 
                    WHEN setting LIKE '%pgaudit%' THEN 'WARNING - pgaudit is in shared_preload_libraries'
                    ELSE 'INFO - pgaudit not found in shared_preload_libraries'
                END AS issue
            FROM pg_settings
            WHERE name = 'shared_preload_libraries';" \
            "${output_file}" \
            "34"
        
        # Check 35: DDL Event Triggers Check
        execute_check \
            "DDL Event Triggers Check - what to check: \"DDL event triggers (ddl_command_start, ddl_command_end, sql_drop) may interfere with Blue/Green deployment. They can be triggered during CREATE SUBSCRIPTION on the green instance. Consider disabling them before creating the Blue/Green deployment.\"" \
            "Check for DDL event triggers that may interfere with Blue/Green deployment" \
            "SELECT
                evtname AS trigger_name,
                evtevent AS event,
                evtfoid::regproc AS function_name,
                CASE evtenabled
                    WHEN 'O' THEN 'enabled'
                    WHEN 'D' THEN 'disabled'
                    WHEN 'R' THEN 'replica'
                    WHEN 'A' THEN 'always'
                END AS status,
                'WARNING - DDL trigger may interfere with Blue/Green deployment' AS recommendation
            FROM pg_event_trigger
            WHERE evtevent IN ('ddl_command_start', 'ddl_command_end', 'sql_drop')
              AND evtname != 'dts_capture_catalog_start'
            ORDER BY evtname;" \
            "${output_file}" \
            "35"
        
        # Check 35b: DTS Trigger Check
        execute_check \
            "DTS Trigger Check - what to check: \"The DTS trigger 'dts_capture_catalog_start' will cause Blue/Green deployment to fail. Drop this trigger before creating the Blue/Green deployment.\"" \
            "Check for DTS trigger that causes Blue/Green deployment failure" \
            "SELECT
                evtname AS trigger_name,
                evtevent AS event,
                evtfoid::regproc AS function_name,
                'CRITICAL - DTS trigger will cause Blue/Green deployment to fail. Drop before upgrade.' AS issue
            FROM pg_event_trigger
            WHERE evtname = 'dts_capture_catalog_start';" \
            "${output_file}" \
            "35b"
        
        # Check 35c: max_locks_per_transaction Validation (all databases)
        execute_max_locks_all_dbs "${output_file}" "35c"
        
        else
            echo ""
            echo -e "${YELLOW}Skipping Blue/Green Deployment Checks (24-35c) - use --blue-green flag to enable${NC}"
            echo ""
        fi
        
        # ===== CRITICAL UPGRADE BLOCKER CHECKS =====
        # These checks are always executed regardless of blue/green mode
        
        echo ""
        echo -e "${YELLOW}Running Critical Upgrade Blocker Checks (36-46)...${NC}"
        echo ""
        
        # Check 36: chkpass Extension Check - Only for PG <= 11
        if [ "$PG_MAJOR_VERSION" -le 11 ]; then
            execute_check_all_dbs \
                "chkpass Extension Check" \
                "Check for chkpass extension (not supported in PostgreSQL >= 11) across all databases" \
                "SELECT current_database() AS database_name,
                    extname AS extension_name,
                    extversion AS version,
                    n.nspname AS schema,
                    'CRITICAL - chkpass extension not supported in PostgreSQL >= 11' AS issue
                FROM pg_extension e
                JOIN pg_namespace n ON e.extnamespace = n.oid
                WHERE extname = 'chkpass'
                ORDER BY n.nspname;" \
                "${output_file}" \
                "36"
        else
            echo "Skipping Check 36 (chkpass Extension) - Not applicable for PostgreSQL > 11"
        fi
        
        # Check 37: tsearch2 Extension Check - Only for PG <= 11
        if [ "$PG_MAJOR_VERSION" -le 11 ]; then
            execute_check_all_dbs \
                "tsearch2 Extension Check" \
                "Check for tsearch2 extension (not supported in PostgreSQL >= 11) across all databases" \
                "SELECT current_database() AS database_name,
                    extname AS extension_name,
                    extversion AS version,
                    n.nspname AS schema,
                    'CRITICAL - tsearch2 extension not supported in PostgreSQL >= 11' AS issue
                FROM pg_extension e
                JOIN pg_namespace n ON e.extnamespace = n.oid
                WHERE extname = 'tsearch2'
                ORDER BY n.nspname;" \
                "${output_file}" \
                "37"
        else
            echo "Skipping Check 37 (tsearch2 Extension) - Not applicable for PostgreSQL > 11"
        fi
        
        # Check 38: pg_repack Extension Check - Only for PG <= 14
        if [ "$PG_MAJOR_VERSION" -le 14 ]; then
            execute_check_all_dbs \
                "pg_repack Extension Check" \
                "Check for pg_repack extension (must be dropped before PostgreSQL >= 14) across all databases" \
                "SELECT current_database() AS database_name,
                    extname AS extension_name,
                    extversion AS version,
                    n.nspname AS schema,
                    'CRITICAL - pg_repack must be dropped before upgrade to PostgreSQL >= 14' AS issue
                FROM pg_extension e
                JOIN pg_namespace n ON e.extnamespace = n.oid
                WHERE extname = 'pg_repack'
                ORDER BY n.nspname;" \
                "${output_file}" \
                "38"
        else
            echo "Skipping Check 38 (pg_repack Extension) - Not applicable for PostgreSQL > 14"
        fi
        
        # Check 39: System-Defined Composite Types Check (all databases)
        execute_check_all_dbs \
            "System-Defined Composite Types in User Tables - what to check: \"Your installation contains system-defined composite types in user tables. These type OIDs are not stable across PostgreSQL versions. Please drop the problem columns before upgrade\"" \
            "Check for system-defined composite types in user tables (OIDs not stable across versions)" \
            "WITH RECURSIVE oids AS (
                SELECT t.oid 
                FROM pg_catalog.pg_type t 
                LEFT JOIN pg_catalog.pg_namespace n ON t.typnamespace = n.oid  
                WHERE typtype = 'c' AND (t.oid < 16384 OR nspname = 'information_schema')
                UNION ALL
                SELECT * FROM (
                    WITH x AS (SELECT oid FROM oids)
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                    WHERE t.typtype = 'c' AND
                        t.oid = c.reltype AND
                        c.oid = a.attrelid AND
                        NOT a.attisdropped AND
                        a.atttypid = x.oid
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                    WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                ) foo
            )
            SELECT 
                n.nspname AS schema_name,
                c.relname AS table_name,
                a.attname AS column_name,
                'CRITICAL - System-defined composite type with unstable OID' AS issue
            FROM pg_catalog.pg_class c,
                pg_catalog.pg_namespace n,
                pg_catalog.pg_attribute a
            WHERE c.oid = a.attrelid AND
                NOT a.attisdropped AND
                a.atttypid IN (SELECT oid FROM oids) AND
                c.relkind IN ('r', 'm', 'i') AND
                c.relnamespace = n.oid AND
                n.nspname !~ '^pg_temp_' AND
                n.nspname !~ '^pg_toast_temp_' AND
                n.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY n.nspname, c.relname, a.attname;" \
            "${output_file}" \
            "39"
        
        # Check 39b: reg* Data Types in User Tables (all databases)
        # More comprehensive check using recursive CTE (from GitHub awslabs script)
        execute_check_all_dbs \
            "reg* Data Types in User Tables Check - what to check: \"Your installation contains reg* data types in user tables. These data types reference system OIDs that are not preserved by pg_upgrade. Please drop the problem columns before upgrade.\"" \
            "Check for reg* data types in user tables (OIDs not preserved across upgrade)" \
            "WITH RECURSIVE oids AS (
                SELECT oid FROM pg_catalog.pg_type t
                WHERE t.typnamespace = (
                    SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'pg_catalog'
                )
                AND t.typname IN (
                    'regcollation', 'regconfig', 'regdictionary', 'regnamespace',
                    'regoper', 'regoperator', 'regproc', 'regprocedure'
                )
                UNION ALL
                SELECT * FROM (
                    WITH x AS (SELECT oid FROM oids)
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                    WHERE t.typtype = 'c' AND
                        t.oid = c.reltype AND
                        c.oid = a.attrelid AND
                        NOT a.attisdropped AND
                        a.atttypid = x.oid
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                    WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                ) foo
            )
            SELECT
                n.nspname AS schema_name,
                c.relname AS table_name,
                a.attname AS column_name,
                'CRITICAL - reg* data type references system OID not preserved by pg_upgrade' AS issue
            FROM pg_catalog.pg_class c,
                pg_catalog.pg_namespace n,
                pg_catalog.pg_attribute a
            WHERE c.oid = a.attrelid AND
                NOT a.attisdropped AND
                a.atttypid IN (SELECT oid FROM oids) AND
                c.relkind IN ('r', 'm', 'i') AND
                c.relnamespace = n.oid AND
                n.nspname !~ '^pg_temp_' AND
                n.nspname !~ '^pg_toast_temp_' AND
                n.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY n.nspname, c.relname, a.attname;" \
            "${output_file}" \
            "39b"
        
        # Check 40: aclitem Data Type Check - Only for PG <= 15 upgrading to >= 16 (all databases)
        # Note: This check is always run but only critical if upgrading from PG <= 15 to PG >= 16
        execute_check_all_dbs \
            "aclitem Data Type Check (PostgreSQL 16+ Incompatibility) - what to check: \"Your installation contains the 'aclitem' data type in user tables. The internal format of 'aclitem' changed in PostgreSQL version 16. Please drop the problem columns before upgrade\"" \
            "Check for aclitem data type in user tables (format changed in PostgreSQL 16). CRITICAL if upgrading from PG <= 15 to PG >= 16" \
            "WITH RECURSIVE oids AS (
                SELECT 'pg_catalog.aclitem'::pg_catalog.regtype AS oid
                UNION ALL
                SELECT * FROM (
                    WITH x AS (SELECT oid FROM oids)
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                    WHERE t.typtype = 'c' AND
                        t.oid = c.reltype AND
                        c.oid = a.attrelid AND
                        NOT a.attisdropped AND
                        a.atttypid = x.oid
                    UNION ALL
                    SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                    WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                ) foo
            )
            SELECT 
                n.nspname AS schema_name,
                c.relname AS table_name,
                a.attname AS column_name,
                'CRITICAL - aclitem format changed in PostgreSQL 16' AS issue
            FROM pg_catalog.pg_class c,
                pg_catalog.pg_namespace n,
                pg_catalog.pg_attribute a
            WHERE c.oid = a.attrelid AND
                NOT a.attisdropped AND
                a.atttypid IN (SELECT oid FROM oids) AND
                c.relkind IN ('r', 'm', 'i') AND
                c.relnamespace = n.oid AND
                n.nspname !~ '^pg_temp_' AND
                n.nspname !~ '^pg_toast_temp_' AND
                n.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY n.nspname, c.relname, a.attname;" \
            "${output_file}" \
            "40"
        
        # Check 41: sql_identifier Data Type Check - Only for PG < 12
        if [ "$PG_MAJOR_VERSION" -lt 12 ]; then
            execute_check_all_dbs \
                "sql_identifier Data Type Check (PostgreSQL 12+ Incompatibility)" \
                "Check for sql_identifier data type in user tables (format changed in PostgreSQL 12)" \
                "WITH RECURSIVE oids AS (
                    SELECT 'information_schema.sql_identifier'::pg_catalog.regtype AS oid
                    UNION ALL
                    SELECT * FROM (
                        WITH x AS (SELECT oid FROM oids)
                        SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                        UNION ALL
                        SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                        UNION ALL
                        SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                        WHERE t.typtype = 'c' AND
                            t.oid = c.reltype AND
                            c.oid = a.attrelid AND
                            NOT a.attisdropped AND
                            a.atttypid = x.oid
                        UNION ALL
                        SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                        WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                    ) foo
                )
                SELECT 
                    n.nspname AS schema_name,
                    c.relname AS table_name,
                    a.attname AS column_name,
                    'CRITICAL - sql_identifier format changed in PostgreSQL 12' AS issue
                FROM pg_catalog.pg_class c,
                    pg_catalog.pg_namespace n,
                    pg_catalog.pg_attribute a
                WHERE c.oid = a.attrelid AND
                    NOT a.attisdropped AND
                    a.atttypid IN (SELECT oid FROM oids) AND
                    c.relkind IN ('r', 'm', 'i') AND
                    c.relnamespace = n.oid AND
                    n.nspname !~ '^pg_temp_' AND
                    n.nspname !~ '^pg_toast_temp_' AND
                    n.nspname NOT IN ('pg_catalog', 'information_schema')
                ORDER BY n.nspname, c.relname, a.attname;" \
                "${output_file}" \
                "41"
        else
            echo "Skipping Check 41 (sql_identifier Data Type) - Not applicable for PostgreSQL >= 12"
        fi
        
        # Check 42: Removed Data Types Check (abstime, reltime, tinterval) - Only for PG < 12
        if [ "$PG_MAJOR_VERSION" -lt 12 ]; then
            execute_check_all_dbs \
                "Removed Data Types Check (abstime, reltime, tinterval)" \
                "Check for removed data types: abstime, reltime, tinterval (removed in PostgreSQL 12)" \
                "WITH RECURSIVE oids AS (
                    SELECT 'pg_catalog.abstime'::pg_catalog.regtype AS oid
                    UNION ALL
                    SELECT 'pg_catalog.reltime'::pg_catalog.regtype AS oid
                    UNION ALL
                    SELECT 'pg_catalog.tinterval'::pg_catalog.regtype AS oid
                    UNION ALL
                    SELECT * FROM (
                        WITH x AS (SELECT oid FROM oids)
                        SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                        UNION ALL
                        SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                        UNION ALL
                        SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                        WHERE t.typtype = 'c' AND
                            t.oid = c.reltype AND
                            c.oid = a.attrelid AND
                            NOT a.attisdropped AND
                            a.atttypid = x.oid
                        UNION ALL
                        SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                        WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                    ) foo
                )
                SELECT 
                    n.nspname AS schema_name,
                    c.relname AS table_name,
                    a.attname AS column_name,
                    t.typname AS data_type,
                    'CRITICAL - Data type removed in PostgreSQL 12' AS issue
                FROM pg_catalog.pg_class c,
                    pg_catalog.pg_namespace n,
                    pg_catalog.pg_attribute a,
                    pg_catalog.pg_type t
                WHERE c.oid = a.attrelid AND
                    NOT a.attisdropped AND
                    a.atttypid IN (SELECT oid FROM oids) AND
                    a.atttypid = t.oid AND
                    c.relkind IN ('r', 'm', 'i') AND
                    c.relnamespace = n.oid AND
                    n.nspname !~ '^pg_temp_' AND
                    n.nspname !~ '^pg_toast_temp_' AND
                    n.nspname NOT IN ('pg_catalog', 'information_schema')
                ORDER BY n.nspname, c.relname, a.attname;" \
                "${output_file}" \
                "42"
        else
            echo "Skipping Check 42 (Removed Data Types) - Not applicable for PostgreSQL >= 12"
        fi
        
        # Check 43: Tables WITH OIDS Check - Only for PG < 12
        if [ "$PG_MAJOR_VERSION" -lt 12 ]; then
            execute_check_all_dbs \
                "Tables WITH OIDS Check" \
                "Check for tables declared WITH OIDS (not supported in PostgreSQL >= 12)" \
                "SELECT 
                    n.nspname AS schema_name,
                    c.relname AS table_name,
                    'CRITICAL - Tables WITH OIDS not supported in PostgreSQL >= 12' AS issue
                FROM pg_catalog.pg_class c,
                    pg_catalog.pg_namespace n
                WHERE c.relnamespace = n.oid AND
                    c.relhasoids AND
                    n.nspname NOT IN ('pg_catalog', 'information_schema')
                ORDER BY n.nspname, c.relname;" \
                "${output_file}" \
                "43"
        else
            echo "Skipping Check 43 (Tables WITH OIDS) - Not applicable for PostgreSQL >= 12"
        fi
        
        # Check 44: User-Defined Encoding Conversions - Only for PG <= 14
        if [ "$PG_MAJOR_VERSION" -le 14 ]; then
            execute_check_all_dbs \
                "User-Defined Encoding Conversions Check - what to check: \"Your installation contains user-defined encoding conversions. The conversion function parameters changed in PostgreSQL version 14. Please remove the encoding conversions before upgrade.\"" \
                "Check for user-defined encoding conversions (not supported in PostgreSQL >= 14)" \
                "SELECT 
                    c.oid,
                    c.conname AS conversion_name,
                    n.nspname AS schema_name,
                    'CRITICAL - User-defined encoding conversions not supported in PostgreSQL >= 14' AS issue
                FROM pg_catalog.pg_conversion c
                JOIN pg_catalog.pg_namespace n ON c.connamespace = n.oid
                WHERE c.oid >= 16384
                ORDER BY n.nspname, c.conname;" \
                "${output_file}" \
                "44"
        else
            echo "Skipping Check 44 (User-Defined Encoding Conversions) - Not applicable for PostgreSQL > 14"
        fi
        
        # Check 45: User-Defined Postfix Operators - Only for PG <= 14
        if [ "$PG_MAJOR_VERSION" -le 14 ]; then
            execute_check_all_dbs \
                "User-Defined Postfix Operators Check - what to check: \"Your installation contains user-defined postfix operators, which are not supported anymore. Consider dropping the postfix operators and replacing them with prefix operators or function calls.\"" \
                "Check for user-defined postfix operators (not supported in PostgreSQL >= 14)" \
                "SELECT 
                    o.oid,
                    o.oprname AS operator_name,
                    n.nspname AS schema_name,
                    oprleft::regtype AS left_type,
                    'CRITICAL - Postfix operators not supported in PostgreSQL >= 14' AS issue
                FROM pg_catalog.pg_operator o
                JOIN pg_catalog.pg_namespace n ON o.oprnamespace = n.oid
                WHERE o.oprright = 0 AND o.oid >= 16384
                ORDER BY n.nspname, o.oprname;" \
                "${output_file}" \
                "45"
        else
            echo "Skipping Check 45 (User-Defined Postfix Operators) - Not applicable for PostgreSQL > 14"
        fi
        
        # Check 46: Incompatible Polymorphic Functions - Only for PG <= 14
        if [ "$PG_MAJOR_VERSION" -le 14 ]; then
            execute_check_all_dbs \
                "Incompatible Polymorphic Functions Check - what to check: \"Your installation contains user-defined objects that refer to internal polymorphic functions with arguments of type anyarray or anyelement. These user-defined objects must be dropped before upgrading and restored afterwards, changing them to refer to the new corresponding functions with arguments of type anycompatiblearray and anycompatible.\"" \
                "Check for functions using old polymorphic types (anyarray/anyelement changed in PostgreSQL 14)" \
                "SELECT 
                    p.oid,
                    p.proname AS function_name,
                    n.nspname AS schema_name,
                    pg_catalog.pg_get_function_identity_arguments(p.oid) AS arguments,
                    'CRITICAL - Polymorphic function signature incompatible with PostgreSQL >= 14' AS issue
                FROM pg_catalog.pg_proc p
                JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
                WHERE p.oid >= 16384
                AND (
                    -- Check for aggregates with anyarray/anyelement
                    (p.prokind = 'a' AND (
                        p.proargtypes::text ~ '2277' OR  -- anyarray
                        p.proargtypes::text ~ '2283'     -- anyelement
                    ))
                    OR
                    -- Check for operators with polymorphic types
                    EXISTS (
                        SELECT 1 FROM pg_catalog.pg_operator o
                        WHERE (o.oprcode = p.oid OR o.oprrest = p.oid OR o.oprjoin = p.oid)
                        AND (
                            o.oprleft::text ~ '2277|2283' OR
                            o.oprright::text ~ '2277|2283'
                        )
                    )
                )
                ORDER BY n.nspname, p.proname;" \
                "${output_file}" \
                "46"
        else
            echo "Skipping Check 46 (Incompatible Polymorphic Functions) - Not applicable for PostgreSQL > 14"
        fi
        
        # Close the checks table (HTML only)
        if [ "${REPORT_FORMAT}" != "text" ]; then
            cat >> "${output_file}" <<EOF
        </table>
EOF
        fi
    fi
    
    # Finalize report
    if [ "${REPORT_FORMAT}" = "text" ]; then
        finalize_text_report "${output_file}"
    else
        finalize_html "${output_file}"
    fi
    
    echo ""
    echo -e "${GREEN}✓ Report generated successfully: ${output_file}${NC}"
    echo ""
    if [ "${REPORT_FORMAT}" = "html" ]; then
        echo "You can open this file in a web browser to view the results."
    else
        echo "You can view this file with any text editor or pager."
    fi
    echo ""
    
    if [ "$RUN_MODE" = "rds" ] || [ "$RUN_MODE" = "both" ]; then
        echo "RDS checks performed:"
        echo "  - RDS instance configuration"
        echo "  - Performance Insights top queries"
        echo "  - CloudWatch metrics (15 days)"
        echo ""
    fi
    
    if [ "$RUN_MODE" = "sql" ] || [ "$RUN_MODE" = "both" ]; then
        echo "SQL checks performed:"
        echo "  - PostgreSQL version verification"
        echo "  - Database size and growth analysis"
        echo "  - Table and index health checks"
        echo "  - Bloat detection and vacuum status"
        echo "  - Replication status (if applicable)"
        echo "  - Configuration parameter review"
        echo "  - Extension compatibility check"
        echo "  - Transaction ID wraparound monitoring"
        echo ""
        echo "Blue/Green Deployment Specific Checks:"
        echo "  - Version compatibility and valid upgrade paths"
        echo "  - Parameter group configuration for logical replication"
        echo "  - Table replica identity verification (primary keys/REPLICA IDENTITY FULL)"
        echo ""
    fi
}

# Run main function with all arguments
main "$@"