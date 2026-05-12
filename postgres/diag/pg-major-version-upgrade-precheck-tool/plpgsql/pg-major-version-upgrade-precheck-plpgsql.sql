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
-- PL/pgSQL Version
-- Supports: Target Major Version 11-17
--
-- Each check is either:
--   [global]       - Run once against the postgres database
--   [per-database] - Must be run against EACH user database
--
-- Step 1: Load the function into the database
--   psql "host=<HOST> port=<PORT> user=<USER> dbname=postgres sslmode=verify-full sslrootcert=global-bundle.pem" \
--        -f pg-major-version-upgrade-precheck_plpgsql.sql
--
--   For per-database checks, load into EACH user database:
--   psql "host=<HOST> port=<PORT> user=<USER> dbname=<DBNAME> sslmode=verify-full sslrootcert=global-bundle.pem" \
--        -f pg-major-version-upgrade-precheck_plpgsql.sql
--
-- Step 2: Run the precheck
--   SELECT * FROM public.pg_major_version_upgrade_precheck(16);
--
--   Or to just see the RAISE NOTICE output:
--   SELECT check_id, check_scope, status FROM pg_major_version_upgrade_precheck(16);
--   SELECT public.pg_major_version_upgrade_precheck(16);
--   SELECT * FROM public.pg_major_version_upgrade_precheck(16);
--
-- Step 3: Clean up (recommended - remove the function after use)
--   DROP FUNCTION IF EXISTS public.pg_major_version_upgrade_precheck(integer);
--
-- Note on internal schemas:
--   This script is designed for Amazon RDS/Aurora PostgreSQL and excludes
--   'rdsadmin' from database/schema lists. For self-managed PostgreSQL
--   or other managed services update the internal-schema list accordingly.
--
-- Required privileges (minimum):
--   Step 1 & 3 (CREATE/DROP function):
--     CREATE privilege on the public schema (or target schema)
--     Ownership of the function (for DROP)
--   Step 2 (execution):
--     SELECT permission on these system catalogs:
--       pg_database, pg_prepared_xacts, pg_replication_slots, pg_settings,
--       pg_extension, pg_available_extensions, pg_type, pg_class, pg_namespace,
--       pg_attribute, pg_range, pg_conversion, pg_operator, pg_proc,
--       pg_aggregate, pg_subscription, pg_constraint, pg_event_trigger
--
-- Blue/Green deployment checks:
--   Checks 24-35c are specific to Blue/Green deployment upgrades.
--   If you do not plan to use Blue/Green deployments for the major version
--   upgrade, you can safely ignore findings from checks 24 through 35c.
--
-- Note:
--   This script creates a function in the public schema. The CREATE/DROP
--   operations are logged by PostgreSQL's DDL logging (log_statement = 'ddl').
--   If your environment uses pgAudit, these operations will also be captured.
--   Always DROP the function after use (Step 3).
-- ============================================

DROP FUNCTION IF EXISTS public.pg_major_version_upgrade_precheck(integer);

