/*
 *  Copyright 2016-2026 Amazon.com, Inc. or its affiliates. 
 *  All Rights Reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License"). 
 *  You may not use this file except in compliance with the License. 
 *  A copy of the License is located at
 * 
 *      https://aws.amazon.com/apache2.0/
 * 
 * or in the "license" file accompanying this file. 
 * This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
 * either express or implied. See the License for the specific language governing permissions 
 * and limitations under the License.
*/

-- ============================================
-- Aurora/RDS PostgreSQL Major Version Upgrade Precheck
-- SQL Version
-- Supports: Target Major Version 11-17
--
-- Each check is either:
--   [global]       - Run once against the postgres database
--   [per-database] - Must be run against EACH user database
--
-- Usage (global checks):
--   psql "host=<HOST> port=<PORT> user=<USER> dbname=postgres sslmode=verify-full sslrootcert=global-bundle.pem" \
--        -v target_version=<ENGINE MAJOR VERSION, for example: 16> -f pg-major-version-upgrade-precheck.sql
--
-- Usage (per-database checks):
--   psql "host=<HOST> port=<PORT> user=<USER> dbname=<DBNAME> sslmode=verify-full sslrootcert=global-bundle.pem" \
--        -v target_version=<ENGINE MAJOR VERSION, for example: 16> -f pg-major-version-upgrade-precheck.sql
--
-- Required privileges (minimum):
--   The executing user needs SELECT permission on these system catalogs:
--     pg_database, pg_prepared_xacts, pg_replication_slots, pg_settings,
--     pg_extension, pg_available_extensions, pg_type, pg_class, pg_namespace,
--     pg_attribute, pg_range, pg_conversion, pg_operator, pg_proc,
--     pg_aggregate, pg_subscription, pg_constraint, pg_event_trigger
--
-- Blue/Green deployment checks:
--   Checks 24-35c are specific to Blue/Green deployment upgrades.
--   If you do not plan to use Blue/Green deployments for the major version
--   upgrade, you can safely ignore findings from checks 24 through 35c.
--
-- Note on internal schemas:
--   This script is designed for Amazon RDS/Aurora PostgreSQL and excludes
--   'rdsadmin' from database/schema lists. For self-managed PostgreSQL
--   or other managed services update the internal-schema list accordingly.
-- ============================================

\set QUIET on
\set ON_ERROR_STOP on
\pset pager off
\pset tuples_only off
\pset format aligned

SET search_path = pg_catalog, pg_temp;

-- Audit logging: set log_statement to 'all' for this session only.
-- This records all SQL executed by this script in the PostgreSQL server log.
-- The setting is session-level and does not affect the global configuration.
-- It is reset at the end of the script.
SET log_statement = 'all';

-- Prevent runaway queries from holding catalog locks too long
-- statement_timeout: Maximum execution time per query (10 minutes).
--   Recursive CTE checks on large databases may take several minutes.
-- lock_timeout: Maximum time to wait for a lock (5 seconds).
--   Prevents the script from blocking on concurrent DDL operations.
-- Values in milliseconds (PostgreSQL default unit for these parameters)
SET statement_timeout = 600000;   -- 10 minutes
SET lock_timeout = 5000;          -- 5 seconds

-- ============================================
-- Validate target_version is set
-- ============================================
\if :{?target_version}
\else
    \echo '============================================'
    \echo 'ERROR: target_version is not set.'
    \echo ''
    \echo 'Usage:'
    \echo '  psql "host=HOST port=PORT user=USER dbname=postgres sslmode=require" \\'
    \echo '       -v target_version=16 -f pg-major-version-upgrade-precheck.sql'
    \echo ''
    \echo 'Or inside psql:'
    \echo '  \\set target_version 16'
    \echo '  \\i pg-major-version-upgrade-precheck.sql'
    \echo '============================================'
    \quit
\endif

\echo '============================================'
\echo 'Aurora/RDS PostgreSQL Upgrade Precheck (SQL)'
\echo '============================================'
\echo ''

-- ============================================
-- Auto-detect source version & pre-compute conditions
-- ============================================
\echo '--- Environment Info ---'
SELECT current_setting('server_version') AS source_version,
       current_setting('server_version_num')::int / 10000 AS source_major,
       :target_version AS target_version,
       current_database() AS current_database;

\echo ''

-- Store source major version
SELECT current_setting('server_version_num')::int / 10000 AS major \gset

-- Pre-compute all boolean conditions for \if
-- (psql \if only accepts true/false, not comparison expressions)
SELECT
  (current_setting('server_version_num')::int / 10000 >= :target_version)::text AS version_invalid,
  (current_setting('server_version_num')::int / 10000 < 17)::text                AS need_slot_check,
  (:target_version >= 11)::text                                                   AS target_ge_11,
  (:target_version >= 14)::text                                                   AS target_ge_14,
  (current_setting('server_version_num')::int / 10000 <= 15
     AND :target_version >= 16)::text                                             AS need_aclitem_check,
  (current_setting('server_version_num')::int / 10000 <= 11)::text               AS source_le_11,
  (current_setting('server_version_num')::int / 10000 <= 13)::text               AS source_le_13
\gset

-- Version sanity check
\if :version_invalid
    \echo '❌ FAILED: Source version >= Target version. Nothing to upgrade.'
    \quit
\endif

-- ============================================
-- Validate target_version is within supported range (11-17)
-- ============================================
SELECT (:target_version < 11 OR :target_version > 17)::text AS version_out_of_range \gset
\if :version_out_of_range
    \echo '❌ FAILED: target_version must be between 11 and 17.'
    \quit
\endif

-- ============================================
-- List user databases (for reference)
-- ============================================
\echo '=== User Databases ==='
SELECT datname,
       CASE WHEN datname = current_database() THEN '← current' ELSE '' END AS note
FROM pg_catalog.pg_database
WHERE datistemplate = false
  AND datname NOT IN ('rdsadmin', 'template0', 'template1')
ORDER BY datname;

\echo ''

-- --------------------------------------------
-- Check 1. PostgreSQL Version Check [global]
-- --------------------------------------------
\echo '=== 1. PostgreSQL Version Check [global] ==='
\echo '✓ INFO'
SELECT version() AS "PostgreSQL Version";

\echo ''

-- --------------------------------------------
-- Check 2. check_for_invalid_database [global]
-- --------------------------------------------
\echo '=== 2. check_for_invalid_database [global] ==='
SELECT (count(*) > 0)::text AS c2_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: Invalid database(s) found (datconnlimit=-2). DROP them and try again.'
            ELSE '✓ PASSED'
       END AS c2_status
FROM pg_catalog.pg_database WHERE datconnlimit = -2 \gset

\echo :c2_status

\if :c2_failed
    SELECT datname FROM pg_catalog.pg_database WHERE datconnlimit = -2;
\endif

\echo ''

-- --------------------------------------------
-- Check 2b. check_database_not_allow_connect [global]
-- --------------------------------------------
\echo '=== 2b. check_database_not_allow_connect [global] ==='
SELECT (count(*) > 0)::text AS c2b_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: Database(s) with datallowconn=false found. Ensure all non-template0 databases allow connections.'
            ELSE '✓ PASSED'
       END AS c2b_status
FROM pg_catalog.pg_database
WHERE datname != 'template0' AND datallowconn = false \gset

\echo :c2b_status

\if :c2b_failed
    SELECT datname FROM pg_catalog.pg_database
    WHERE datname != 'template0' AND datallowconn = false;
\endif

\echo ''

-- --------------------------------------------
-- Check 3. check_template_0_and_template1 [global]
-- --------------------------------------------
\echo '=== 3. check_template_0_and_template1 [global] ==='
SELECT (count(*) != 2)::text AS c3_failed,
       CASE WHEN count(*) != 2
            THEN '❌ FAILED: template0/template1 invalid. Make sure both exist with datistemplate=true.'
            ELSE '✓ PASSED'
       END AS c3_status
FROM pg_catalog.pg_database
WHERE datistemplate = true AND datname IN ('template0', 'template1') \gset

\echo :c3_status

\echo ''

-- --------------------------------------------
-- Check 4. Master Username Check [global]
-- --------------------------------------------
\echo '=== 4. Master Username Check [global] ==='
SELECT (count(*) > 0)::text AS c4_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: Role(s) starting with pg_ found that have create role/db privileges. Master username cannot start with pg_.'
            ELSE '✓ PASSED'
       END AS c4_status
