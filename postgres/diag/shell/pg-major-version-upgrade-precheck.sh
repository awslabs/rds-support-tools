#!/bin/bash

#/
 #  Copyright 2016 Amazon.com, Inc. or its affiliates. 
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

##################
#

# Overview
# The Aurora/RDS PostgreSQL MVU (Major Version Upgrade) Pre-check Tool validates your database configuration and identifies potential compatibility issues before performing a major version upgrade.Detects incompatibilities and BGD issues for upgrade early, helping resolve 80-90% of upgrade problems before testing begins.

## Usage
# bash pg-major-version-upgrade-precheck.sh [endpoint] [port] [user] [TargetVersion]

# Pre-check Process
# 1. **Blue-Green Configuration Check** - Verifies whether blue-green related settings need to be configured
# 2. **Compatibility Analysis** - Identifies incompatible features and settings for the target version
# 3. **Summary Report** - Generates a comprehensive pre-check summary with findings and recommendations

# Output
# The tool provides:
# - List of incompatible components
# - Configuration recommendations
# - Pre-check summary report

#
#################

set -uo pipefail
# ============================================
# Aurora/RDS PostgreSQL Upgrade Precheck Script
# Supports: Target Major Version 11-17
# If the query returns results, the upgrade will fail.
# ============================================

HOST="${1:-}"
PORT="${2:-}"
USER="${3:-}"
TARGET_VERSION="${4:-}"

# Check required parameters
if [ -z "${HOST:-}" ] || [ -z "${PORT:-}" ] || [ -z "${USER:-}" ] || [ -z "${TARGET_VERSION:-}" ]; then
    echo "Usage: $0 <HOST> <PORT> <USER> <TARGET_VERSION>"
    exit 1
fi