CREATE OR REPLACE FUNCTION public.pg_major_version_upgrade_precheck(p_target_version integer)
RETURNS TABLE (
    check_id    text,
    check_scope text,
    status      text,
    message     text,
    detail      text
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_source_major      integer;
    v_source_version    text;
    v_current_db        text;
    v_count             bigint;
    v_status            text;
    v_msg               text;
    v_detail            text;
    -- Pre-computed conditions
    v_need_slot_check   boolean;
    v_target_ge_11      boolean;
    v_target_ge_14      boolean;
    v_need_aclitem_check boolean;
    v_source_le_11      boolean;
    v_source_le_13      boolean;
BEGIN
    -- Prevent runaway queries from holding catalog locks too long
    SET LOCAL statement_timeout = 600000;   -- 10 minutes
    SET LOCAL lock_timeout = 5000;          -- 5 seconds

    -- Prevent concurrent executions of this precheck
    IF NOT pg_try_advisory_xact_lock(hashtext('pg_major_version_upgrade_precheck')) THEN
        RAISE EXCEPTION '[MVU-Precheck] Another instance is already running in this database. Aborting.';
    END IF;

    -- ============================================
    -- Auto-detect source version & pre-compute conditions
    -- ============================================
    v_source_version := current_setting('server_version');
    v_source_major   := current_setting('server_version_num')::int / 10000;
    v_current_db     := current_database();

    RAISE LOG '[MVU-Precheck] Started: target_version=%, db=%, user=%, pid=%',
        p_target_version, current_database(), current_user, pg_backend_pid();

    RAISE NOTICE '============================================';
    RAISE NOTICE 'Aurora/RDS PostgreSQL Upgrade Precheck (PL/pgSQL)';
    RAISE NOTICE '============================================';
    RAISE NOTICE '';
    RAISE NOTICE '--- Environment Info ---';
    RAISE NOTICE 'Source version : %', v_source_version;
    RAISE NOTICE 'Source major   : %', v_source_major;
    RAISE NOTICE 'Target version : %', p_target_version;
    RAISE NOTICE 'Current database: %', v_current_db;
    RAISE NOTICE '';

    -- Pre-compute boolean conditions
    v_need_slot_check    := (v_source_major < 17);
    v_target_ge_11       := (p_target_version >= 11);
    v_target_ge_14       := (p_target_version >= 14);
    v_need_aclitem_check := (v_source_major <= 15 AND p_target_version >= 16);
    v_source_le_11       := (v_source_major <= 11);
    v_source_le_13       := (v_source_major <= 13);

    -- Validate target_version is within supported range (11-17)
    IF p_target_version < 11 OR p_target_version > 17 THEN
        RAISE EXCEPTION 'ERROR: Target version must be between 11 and 17. Got: %', p_target_version;
    END IF;

    -- Version sanity check
    IF v_source_major >= p_target_version THEN
        RAISE EXCEPTION 'ERROR: Source version (%) >= Target version (%). Nothing to upgrade.',
            v_source_major, p_target_version;
    END IF;

    -- ============================================
    -- List user databases (for reference)
    -- ============================================
    RAISE NOTICE '=== User Databases ===';
    FOR v_msg IN
        SELECT datname || CASE WHEN datname = current_database() THEN ' ← current' ELSE '' END
        FROM pg_catalog.pg_database
        WHERE datistemplate = false
          AND datname NOT IN ('rdsadmin', 'template0', 'template1')
        ORDER BY datname
    LOOP
        RAISE NOTICE '  %', v_msg;
    END LOOP;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 1. PostgreSQL Version Check [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 1. PostgreSQL Version Check [global] ===';
    v_status := '✓ INFO';
    v_msg := v_source_version;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '1'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 2. Invalid databases (datconnlimit=-2) [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 2. check_for_invalid_database [global] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_database WHERE datconnlimit = -2;
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := 'Invalid database(s) found (datconnlimit=-2). DROP them and try again.';
        SELECT string_agg(datname, E'
    ') INTO v_detail FROM pg_catalog.pg_database WHERE datconnlimit = -2;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No invalid databases found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '2'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 2b. Database not allow connect [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 2b. check_database_not_allow_connect [global] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_database
    WHERE datname != 'template0' AND datallowconn = false;
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := 'Database(s) with datallowconn=false found. Ensure all non-template0 databases allow connections.';
        SELECT string_agg(datname, E'
    ') INTO v_detail FROM pg_catalog.pg_database WHERE datname != 'template0' AND datallowconn = false;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'All databases allow connections.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '2b'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 3. Template database verification [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 3. check_template_0_and_template1 [global] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_database
    WHERE datistemplate = true AND datname IN ('template0', 'template1');
    IF v_count != 2 THEN
        v_status := '❌ FAILED';
        v_msg := 'template0/template1 invalid. Make sure both exist with datistemplate=true.';
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'template0 and template1 are valid.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '3'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 4. Master Username Check [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 4. Master Username Check [global] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_roles
    WHERE rolname LIKE 'pg_%' AND (rolcreaterole OR rolcreatedb)
      AND rolname NOT IN ('pg_monitor','pg_read_all_settings','pg_read_all_stats',
                          'pg_stat_scan_tables','pg_signal_backend','pg_read_server_files',
                          'pg_write_server_files','pg_execute_server_program',
                          'pg_checkpoint','pg_maintain','pg_use_reserved_connections',
                          'pg_create_subscription');
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := 'Role(s) starting with pg_ found with create privileges. Master username cannot start with pg_.';
        SELECT string_agg(rolname, E'
    ') INTO v_detail FROM pg_catalog.pg_roles
        WHERE rolname LIKE 'pg_%' AND (rolcreaterole OR rolcreatedb)
          AND rolname NOT IN ('pg_monitor','pg_read_all_settings','pg_read_all_stats',
                              'pg_stat_scan_tables','pg_signal_backend','pg_read_server_files',
                              'pg_write_server_files','pg_execute_server_program',
                              'pg_checkpoint','pg_maintain','pg_use_reserved_connections',
                              'pg_create_subscription');
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No problematic pg_ roles found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '4'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 5. Database Size Analysis [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 5. Database Size Analysis [global] ===';
    v_status := '✓ INFO';
    v_msg := 'Database: ' || v_current_db || ' Size: ' || pg_size_pretty(pg_database_size(v_current_db));
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '5'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 6. Object Count Check [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 6. Object Count Check [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');
    v_status := '✓ INFO';
    v_msg := v_count || ' user tables in ' || v_current_db;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '6'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 7. Top 20 Largest Tables [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 7. Top 20 Largest Tables [per-database] ===';
    SELECT string_agg(schemaname || '.' || tablename || ' (' || pg_size_pretty(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename))) || ')', E'\n    ')
    INTO v_detail
    FROM (
        SELECT schemaname, tablename
        FROM pg_catalog.pg_tables
        WHERE schemaname NOT IN ('pg_catalog','information_schema')
        ORDER BY pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename)) DESC
        LIMIT 5
    ) sub;
    v_status := '✓ INFO';
    v_msg := 'Top tables listed in detail.';
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '7'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 8. Invalid Indexes Check [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 8. Invalid Indexes Check [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_index WHERE NOT indisvalid;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' invalid index(es) found. Consider REINDEX.';
        SELECT string_agg(n.nspname || '.' || c.relname || '.' || i.relname, E'
    ')
        INTO v_detail
        FROM pg_catalog.pg_index x
        JOIN pg_catalog.pg_class c ON x.indrelid = c.oid
        JOIN pg_catalog.pg_class i ON x.indexrelid = i.oid
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE NOT x.indisvalid AND n.nspname NOT IN ('pg_catalog','information_schema');
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No invalid indexes.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '8'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 9. Duplicate Indexes Detection [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 9. Duplicate Indexes Detection [per-database] ===';
    SELECT count(*) INTO v_count FROM (
        SELECT indexdef FROM pg_catalog.pg_indexes WHERE schemaname NOT IN ('pg_catalog','information_schema')
        GROUP BY tablename, indexdef HAVING count(*) > 1
    ) dup;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' duplicate index group(s) found.';
        SELECT string_agg(tablename || ': ' || indexname, E'
    ')
        INTO v_detail
        FROM (SELECT tablename, indexname FROM pg_catalog.pg_indexes
              WHERE schemaname NOT IN ('pg_catalog','information_schema')
              GROUP BY tablename, indexdef, indexname HAVING count(*) > 1) d;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No duplicate indexes.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '9'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 10. Unused Indexes Analysis [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 10. Unused Indexes Analysis [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_stat_user_indexes WHERE idx_scan = 0 AND pg_relation_size(indexrelid) > 10240;
    IF v_count > 0 THEN
        v_status := '✓ INFO';
        v_msg := v_count || ' unused index(es) > 10KB found. Consider dropping to reduce upgrade time.';
        SELECT string_agg(schemaname || '.' || relname || '.' || indexrelname || ' (' || pg_size_pretty(pg_relation_size(indexrelid)) || ')', E'\n    ')
        INTO v_detail
        FROM (
            SELECT schemaname, relname, indexrelname, indexrelid
            FROM pg_catalog.pg_stat_user_indexes
            WHERE idx_scan = 0 AND pg_relation_size(indexrelid) > 10240
            ORDER BY pg_relation_size(indexrelid) DESC LIMIT 10
        ) sub;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No unused indexes > 10KB.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '10'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 11. Table Bloat Analysis [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 11. Table Bloat Analysis [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_stat_user_tables WHERE n_dead_tup > 1000;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' table(s) with significant bloat (>1000 dead tuples). Consider VACUUM before upgrade.';
        SELECT string_agg(schemaname || '.' || relname || ' (' || n_dead_tup || ' dead)', E'\n    ')
        INTO v_detail
        FROM (
            SELECT schemaname, relname, n_dead_tup
            FROM pg_catalog.pg_stat_user_tables
            WHERE n_dead_tup > 1000
            ORDER BY n_dead_tup DESC LIMIT 10
        ) sub;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No significant table bloat.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '11'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 12. Active Long Running Queries [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 12. Active Long Running Queries [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_stat_activity
    WHERE state != 'idle' AND query NOT LIKE '%pg_stat_activity%'
      AND now() - query_start > interval '5 minutes';
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' query(ies) running longer than 5 minutes. Long transactions may block upgrade.';
        SELECT string_agg('pid=' || pid || ' (' || usename || ', ' || (now() - query_start)::text || ')', E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_stat_activity
        WHERE state != 'idle' AND query NOT LIKE '%pg_stat_activity%'
          AND now() - query_start > interval '5 minutes';
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No long running queries.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '12'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 13. Replication slots [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 13. check_for_replication_slots [global] ===';
    IF v_need_slot_check THEN
        SELECT count(*) INTO v_count FROM pg_catalog.pg_replication_slots;
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := v_count || ' replication slot(s) found. Drop all logical replication slots and try again.';
            SELECT string_agg(slot_name || ' (' || slot_type || ', ' || COALESCE(database, 'N/A') || ')', E'\n    ')
            INTO v_detail FROM pg_catalog.pg_replication_slots;
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'No replication slots found.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (APG 17+ supports logical slot migration).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '13'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 14. Critical Configuration Parameters [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 14. Critical Configuration Parameters [global] ===';
    SELECT string_agg(name || '=' || setting, E'
    ')
    INTO v_detail
    FROM pg_catalog.pg_settings
    WHERE name IN ('max_connections','shared_buffers','effective_cache_size',
                   'maintenance_work_mem','work_mem','wal_level',
                   'max_wal_senders','max_replication_slots','autovacuum','log_statement');
    v_status := '✓ INFO';
    v_msg := 'Key parameters listed in detail.';
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '14'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 15. Installed Extensions [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 15. Installed Extensions [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_extension e
    LEFT JOIN pg_catalog.pg_available_extensions a ON e.extname = a.name
    WHERE a.default_version IS NOT NULL AND e.extversion <> a.default_version;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' extension(s) have newer versions available. Consider updating before upgrade.';
        SELECT string_agg(e.extname || ' (' || e.extversion || ' -> ' || a.default_version || ')', E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_extension e
        LEFT JOIN pg_catalog.pg_available_extensions a ON e.extname = a.name
        WHERE a.default_version IS NOT NULL AND e.extversion <> a.default_version;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'All extensions are up to date.';
        SELECT string_agg(e.extname || ' v' || e.extversion, E'
    ')
        INTO v_detail
        FROM pg_catalog.pg_extension e WHERE e.extname != 'plpgsql';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '15'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 15b. Extension version check [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 15b. check_for_multi_extensions_version [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_available_extensions
    WHERE name IN ('postgis','pgrouting','postgis_raster','postgis_tiger_geocoder',
                   'postgis_topology','address_standardizer','address_standardizer_data_us','rdkit')
      AND installed_version IS NOT NULL
      AND default_version != installed_version;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' extension(s) need updating before upgrade.';
        SELECT string_agg(name || ' (' || installed_version || ' -> ' || default_version || ')', E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_available_extensions
        WHERE name IN ('postgis','pgrouting','postgis_raster','postgis_tiger_geocoder',
                       'postgis_topology','address_standardizer','address_standardizer_data_us','rdkit')
          AND installed_version IS NOT NULL AND default_version != installed_version;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'All monitored extensions are up to date.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '15b'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 16. Views Dependent on System Catalogs [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 16. Views Dependent on System Catalogs [per-database] ===';
    SELECT count(*) INTO v_count
    FROM (
        SELECT DISTINCT dependent_view.relname
        FROM pg_catalog.pg_depend
        JOIN pg_catalog.pg_rewrite ON pg_depend.objid = pg_rewrite.oid
        JOIN pg_catalog.pg_class AS dependent_view ON pg_rewrite.ev_class = dependent_view.oid
        JOIN pg_catalog.pg_class AS source_table ON pg_depend.refobjid = source_table.oid
        JOIN pg_catalog.pg_namespace AS dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
        JOIN pg_catalog.pg_namespace AS source_ns ON source_ns.oid = source_table.relnamespace
        WHERE source_ns.nspname = 'pg_catalog'
          AND dependent_ns.nspname NOT IN ('pg_catalog', 'information_schema')
    ) sub;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' view(s) depend on system catalogs. Drop and recreate after upgrade.';
        SELECT string_agg(dependent_ns.nspname || '.' || dependent_view.relname || ' -> ' || source_table.relname, E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_depend
        JOIN pg_catalog.pg_rewrite ON pg_depend.objid = pg_rewrite.oid
        JOIN pg_catalog.pg_class AS dependent_view ON pg_rewrite.ev_class = dependent_view.oid
        JOIN pg_catalog.pg_class AS source_table ON pg_depend.refobjid = source_table.oid
        JOIN pg_catalog.pg_namespace AS dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
        JOIN pg_catalog.pg_namespace AS source_ns ON source_ns.oid = source_table.relnamespace
        WHERE source_ns.nspname = 'pg_catalog'
          AND dependent_ns.nspname NOT IN ('pg_catalog', 'information_schema');
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No views depend on system catalogs.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '16'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 17. Prepared transactions [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 17. check_for_prepared_transactions [global] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_prepared_xacts;
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := v_count || ' uncommitted prepared transaction(s) found. Please commit or rollback.';
        SELECT string_agg(gid || ' (owner: ' || owner || ', db: ' || database || ')', E'\n    ')
        INTO v_detail FROM pg_catalog.pg_prepared_xacts;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No prepared transactions found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '17'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 18. Transaction ID Age Check [global]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 18. Transaction ID Age Check [global] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_database WHERE age(datfrozenxid) > 200000000;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := 'Database(s) with high transaction ID age found. Consider VACUUM FREEZE.';
        SELECT string_agg(datname || ' (age: ' || age(datfrozenxid) || ')', E'\n    ')
        INTO v_detail
        FROM (
            SELECT datname, datfrozenxid
            FROM pg_catalog.pg_database
            WHERE age(datfrozenxid) > 150000000
            ORDER BY age(datfrozenxid) DESC
        ) sub;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'All databases have healthy transaction ID age.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '18'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 19. Unsupported Data Types (reg*) [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 19. Unsupported Data Types Check (reg* Types) [per-database] ===';
    SELECT count(*) INTO v_count
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
                UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid = x.oid
                UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
            ) foo
        )
        SELECT n.nspname, c.relname, a.attname
        FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
        WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN (SELECT oid FROM oids)
          AND c.relkind IN ('r','m','i') AND c.relnamespace = n.oid
          AND n.nspname !~ '^pg_temp_' AND n.nspname !~ '^pg_toast_temp_'
          AND n.nspname NOT IN ('pg_catalog','information_schema')
    ) sub;
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := v_count || ' reg* data type column(s) found. OIDs not preserved by pg_upgrade.';
        SELECT string_agg(nspname || '.' || relname || '.' || attname, E'\n    ')
        INTO v_detail
        FROM (
            WITH RECURSIVE oids AS (
                SELECT oid FROM pg_catalog.pg_type t
                WHERE t.typnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'pg_catalog')
                  AND t.typname IN ('regcollation','regconfig','regdictionary','regnamespace','regoper','regoperator','regproc','regprocedure')
                UNION ALL
                SELECT * FROM (
                    WITH x AS (SELECT oid FROM oids)
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                    WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid = x.oid
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                    WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                ) foo
            )
            SELECT n.nspname, c.relname, a.attname
            FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
            WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN (SELECT oid FROM oids)
              AND c.relkind IN ('r','m','i') AND c.relnamespace = n.oid
              AND n.nspname !~ '^pg_temp_' AND n.nspname !~ '^pg_toast_temp_'
              AND n.nspname NOT IN ('pg_catalog','information_schema')
        ) sub;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No reg* data type columns found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '19'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 20. Large Objects Check [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 20. Large Objects Check [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_largeobject_metadata;
    IF v_count > 100000 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' large objects found. Excessive large objects can cause OOM during upgrade.';
    ELSE
        v_status := '✓ PASSED';
        v_msg := v_count || ' large objects.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '20'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 21. Unknown Data Type Check (PG 9.6 -> 10+) [per-database]
    -- SKIP: PostgreSQL 9.6 is EOL.
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 21. Unknown Data Type Check (PG 9.6 -> 10+) [per-database] ===';
    v_status := '- SKIP';
    v_msg := 'Only applicable for PostgreSQL < 10 (EOL).';
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '21'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 22. Parameter Permissions Check [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 22. Parameter Permissions Check [per-database] ===';
    SELECT count(*) INTO v_count FROM information_schema.role_routine_grants WHERE routine_name LIKE '%parameter%';
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' custom parameter permission(s) found. May cause upgrade failure.';
        SELECT string_agg(routine_name || ' (' || grantee || ': ' || privilege_type || ')', E'\n    ')
        INTO v_detail FROM information_schema.role_routine_grants WHERE routine_name LIKE '%parameter%';
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No custom parameter permissions.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '22'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 23. Schema Usage [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 23. Schema Usage [per-database] ===';
    SELECT string_agg(schema_info, E'\n    ')
    INTO v_detail
    FROM (
        SELECT n.nspname || ' (' || pg_catalog.pg_get_userbyid(n.nspowner) || ', ' ||
               COALESCE(pg_size_pretty(SUM(pg_total_relation_size(c.oid))), '0 bytes') || ')' AS schema_info
        FROM pg_catalog.pg_namespace n
        LEFT JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%'
        GROUP BY n.nspname, n.nspowner
    ) sub;
    v_status := '✓ INFO';
    v_msg := 'Schema usage listed in detail.';
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '23'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 24. Version Compatibility and Upgrade Path [global]
    -- SKIP: Requires AWS CLI.
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 24. Version Compatibility and Upgrade Path [global] ===';
    v_status := '- SKIP';
    v_msg := 'Requires AWS CLI. Use shell script (pg-major-version-upgrade-precheck.sh) for this check.';
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '24'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 25. Logical replication parameters [global] (Blue/Green)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 25. Logical replication parameters [global] ===';
    SELECT count(*) INTO v_count
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
    ) sub;
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := 'Logical replication parameters are insufficient. Check max_replication_slots, max_wal_senders, max_logical_replication_workers, max_worker_processes.';
        v_detail := 'Increase parameters in the DB cluster parameter group and reboot.';
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'Logical replication parameters are sufficient.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '25'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 25b. rds.logical_replication [global] (Blue/Green)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 25b. rds.logical_replication [global] ===';
    BEGIN
        SELECT setting INTO v_msg
        FROM pg_catalog.pg_settings
        WHERE name = 'rds.logical_replication';

        IF NOT FOUND THEN
            v_status := '- SKIP';
            v_msg := 'rds.logical_replication setting not found (non-RDS instance?).';
        ELSIF v_msg = 'on' THEN
            v_status := '✓ PASSED';
            v_msg := 'rds.logical_replication is on.';
        ELSE
            v_status := '❌ FAILED';
            v_msg := 'rds.logical_replication is ' || v_msg || '. Set to 1 in parameter group and reboot.';
        END IF;
    EXCEPTION
        WHEN insufficient_privilege THEN
            v_status := '❌ FAILED';
            v_msg := 'Insufficient privilege to read pg_settings: ' || SQLERRM;
        WHEN OTHERS THEN
            v_status := '❌ FAILED';
            v_msg := 'Unexpected error reading pg_settings [' || SQLSTATE || ']: ' || SQLERRM;
    END;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '25b'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 26. Tables without Primary Key [per-database] (Blue/Green)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 26. Check tables without Primary Key [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'rdsadmin')
      AND NOT EXISTS (
          SELECT 1 FROM pg_catalog.pg_constraint con
          WHERE con.conrelid = c.oid AND con.contype = 'p'
      );
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' table(s) without Primary Key. Logical replication requires PK or REPLICA IDENTITY FULL.';
        SELECT string_agg(n.nspname || '.' || c.relname, E'
    ')
        INTO v_detail
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'rdsadmin')
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con WHERE con.conrelid = c.oid AND con.contype = 'p');
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'All tables have primary keys.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '26'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 27. Foreign Tables Check for Blue/Green [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 27. Foreign Tables Check for Blue/Green [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_foreign_table ft
    JOIN pg_catalog.pg_class c ON c.oid = ft.ftrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog','information_schema');
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' foreign table(s) found. These will NOT be replicated during Blue/Green deployment.';
        SELECT string_agg(n.nspname || '.' || c.relname || ' (server: ' || s.srvname || ')', E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_foreign_table ft
        JOIN pg_catalog.pg_class c ON c.oid = ft.ftrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_foreign_server s ON s.oid = ft.ftserver
        WHERE n.nspname NOT IN ('pg_catalog','information_schema');
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No foreign tables found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '27'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 28. Unlogged Tables Check for Blue/Green [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 28. Unlogged Tables Check for Blue/Green [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relpersistence = 'u' AND c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog','information_schema');
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' unlogged table(s) found. These will NOT be replicated during Blue/Green deployment.';
        SELECT string_agg(n.nspname || '.' || c.relname || ' (' || pg_size_pretty(pg_total_relation_size(c.oid)) || ')', E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relpersistence = 'u' AND c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog','information_schema');
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No unlogged tables found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '28'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 29. Publications Check for Blue/Green [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 29. Publications Check for Blue/Green [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_publication;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' publication(s) found. Review before Blue/Green deployment.';
        SELECT string_agg(pubname, E'\n    ') INTO v_detail FROM pg_catalog.pg_publication;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No publications found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '29'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 30. Logical replication subscriptions [per-database] (Blue/Green)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 30. Check for logical replication subscriptions [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_subscription;
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := v_count || ' subscription(s) found. Must be dropped before Blue/Green upgrade.';
        SELECT string_agg(subname, E'
    ') INTO v_detail FROM pg_catalog.pg_subscription;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No logical replication subscriptions found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '30'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 31. Foreign Data Wrapper Endpoint Check for Blue/Green [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 31. Foreign Data Wrapper Endpoint Check for Blue/Green [per-database] ===';
    SELECT count(*) INTO v_count FROM pg_catalog.pg_foreign_server;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' foreign server(s) found. Verify endpoints are accessible from new Blue/Green environment.';
        SELECT string_agg(s.srvname || ' (fdw: ' || f.fdwname || ')', E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_foreign_server s
        JOIN pg_catalog.pg_foreign_data_wrapper f ON f.oid = s.srvfdw;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No foreign servers found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '31'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 32. High Write Volume Tables Check for Blue/Green [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 32. High Write Volume Tables Check for Blue/Green [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_stat_user_tables
    WHERE (n_tup_ins + n_tup_upd + n_tup_del) > 100000;
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' table(s) with high write volume. May increase Blue/Green switchover time.';
        SELECT string_agg(sub.info, E'\n    ')
        INTO v_detail
        FROM (
            SELECT schemaname || '.' || relname || ' (writes: ' || (n_tup_ins + n_tup_upd + n_tup_del) || ')' AS info
            FROM pg_catalog.pg_stat_user_tables
            WHERE (n_tup_ins + n_tup_upd + n_tup_del) > 100000
            ORDER BY (n_tup_ins + n_tup_upd + n_tup_del) DESC
            LIMIT 20
        ) sub;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No high write volume tables.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '32'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 33. Partitioned Tables Check for Blue/Green [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 33. Partitioned Tables Check for Blue/Green [per-database] ===';
    SELECT string_agg(sub.info, E'\n    ')
    INTO v_detail
    FROM (
        SELECT n.nspname || '.' || c.relname || ' (' || pg_size_pretty(pg_total_relation_size(c.oid)) ||
               ', ' || (SELECT count(*) FROM pg_catalog.pg_inherits i WHERE i.inhparent = c.oid) || ' partitions)' AS info
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'p' AND n.nspname NOT IN ('pg_catalog','information_schema')
        ORDER BY pg_total_relation_size(c.oid) DESC
    ) sub;
    v_status := '✓ INFO';
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        v_msg := 'Partitioned tables listed in detail.';
    ELSE
        v_msg := 'No partitioned tables found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '33'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 34. Blue/Green Extension Compatibility Check [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 34. Blue/Green Extension Compatibility Check [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_extension e
    WHERE e.extname IN ('pglogical', 'pg_repack', 'pg_hint_plan', 'pg_cron', 'pg_tle');
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' extension(s) may have compatibility issues with Blue/Green deployment.';
        SELECT string_agg(extname || ' v' || extversion, E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_extension
        WHERE extname IN ('pglogical', 'pg_repack', 'pg_hint_plan', 'pg_cron', 'pg_tle');
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No problematic extensions for Blue/Green.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '34'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 35. DDL event triggers [per-database] (Blue/Green)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 35. Check DDL event triggers [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_event_trigger
    WHERE evtevent IN ('ddl_command_start', 'ddl_command_end', 'sql_drop')
      AND evtname != 'dts_capture_catalog_start';
    IF v_count > 0 THEN
        v_status := '⚠️ WARNING';
        v_msg := v_count || ' DDL event trigger(s) found - may interfere with Blue/Green deployment. Consider disabling.';
        SELECT string_agg(evtname || ' (' || evtevent || ')', E'\n    ')
        INTO v_detail
        FROM pg_catalog.pg_event_trigger
        WHERE evtevent IN ('ddl_command_start', 'ddl_command_end', 'sql_drop')
          AND evtname != 'dts_capture_catalog_start';
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No problematic DDL event triggers found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '35'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 35b. DTS trigger [per-database] (Blue/Green)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 35b. Check for DTS trigger [per-database] ===';
    SELECT count(*) INTO v_count
    FROM pg_catalog.pg_event_trigger
    WHERE evtname = 'dts_capture_catalog_start';
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := 'DTS trigger dts_capture_catalog_start found. Must be dropped before Blue/Green upgrade.';
        v_detail := 'dts_capture_catalog_start';
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No DTS trigger found.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '35b'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 35c. max_locks_per_transaction Validation for Blue/Green [global]
    -- Note: Validates against current database only. Shell script sums across ALL databases.
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 35c. max_locks_per_transaction Validation for Blue/Green [global] ===';
    SELECT count(*) INTO v_count
    FROM information_schema.tables
    WHERE table_schema NOT IN ('pg_catalog','information_schema','pg_toast')
      AND table_type = 'BASE TABLE';
    IF (current_setting('max_connections')::integer + current_setting('max_prepared_transactions')::integer) > 0
       AND current_setting('max_locks_per_transaction')::integer <
           CEIL(v_count::numeric / (current_setting('max_connections')::integer + current_setting('max_prepared_transactions')::integer))
    THEN
        v_status := '⚠️ WARNING';
        v_msg := 'max_locks_per_transaction (' || current_setting('max_locks_per_transaction') ||
                 ') may be insufficient. Tables: ' || v_count ||
                 ', required: ' || CEIL(v_count::numeric / (current_setting('max_connections')::integer + current_setting('max_prepared_transactions')::integer)) ||
                 '. Note: Shell script checks across ALL databases.';
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'max_locks_per_transaction=' || current_setting('max_locks_per_transaction') || ', tables in current DB: ' || v_count;
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '35c'; check_scope := 'global'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 36. chkpass extension [per-database]
    -- (target >= 11)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 36. check_chkpass_extension [per-database] ===';
    IF v_target_ge_11 THEN
        SELECT count(*) INTO v_count FROM pg_catalog.pg_extension WHERE extname = 'chkpass';
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := 'chkpass extension installed - not supported in PG >= 11. Please drop the extension.';
            v_detail := 'chkpass';
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'chkpass extension not installed.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (target version < 11).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '36'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 37. tsearch2 extension [per-database]
    -- (target >= 11)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 37. check_tsearch2_extension [per-database] ===';
    IF v_target_ge_11 THEN
        SELECT count(*) INTO v_count FROM pg_catalog.pg_extension WHERE extname = 'tsearch2';
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := 'tsearch2 extension installed - not supported in PG >= 11. Please drop the extension.';
            v_detail := 'tsearch2';
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'tsearch2 extension not installed.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (target version < 11).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '37'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 38. pg_repack extension [per-database]
    -- (target >= 14)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 38. check_pg_repack_extension [per-database] ===';
    IF v_target_ge_14 THEN
        SELECT count(*) INTO v_count FROM pg_catalog.pg_extension WHERE extname = 'pg_repack';
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := 'pg_repack installed. Must be dropped before upgrade to PG >= 14.';
            SELECT string_agg(extname || ' v' || extversion, E'
    ') INTO v_detail FROM pg_catalog.pg_extension WHERE extname = 'pg_repack';
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'pg_repack not installed.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (target version < 14).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '38'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 39. System-defined composite types in user tables [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 39. Checking for system-defined composite types in user tables [per-database] ===';
    SELECT count(*) INTO v_count
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
    ) sub;
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := v_count || ' system-defined composite type column(s) found in user tables. Please drop the problem columns.';
        SELECT string_agg(nspname || '.' || relname || '.' || attname, E'
    ')
        INTO v_detail
        FROM (
            WITH RECURSIVE oids AS (
                SELECT t.oid FROM pg_catalog.pg_type t
                LEFT JOIN pg_catalog.pg_namespace n ON t.typnamespace = n.oid
                WHERE typtype = 'c' AND (t.oid < 16384 OR nspname = 'information_schema')
                UNION ALL
                SELECT * FROM (
                    WITH x AS (SELECT oid FROM oids)
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                    WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid = x.oid
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                    WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                ) foo
            )
            SELECT n.nspname, c.relname, a.attname
            FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
            WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN (SELECT oid FROM oids)
              AND c.relkind IN ('r','m','i') AND c.relnamespace = n.oid
              AND n.nspname !~ '^pg_temp_' AND n.nspname !~ '^pg_toast_temp_'
              AND n.nspname NOT IN ('pg_catalog','information_schema')
        ) sub;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No system-defined composite type columns in user tables.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '39'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 39b. reg* data types in user tables [per-database]
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 39b. Checking for reg* data types in user tables [per-database] ===';
    SELECT count(*) INTO v_count
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
    ) sub;
    IF v_count > 0 THEN
        v_status := '❌ FAILED';
        v_msg := v_count || ' reg* data type column(s) found in user tables. Please drop the problem columns.';
        SELECT string_agg(nspname || '.' || relname || '.' || attname, E'
    ')
        INTO v_detail
        FROM (
            WITH RECURSIVE oids AS (
                SELECT oid FROM pg_catalog.pg_type t
                WHERE t.typnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'pg_catalog')
                  AND t.typname IN ('regcollation','regconfig','regdictionary','regnamespace','regoper','regoperator','regproc','regprocedure')
                UNION ALL
                SELECT * FROM (
                    WITH x AS (SELECT oid FROM oids)
                    SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                    WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid = x.oid
                    UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                    WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                ) foo
            )
            SELECT n.nspname, c.relname, a.attname
            FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
            WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN (SELECT oid FROM oids)
              AND c.relkind IN ('r','m','i') AND c.relnamespace = n.oid
              AND n.nspname !~ '^pg_temp_' AND n.nspname !~ '^pg_toast_temp_'
              AND n.nspname NOT IN ('pg_catalog','information_schema')
        ) sub;
    ELSE
        v_status := '✓ PASSED';
        v_msg := 'No reg* data type columns in user tables.';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '39b'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 40. Incompatible aclitem data type [per-database]
    -- (source <= 15 AND target >= 16)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 40. Checking for incompatible aclitem data type [per-database] ===';
    IF v_need_aclitem_check THEN
        SELECT count(*) INTO v_count
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
        ) sub;
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := v_count || ' aclitem column(s) found - format changed in PG 16. Please drop the problem columns.';
            SELECT string_agg(nspname || '.' || relname || '.' || attname, E'
    ')
            INTO v_detail
            FROM (
                WITH RECURSIVE oids AS (
                    SELECT 'pg_catalog.aclitem'::pg_catalog.regtype AS oid
                    UNION ALL SELECT * FROM (
                        WITH x AS (SELECT oid FROM oids)
                        SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                        WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid = x.oid
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                        WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                    ) foo
                )
                SELECT n.nspname, c.relname, a.attname
                FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
                WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN (SELECT oid FROM oids)
                  AND c.relkind IN ('r','m','i') AND c.relnamespace = n.oid
                  AND n.nspname !~ '^pg_temp_' AND n.nspname !~ '^pg_toast_temp_'
                  AND n.nspname NOT IN ('pg_catalog','information_schema')
            ) sub;
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'No incompatible aclitem columns found.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (not applicable for this upgrade path).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '40'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 41. sql_identifier data type [per-database]
    -- (source <= 11)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 41. Checking for invalid sql_identifier user columns [per-database] ===';
    IF v_source_le_11 THEN
        SELECT count(*) INTO v_count
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
        ) sub;
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := v_count || ' sql_identifier column(s) found - format changed in PG 12. Please drop the problem columns.';
            SELECT string_agg(nspname || '.' || relname || '.' || attname, E'
    ')
            INTO v_detail
            FROM (
                WITH RECURSIVE oids AS (
                    SELECT 'information_schema.sql_identifier'::pg_catalog.regtype AS oid
                    UNION ALL SELECT * FROM (
                        WITH x AS (SELECT oid FROM oids)
                        SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                        WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid = x.oid
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                        WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                    ) foo
                )
                SELECT n.nspname, c.relname, a.attname
                FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
                WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN (SELECT oid FROM oids)
                  AND c.relkind IN ('r','m','i') AND c.relnamespace = n.oid
                  AND n.nspname !~ '^pg_temp_' AND n.nspname !~ '^pg_toast_temp_'
                  AND n.nspname NOT IN ('pg_catalog','information_schema')
            ) sub;
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'No invalid sql_identifier columns found.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (source version > 11).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '41'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 42. Removed data types (abstime/reltime/tinterval) [per-database]
    -- (source <= 11)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 42. Checking for removed abstime/reltime/tinterval data types [per-database] ===';
    IF v_source_le_11 THEN
        SELECT count(*) INTO v_count
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
        ) sub;
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := v_count || ' column(s) using removed data types (abstime/reltime/tinterval). Please drop or alter the problem columns.';
            SELECT string_agg(nspname || '.' || relname || '.' || attname, E'
    ')
            INTO v_detail
            FROM (
                WITH RECURSIVE oids AS (
                    SELECT 'pg_catalog.abstime'::pg_catalog.regtype AS oid
                    UNION ALL SELECT 'pg_catalog.reltime'::pg_catalog.regtype
                    UNION ALL SELECT 'pg_catalog.tinterval'::pg_catalog.regtype
                    UNION ALL SELECT * FROM (
                        WITH x AS (SELECT oid FROM oids)
                        SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typbasetype = x.oid AND typtype = 'd'
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, x WHERE typelem = x.oid AND typtype = 'b'
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_class c, pg_catalog.pg_attribute a, x
                        WHERE t.typtype = 'c' AND t.oid = c.reltype AND c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid = x.oid
                        UNION ALL SELECT t.oid FROM pg_catalog.pg_type t, pg_catalog.pg_range r, x
                        WHERE t.typtype = 'r' AND r.rngtypid = t.oid AND r.rngsubtype = x.oid
                    ) foo
                )
                SELECT n.nspname, c.relname, a.attname
                FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n, pg_catalog.pg_attribute a
                WHERE c.oid = a.attrelid AND NOT a.attisdropped AND a.atttypid IN (SELECT oid FROM oids)
                  AND c.relkind IN ('r','m','i') AND c.relnamespace = n.oid
                  AND n.nspname !~ '^pg_temp_' AND n.nspname !~ '^pg_toast_temp_'
                  AND n.nspname NOT IN ('pg_catalog','information_schema')
            ) sub;
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'No removed data type columns found.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (source version > 11).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '42'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 43. Tables WITH OIDS [per-database]
    -- (source <= 11)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 43. Checking for tables WITH OIDS [per-database] ===';
    IF v_source_le_11 THEN
        SELECT count(*) INTO v_count
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relhasoids AND n.nspname NOT IN ('pg_catalog');
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := v_count || ' table(s) WITH OIDS found. Use ALTER TABLE ... SET WITHOUT OIDS.';
            SELECT string_agg(n.nspname || '.' || c.relname, E'
    ')
            INTO v_detail
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
            WHERE c.relhasoids AND n.nspname NOT IN ('pg_catalog');
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'No tables WITH OIDS found.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (source version > 11).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '43'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 44. User-defined encoding conversions [per-database]
    -- (source <= 13)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 44. Checking for user-defined encoding conversions [per-database] ===';
    IF v_source_le_13 THEN
        SELECT count(*) INTO v_count
        FROM pg_catalog.pg_conversion c
        WHERE c.oid >= 16384;
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := v_count || ' user-defined encoding conversion(s) found. Please remove them before upgrade.';
            SELECT string_agg(n.nspname || '.' || c.conname, E'
    ')
            INTO v_detail
            FROM pg_catalog.pg_conversion c
            JOIN pg_catalog.pg_namespace n ON c.connamespace = n.oid
            WHERE c.oid >= 16384;
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'No user-defined encoding conversions found.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (source version > 13).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '44'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 45. User-defined postfix operators [per-database]
    -- (source <= 13)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 45. Checking for user-defined postfix operators [per-database] ===';
    IF v_source_le_13 THEN
        SELECT count(*) INTO v_count
        FROM pg_catalog.pg_operator o
        WHERE o.oprright = 0 AND o.oid >= 16384;
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := v_count || ' user-defined postfix operator(s) found. Please drop them before upgrade.';
            SELECT string_agg(n.nspname || '.' || o.oprname, E'
    ')
            INTO v_detail
            FROM pg_catalog.pg_operator o
            JOIN pg_catalog.pg_namespace n ON o.oprnamespace = n.oid
            WHERE o.oprright = 0 AND o.oid >= 16384;
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'No user-defined postfix operators found.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (source version > 13).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '45'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- --------------------------------------------
    -- Check 46. Incompatible polymorphic functions [per-database]
    -- (source <= 13)
    -- --------------------------------------------
    v_detail := '';
    RAISE NOTICE '=== 46. check_for_incompatible_polymorphics [per-database] ===';
    IF v_source_le_13 THEN
        SELECT count(*) INTO v_count
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
        ) sub;
        IF v_count > 0 THEN
            v_status := '❌ FAILED';
            v_msg := v_count || ' incompatible polymorphic object(s) found. Please drop and recreate with anycompatible types.';
            SELECT string_agg(n.nspname || '.' || p.proname, E'
    ')
            INTO v_detail
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
        ELSE
            v_status := '✓ PASSED';
            v_msg := 'No incompatible polymorphic objects found.';
        END IF;
    ELSE
        v_status := '- SKIP';
        v_msg := 'Skipped (source version > 13).';
    END IF;
    RAISE NOTICE '%: %', v_status, v_msg;
    IF v_detail IS NOT NULL AND v_detail != '' THEN
        RAISE NOTICE '  Detail:'; RAISE NOTICE '    %', v_detail;
    END IF;
    check_id := '46'; check_scope := 'per-database'; status := v_status; message := v_msg; detail := v_detail;
    RETURN NEXT;
    RAISE NOTICE '';

    -- ============================================
    -- Summary
    -- ============================================
    RAISE NOTICE '============================================';
    RAISE NOTICE 'Summary';
    RAISE NOTICE '============================================';
    RAISE NOTICE 'Database: %  |  Source: %  |  Target: %', v_current_db, v_source_major, p_target_version;

    RAISE LOG '[MVU-Precheck] Completed: target_version=%, db=%, user=%, pid=%',
        p_target_version, current_database(), current_user, pg_backend_pid();

    RETURN;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.pg_major_version_upgrade_precheck(integer) FROM PUBLIC;

-- ============================================
-- Example usage:
--   SELECT * FROM pg_major_version_upgrade_precheck(16);
--
-- After running the precheck, remove the function:
--   DROP FUNCTION IF EXISTS public.pg_major_version_upgrade_precheck(integer);
-- ============================================