FROM pg_catalog.pg_roles
WHERE rolname LIKE 'pg_%'
  AND (rolcreaterole = true OR rolcreatedb = true)
  AND rolname NOT IN ('pg_monitor', 'pg_read_all_settings', 'pg_read_all_stats',
                      'pg_stat_scan_tables', 'pg_signal_backend', 'pg_read_server_files',
                      'pg_write_server_files', 'pg_execute_server_program',
                      'pg_checkpoint', 'pg_maintain', 'pg_use_reserved_connections',
                      'pg_create_subscription') \gset

\echo :c4_status

\if :c4_failed
    SELECT rolname, rolcreaterole, rolcreatedb
    FROM pg_catalog.pg_roles
    WHERE rolname LIKE 'pg_%'
      AND (rolcreaterole = true OR rolcreatedb = true)
      AND rolname NOT IN ('pg_monitor', 'pg_read_all_settings', 'pg_read_all_stats',
                          'pg_stat_scan_tables', 'pg_signal_backend', 'pg_read_server_files',
                          'pg_write_server_files', 'pg_execute_server_program',
                          'pg_checkpoint', 'pg_maintain', 'pg_use_reserved_connections',
                          'pg_create_subscription');
\endif

\echo ''

-- --------------------------------------------
-- Check 5. Database Size Analysis [global]
-- --------------------------------------------
\echo '=== 5. Database Size Analysis [global] ==='
\echo '✓ INFO'
SELECT datname AS database_name,
       pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_catalog.pg_database
WHERE datname NOT IN ('template0', 'template1', 'rdsadmin')
ORDER BY pg_database_size(datname) DESC;

\echo ''

-- --------------------------------------------
-- Check 6. Object Count Check [per-database]
-- --------------------------------------------
\echo '=== 6. Object Count Check [per-database] ==='
\echo '✓ INFO'
SELECT 'Tables' AS object_type, count(*) AS count
FROM pg_catalog.pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'Views', count(*)
FROM pg_catalog.pg_views
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'Materialized Views', count(*)
FROM pg_catalog.pg_matviews
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'Indexes', count(*)
FROM pg_catalog.pg_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'Sequences', count(*)
FROM pg_catalog.pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'Functions', count(*)
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT 'Triggers', count(*)
FROM pg_catalog.pg_trigger
WHERE NOT tgisinternal
UNION ALL
SELECT 'Extensions', count(*)
FROM pg_catalog.pg_extension
WHERE extname != 'plpgsql'
ORDER BY object_type;

\echo ''

-- --------------------------------------------
-- Check 7. Top 20 Largest Tables [per-database]
-- --------------------------------------------
\echo '=== 7. Top 20 Largest Tables [per-database] ==='
\echo '✓ Info'
SELECT schemaname AS schema_name,
       tablename AS table_name,
       pg_size_pretty(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename))) AS total_size,
       pg_size_pretty(pg_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename))) AS table_size,
       pg_size_pretty(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename))
                      - pg_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename))) AS index_size
FROM pg_catalog.pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename)) DESC
LIMIT 20;

\echo ''

-- --------------------------------------------
-- Check 8. Invalid Indexes Check [per-database]
-- --------------------------------------------
\echo '=== 8. Invalid Indexes Check [per-database] ==='
SELECT (count(*) > 0)::text AS c8_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' invalid index(es) found. Consider rebuilding with REINDEX.'
            ELSE '✓ PASSED'
       END AS c8_status
FROM pg_catalog.pg_index
WHERE NOT indisvalid \gset

\echo :c8_status

\if :c8_failed
    SELECT n.nspname AS schema, c.relname AS table_name, i.relname AS index_name
    FROM pg_catalog.pg_index x
    JOIN pg_catalog.pg_class i ON i.oid = x.indexrelid
    JOIN pg_catalog.pg_class c ON c.oid = x.indrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT x.indisvalid
    ORDER BY n.nspname, c.relname;
\endif

\echo ''

-- --------------------------------------------
-- Check 9. Duplicate Indexes Detection [per-database]
-- --------------------------------------------
\echo '=== 9. Duplicate Indexes Detection [per-database] ==='
SELECT (count(*) > 0)::text AS c9_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: Duplicate indexes found. Consider dropping duplicates to reduce upgrade time.'
            ELSE '✓ PASSED'
       END AS c9_status
FROM (
    SELECT indexdef, count(*) AS cnt
    FROM pg_catalog.pg_indexes
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY tablename, indexdef
    HAVING count(*) > 1
) sub \gset

\echo :c9_status

\if :c9_failed
    SELECT tablename, array_agg(indexname) AS duplicate_indexes, indexdef, count(*) AS duplicate_count
    FROM pg_catalog.pg_indexes
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY tablename, indexdef
    HAVING count(*) > 1
    ORDER BY tablename;
\endif

\echo ''

-- --------------------------------------------
-- Check 10. Unused Indexes Analysis [per-database]
-- --------------------------------------------
\echo '=== 10. Unused Indexes Analysis [per-database] ==='
SELECT 'false' AS c10_failed,
       '✓ Info: ' || count(*) || ' unused index(es) found (>10KB, 0 scans).' AS c10_status
FROM pg_catalog.pg_stat_user_indexes
WHERE idx_scan = 0
  AND pg_relation_size(indexrelid) > 10240 \gset

\echo :c10_status

SELECT schemaname, relname, indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
       idx_scan AS index_scans
FROM pg_catalog.pg_stat_user_indexes
WHERE idx_scan = 0
  AND pg_relation_size(indexrelid) > 10240
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

\echo ''

-- --------------------------------------------
-- Check 11. Table Bloat Analysis [per-database]
-- --------------------------------------------
\echo '=== 11. Table Bloat Analysis [per-database] ==='
SELECT (count(*) > 0)::text AS c11_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' table(s) with significant bloat (>1000 dead tuples). Consider VACUUM before upgrade.'
            ELSE '✓ PASSED'
       END AS c11_status
FROM pg_catalog.pg_stat_user_tables
WHERE n_dead_tup > 1000 \gset

\echo :c11_status

\if :c11_failed
    SELECT schemaname, relname,
           n_live_tup AS live_tuples,
           n_dead_tup AS dead_tuples,
           ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
           last_vacuum, last_autovacuum
    FROM pg_catalog.pg_stat_user_tables
    WHERE n_dead_tup > 1000
    ORDER BY n_dead_tup DESC
    LIMIT 20;
\endif

\echo ''

-- --------------------------------------------
-- Check 12. Active Long Running Queries [per-database]
-- --------------------------------------------
\echo '=== 12. Active Long Running Queries [per-database] ==='
SELECT (count(*) > 0)::text AS c12_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' query(ies) running longer than 5 minutes. Long transactions may block upgrade.'
            ELSE '✓ PASSED'
       END AS c12_status
FROM pg_catalog.pg_stat_activity
WHERE state != 'idle'
  AND query NOT LIKE '%pg_stat_activity%'
  AND now() - query_start > interval '5 minutes' \gset

\echo :c12_status

\if :c12_failed
    SELECT pid, usename, application_name, client_addr, state,
           now() - query_start AS duration,
           LEFT(query, 100) AS query_preview
    FROM pg_catalog.pg_stat_activity
    WHERE state != 'idle'
      AND query NOT LIKE '%pg_stat_activity%'
      AND now() - query_start > interval '5 minutes'
    ORDER BY duration DESC;
\endif

\echo ''

-- --------------------------------------------
-- Check 13. check_for_replication_slots [global]
-- --------------------------------------------
\echo '=== 13. check_for_replication_slots [global] ==='
\if :need_slot_check
    SELECT (count(*) > 0)::text AS c13_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: ' || count(*) || ' replication slot(s) found. Drop all logical replication slots and try again.'
                ELSE '✓ PASSED'
           END AS c13_status
    FROM pg_catalog.pg_replication_slots \gset

    \echo :c13_status

    \if :c13_failed
        SELECT slot_name, plugin, slot_type, database, active
        FROM pg_catalog.pg_replication_slots WHERE slot_type = 'logical';
    \endif