# Validate input parameters
if [ ${#HOST} -gt 253 ] || [[ ! "$HOST" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "❌ ERROR: Invalid hostname format"
    exit 1
fi

if [ ${#PORT} -gt 5 ] || [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "❌ ERROR: Invalid port number (must be 1-65535)"
    exit 1
fi

if [ ${#USER} -gt 63 ] || [[ ! "$USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "❌ ERROR: Invalid username format"
    exit 1
fi

if ! [[ "$TARGET_VERSION" =~ ^(11|12|13|14|15|16|17)$ ]]; then
    echo "❌ ERROR: Invalid target version '$TARGET_VERSION'"
    echo "   Supported versions: 11, 12, 13, 14, 15, 16, 17"
    exit 1
fi

read -rs -p "Enter PostgreSQL password: " PGPASSWORD
echo ""
export PGPASSWORD
export PGCONNECT_TIMEOUT=10

PSQL="psql -h $HOST -p $PORT -U $USER sslmode=require"

# ============================================
# Auto-detect source version
# ============================================
SOURCE_VERSION=$($PSQL -d postgres -t -A -c "SHOW server_version_num;" 2>/dev/null)
if [ -z "$SOURCE_VERSION" ]; then
    echo "❌ ERROR: Unable to connect to database. Please verify credentials and connectivity."
    exit 1
fi

# Convert version number (e.g., 130012 -> 13, 150004 -> 15)
MAJOR_VERSION=$((SOURCE_VERSION / 10000))

echo "============================================"
echo "Aurora/RDS PostgreSQL Upgrade Precheck"
echo "============================================"
echo "Host: $HOST"
echo "Port: $PORT"
echo "User: $USER"
echo "Source Version: $MAJOR_VERSION (detected)"
echo "Target Version: $TARGET_VERSION"
echo "============================================"

# Version check: source must be less than target
if [ "$MAJOR_VERSION" -ge "$TARGET_VERSION" ]; then
    echo "❌ ERROR: Source version ($MAJOR_VERSION) >= Target version ($TARGET_VERSION)"
    echo "   This precheck is for upgrading TO version $TARGET_VERSION."
    exit 1
fi

echo "✓ Version check passed: $MAJOR_VERSION -> $TARGET_VERSION"

# ============================================
# Ask if Blue/Green deployment check is needed
# ============================================
echo ""
while true; do
    read -rp "Do you need Blue/Green deployment checks? (yes/no): " BG_DEPLOY
    BG_DEPLOY=$(echo "$BG_DEPLOY" | tr '[:upper:]' '[:lower:]')
    if [[ "$BG_DEPLOY" =~ ^(yes|y|no|n)$ ]]; then
        break
    fi
    echo "Invalid input. Please enter 'yes' or 'no'."
done

echo ""
echo "============================================"
echo "Starting Precheck..."
echo "============================================"
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# Get all user databases
DBS=$($PSQL -d postgres -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('rdsadmin', 'template0', 'template1');")

# Filter out invalid database names
VALID_DBS=""
for db in $DBS; do
    if [[ "$db" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        VALID_DBS="${VALID_DBS}${db}"$'\n'
    else
        echo "⚠️ WARN: Skipping invalid database name: $db"
    fi
done
DBS=$(echo "$VALID_DBS" | sed '/^$/d')
DB_COUNT=$(echo "$DBS" | wc -l | tr -d ' ')

ERRORS=0
WARNS=0
FAILED_CHECKS=()
WARN_CHECKS=()

# ============================================

# ============================================
# SECTION 1: Aurora/RDS Precheck (pg_upgrade_precheck.log)
# ============================================
echo ""
echo "============================================"
echo "SECTION 1: Aurora/RDS Precheck (pg_upgrade_precheck.log)"
echo "============================================"

# --------------------------------------------
# A-1. check_for_prepared_transactions
# --------------------------------------------
echo ""
echo "=== A-1. check_for_prepared_transactions ==="
result=$($PSQL -d postgres -t -A -c "SELECT count(*) FROM pg_prepared_xacts;")
if [ "${result:-0}" -gt 0 ]; then
    echo "❌ ERROR: Uncommitted prepared transactions exist"
    echo "   Please commit or rollback all prepared transactions and try again."
    $PSQL -d postgres -c "SELECT gid, prepared, owner, database FROM pg_prepared_xacts;"
    ((ERRORS++))
    FAILED_CHECKS+=("A-1. check_for_prepared_transactions")
else
    echo "✓ OK"
fi

# --------------------------------------------
# A-2. check_database_not_allow_connect
# --------------------------------------------
echo ""
echo "=== A-2. check_database_not_allow_connect ==="
result=$($PSQL -d postgres -t -A -c "
SELECT datname FROM pg_database
WHERE datname != 'template0' AND datallowconn = 'false';")
if [ -n "$result" ]; then
    echo "❌ ERROR: Database connection settings error"
    echo "   Please ensure all non-template0 databases allow connections and try again."
    echo "$result"
    ((ERRORS++))
    FAILED_CHECKS+=("A-2. check_database_not_allow_connect")
else
    echo "✓ OK"
fi

# --------------------------------------------
# A-3. check_template_0_1
# --------------------------------------------
echo ""
echo "=== A-3. check_template_0_and_template1  ==="
result=$($PSQL -d postgres -t -A -c "SELECT count(*) FROM pg_database WHERE datistemplate = 't' AND datname IN ('template1','template0');")
if [ "$result" -ne 2 ]; then
    echo "❌ ERROR: template1 and tempate0 are invalid (must exist with datistemplate = true)"
    echo "   Make sure that template1 and template0 exists and has datistemplate set to 't'."
    ((ERRORS++))
    FAILED_CHECKS+=("A-3. check_template_0_and_template1")
else
    echo "✓ OK"
fi

# --------------------------------------------
# A-4. INVALID_DATABASE (datconnlimit = -2)
# --------------------------------------------
echo ""
echo "=== A-4. check_for_invalid_database ==="
result=$($PSQL -d postgres -t -A -c "SELECT datname FROM pg_database WHERE datconnlimit = -2;")
if [ -n "$result" ]; then
    echo "❌ ERROR: Invalid database(s) found (datconnlimit = -2)"
    echo "   To identify invalid databases, run 'SELECT datname FROM pg_catalog.pg_database WHERE datconnlimit = -2;', remove them with 'DROP DATABASE', and try again."
    echo "$result"
    ((ERRORS++))
    FAILED_CHECKS+=("A-4. check_for_invalid_database")
else
    echo "✓ OK"
fi

# --------------------------------------------
# A-5. DATABASE_HAS_REPLICATION_SLOTS
# --------------------------------------------
echo ""
echo "=== A-5. check_for_replication_slots ==="
if [ "$MAJOR_VERSION" -lt 17 ]; then
    slot_count=$($PSQL -d postgres -t -A -c "SELECT count(*) FROM pg_replication_slots;")
    if [ "${slot_count:-0}" -gt 0 ]; then
        echo "❌ ERROR: $slot_count logical replication slot(s) exist - must be dropped before upgrade"
        echo "   Please drop all logical replication slots and try again."
        $PSQL -d postgres -c "SELECT slot_name, plugin, slot_type, database, active FROM pg_replication_slots WHERE slot_type = 'logical';"
        ((ERRORS++))
        FAILED_CHECKS+=("A-5. check_for_replication_slots")
    else
        echo "✓ OK"
    fi
else
    echo "  Skipped (APG 17+ supports logical slot migration)"
fi

# --------------------------------------------
# A-6. CHKPASS_INSTALLED (target >= 11)
# --------------------------------------------
echo ""
echo "=== A-6. check_chkpass_extension ==="
if [ "$TARGET_VERSION" -ge 11 ]; then
    A6_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "SELECT extname FROM pg_extension WHERE extname = 'chkpass';" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: chkpass extension installed - not supported in PG >= 11"
            echo "   This extension is not supported in the target version.  Please drop the extension and try again."
            ((ERRORS++))
            A6_FAILED=1
        fi
    done
    [ "$A6_FAILED" -eq 1 ] && FAILED_CHECKS+=("A-6. check_chkpass_extension")
    [ "$A6_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (target version < 11)"
fi

# --------------------------------------------
# A-7. TSEARCH2_INSTALLED (target >= 11)
# --------------------------------------------
echo ""
echo "=== A-7. check_tsearch2_extension ==="
if [ "$TARGET_VERSION" -ge 11 ]; then
    A7_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "SELECT extname FROM pg_extension WHERE extname = 'tsearch2';" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: tsearch2 extension installed - not supported in PG >= 11"
            echo "   This extension is not supported in the target version.  Please drop the extension and try again."
            ((ERRORS++))
            A7_FAILED=1
        fi
    done
    [ "$A7_FAILED" -eq 1 ] && FAILED_CHECKS+=("A-7. check_tsearch2_extension")
    [ "$A7_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (target version < 11)"
fi

# --------------------------------------------
# A-8. PG_REPACK_INSTALLED (target >= 14)
# --------------------------------------------
echo ""
echo "=== A-8. check_pg_repack_extension ==="
if [ "$TARGET_VERSION" -ge 14 ]; then
    A8_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "SELECT extversion FROM pg_extension WHERE extname = 'pg_repack';" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: pg_repack $result installed - must be dropped before upgrade to PG >= 14"
            echo "   Drop the extension and try again."
            ((ERRORS++))
            A8_FAILED=1
        fi
    done
    [ "$A8_FAILED" -eq 1 ] && FAILED_CHECKS+=("A-8. check_pg_repack_extension")
    [ "$A8_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (target version < 14)"
fi

# --------------------------------------------
# A-9. CHECK_FOR_MULTI_EXTENSION_VERSION
# Check if installed extensions need to be updated before upgrade
# --------------------------------------------
echo ""
echo "=== A-9. check_for_multi_extensions_version ==="
A9_FAILED=0
MULTI_EXTENSIONS="postgis pgrouting postgis_raster postgis_tiger_geocoder postgis_topology address_standardizer address_standardizer_data_us rdkit"
for db in $DBS; do
    for ext in $MULTI_EXTENSIONS; do
        result=$($PSQL -d "$db" -t -A -c "
            SELECT name || '|' || installed_version || '|' || default_version 
            FROM pg_available_extensions 
            WHERE name = '$ext' 
              AND installed_version IS NOT NULL 
              AND default_version != installed_version;" 2>/dev/null)
        if [ -n "$result" ]; then
            ext_name=$(echo "$result" | cut -d'|' -f1)
            installed_ver=$(echo "$result" | cut -d'|' -f2)
            default_ver=$(echo "$result" | cut -d'|' -f3)
            echo "⚠️ WARN [$db]: $ext_name installed: $installed_ver, available: $default_ver"
            echo "   You can either drop the extension or upgrade the extension and try the upgrade again."
            ((WARNS++))
            A9_FAILED=1
        fi
    done
done
[ "$A9_FAILED" -eq 1 ] && WARN_CHECKS+=("A-9. check_for_multi_extensions_version")
[ "$A9_FAILED" -eq 0 ] && echo "✓ OK"

# ============================================
# SECTION 2: Engine Checks (pg_upgrade_internal.log)
# ============================================
echo ""
echo "============================================"
echo "SECTION 2: Engine Checks (pg_upgrade_internal.log)"
echo "============================================"

# --------------------------------------------
# E-1. Checking for system-defined composite types in user tables 
# --------------------------------------------
echo ""
echo "=== E-1. Checking for system-defined composite types in user tables ==="
E1_FAILED=0
for db in $DBS; do
    result=$($PSQL -d "$db" -t -A -c "
    WITH RECURSIVE oids AS (     SELECT t.oid FROM pg_catalog.pg_type t LEFT JOIN pg_catalog.pg_namespace n ON t.typnamespace = n.oid  WHERE typtype = 'c' AND (t.oid < 16384 OR nspname = 'information_schema')     UNION ALL   SELECT * FROM (         WITH x AS (SELECT oid FROM oids)            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'           UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'           UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x             WHERE t.typtype = 'c' AND                 t.oid = c.reltype AND                   c.oid = a.attrelid AND                  NOT a.attisdropped AND                  a.atttypid = x.oid            UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid   ) foo ) SELECT n.nspname, c.relname, a.attname FROM pg_catalog.pg_class c,      pg_catalog.pg_namespace n,      pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND      NOT a.attisdropped AND      a.atttypid IN (SELECT oid FROM oids) AND        c.relkind IN ('r', 'm', 'i') AND        c.relnamespace = n.oid AND      n.nspname !~ '^pg_temp_' AND        n.nspname !~ '^pg_toast_temp_' AND      n.nspname NOT IN ('pg_catalog', 'information_schema');
    " 2>/dev/null)
    if [ -n "$result" ]; then
        echo "❌ ERROR [$db]: System-defined composite types in user tables"
        echo "   Your installation contains system-defined composite types in user tables."
        echo "   These type OIDs are not stable across PostgreSQL versions."
        echo "   Please drop the problem columns and try again."
        $PSQL -d "$db" -c "
        WITH RECURSIVE oids AS (     SELECT t.oid FROM pg_catalog.pg_type t LEFT JOIN pg_catalog.pg_namespace n ON t.typnamespace = n.oid  WHERE typtype = 'c' AND (t.oid < 16384 OR nspname = 'information_schema')     UNION ALL   SELECT * FROM (         WITH x AS (SELECT oid FROM oids)            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'           UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'           UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x             WHERE t.typtype = 'c' AND                 t.oid = c.reltype AND                   c.oid = a.attrelid AND                  NOT a.attisdropped AND                  a.atttypid = x.oid            UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid   ) foo ) SELECT n.nspname, c.relname, a.attname FROM pg_catalog.pg_class c,      pg_catalog.pg_namespace n,      pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND      NOT a.attisdropped AND      a.atttypid IN (SELECT oid FROM oids) AND        c.relkind IN ('r', 'm', 'i') AND        c.relnamespace = n.oid AND      n.nspname !~ '^pg_temp_' AND        n.nspname !~ '^pg_toast_temp_' AND      n.nspname NOT IN ('pg_catalog', 'information_schema');
        "
        ((ERRORS++))
        E1_FAILED=1
    fi
done
[ "$E1_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-1. Checking for system-defined composite types in user tables")
[ "$E1_FAILED" -eq 0 ] && echo "✓ OK"

# --------------------------------------------
# E-2. Checking for reg* data types in user tables  
# --------------------------------------------
echo ""
echo "=== E-2. Checking for reg* data types in user tables   ==="
E2_FAILED=0
for db in $DBS; do
    result=$($PSQL -d "$db" -t -A -c "
    WITH RECURSIVE oids AS (     SELECT oid FROM pg_catalog.pg_type t WHERE t.typnamespace =         (SELECT oid FROM pg_catalog.pg_namespace          WHERE nspname = 'pg_catalog')   AND t.typname IN (            'regcollation',            'regconfig',            'regdictionary',            'regnamespace',            'regoper',            'regoperator',            'regproc',            'regprocedure'          )   UNION ALL   SELECT * FROM (         WITH x AS (SELECT oid FROM oids)            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'           UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'           UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x             WHERE t.typtype = 'c' AND                 t.oid = c.reltype AND                   c.oid = a.attrelid AND                  NOT a.attisdropped AND                  a.atttypid = x.oid            UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid   ) foo ) SELECT n.nspname, c.relname, a.attname FROM pg_catalog.pg_class c,      pg_catalog.pg_namespace n,      pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND      NOT a.attisdropped AND      a.atttypid IN (SELECT oid FROM oids) AND        c.relkind IN ('r', 'm', 'i') AND        c.relnamespace = n.oid AND      n.nspname !~ '^pg_temp_' AND        n.nspname !~ '^pg_toast_temp_' AND      n.nspname NOT IN ('pg_catalog', 'information_schema');" 2>/dev/null)
    if [ -n "$result" ]; then
        echo "❌ ERROR [$db]: reg* data types in user tables"
        echo "   Your installation contains one of the reg* data types in user tables."
        echo "   These data types reference system OIDs that are not preserved by pg_upgrade."
        echo "   Please drop the problem columns and try again."
        $PSQL -d "$db" -c "
        WITH RECURSIVE oids AS (     SELECT oid FROM pg_catalog.pg_type t WHERE t.typnamespace =         (SELECT oid FROM pg_catalog.pg_namespace          WHERE nspname = 'pg_catalog')   AND t.typname IN (            'regcollation',            'regconfig',            'regdictionary',            'regnamespace',            'regoper',            'regoperator',            'regproc',            'regprocedure'          )   UNION ALL   SELECT * FROM (         WITH x AS (SELECT oid FROM oids)            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'           UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'           UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x             WHERE t.typtype = 'c' AND                 t.oid = c.reltype AND                   c.oid = a.attrelid AND                  NOT a.attisdropped AND                  a.atttypid = x.oid            UNION ALL           SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid   ) foo ) SELECT n.nspname, c.relname, a.attname FROM pg_catalog.pg_class c,      pg_catalog.pg_namespace n,      pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND      NOT a.attisdropped AND      a.atttypid IN (SELECT oid FROM oids) AND        c.relkind IN ('r', 'm', 'i') AND        c.relnamespace = n.oid AND      n.nspname !~ '^pg_temp_' AND        n.nspname !~ '^pg_toast_temp_' AND      n.nspname NOT IN ('pg_catalog', 'information_schema');
        "
        ((ERRORS++))
        E2_FAILED=1
    fi
done
[ "$E2_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-2. Checking for reg* data types in user tables  ")
[ "$E2_FAILED" -eq 0 ] && echo "✓ OK"

# --------------------------------------------
# E-3. Checking for incompatible aclitem data type in user tables
# --------------------------------------------
echo ""
echo "=== E-3. Checking for incompatible aclitem data type in user tables ==="
if [ "$MAJOR_VERSION" -le 15 ] && [ "$TARGET_VERSION" -ge 16 ]; then
    E3_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        WITH RECURSIVE oids AS ( 	SELECT 'pg_catalog.aclitem'::pg_catalog.regtype AS oid 	UNION ALL 	SELECT * FROM ( 		WITH x AS (SELECT oid FROM oids) 			SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd' 			UNION ALL 			SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b' 			UNION ALL 			SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x 			WHERE t.typtype = 'c' AND 				  t.oid = c.reltype AND 				  c.oid = a.attrelid AND 				  NOT a.attisdropped AND 				  a.atttypid = x.oid 			UNION ALL 			SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x 			WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid	) foo ) SELECT n.nspname, c.relname, a.attname FROM	pg_catalog.pg_class c, 		pg_catalog.pg_namespace n, 		pg_catalog.pg_attribute a WHERE	c.oid = a.attrelid AND 		NOT a.attisdropped AND 		a.atttypid IN (SELECT oid FROM oids) AND 		c.relkind IN ('r', 'm', 'i') AND 		c.relnamespace = n.oid AND 		n.nspname !~ '^pg_temp_' AND 		n.nspname !~ '^pg_toast_temp_' AND 		n.nspname NOT IN ('pg_catalog', 'information_schema');
        " 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: 'aclitem' data type found - format changed in PG 16"
            echo "   Your installation contains the \"aclitem\" data type in user tables."
            echo "   The internal format of \"aclitem\" changed in PostgreSQL version 16."
            echo "   Please drop the problem columns and try again."
            $PSQL -d "$db" -c "
            WITH RECURSIVE oids AS ( 	SELECT 'pg_catalog.aclitem'::pg_catalog.regtype AS oid 	UNION ALL 	SELECT * FROM ( 		WITH x AS (SELECT oid FROM oids) 			SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd' 			UNION ALL 			SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b' 			UNION ALL 			SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x 			WHERE t.typtype = 'c' AND 				  t.oid = c.reltype AND 				  c.oid = a.attrelid AND 				  NOT a.attisdropped AND 				  a.atttypid = x.oid 			UNION ALL 			SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x 			WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid	) foo ) SELECT n.nspname, c.relname, a.attname FROM	pg_catalog.pg_class c, 		pg_catalog.pg_namespace n, 		pg_catalog.pg_attribute a WHERE	c.oid = a.attrelid AND 		NOT a.attisdropped AND 		a.atttypid IN (SELECT oid FROM oids) AND 		c.relkind IN ('r', 'm', 'i') AND 		c.relnamespace = n.oid AND 		n.nspname !~ '^pg_temp_' AND 		n.nspname !~ '^pg_toast_temp_' AND 		n.nspname NOT IN ('pg_catalog', 'information_schema');
            "
            ((ERRORS++))
            E3_FAILED=1
        fi
    done
    [ "$E3_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-3. Checking for incompatible aclitem data type in user tables")
    [ "$E3_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (not applicable for this upgrade path)"
fi

# --------------------------------------------
# E-4. Checking for invalid sql_identifier user columns (source <= 11)
# --------------------------------------------
echo ""
echo "=== E-4. Checking for invalid sql_identifier user columns ==="
if [ "$MAJOR_VERSION" -le 11 ]; then
    E4_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        WITH RECURSIVE oids AS (   SELECT 'information_schema.sql_identifier'::pg_catalog.regtype AS oid   UNION ALL   SELECT * FROM (     WITH x AS (SELECT oid FROM oids)      SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'       UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'       UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x       WHERE t.typtype = 'c' AND           t.oid = c.reltype AND           c.oid = a.attrelid AND          NOT a.attisdropped AND          a.atttypid = x.oid      UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x      WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid ) foo ) SELECT n.nspname, c.relname, a.attname FROM pg_catalog.pg_class c,    pg_catalog.pg_namespace n,    pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND    NOT a.attisdropped AND    a.atttypid IN (SELECT oid FROM oids) AND    c.relkind IN ('r', 'm', 'i') AND    c.relnamespace = n.oid AND    n.nspname !~ '^pg_temp_' AND    n.nspname !~ '^pg_toast_temp_' AND    n.nspname NOT IN ('pg_catalog', 'information_schema');
        " 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: 'sql_identifier' data type found - format changed in PG 12"
            echo "   Your installation contains the \"sql_identifier\" data type in user tables."
            echo "   The on-disk format for this data type has changed."
            echo "   Please drop the problem columns and try again."
            $PSQL -d "$db" -c "
            WITH RECURSIVE oids AS (   SELECT 'information_schema.sql_identifier'::pg_catalog.regtype AS oid   UNION ALL   SELECT * FROM (     WITH x AS (SELECT oid FROM oids)      SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'       UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'       UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x       WHERE t.typtype = 'c' AND           t.oid = c.reltype AND           c.oid = a.attrelid AND          NOT a.attisdropped AND          a.atttypid = x.oid      UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x      WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid ) foo ) SELECT n.nspname, c.relname, a.attname FROM pg_catalog.pg_class c,    pg_catalog.pg_namespace n,    pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND    NOT a.attisdropped AND    a.atttypid IN (SELECT oid FROM oids) AND    c.relkind IN ('r', 'm', 'i') AND    c.relnamespace = n.oid AND    n.nspname !~ '^pg_temp_' AND    n.nspname !~ '^pg_toast_temp_' AND    n.nspname NOT IN ('pg_catalog', 'information_schema');
            "
            ((ERRORS++))
            E4_FAILED=1
        fi
    done
    [ "$E4_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-4. Checking for invalid sql_identifier user columns")
    [ "$E4_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (source version > 11)"
fi

# --------------------------------------------
# E-5. Checking for removed abstime & reltime & tinterval data type in user tables (source <= 11)
# --------------------------------------------
echo ""
echo "=== E-5. Checking for removed abstime & reltime & tinterval data type in user tables ==="
if [ "$MAJOR_VERSION" -le 11 ]; then
    E5_FAILED=0
    REMOVED_TYPES="abstime reltime tinterval"
    for db in $DBS; do
        for dtype in $REMOVED_TYPES; do
            result=$($PSQL -d "$db" -t -A -c "
            WITH RECURSIVE oids AS (   SELECT 'pg_catalog.${dtype}'::pg_catalog.regtype AS oid  UNION ALL   SELECT * FROM (     WITH x AS (SELECT oid FROM oids)      SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'       UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'       UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x       WHERE t.typtype = 'c' AND           t.oid = c.reltype AND           c.oid = a.attrelid AND          NOT a.attisdropped AND          a.atttypid = x.oid      UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x      WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid ) foo ) SELECT n.nspname, c.relname, a.attname FROM pg_catalog.pg_class c,    pg_catalog.pg_namespace n,    pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND    NOT a.attisdropped AND    a.atttypid IN (SELECT oid FROM oids) AND    c.relkind IN ('r', 'm', 'i') AND    c.relnamespace = n.oid AND    n.nspname !~ '^pg_temp_' AND    n.nspname !~ '^pg_toast_temp_' AND    n.nspname NOT IN ('pg_catalog', 'information_schema');
            " 2>/dev/null)
            if [ -n "$result" ]; then
                echo "❌ ERROR [$db]: Removed data type '${dtype}' found in user tables"
                echo "   Your installation contains the \"${dtype}\" data type in user tables."
                echo "   The \"${dtype}\" type has been removed in PostgreSQL version 12,"
                echo "   Please drop the problem columns, or change them to another data type, and try again." 
                $PSQL -d "$db" -c "
                WITH RECURSIVE oids AS (   SELECT 'pg_catalog.${dtype}'::pg_catalog.regtype AS oid  UNION ALL   SELECT * FROM (     WITH x AS (SELECT oid FROM oids)      SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'       UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'       UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x       WHERE t.typtype = 'c' AND           t.oid = c.reltype AND           c.oid = a.attrelid AND          NOT a.attisdropped AND          a.atttypid = x.oid      UNION ALL       SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x      WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid ) foo ) SELECT n.nspname, c.relname, a.attname FROM pg_catalog.pg_class c,    pg_catalog.pg_namespace n,    pg_catalog.pg_attribute a WHERE c.oid = a.attrelid AND    NOT a.attisdropped AND    a.atttypid IN (SELECT oid FROM oids) AND    c.relkind IN ('r', 'm', 'i') AND    c.relnamespace = n.oid AND    n.nspname !~ '^pg_temp_' AND    n.nspname !~ '^pg_toast_temp_' AND    n.nspname NOT IN ('pg_catalog', 'information_schema');
                "
                ((ERRORS++))
                E5_FAILED=1
            fi
        done
    done
    [ "$E5_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-5. Checking for removed abstime & reltime & tinterval data type in user tables")
    [ "$E5_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (source version > 11)"
fi

# --------------------------------------------
# E-6. Checking for user-defined encoding conversions     
# --------------------------------------------
echo ""
echo "=== E-6. Checking for user-defined encoding conversions ==="
if [ "$MAJOR_VERSION" -le 13 ]; then
    E6_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        SELECT c.oid as conoid, c.conname, n.nspname FROM pg_catalog.pg_conversion c,      pg_catalog.pg_namespace n WHERE c.connamespace = n.oid AND       c.oid >= 16384;" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: User-defined encoding conversions found"
            echo "   Your installation contains user-defined encoding conversions."
            echo "   The conversion function parameters changed in PostgreSQL version 14."
            echo "   Please remove the encoding conversions and try again."
            $PSQL -d "$db" -c "
            SELECT c.oid as conoid, c.conname, n.nspname FROM pg_catalog.pg_conversion c, pg_catalog.pg_namespace n WHERE c.connamespace = n.oid AND c.oid >= 16384;
            "
            ((ERRORS++))
            E6_FAILED=1
        fi
    done
    [ "$E6_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-6. Checking for user-defined encoding conversions")
    [ "$E6_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (source version > 13)"
fi

# --------------------------------------------
# E-7. Checking for user-defined postfix operators
# --------------------------------------------
echo ""
echo "=== E-7. Checking for user-defined postfix operators ==="
if [ "$MAJOR_VERSION" -le 13 ]; then
    E7_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        SELECT o.oid AS oproid,        n.nspname AS oprnsp,        o.oprname,        tn.nspname AS typnsp,        t.typname FROM pg_catalog.pg_operator o,      pg_catalog.pg_namespace n,      pg_catalog.pg_type t,      pg_catalog.pg_namespace tn WHERE o.oprnamespace = n.oid AND       o.oprleft = t.oid AND       t.typnamespace = tn.oid AND       o.oprright = 0 AND       o.oid >= 16384;
        " 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: User-defined postfix operators found"
            echo "   Your installation contains user-defined postfix operators, which are not supported anymore."
            echo "   Consider dropping the postfix operators and replacing them with prefix operators or function calls."
            $PSQL -d "$db" -c "
            SELECT o.oid AS oproid,        n.nspname AS oprnsp,        o.oprname,        tn.nspname AS typnsp,        t.typname FROM pg_catalog.pg_operator o,      pg_catalog.pg_namespace n,      pg_catalog.pg_type t,      pg_catalog.pg_namespace tn WHERE o.oprnamespace = n.oid AND       o.oprleft = t.oid AND       t.typnamespace = tn.oid AND       o.oprright = 0 AND       o.oid >= 16384;
            "
            ((ERRORS++))
            E7_FAILED=1
        fi
    done
    [ "$E7_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-7. Checking for user-defined postfix operators")
    [ "$E7_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (source version > 13)"
fi

# --------------------------------------------
# E-8. Checking for incompatible polymorphic functions
# --------------------------------------------
echo ""
echo "=== E-8. check_for_incompatible_polymorphics ==="
if [ "$MAJOR_VERSION" -le 13 ]; then
    E8_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        SELECT 'aggregate' AS objkind, p.oid::regprocedure::text AS objname FROM pg_proc AS p JOIN pg_aggregate AS a ON a.aggfnoid=p.oid JOIN pg_proc AS transfn ON transfn.oid=a.aggtransfn WHERE p.oid >= 16384 AND a.aggtransfn = ANY(ARRAY['array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)', 'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)', 'array_replace(anyarray,anyelement,anyelement)', 'array_position(anyarray,anyelement)', 'array_position(anyarray,anyelement,integer)', 'array_positions(anyarray,anyelement)', 'width_bucket(anyelement,anyarray)']::regprocedure[]) AND a.aggtranstype = ANY(ARRAY['anyarray', 'anyelement']::regtype[]) UNION ALL SELECT 'aggregate' AS objkind, p.oid::regprocedure::text AS objname FROM pg_proc AS p JOIN pg_aggregate AS a ON a.aggfnoid=p.oid JOIN pg_proc AS finalfn ON finalfn.oid=a.aggfinalfn WHERE p.oid >= 16384 AND a.aggfinalfn = ANY(ARRAY['array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)', 'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)', 'array_replace(anyarray,anyelement,anyelement)', 'array_position(anyarray,anyelement)', 'array_position(anyarray,anyelement,integer)', 'array_positions(anyarray,anyelement)', 'width_bucket(anyelement,anyarray)']::regprocedure[]) AND a.aggtranstype = ANY(ARRAY['anyarray', 'anyelement']::regtype[]) UNION ALL SELECT 'operator' AS objkind, op.oid::regoperator::text AS objname FROM pg_operator AS op WHERE op.oid >= 16384 AND oprcode = ANY(ARRAY['array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)', 'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)', 'array_replace(anyarray,anyelement,anyelement)', 'array_position(anyarray,anyelement)', 'array_position(anyarray,anyelement,integer)', 'array_positions(anyarray,anyelement)', 'width_bucket(anyelement,anyarray)']::regprocedure[]) AND oprleft = ANY(ARRAY['anyarray', 'anyelement']::regtype[]);
        " 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: Incompatible polymorphic functions found"
            echo "   Your installation contains user-defined objects that refer to internal polymorphic functions with arguments of type \"anyarray\" or \"anyelement\"."
            echo "   These user-defined objects must be dropped before upgrading and restored afterwards, changing them to refer to the new corresponding functions with arguments of type \"anycompatiblearray\" and \"anycompatible\"."
            $PSQL -d "$db" -c "
            SELECT 'aggregate' AS objkind, p.oid::regprocedure::text AS objname FROM pg_proc AS p JOIN pg_aggregate AS a ON a.aggfnoid=p.oid JOIN pg_proc AS transfn ON transfn.oid=a.aggtransfn WHERE p.oid >= 16384 AND a.aggtransfn = ANY(ARRAY['array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)', 'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)', 'array_replace(anyarray,anyelement,anyelement)', 'array_position(anyarray,anyelement)', 'array_position(anyarray,anyelement,integer)', 'array_positions(anyarray,anyelement)', 'width_bucket(anyelement,anyarray)']::regprocedure[]) AND a.aggtranstype = ANY(ARRAY['anyarray', 'anyelement']::regtype[]) UNION ALL SELECT 'aggregate' AS objkind, p.oid::regprocedure::text AS objname FROM pg_proc AS p JOIN pg_aggregate AS a ON a.aggfnoid=p.oid JOIN pg_proc AS finalfn ON finalfn.oid=a.aggfinalfn WHERE p.oid >= 16384 AND a.aggfinalfn = ANY(ARRAY['array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)', 'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)', 'array_replace(anyarray,anyelement,anyelement)', 'array_position(anyarray,anyelement)', 'array_position(anyarray,anyelement,integer)', 'array_positions(anyarray,anyelement)', 'width_bucket(anyelement,anyarray)']::regprocedure[]) AND a.aggtranstype = ANY(ARRAY['anyarray', 'anyelement']::regtype[]) UNION ALL SELECT 'operator' AS objkind, op.oid::regoperator::text AS objname FROM pg_operator AS op WHERE op.oid >= 16384 AND oprcode = ANY(ARRAY['array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)', 'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)', 'array_replace(anyarray,anyelement,anyelement)', 'array_position(anyarray,anyelement)', 'array_position(anyarray,anyelement,integer)', 'array_positions(anyarray,anyelement)', 'width_bucket(anyelement,anyarray)']::regprocedure[]) AND oprleft = ANY(ARRAY['anyarray', 'anyelement']::regtype[]);
            "
            ((ERRORS++))
            E8_FAILED=1
        fi
    done
    [ "$E8_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-8. check_for_incompatible_polymorphics")
    [ "$E8_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (source version > 13)"
fi

# --------------------------------------------
# E-9. Checking for tables WITH OIDS (source <= 11)
# --------------------------------------------
echo ""
echo "=== E-9. Checking for tables WITH OIDS ==="
if [ "$MAJOR_VERSION" -le 11 ]; then
    E9_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        SELECT n.nspname, c.relname FROM pg_catalog.pg_class c,    pg_catalog.pg_namespace n WHERE c.relnamespace = n.oid AND    c.relhasoids AND       n.nspname NOT IN ('pg_catalog');
        " 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: Tables WITH OIDS found"
            echo "   Your installation contains tables declared WITH OIDS, which is not supported anymore."
            echo "   Consider removing the oid column using:"
            echo "       ALTER TABLE ... SET WITHOUT OIDS;"
            $PSQL -d "$db" -c "
            SELECT n.nspname, c.relname FROM pg_catalog.pg_class c,    pg_catalog.pg_namespace n WHERE c.relnamespace = n.oid AND    c.relhasoids AND       n.nspname NOT IN ('pg_catalog');
            "
            ((ERRORS++))
            E9_FAILED=1
        fi
    done
    [ "$E9_FAILED" -eq 1 ] && FAILED_CHECKS+=("E-9. Checking for tables WITH OIDS")
    [ "$E9_FAILED" -eq 0 ] && echo "✓ OK"
else
    echo "  Skipped (source version > 11)"
fi

# ============================================
# SECTION 3: Blue/Green Deployment Checks
# ============================================
if [ "$BG_DEPLOY" = "yes" ] || [ "$BG_DEPLOY" = "y" ]; then
    echo ""
    echo "============================================"
    echo "SECTION 3: Blue/Green Deployment Checks"
    echo "============================================"

    # --------------------------------------------
    # BG-1. Check logical replication parameters
    # --------------------------------------------
    echo ""
    echo "=== BG-1. Check logical replication parameters ==="
    
    max_replication_slots=$($PSQL -d postgres -t -A -c "SHOW max_replication_slots;")
    max_wal_senders=$($PSQL -d postgres -t -A -c "SHOW max_wal_senders;")
    max_logical_replication_workers=$($PSQL -d postgres -t -A -c "SHOW max_logical_replication_workers;")
    max_worker_processes=$($PSQL -d postgres -t -A -c "SHOW max_worker_processes;")
    
    required_slots=$((DB_COUNT + 1))
    required_workers=$((DB_COUNT + 1))
    
    echo "Database count (excluding system): $DB_COUNT"
    echo "max_replication_slots: $max_replication_slots (required >= $required_slots)"
    echo "max_wal_senders: $max_wal_senders (required >= $max_replication_slots)"
    echo "max_logical_replication_workers: $max_logical_replication_workers (required >= $required_workers)"
    echo "max_worker_processes: $max_worker_processes (required > $max_logical_replication_workers)"
    
    BG1_FAILED=0
    if [ "$max_replication_slots" -lt "$required_slots" ]; then
        echo "❌ ERROR: max_replication_slots ($max_replication_slots) < required ($required_slots)"
        ((ERRORS++))
        BG1_FAILED=1
    fi
    if [ "$max_wal_senders" -lt "$max_replication_slots" ]; then
        echo "❌ ERROR: max_wal_senders ($max_wal_senders) < max_replication_slots ($max_replication_slots)"
        ((ERRORS++))
        BG1_FAILED=1
    fi
    if [ "$max_logical_replication_workers" -lt "$required_workers" ]; then
        echo "❌ ERROR: max_logical_replication_workers ($max_logical_replication_workers) < required ($required_workers)"
        ((ERRORS++))
        BG1_FAILED=1
    fi
    if [ "$max_worker_processes" -le "$max_logical_replication_workers" ]; then
        echo "❌ ERROR: max_worker_processes ($max_worker_processes) <= max_logical_replication_workers ($max_logical_replication_workers)"
        ((ERRORS++))
        BG1_FAILED=1
    fi
    [ "$BG1_FAILED" -eq 1 ] && FAILED_CHECKS+=("BG-1. Logical replication parameters")
    [ "$BG1_FAILED" -eq 0 ] && echo "✓ OK"

    # --------------------------------------------
    # BG-2. Check for logical replication subscriptions
    # --------------------------------------------
    echo ""
    echo "=== BG-2. Check for logical replication subscriptions ==="
    BG2_FAILED=0
    for db in $DBS; do
        sub_count=$($PSQL -d "$db" -t -A -c "SELECT count(*) FROM pg_subscription;" 2>/dev/null)
        if [ "${sub_count:-0}" -gt 0 ]; then
            echo "❌ ERROR [$db]: $sub_count subscription(s) exist - must be dropped before Blue/Green upgrade"
            echo "   Please drop the SUBSCRIPTION using:"
            echo "       DROP SUBSCRIPTION ...;"

            $PSQL -d "$db" -c "SELECT subname, subconninfo, subslotname, subenabled FROM pg_subscription;"
            ((ERRORS++))
            BG2_FAILED=1
        fi
    done
    [ "$BG2_FAILED" -eq 1 ] && FAILED_CHECKS+=("BG-2. Logical replication subscriptions")
    [ "$BG2_FAILED" -eq 0 ] && echo "✓ OK"

    # --------------------------------------------
    # BG-3. Check tables without Primary Key
    # --------------------------------------------
    echo ""
    echo "=== BG-3. Check tables without Primary Key ==="
    BG3_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        SELECT count(*) FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'rdsadmin')
          AND NOT EXISTS (
              SELECT 1 FROM pg_constraint con
              WHERE con.conrelid = c.oid AND con.contype = 'p'
          );" 2>/dev/null)
        if [ "${result:-0}" -gt 0 ]; then
            echo "❌ ERROR [$db]: $result table(s) without Primary Key"
            $PSQL -d "$db" -c "
            SELECT n.nspname AS schema, c.relname AS table_name,
                   CASE WHEN i.relreplident = 'd' THEN 'DEFAULT'
                        WHEN i.relreplident = 'n' THEN 'NOTHING'
                        WHEN i.relreplident = 'f' THEN 'FULL'
                        WHEN i.relreplident = 'i' THEN 'INDEX'
                   END AS replica_identity
            FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            JOIN pg_class i ON i.oid = c.oid
            WHERE c.relkind = 'r'
              AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'rdsadmin')
              AND NOT EXISTS (
                  SELECT 1 FROM pg_constraint con
                  WHERE con.conrelid = c.oid AND con.contype = 'p'
              )
            ORDER BY n.nspname, c.relname;"
            echo "  Note: Tables without PK need REPLICA IDENTITY FULL for logical replication"
            ((ERRORS++))
            BG3_FAILED=1
        fi
    done
    [ "$BG3_FAILED" -eq 1 ] && FAILED_CHECKS+=("BG-3. Tables without Primary Key")
    [ "$BG3_FAILED" -eq 0 ] && echo "✓ OK"

    # --------------------------------------------
    # BG-4. Check DDL event triggers
    # --------------------------------------------
    echo ""
    echo "=== BG-4. Check DDL event triggers ==="
    BG4_WARN=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        SELECT count(*) FROM pg_event_trigger
        WHERE evtevent IN ('ddl_command_start', 'ddl_command_end', 'sql_drop')
          AND evtname != 'dts_capture_catalog_start';" 2>/dev/null)
        if [ "${result:-0}" -gt 0 ]; then
            echo "⚠️ WARN [$db]: DDL event trigger(s) found - may interfere with Blue/Green deployment"
            $PSQL -d "$db" -c "
            SELECT evtname AS trigger_name,
                   evtevent AS event,
                   evtfoid::regproc AS function_name,
                   evtenabled AS enabled
            FROM pg_event_trigger
            WHERE evtevent IN ('ddl_command_start', 'ddl_command_end', 'sql_drop')
              AND evtname != 'dts_capture_catalog_start';"
            echo "  Note: DDL triggers may be triggered during CREATE SUBSCRIPTION on green instance"
            echo "  Consider disabling the DDL triggers."
            ((WARNS++))
            BG4_WARN=1
        fi
    done
    [ "$BG4_WARN" -eq 1 ] && WARN_CHECKS+=("BG-4. DDL event triggers")
    [ "$BG4_WARN" -eq 0 ] && echo "✓ OK"

    # --------------------------------------------
    # BG-5. Check rds.logical_replication parameter
    # --------------------------------------------
    echo ""
    echo "=== BG-5. Check rds.logical_replication parameter ==="
    BG5_FAILED=0
    result=$($PSQL -d postgres -t -A -c "SHOW rds.logical_replication;" 2>/dev/null)
    if [ "$result" != "on" ]; then
        echo "❌ ERROR: rds.logical_replication is NOT enabled (current: ${result:-unknown})"
        echo "  Blue/Green deployment requires logical replication to be enabled."
        echo "  Action: Set rds.logical_replication=1 in the DB cluster parameter group and reboot."
        ((ERRORS++))
        BG5_FAILED=1
    fi
    [ "$BG5_FAILED" -eq 1 ] && FAILED_CHECKS+=("BG-5. rds.logical_replication not enabled")
    [ "$BG5_FAILED" -eq 0 ] && echo "✓ OK"

    # --------------------------------------------
    # BG-6. Check for DTS trigger
    # --------------------------------------------
    echo ""
    echo "=== BG-6. Check for DTS trigger ==="
    BG6_FAILED=0
    for db in $DBS; do
        result=$($PSQL -d "$db" -t -A -c "
        SELECT evtname FROM pg_event_trigger 
        WHERE evtname = 'dts_capture_catalog_start';" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "❌ ERROR [$db]: DTS trigger 'dts_capture_catalog_start' found"
            echo "  This trigger will cause Blue/Green deployment to fail."
            echo "  Action: Drop the trigger before upgrade: dts_capture_catalog_start()"
            ((ERRORS++))
            BG6_FAILED=1
        fi
    done
    [ "$BG6_FAILED" -eq 1 ] && FAILED_CHECKS+=("BG-6. DTS trigger")
    [ "$BG6_FAILED" -eq 0 ] && echo "✓ OK"
fi

# ============================================
# Summary
# ============================================
END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo ""
echo "============================================"
echo "Precheck Summary"
echo "============================================"
echo "Source Version: $MAJOR_VERSION"
echo "Target Version: $TARGET_VERSION"
echo "Blue/Green Check: $BG_DEPLOY"
echo "Database Count: $DB_COUNT"
echo "Start Time: $START_TIME"
echo "End Time: $END_TIME"
echo "============================================"
if [ "$ERRORS" -gt 0 ]; then
    echo "❌ Precheck identified $ERRORS error(s) in ${#FAILED_CHECKS[@]} check(s) that need to be addressed before upgrading."
    echo "   Please review the error details in each check above."
    echo ""
    echo "Failed Checks:"
    for check in "${FAILED_CHECKS[@]}"; do
        echo "  - $check"
    done
    echo ""
fi
if [ "$WARNS" -gt 0 ]; then
    echo "⚠️ Precheck identified $WARNS warning(s) in ${#WARN_CHECKS[@]} check(s) that should be reviewed before upgrading."
    echo "   Please review the warning details in each check above."
    echo ""
    echo "Warning Checks:"
    for check in "${WARN_CHECKS[@]}"; do
        echo "  - $check"
    done
    echo ""
fi
if [ "$ERRORS" -eq 0 ] && [ "$WARNS" -eq 0 ]; then
    echo "✓ Precheck passed. Upgrade can proceed."
fi
echo "============================================"

exit $ERRORS