\else
    SELECT 'false' AS c13_failed, '- SKIP' AS c13_status \gset
    \echo '- Skipped (APG 17+ supports logical slot migration)'
\endif

\echo ''

-- --------------------------------------------
-- Check 14. Critical Configuration Parameters [global]
-- --------------------------------------------
\echo '=== 14. Critical Configuration Parameters [global] ==='
\echo '✓ Info'
SELECT name, setting, unit, source, context
FROM pg_catalog.pg_settings
WHERE name IN (
    'max_connections', 'shared_buffers', 'effective_cache_size',
    'maintenance_work_mem', 'work_mem', 'wal_level',
    'max_wal_senders', 'max_replication_slots',
    'autovacuum', 'log_statement'
)
ORDER BY name;

\echo ''

-- --------------------------------------------
-- Check 15. Installed Extensions [per-database]
-- --------------------------------------------
\echo '=== 15. Installed Extensions [per-database] ==='
SELECT (count(*) > 0)::text AS c15_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' extension(s) have newer versions available. Consider updating before upgrade.'
            ELSE '✓ PASSED'
       END AS c15_status
FROM pg_catalog.pg_extension e
LEFT JOIN pg_catalog.pg_available_extensions a ON e.extname = a.name
WHERE a.default_version IS NOT NULL
  AND e.extversion <> a.default_version \gset

\echo :c15_status

SELECT e.extname AS extension_name,
       e.extversion AS installed_version,
       a.default_version AS available_version,
       CASE WHEN a.default_version IS NULL THEN 'UNAVAILABLE'
            WHEN e.extversion <> a.default_version THEN 'UPDATE AVAILABLE'
            ELSE 'OK'
       END AS status
FROM pg_catalog.pg_extension e
LEFT JOIN pg_catalog.pg_available_extensions a ON e.extname = a.name
WHERE e.extname != 'plpgsql'
ORDER BY CASE WHEN e.extversion <> a.default_version THEN 0 ELSE 1 END, e.extname;

\echo ''

-- --------------------------------------------
-- Check 15b. check_for_multi_extensions_version [per-database]
-- --------------------------------------------
\echo '=== 15b. check_for_multi_extensions_version [per-database] ==='
SELECT (count(*) > 0)::text AS c15b_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' extension(s) need updating before upgrade.'
            ELSE '✓ PASSED'
       END AS c15b_status
FROM pg_catalog.pg_available_extensions
WHERE name IN ('postgis','pgrouting','postgis_raster','postgis_tiger_geocoder',
               'postgis_topology','address_standardizer','address_standardizer_data_us','rdkit')
  AND installed_version IS NOT NULL
  AND default_version != installed_version \gset

\echo :c15b_status

\if :c15b_failed
    SELECT name, installed_version, default_version
    FROM pg_catalog.pg_available_extensions
    WHERE name IN ('postgis','pgrouting','postgis_raster','postgis_tiger_geocoder',
                   'postgis_topology','address_standardizer','address_standardizer_data_us','rdkit')
      AND installed_version IS NOT NULL
      AND default_version != installed_version;
\endif

\echo ''

-- --------------------------------------------
-- Check 16. Views Dependent on System Catalogs [per-database]
-- --------------------------------------------
\echo '=== 16. Views Dependent on System Catalogs [per-database] ==='
SELECT (count(*) > 0)::text AS c16_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' view(s) depend on system catalogs. Drop and recreate after upgrade.'
            ELSE '✓ PASSED'
       END AS c16_status
FROM (
    SELECT dependent_view.relname
    FROM pg_catalog.pg_depend
    JOIN pg_catalog.pg_rewrite ON pg_depend.objid = pg_rewrite.oid
    JOIN pg_catalog.pg_class AS dependent_view ON pg_rewrite.ev_class = dependent_view.oid
    JOIN pg_catalog.pg_class AS source_table ON pg_depend.refobjid = source_table.oid
    JOIN pg_catalog.pg_namespace AS dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
    JOIN pg_catalog.pg_namespace AS source_ns ON source_ns.oid = source_table.relnamespace
    WHERE source_ns.nspname = 'pg_catalog'
      AND dependent_ns.nspname NOT IN ('pg_catalog', 'information_schema')
) sub \gset

\echo :c16_status

\if :c16_failed
    SELECT DISTINCT
        dependent_ns.nspname AS view_schema,
        dependent_view.relname AS view_name,
        source_table.relname AS depends_on
    FROM pg_catalog.pg_depend
    JOIN pg_catalog.pg_rewrite ON pg_depend.objid = pg_rewrite.oid
    JOIN pg_catalog.pg_class AS dependent_view ON pg_rewrite.ev_class = dependent_view.oid
    JOIN pg_catalog.pg_class AS source_table ON pg_depend.refobjid = source_table.oid
    JOIN pg_catalog.pg_namespace AS dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
    JOIN pg_catalog.pg_namespace AS source_ns ON source_ns.oid = source_table.relnamespace
    WHERE source_ns.nspname = 'pg_catalog'
      AND dependent_ns.nspname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY dependent_ns.nspname, dependent_view.relname;
\endif

\echo ''

-- --------------------------------------------
-- Check 17. check_for_prepared_transactions [global]
-- --------------------------------------------
\echo '=== 17. check_for_prepared_transactions [global] ==='
SELECT (count(*) > 0)::text AS c17_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: ' || count(*) || ' uncommitted prepared transaction(s) found. Please commit or rollback.'
            ELSE '✓ PASSED'
       END AS c17_status
FROM pg_catalog.pg_prepared_xacts \gset

\echo :c17_status

\if :c17_failed
    SELECT gid, prepared, owner, database
    FROM pg_catalog.pg_prepared_xacts;
\endif

\echo ''

-- --------------------------------------------
-- Check 18. Transaction ID Age Check [global]
-- --------------------------------------------
\echo '=== 18. Transaction ID Age Check [global] ==='
SELECT (count(*) > 0)::text AS c18_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: Database(s) with high transaction ID age found. Consider VACUUM FREEZE.'
            ELSE '✓ PASSED'
       END AS c18_status
FROM pg_catalog.pg_database
WHERE age(datfrozenxid) > 200000000 \gset

\echo :c18_status

SELECT datname AS database_name,
       age(datfrozenxid) AS xid_age,
       CASE
           WHEN age(datfrozenxid) > 200000000 THEN 'CRITICAL - VACUUM REQUIRED'
           WHEN age(datfrozenxid) > 150000000 THEN 'WARNING - Plan VACUUM'
           ELSE 'OK'
       END AS status
FROM pg_catalog.pg_database
ORDER BY age(datfrozenxid) DESC
LIMIT 20;

\echo ''

-- --------------------------------------------
-- Check 19. Unsupported Data Types (reg*) [per-database]
-- --------------------------------------------
\echo '=== 19. Unsupported Data Types Check (reg* Types) [per-database] ==='
SELECT (count(*) > 0)::text AS c19_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: ' || count(*) || ' reg* data type column(s) found in user tables. OIDs not preserved by pg_upgrade.'
            ELSE '✓ PASSED'
       END AS c19_status
FROM (
    WITH RECURSIVE oids AS (
        SELECT oid FROM pg_catalog.pg_type t
        WHERE t.typnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'pg_catalog')
          AND t.typname IN ('regcollation','regconfig','regdictionary','regnamespace',
                            'regoper','regoperator','regproc','regprocedure')
        UNION ALL
        SELECT * FROM (
            WITH x AS (SELECT oid FROM oids)
            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
            WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
              AND NOT a.attisdropped AND a.atttypid = x.oid
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
        ) foo
    )
    SELECT n.nspname, c.relname, a.attname
    FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
    WHERE c.oid = a.attrelid AND NOT a.attisdropped
      AND a.atttypid IN (SELECT oid FROM oids)
      AND c.relkind IN ('r', 'm', 'i')
      AND c.relnamespace = n.oid
      AND n.nspname !~ '^pg_temp_'
      AND n.nspname !~ '^pg_toast_temp_'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
) sub \gset

\echo :c19_status

\if :c19_failed
    WITH RECURSIVE oids AS (
        SELECT oid FROM pg_catalog.pg_type t
        WHERE t.typnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'pg_catalog')
          AND t.typname IN ('regcollation','regconfig','regdictionary','regnamespace',
                            'regoper','regoperator','regproc','regprocedure')
        UNION ALL
        SELECT * FROM (
            WITH x AS (SELECT oid FROM oids)
            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
            WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
              AND NOT a.attisdropped AND a.atttypid = x.oid
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
        ) foo
    )
    SELECT n.nspname, c.relname, a.attname
    FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
    WHERE c.oid = a.attrelid AND NOT a.attisdropped
      AND a.atttypid IN (SELECT oid FROM oids)
      AND c.relkind IN ('r', 'm', 'i')
      AND c.relnamespace = n.oid
      AND n.nspname !~ '^pg_temp_'
      AND n.nspname !~ '^pg_toast_temp_'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema');
\endif

\echo ''

-- --------------------------------------------
-- Check 20. Large Objects Check [per-database]
-- --------------------------------------------
\echo '=== 20. Large Objects Check [per-database] ==='
SELECT (count(*) > 100000)::text AS c20_failed,
       CASE WHEN count(*) > 100000
            THEN '⚠️ WARNING: ' || count(*) || ' large objects found. Excessive large objects can cause OOM during upgrade.'
            ELSE '✓ PASSED (' || count(*) || ' large objects)'
       END AS c20_status
FROM pg_catalog.pg_largeobject_metadata \gset

\echo :c20_status

\if :c20_failed
    SELECT count(*) AS large_object_count FROM pg_catalog.pg_largeobject_metadata;
    SELECT pg_size_pretty(pg_total_relation_size('pg_largeobject')) AS lo_table_size;
\endif

\echo ''

-- --------------------------------------------
-- Check 21. Unknown Data Type Check (PG 9.6 -> 10+) [per-database]
-- SKIP: PostgreSQL 9.6 is EOL. This check only applies to PG < 10.
-- --------------------------------------------
\echo '=== 21. Unknown Data Type Check (PG 9.6 -> 10+) [per-database] ==='
\echo '- SKIP: Only applicable for PostgreSQL < 10 (EOL)'

\echo ''

-- --------------------------------------------
-- Check 22. Parameter Permissions Check [per-database]
-- (source >= 15)
-- --------------------------------------------
\echo '=== 22. Parameter Permissions Check [per-database] ==='
SELECT (count(*) > 0)::text AS c22_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' custom parameter permission(s) found. May cause upgrade failure.'
            ELSE '✓ PASSED'
       END AS c22_status
FROM information_schema.role_routine_grants
WHERE routine_name LIKE '%parameter%' \gset

\echo :c22_status

\if :c22_failed
    SELECT routine_name, grantee, privilege_type
    FROM information_schema.role_routine_grants
    WHERE routine_name LIKE '%parameter%';
\endif

\echo ''

-- --------------------------------------------
-- Check 23. Schema Usage [per-database]
-- --------------------------------------------
\echo '=== 23. Schema Usage [per-database] ==='
\echo '✓ Info'
SELECT n.nspname AS schema_name,
       pg_catalog.pg_get_userbyid(n.nspowner) AS owner,
       COALESCE(pg_size_pretty(SUM(pg_total_relation_size(c.oid))), '0 bytes') AS size,
       COUNT(DISTINCT CASE WHEN c.relkind = 'r' THEN c.oid END) AS tables,
       COUNT(DISTINCT CASE WHEN c.relkind = 'i' THEN c.oid END) AS indexes,
       COUNT(DISTINCT CASE WHEN c.relkind = 'v' THEN c.oid END) AS views
FROM pg_catalog.pg_namespace n
LEFT JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND n.nspname NOT LIKE 'pg_temp%'
GROUP BY n.nspname, n.nspowner
ORDER BY COALESCE(SUM(pg_total_relation_size(c.oid)), 0) DESC;

\echo ''

-- --------------------------------------------
-- Check 24. Version Compatibility and Upgrade Path [global]
-- SKIP: Requires AWS CLI (aws rds describe-db-engine-versions).
-- --------------------------------------------
\echo '=== 24. Version Compatibility and Upgrade Path [global] ==='
\echo '- SKIP: Requires AWS CLI. Use shell script (pg-major-version-upgrade-precheck.sh) for this check.'

\echo ''

-- --------------------------------------------
-- Check 25. Check logical replication parameters [global]
-- --------------------------------------------
\echo '=== 25. Logical replication parameters [global] ==='
SELECT (count(*) > 0)::text AS c25_failed,
       CASE WHEN count(*) > 0 THEN '❌ FAILED' ELSE '✓ PASSED' END AS c25_status
FROM (
    WITH db_count AS (
        SELECT count(*) AS cnt
        FROM pg_catalog.pg_database
        WHERE datistemplate = false
          AND datname NOT IN ('rdsadmin', 'template0', 'template1')
    ),
    params AS (
        SELECT name, setting::bigint AS setting
        FROM pg_catalog.pg_settings
        WHERE name IN ('max_replication_slots', 'max_wal_senders',
                       'max_logical_replication_workers', 'max_worker_processes')
    )
    SELECT 1
    FROM params p, db_count d
    WHERE (p.name = 'max_replication_slots' AND p.setting < d.cnt + 1)
       OR (p.name = 'max_wal_senders' AND p.setting < (SELECT setting FROM params WHERE name = 'max_replication_slots'))
       OR (p.name = 'max_logical_replication_workers' AND p.setting < d.cnt + 1)
       OR (p.name = 'max_worker_processes' AND p.setting <= (SELECT setting FROM params WHERE name = 'max_logical_replication_workers'))
) sub \gset

\echo :c25_status

-- Show parameter details
WITH db_count AS (
    SELECT count(*) AS cnt
    FROM pg_catalog.pg_database
    WHERE datistemplate = false
      AND datname NOT IN ('rdsadmin', 'template0', 'template1')
),
params AS (
    SELECT name, setting::bigint AS setting
    FROM pg_catalog.pg_settings
    WHERE name IN ('max_replication_slots', 'max_wal_senders',
                   'max_logical_replication_workers', 'max_worker_processes')
)
SELECT p.name,
       p.setting AS current_value,
       CASE p.name
           WHEN 'max_logical_replication_workers' THEN d.cnt + 1
           WHEN 'max_replication_slots'           THEN d.cnt + 1
           WHEN 'max_wal_senders'                 THEN (SELECT setting FROM params WHERE name = 'max_replication_slots')
           WHEN 'max_worker_processes'             THEN (SELECT setting FROM params WHERE name = 'max_logical_replication_workers') + 1
       END AS required_value
FROM params p, db_count d
ORDER BY p.name;

\echo ''

-- --------------------------------------------
-- Check 25b. Check rds.logical_replication [global]
-- --------------------------------------------
\echo '=== 25b. rds.logical_replication [global] ==='
SELECT (setting != 'on')::text AS c25b_failed,
       CASE WHEN setting = 'on'
            THEN '✓ PASSED'
            ELSE '❌ FAILED: rds.logical_replication is ' || setting || '. Set to 1 in parameter group and reboot.'
       END AS c25b_status
FROM pg_catalog.pg_settings
WHERE name = 'rds.logical_replication' \gset

\echo :c25b_status

\echo ''

-- --------------------------------------------
-- Check 26. Check tables without Primary Key [per-database]
-- (always runs)
-- --------------------------------------------
\echo '=== 26. Check tables without Primary Key [per-database] ==='
SELECT (count(*) > 0)::text AS c26_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' table(s) without Primary Key. Logical replication requires PK or REPLICA IDENTITY FULL.'
            ELSE '✓ PASSED'
       END AS c26_status
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'rdsadmin')
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint con
      WHERE con.conrelid = c.oid AND con.contype = 'p'
  ) \gset

\echo :c26_status

\if :c26_failed
    -- Show details if any found
    SELECT n.nspname AS schema, c.relname AS table_name,
           CASE WHEN c.relreplident = 'd' THEN 'DEFAULT'
                WHEN c.relreplident = 'n' THEN 'NOTHING'
                WHEN c.relreplident = 'f' THEN 'FULL'
                WHEN c.relreplident = 'i' THEN 'INDEX'
           END AS replica_identity
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'rdsadmin')
      AND NOT EXISTS (
          SELECT 1 FROM pg_catalog.pg_constraint con
          WHERE con.conrelid = c.oid AND con.contype = 'p'
      )
    ORDER BY n.nspname, c.relname;
\endif

\echo ''

-- --------------------------------------------
-- Check 27. Foreign Tables Check for Blue/Green [per-database]
-- --------------------------------------------
\echo '=== 27. Foreign Tables Check for Blue/Green [per-database] ==='
SELECT (count(*) > 0)::text AS c27_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' foreign table(s) found. These will NOT be replicated during Blue/Green deployment.'
            ELSE '✓ PASSED'
       END AS c27_status
FROM pg_catalog.pg_foreign_table ft
JOIN pg_catalog.pg_class c ON c.oid = ft.ftrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') \gset

\echo :c27_status

\if :c27_failed
    SELECT n.nspname AS schema, c.relname AS table_name, s.srvname AS server
    FROM pg_catalog.pg_foreign_table ft
    JOIN pg_catalog.pg_class c ON c.oid = ft.ftrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_foreign_server s ON s.oid = ft.ftserver
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY n.nspname, c.relname;
\endif

\echo ''

-- --------------------------------------------
-- Check 28. Unlogged Tables Check for Blue/Green [per-database]
-- --------------------------------------------
\echo '=== 28. Unlogged Tables Check for Blue/Green [per-database] ==='
SELECT (count(*) > 0)::text AS c28_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' unlogged table(s) found. These will NOT be replicated during Blue/Green deployment.'
            ELSE '✓ PASSED'
       END AS c28_status
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relpersistence = 'u'
  AND c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema') \gset

\echo :c28_status

\if :c28_failed
    SELECT n.nspname AS schema, c.relname AS table_name,
           pg_size_pretty(pg_total_relation_size(c.oid)) AS size
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relpersistence = 'u'
      AND c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY pg_total_relation_size(c.oid) DESC;
\endif

\echo ''

-- --------------------------------------------
-- Check 29. Publications Check for Blue/Green [per-database]
-- --------------------------------------------
\echo '=== 29. Publications Check for Blue/Green [per-database] ==='
SELECT (count(*) > 0)::text AS c29_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' publication(s) found. Review before Blue/Green deployment.'
            ELSE '✓ PASSED'
       END AS c29_status
FROM pg_catalog.pg_publication \gset

\echo :c29_status

\if :c29_failed
    SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
    FROM pg_catalog.pg_publication;
\endif

\echo ''

-- --------------------------------------------
-- Check 30. Check for logical replication subscriptions [per-database]
-- --------------------------------------------
\echo '=== 30. Check for logical replication subscriptions [per-database] ==='
SELECT (count(*) > 0)::text AS c30_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: ' || count(*) || ' subscription(s) found. Must be dropped before Blue/Green upgrade.'
            ELSE '✓ PASSED'
       END AS c30_status
FROM pg_catalog.pg_subscription \gset

\echo :c30_status

\if :c30_failed
    SELECT subname,
           regexp_replace(subconninfo, 'password=[^ ]*', 'password=***') AS subconninfo_masked,
           subslotname,
           subenabled
    FROM pg_catalog.pg_subscription;
\endif

\echo ''

-- --------------------------------------------
-- Check 31. Foreign Data Wrapper Endpoint Check for Blue/Green [per-database]
-- --------------------------------------------
\echo '=== 31. Foreign Data Wrapper Endpoint Check for Blue/Green [per-database] ==='
SELECT (count(*) > 0)::text AS c31_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' foreign server(s) found. Verify endpoints are accessible from new Blue/Green environment.'
            ELSE '✓ PASSED'
       END AS c31_status
FROM pg_catalog.pg_foreign_server \gset

\echo :c31_status

\if :c31_failed
    SELECT s.srvname AS server_name,
           f.fdwname AS fdw_name,
           s.srvoptions AS options
    FROM pg_catalog.pg_foreign_server s
    JOIN pg_catalog.pg_foreign_data_wrapper f ON f.oid = s.srvfdw
    ORDER BY s.srvname;
\endif

\echo ''

-- --------------------------------------------
-- Check 32. High Write Volume Tables Check for Blue/Green [per-database]
-- --------------------------------------------
\echo '=== 32. High Write Volume Tables Check for Blue/Green [per-database] ==='
SELECT (count(*) > 0)::text AS c32_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' table(s) with high write volume. May increase Blue/Green switchover time.'
            ELSE '✓ PASSED'
       END AS c32_status
FROM pg_catalog.pg_stat_user_tables
WHERE (n_tup_ins + n_tup_upd + n_tup_del) > 100000 \gset

\echo :c32_status

\if :c32_failed
    SELECT schemaname, relname,
           n_tup_ins AS inserts, n_tup_upd AS updates, n_tup_del AS deletes,
           (n_tup_ins + n_tup_upd + n_tup_del) AS total_writes
    FROM pg_catalog.pg_stat_user_tables
    WHERE (n_tup_ins + n_tup_upd + n_tup_del) > 100000
    ORDER BY (n_tup_ins + n_tup_upd + n_tup_del) DESC
    LIMIT 20;
\endif

\echo ''

-- --------------------------------------------
-- Check 33. Partitioned Tables Check for Blue/Green [per-database]
-- --------------------------------------------
\echo '=== 33. Partitioned Tables Check for Blue/Green [per-database] ==='
\echo '✓ Info'
SELECT n.nspname AS schema, c.relname AS table_name,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
       (SELECT count(*) FROM pg_catalog.pg_inherits i WHERE i.inhparent = c.oid) AS partition_count
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'p'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(c.oid) DESC;

\echo ''

-- --------------------------------------------
-- Check 34. Blue/Green Extension Compatibility Check [per-database]
-- --------------------------------------------
\echo '=== 34. Blue/Green Extension Compatibility Check [per-database] ==='
SELECT (count(*) > 0)::text AS c34_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' extension(s) may have compatibility issues with Blue/Green deployment.'
            ELSE '✓ PASSED'
       END AS c34_status
FROM pg_catalog.pg_extension e
WHERE e.extname IN ('pglogical', 'pg_repack', 'pg_hint_plan', 'pg_cron', 'pg_tle') \gset

\echo :c34_status

\if :c34_failed
    SELECT extname, extversion
    FROM pg_catalog.pg_extension
    WHERE extname IN ('pglogical', 'pg_repack', 'pg_hint_plan', 'pg_cron', 'pg_tle')
    ORDER BY extname;
\endif

\echo ''

-- --------------------------------------------
-- Check 35. Check DDL event triggers [per-database]
-- --------------------------------------------
\echo '=== 35. Check DDL event triggers [per-database] ==='
SELECT (count(*) > 0)::text AS c35_failed,
       CASE WHEN count(*) > 0
            THEN '⚠️ WARNING: ' || count(*) || ' DDL event trigger(s) found - may interfere with Blue/Green deployment. Consider disabling.'
            ELSE '✓ PASSED'
       END AS c35_status
FROM pg_catalog.pg_event_trigger
WHERE evtevent IN ('ddl_command_start', 'ddl_command_end', 'sql_drop')
  AND evtname != 'dts_capture_catalog_start' \gset

\echo :c35_status

\if :c35_failed
    SELECT evtname AS trigger_name, evtevent AS event,
           evtfoid::regproc AS function_name, evtenabled AS enabled
    FROM pg_catalog.pg_event_trigger
    WHERE evtevent IN ('ddl_command_start', 'ddl_command_end', 'sql_drop')
      AND evtname != 'dts_capture_catalog_start';
\endif

\echo ''

-- --------------------------------------------
-- Check 35b. Check for DTS trigger [per-database]
-- --------------------------------------------
\echo '=== 35b. Check for DTS trigger [per-database] ==='
SELECT (count(*) > 0)::text AS c35b_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: DTS trigger dts_capture_catalog_start found. Must be dropped before Blue/Green upgrade.'
            ELSE '✓ PASSED'
       END AS c35b_status
FROM pg_catalog.pg_event_trigger
WHERE evtname = 'dts_capture_catalog_start' \gset

\echo :c35b_status

\if :c35b_failed
    SELECT evtname AS trigger_name, evtevent AS event, evtenabled AS enabled
    FROM pg_catalog.pg_event_trigger
    WHERE evtname = 'dts_capture_catalog_start';
\endif

\echo ''

-- --------------------------------------------
-- Check 35c. max_locks_per_transaction Validation for Blue/Green [global]
-- Note: This check validates against the current database only.
--       Shell script version sums tables across ALL databases.
-- --------------------------------------------
\echo '=== 35c. max_locks_per_transaction Validation for Blue/Green [global] ==='
SELECT (CASE WHEN current_setting('max_locks_per_transaction')::int <
              CEIL(count(*)::numeric / (current_setting('max_connections')::int +
                   current_setting('max_prepared_transactions')::int))
         THEN true ELSE false END)::text AS c35c_failed,
       CASE WHEN current_setting('max_locks_per_transaction')::int <
              CEIL(count(*)::numeric / (current_setting('max_connections')::int +
                   current_setting('max_prepared_transactions')::int))
            THEN '⚠️ WARNING: max_locks_per_transaction (' || current_setting('max_locks_per_transaction') ||
                 ') may be insufficient. Tables in current DB: ' || count(*) ||
                 '. Note: Shell script checks across ALL databases for accurate calculation.'
            ELSE '✓ PASSED (max_locks_per_transaction=' || current_setting('max_locks_per_transaction') ||
                 ', tables in current DB: ' || count(*) || ')'
       END AS c35c_status
FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND table_type = 'BASE TABLE' \gset

\echo :c35c_status

\echo ''

-- --------------------------------------------
-- Check 36. check_chkpass_extension [per-database]
-- (target >= 11)
-- --------------------------------------------
\echo '=== 36. check_chkpass_extension [per-database] ==='
\if :target_ge_11
    SELECT (count(*) > 0)::text AS c36_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: chkpass extension installed - not supported in PG >= 11. Please drop the extension.'
                ELSE '✓ PASSED'
           END AS c36_status
    FROM pg_catalog.pg_extension WHERE extname = 'chkpass' \gset

    \echo :c36_status

    \if :c36_failed
        SELECT extname, extversion FROM pg_catalog.pg_extension WHERE extname = 'chkpass';
    \endif
\else
    SELECT 'false' AS c36_failed, '- SKIP' AS c36_status \gset
    \echo '- Skipped (target version < 11)'
\endif

\echo ''

-- --------------------------------------------
-- Check 37. check_tsearch2_extension [per-database]
-- (target >= 11)
-- --------------------------------------------
\echo '=== 37. check_tsearch2_extension [per-database] ==='
\if :target_ge_11
    SELECT (count(*) > 0)::text AS c37_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: tsearch2 extension installed - not supported in PG >= 11. Please drop the extension.'
                ELSE '✓ PASSED'
           END AS c37_status
    FROM pg_catalog.pg_extension WHERE extname = 'tsearch2' \gset

    \echo :c37_status

    \if :c37_failed
        SELECT extname, extversion FROM pg_catalog.pg_extension WHERE extname = 'tsearch2';
    \endif
\else
    SELECT 'false' AS c37_failed, '- SKIP' AS c37_status \gset
    \echo '- Skipped (target version < 11)'
\endif

\echo ''

-- --------------------------------------------
-- Check 38. check_pg_repack_extension [per-database]
-- (target >= 14)
-- --------------------------------------------
\echo '=== 38. check_pg_repack_extension [per-database] ==='
\if :target_ge_14
    SELECT (count(*) > 0)::text AS c38_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: pg_repack installed (version: ' || string_agg(extversion, ', ') || '). Must be dropped before upgrade to PG >= 14.'
                ELSE '✓ PASSED'
           END AS c38_status
    FROM pg_catalog.pg_extension WHERE extname = 'pg_repack' \gset

    \echo :c38_status
\else
    SELECT 'false' AS c38_failed, '- SKIP' AS c38_status \gset
    \echo '- Skipped (target version < 14)'
\endif

\echo ''

-- --------------------------------------------
-- Check 39. Checking for system-defined composite types in user tables [per-database]
-- --------------------------------------------
\echo '=== 39. Checking for system-defined composite types in user tables [per-database] ==='
SELECT (count(*) > 0)::text AS c39_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: ' || count(*) || ' system-defined composite type column(s) found in user tables. Please drop the problem columns.'
            ELSE '✓ PASSED'
       END AS c39_status
FROM (
    WITH RECURSIVE oids AS (
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
            WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
              AND NOT a.attisdropped AND a.atttypid = x.oid
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
        ) foo
    )
    SELECT n.nspname, c.relname, a.attname
    FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
    WHERE c.oid = a.attrelid AND NOT a.attisdropped
      AND a.atttypid IN (SELECT oid FROM oids)
      AND c.relkind IN ('r', 'm', 'i')
      AND c.relnamespace = n.oid
      AND n.nspname !~ '^pg_temp_'
      AND n.nspname !~ '^pg_toast_temp_'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
) sub \gset

\echo :c39_status

\if :c39_failed
    -- Show details if any found
    WITH RECURSIVE oids AS (
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
            WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
              AND NOT a.attisdropped AND a.atttypid = x.oid
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
        ) foo
    )
    SELECT n.nspname, c.relname, a.attname
    FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
    WHERE c.oid = a.attrelid AND NOT a.attisdropped
      AND a.atttypid IN (SELECT oid FROM oids)
      AND c.relkind IN ('r', 'm', 'i')
      AND c.relnamespace = n.oid
      AND n.nspname !~ '^pg_temp_'
      AND n.nspname !~ '^pg_toast_temp_'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema');
\endif

\echo ''

-- --------------------------------------------
-- Check 39b. Checking for reg* data types in user tables [per-database]
-- --------------------------------------------
\echo '=== 39b. Checking for reg* data types in user tables [per-database] ==='
SELECT (count(*) > 0)::text AS c39b_failed,
       CASE WHEN count(*) > 0
            THEN '❌ FAILED: ' || count(*) || ' reg* data type column(s) found in user tables. Please drop the problem columns.'
            ELSE '✓ PASSED'
       END AS c39b_status
FROM (
    WITH RECURSIVE oids AS (
        SELECT oid FROM pg_catalog.pg_type t
        WHERE t.typnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'pg_catalog')
          AND t.typname IN ('regcollation','regconfig','regdictionary','regnamespace',
                            'regoper','regoperator','regproc','regprocedure')
        UNION ALL
        SELECT * FROM (
            WITH x AS (SELECT oid FROM oids)
            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
            WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
              AND NOT a.attisdropped AND a.atttypid = x.oid
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
        ) foo
    )
    SELECT n.nspname, c.relname, a.attname
    FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
    WHERE c.oid = a.attrelid AND NOT a.attisdropped
      AND a.atttypid IN (SELECT oid FROM oids)
      AND c.relkind IN ('r', 'm', 'i')
      AND c.relnamespace = n.oid
      AND n.nspname !~ '^pg_temp_'
      AND n.nspname !~ '^pg_toast_temp_'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
) sub \gset

\echo :c39b_status

\if :c39b_failed
    -- Show details if any found
    WITH RECURSIVE oids AS (
        SELECT oid FROM pg_catalog.pg_type t
        WHERE t.typnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'pg_catalog')
          AND t.typname IN ('regcollation','regconfig','regdictionary','regnamespace',
                            'regoper','regoperator','regproc','regprocedure')
        UNION ALL
        SELECT * FROM (
            WITH x AS (SELECT oid FROM oids)
            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
            WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
              AND NOT a.attisdropped AND a.atttypid = x.oid
            UNION ALL
            SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
            WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
        ) foo
    )
    SELECT n.nspname, c.relname, a.attname
    FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
    WHERE c.oid = a.attrelid AND NOT a.attisdropped
      AND a.atttypid IN (SELECT oid FROM oids)
      AND c.relkind IN ('r', 'm', 'i')
      AND c.relnamespace = n.oid
      AND n.nspname !~ '^pg_temp_'
      AND n.nspname !~ '^pg_toast_temp_'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema');
\endif

\echo ''

-- --------------------------------------------
-- Check 40. Checking for incompatible aclitem data type [per-database]
-- (source <= 15 AND target >= 16)
-- --------------------------------------------
\echo '=== 40. Checking for incompatible aclitem data type [per-database] ==='
\if :need_aclitem_check
    SELECT (count(*) > 0)::text AS c40_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: ' || count(*) || ' aclitem column(s) found - format changed in PG 16. Please drop the problem columns.'
                ELSE '✓ PASSED'
           END AS c40_status
    FROM (
        WITH RECURSIVE oids AS (
            SELECT 'pg_catalog.aclitem'::pg_catalog.regtype AS oid
            UNION ALL
            SELECT * FROM (
                WITH x AS (SELECT oid FROM oids)
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
                  AND NOT a.attisdropped AND a.atttypid = x.oid
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
            ) foo
        )
        SELECT n.nspname, c.relname, a.attname
        FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
        WHERE c.oid = a.attrelid AND NOT a.attisdropped
          AND a.atttypid IN (SELECT oid FROM oids)
          AND c.relkind IN ('r', 'm', 'i')
          AND c.relnamespace = n.oid
          AND n.nspname !~ '^pg_temp_'
          AND n.nspname !~ '^pg_toast_temp_'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    ) sub \gset

    \echo :c40_status

    \if :c40_failed
        -- Show details if any found
        WITH RECURSIVE oids AS (
            SELECT 'pg_catalog.aclitem'::pg_catalog.regtype AS oid
            UNION ALL
            SELECT * FROM (
                WITH x AS (SELECT oid FROM oids)
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
                  AND NOT a.attisdropped AND a.atttypid = x.oid
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
            ) foo
        )
        SELECT n.nspname, c.relname, a.attname
        FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
        WHERE c.oid = a.attrelid AND NOT a.attisdropped
          AND a.atttypid IN (SELECT oid FROM oids)
          AND c.relkind IN ('r', 'm', 'i')
          AND c.relnamespace = n.oid
          AND n.nspname !~ '^pg_temp_'
          AND n.nspname !~ '^pg_toast_temp_'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema');
    \endif
\else
    SELECT 'false' AS c40_failed, '- SKIP' AS c40_status \gset
    \echo '- Skipped (not applicable for this upgrade path)'
\endif

\echo ''

-- --------------------------------------------
-- Check 41. Checking for invalid sql_identifier user columns [per-database]
-- (source <= 11)
-- --------------------------------------------
\echo '=== 41. Checking for invalid sql_identifier user columns [per-database] ==='
\if :source_le_11
    SELECT (count(*) > 0)::text AS c41_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: ' || count(*) || ' sql_identifier column(s) found - format changed in PG 12. Please drop the problem columns.'
                ELSE '✓ PASSED'
           END AS c41_status
    FROM (
        WITH RECURSIVE oids AS (
            SELECT 'information_schema.sql_identifier'::pg_catalog.regtype AS oid
            UNION ALL
            SELECT * FROM (
                WITH x AS (SELECT oid FROM oids)
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
                  AND NOT a.attisdropped AND a.atttypid = x.oid
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
            ) foo
        )
        SELECT n.nspname, c.relname, a.attname
        FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
        WHERE c.oid = a.attrelid AND NOT a.attisdropped
          AND a.atttypid IN (SELECT oid FROM oids)
          AND c.relkind IN ('r', 'm', 'i')
          AND c.relnamespace = n.oid
          AND n.nspname !~ '^pg_temp_'
          AND n.nspname !~ '^pg_toast_temp_'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    ) sub \gset

    \echo :c41_status

    \if :c41_failed
        WITH RECURSIVE oids AS (
            SELECT 'information_schema.sql_identifier'::pg_catalog.regtype AS oid
            UNION ALL
            SELECT * FROM (
                WITH x AS (SELECT oid FROM oids)
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
                  AND NOT a.attisdropped AND a.atttypid = x.oid
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
            ) foo
        )
        SELECT n.nspname, c.relname, a.attname
        FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
        WHERE c.oid = a.attrelid AND NOT a.attisdropped
          AND a.atttypid IN (SELECT oid FROM oids)
          AND c.relkind IN ('r', 'm', 'i')
          AND c.relnamespace = n.oid
          AND n.nspname !~ '^pg_temp_'
          AND n.nspname !~ '^pg_toast_temp_'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema');
    \endif
\else
    SELECT 'false' AS c41_failed, '- SKIP' AS c41_status \gset
    \echo '- Skipped (source version > 11)'
\endif

\echo ''

-- --------------------------------------------
-- Check 42. Checking for removed abstime/reltime/tinterval data types [per-database]
-- (source <= 11)
-- --------------------------------------------
\echo '=== 42. Checking for removed abstime/reltime/tinterval data types [per-database] ==='
\if :source_le_11
    SELECT (count(*) > 0)::text AS c42_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: ' || count(*) || ' column(s) using removed data types (abstime/reltime/tinterval). Please drop or alter the problem columns.'
                ELSE '✓ PASSED'
           END AS c42_status
    FROM (
        WITH RECURSIVE oids AS (
            SELECT 'pg_catalog.abstime'::pg_catalog.regtype AS oid
            UNION ALL SELECT 'pg_catalog.reltime'::pg_catalog.regtype
            UNION ALL SELECT 'pg_catalog.tinterval'::pg_catalog.regtype
            UNION ALL
            SELECT * FROM (
                WITH x AS (SELECT oid FROM oids)
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
                  AND NOT a.attisdropped AND a.atttypid = x.oid
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
            ) foo
        )
        SELECT n.nspname, c.relname, a.attname
        FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
        WHERE c.oid = a.attrelid AND NOT a.attisdropped
          AND a.atttypid IN (SELECT oid FROM oids)
          AND c.relkind IN ('r', 'm', 'i')
          AND c.relnamespace = n.oid
          AND n.nspname !~ '^pg_temp_'
          AND n.nspname !~ '^pg_toast_temp_'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    ) sub \gset

    \echo :c42_status

    \if :c42_failed
        WITH RECURSIVE oids AS (
            SELECT 'pg_catalog.abstime'::pg_catalog.regtype AS oid
            UNION ALL SELECT 'pg_catalog.reltime'::pg_catalog.regtype
            UNION ALL SELECT 'pg_catalog.tinterval'::pg_catalog.regtype
            UNION ALL
            SELECT * FROM (
                WITH x AS (SELECT oid FROM oids)
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid
                  AND NOT a.attisdropped AND a.atttypid = x.oid
                UNION ALL
                SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
            ) foo
        )
        SELECT n.nspname, c.relname, a.attname
        FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
        WHERE c.oid = a.attrelid AND NOT a.attisdropped
          AND a.atttypid IN (SELECT oid FROM oids)
          AND c.relkind IN ('r', 'm', 'i')
          AND c.relnamespace = n.oid
          AND n.nspname !~ '^pg_temp_'
          AND n.nspname !~ '^pg_toast_temp_'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema');
    \endif
\else
    SELECT 'false' AS c42_failed, '- SKIP' AS c42_status \gset
    \echo '- Skipped (source version > 11)'
\endif

\echo ''

-- --------------------------------------------
-- Check 43. Checking for tables WITH OIDS [per-database]
-- (source <= 11)
-- --------------------------------------------
\echo '=== 43. Checking for tables WITH OIDS [per-database] ==='
\if :source_le_11
    SELECT (count(*) > 0)::text AS c43_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: ' || count(*) || ' table(s) WITH OIDS found. Use ALTER TABLE ... SET WITHOUT OIDS.'
                ELSE '✓ PASSED'
           END AS c43_status
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relhasoids AND n.nspname NOT IN ('pg_catalog') \gset

    \echo :c43_status

    \if :c43_failed
        -- Show details if any found
        SELECT n.nspname, c.relname
        FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n
        WHERE c.relnamespace = n.oid AND c.relhasoids AND n.nspname NOT IN ('pg_catalog');
    \endif
\else
    SELECT 'false' AS c43_failed, '- SKIP' AS c43_status \gset
    \echo '- Skipped (source version > 11)'
\endif

\echo ''

-- --------------------------------------------
-- Check 44. Checking for user-defined encoding conversions [per-database]
-- (source <= 13)
-- --------------------------------------------
\echo '=== 44. Checking for user-defined encoding conversions [per-database] ==='
\if :source_le_13
    SELECT (count(*) > 0)::text AS c44_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: ' || count(*) || ' user-defined encoding conversion(s) found. Please remove them before upgrade.'
                ELSE '✓ PASSED'
           END AS c44_status
    FROM pg_catalog.pg_conversion c
    WHERE c.oid >= 16384 \gset

    \echo :c44_status

    \if :c44_failed
        -- Show details if any found
        SELECT c.oid AS conoid, c.conname, n.nspname
        FROM pg_catalog.pg_conversion c, pg_catalog.pg_namespace n
        WHERE c.connamespace = n.oid AND c.oid >= 16384;
    \endif
\else
    SELECT 'false' AS c44_failed, '- SKIP' AS c44_status \gset
    \echo '- Skipped (source version > 13)'
\endif

\echo ''

-- --------------------------------------------
-- Check 45. Checking for user-defined postfix operators [per-database]
-- (source <= 13)
-- --------------------------------------------
\echo '=== 45. Checking for user-defined postfix operators [per-database] ==='
\if :source_le_13
    SELECT (count(*) > 0)::text AS c45_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: ' || count(*) || ' user-defined postfix operator(s) found. Please drop them before upgrade.'
                ELSE '✓ PASSED'
           END AS c45_status
    FROM pg_catalog.pg_operator o
    WHERE o.oprright = 0 AND o.oid >= 16384 \gset

    \echo :c45_status

    \if :c45_failed
        -- Show details if any found
        SELECT o.oid AS oproid, n.nspname AS oprnsp, o.oprname, tn.nspname AS typnsp, t.typname
        FROM pg_catalog.pg_operator o, pg_catalog.pg_namespace n,
             pg_catalog.pg_type t, pg_catalog.pg_namespace tn
        WHERE o.oprnamespace = n.oid AND o.oprleft = t.oid
          AND t.typnamespace = tn.oid AND o.oprright = 0 AND o.oid >= 16384;
    \endif
\else
    SELECT 'false' AS c45_failed, '- SKIP' AS c45_status \gset
    \echo '- Skipped (source version > 13)'
\endif

\echo ''

-- --------------------------------------------
-- Check 46. Checking for incompatible polymorphic functions [per-database]
-- (source <= 13)
-- --------------------------------------------
\echo '=== 46. check_for_incompatible_polymorphics [per-database] ==='
\if :source_le_13
    SELECT (count(*) > 0)::text AS c46_failed,
           CASE WHEN count(*) > 0
                THEN '❌ FAILED: ' || count(*) || ' incompatible polymorphic object(s) found. Please drop and recreate with anycompatible types.'
                ELSE '✓ PASSED'
           END AS c46_status
    FROM (
        SELECT p.oid
        FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_aggregate AS a ON a.aggfnoid = p.oid
        JOIN pg_catalog.pg_proc AS transfn ON transfn.oid = a.aggtransfn
        WHERE p.oid >= 16384
          AND a.aggtransfn = ANY(ARRAY[
              'array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)',
              'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)',
              'array_replace(anyarray,anyelement,anyelement)',
              'array_position(anyarray,anyelement)',
              'array_position(anyarray,anyelement,integer)',
              'array_positions(anyarray,anyelement)',
              'width_bucket(anyelement,anyarray)']::regprocedure[])
          AND a.aggtranstype = ANY(ARRAY['anyarray', 'anyelement']::regtype[])
        UNION ALL
        SELECT p.oid
        FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_aggregate AS a ON a.aggfnoid = p.oid
        JOIN pg_catalog.pg_proc AS finalfn ON finalfn.oid = a.aggfinalfn
        WHERE p.oid >= 16384
          AND a.aggfinalfn = ANY(ARRAY[
              'array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)',
              'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)',
              'array_replace(anyarray,anyelement,anyelement)',
              'array_position(anyarray,anyelement)',
              'array_position(anyarray,anyelement,integer)',
              'array_positions(anyarray,anyelement)',
              'width_bucket(anyelement,anyarray)']::regprocedure[])
          AND a.aggtranstype = ANY(ARRAY['anyarray', 'anyelement']::regtype[])
        UNION ALL
        SELECT op.oid
        FROM pg_catalog.pg_operator AS op
        WHERE op.oid >= 16384
          AND oprcode = ANY(ARRAY[
              'array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)',
              'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)',
              'array_replace(anyarray,anyelement,anyelement)',
              'array_position(anyarray,anyelement)',
              'array_position(anyarray,anyelement,integer)',
              'array_positions(anyarray,anyelement)',
              'width_bucket(anyelement,anyarray)']::regprocedure[])
          AND oprleft = ANY(ARRAY['anyarray', 'anyelement']::regtype[])
    ) sub \gset

    \echo :c46_status

    \if :c46_failed
        SELECT p.oid, n.nspname, p.proname, pg_catalog.format_type(p.prorettype, NULL) AS return_type
        FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
        JOIN pg_catalog.pg_aggregate AS a ON a.aggfnoid = p.oid
        WHERE p.oid >= 16384
          AND (a.aggtransfn = ANY(ARRAY[
              'array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)',
              'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)',
              'array_replace(anyarray,anyelement,anyelement)',
              'array_position(anyarray,anyelement)',
              'array_position(anyarray,anyelement,integer)',
              'array_positions(anyarray,anyelement)',
              'width_bucket(anyelement,anyarray)']::regprocedure[])
           OR a.aggfinalfn = ANY(ARRAY[
              'array_append(anyarray,anyelement)', 'array_cat(anyarray,anyarray)',
              'array_prepend(anyelement,anyarray)', 'array_remove(anyarray,anyelement)',
              'array_replace(anyarray,anyelement,anyelement)',
              'array_position(anyarray,anyelement)',
              'array_position(anyarray,anyelement,integer)',
              'array_positions(anyarray,anyelement)',
              'width_bucket(anyelement,anyarray)']::regprocedure[]))
          AND a.aggtranstype = ANY(ARRAY['anyarray', 'anyelement']::regtype[]);
    \endif
\else
    SELECT 'false' AS c46_failed, '- SKIP' AS c46_status \gset
    \echo '- Skipped (source version > 13)'
\endif

\echo ''

-- ============================================
-- Summary
-- ============================================
\echo '============================================'
\echo 'Summary'
\echo '============================================'

SELECT 'Database: ' || current_database() || '  |  Source: ' || :'major' || '  |  Target: ' || :target_version AS "Environment";

-- FAILED list
SELECT COALESCE(
    '❌ FAILED list: ' || string_agg(check_name, ', ' ORDER BY regexp_replace(check_name, '[^0-9]', '', 'g')::int, check_name),
    '✓ No failures found'
) AS "Failed Checks"
FROM (VALUES
    ('2', :'c2_failed'), ('2b', :'c2b_failed'), ('3', :'c3_failed'),
    ('4', :'c4_failed'),
    ('13', :'c13_failed'), ('17', :'c17_failed'), ('19', :'c19_failed'),
    ('25', :'c25_failed'), ('25b', :'c25b_failed'),
    ('30', :'c30_failed'), ('35b', :'c35b_failed'),
    ('36', :'c36_failed'), ('37', :'c37_failed'), ('38', :'c38_failed'),
    ('39', :'c39_failed'), ('39b', :'c39b_failed'), ('40', :'c40_failed'),
    ('41', :'c41_failed'), ('42', :'c42_failed'), ('43', :'c43_failed'),
    ('44', :'c44_failed'), ('45', :'c45_failed'), ('46', :'c46_failed')
) AS t(check_name, failed)
WHERE failed = 'true';

-- WARNING list
SELECT COALESCE(
    '⚠️ WARNING list: ' || string_agg(check_name, ', ' ORDER BY regexp_replace(check_name, '[^0-9]', '', 'g')::int, check_name),
    '✓ No warnings found'
) AS "Warning Checks"
FROM (VALUES
    ('8', :'c8_failed'), ('9', :'c9_failed'),
    ('11', :'c11_failed'), ('12', :'c12_failed'),
    ('15', :'c15_failed'), ('15b', :'c15b_failed'),
    ('16', :'c16_failed'), ('18', :'c18_failed'),
    ('20', :'c20_failed'), ('22', :'c22_failed'),
    ('26', :'c26_failed'),
    ('27', :'c27_failed'), ('28', :'c28_failed'), ('29', :'c29_failed'),
    ('31', :'c31_failed'), ('32', :'c32_failed'), ('34', :'c34_failed'),
    ('35', :'c35_failed'), ('35c', :'c35c_failed')
) AS t(check_name, failed)
WHERE failed = 'true';

\echo '============================================'

-- Reset log_statement to its original value
RESET log_statement;