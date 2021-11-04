create extension pg_stat_statements;

CREATE OR REPLACE FUNCTION destroy_snapshot_stats()
RETURNS void
LANGUAGE PLPGSQL
AS
$$
DECLARE
BEGIN
  EXECUTE  '
  DROP TABLE IF EXISTS pg_stat_all_tables_history ;
  DROP TABLE IF EXISTS pg_stat_all_indexes_history ;
  DROP TABLE IF EXISTS pg_statio_all_tables_history ;
  DROP TABLE IF EXISTS pg_statio_all_indexes_history ;
  DROP TABLE IF EXISTS pg_stat_statements_history;
  DROP TABLE IF EXISTS pg_stat_database_history ;
  DROP TABLE IF EXISTS pg_stat_bgwriter_history ;
  ';
END;
$$;

CREATE OR REPLACE FUNCTION create_snapshot_stats()
RETURNS void
LANGUAGE PLPGSQL
AS
$$
DECLARE
BEGIN
  EXECUTE '
      CREATE TABLE pg_stat_all_tables_history AS SELECT * FROM pg_stat_all_tables WITH NO DATA;
      ALTER TABLE pg_stat_all_tables_history ADD COLUMN inserted_at timestamp DEFAULT now();
      ALTER TABLE pg_stat_all_tables_history ADD COLUMN tags TEXT;

      CREATE TABLE pg_stat_all_indexes_history AS SELECT * FROM pg_stat_all_indexes WITH NO DATA;
      ALTER TABLE pg_stat_all_indexes_history ADD COLUMN inserted_at timestamp DEFAULT now();
      ALTER TABLE pg_stat_all_indexes_history ADD COLUMN tags TEXT;

      CREATE TABLE pg_statio_all_tables_history AS SELECT * FROM pg_statio_all_tables WITH NO DATA;
      ALTER TABLE pg_statio_all_tables_history ADD COLUMN inserted_at timestamp DEFAULT now();
      ALTER TABLE pg_statio_all_tables_history ADD COLUMN tags TEXT;

      CREATE TABLE pg_statio_all_indexes_history AS SELECT * FROM pg_statio_all_indexes WITH NO DATA;
      ALTER TABLE pg_statio_all_indexes_history ADD COLUMN inserted_at timestamp DEFAULT now();
      ALTER TABLE pg_statio_all_indexes_history ADD COLUMN tags TEXT;

      CREATE TABLE pg_stat_statements_history AS SELECT * FROM pg_stat_statements WITH NO DATA;
      ALTER TABLE pg_stat_statements_history ADD COLUMN inserted_at timestamp DEFAULT now();
      ALTER TABLE pg_stat_statements_history ADD COLUMN tags TEXT;

      CREATE TABLE pg_stat_database_history AS SELECT * FROM pg_stat_database WITH NO DATA;
      ALTER TABLE pg_stat_database_history ADD COLUMN inserted_at timestamp DEFAULT now();
      ALTER TABLE pg_stat_database_history ADD COLUMN tags TEXT;

      CREATE TABLE pg_stat_bgwriter_history AS SELECT * FROM pg_stat_bgwriter WITH NO DATA;
      ALTER TABLE pg_stat_bgwriter_history ADD COLUMN inserted_at timestamp DEFAULT now();
      ALTER TABLE pg_stat_bgwriter_history ADD COLUMN tags TEXT;
    ';
END;
$$ ;

CREATE OR REPLACE FUNCTION snapshot_stats(tag TEXT DEFAULT 'none')
RETURNS void
LANGUAGE PLPGSQL
AS
$$
DECLARE
  v_query TEXT;
  v_clock timestamp;

BEGIN
  v_clock := clock_timestamp();
  v_query := 'INSERT INTO pg_stat_all_tables_history    SELECT *, '||quote_literal(v_clock)||','||quote_literal(tag)||' FROM pg_stat_all_tables;';
  EXECUTE v_query;

  v_clock := clock_timestamp();
  v_query := 'INSERT INTO pg_stat_all_indexes_history   SELECT *, '||quote_literal(v_clock)||','||quote_literal(tag)||' FROM pg_stat_all_indexes;';
  EXECUTE v_query;

  v_clock := clock_timestamp();
  v_query := 'INSERT INTO pg_statio_all_tables_history  SELECT *, '||quote_literal(v_clock)||','||quote_literal(tag)||' FROM pg_statio_all_tables;';
  EXECUTE v_query;

  v_clock := clock_timestamp();
  v_query := 'INSERT INTO pg_statio_all_indexes_history SELECT *, '||quote_literal(v_clock)||','||quote_literal(tag)||' FROM pg_statio_all_indexes;';
  EXECUTE v_query;

  v_clock := clock_timestamp();
  v_query := 'INSERT INTO pg_stat_statements_history    SELECT *, '||quote_literal(v_clock)||','||quote_literal(tag)||' FROM pg_stat_statements;';
  EXECUTE v_query;

  v_clock := clock_timestamp();
  v_query := 'INSERT INTO pg_stat_database_history      SELECT *, '||quote_literal(v_clock)||','||quote_literal(tag)||' FROM pg_stat_database;';
  EXECUTE v_query;

  v_clock := clock_timestamp();
  v_query := 'INSERT INTO pg_stat_bgwriter_history      SELECT *, '||quote_literal(v_clock)||','||quote_literal(tag)||' FROM pg_stat_bgwriter;';
  EXECUTE v_query;
END;
$$;


CREATE OR REPLACE FUNCTION snapshot_export_csv(p_tags TEXT )
RETURNS void
LANGUAGE PLPGSQL
AS
$$
DECLARE
  v_dest_path     TEXT := '/rdsdbdata/tmp' ;
  v_history_table TEXT;
  v_output_file   TEXT;
  v_query         TEXT;
  v_inserted_at   timestamp;
    
BEGIN
    
    -- exporting history data as .csv files:

    v_history_table := 'pg_stat_statements_history'; 
    v_output_file := v_history_table||'_'|| p_tags ||'.csv'; 
    EXECUTE 'SELECT max(inserted_at) FROM '|| v_history_table ||' WHERE tags = '||quote_literal(p_tags) INTO v_inserted_at ; 
    v_query := 'COPY (SELECT * FROM '|| v_history_table || ' WHERE inserted_at = '|| quote_literal(v_inserted_at) || ' and tags = '|| quote_literal(p_tags) || ') TO ' 
                  || quote_literal(concat(v_dest_path,'/',v_output_file)) || ' DELIMITER' || quote_literal(',') || ' CSV HEADER'; 
    EXECUTE v_query;

    v_history_table := 'pg_stat_all_tables_history'; 
    v_output_file := v_history_table||'_'|| p_tags ||'.csv'; 
    EXECUTE 'SELECT max(inserted_at) FROM '|| v_history_table ||' WHERE tags = '||quote_literal(p_tags) INTO v_inserted_at ; 
    v_query := 'COPY (SELECT * FROM '|| v_history_table || ' WHERE inserted_at = '|| quote_literal(v_inserted_at) || ' and tags = '|| quote_literal(p_tags) || ') TO ' 
                  || quote_literal(concat(v_dest_path,'/',v_output_file)) || ' DELIMITER' || quote_literal(',') || ' CSV HEADER'; 
    EXECUTE v_query;

    v_history_table := 'pg_statio_all_tables_history'; 
    v_output_file := v_history_table||'_'|| p_tags ||'.csv'; 
    EXECUTE 'SELECT max(inserted_at) FROM '|| v_history_table ||' WHERE tags = '||quote_literal(p_tags) INTO v_inserted_at ; 
    v_query := 'COPY (SELECT * FROM '|| v_history_table || ' WHERE inserted_at = '|| quote_literal(v_inserted_at) || ' and tags = '|| quote_literal(p_tags) || ') TO ' 
                  || quote_literal(concat(v_dest_path,'/',v_output_file)) || ' DELIMITER' || quote_literal(',') || ' CSV HEADER'; 
    EXECUTE v_query;

    v_history_table := 'pg_statio_all_indexes_history'; 
    v_output_file := v_history_table||'_'|| p_tags ||'.csv'; 
    EXECUTE 'SELECT max(inserted_at) FROM '|| v_history_table ||' WHERE tags = '||quote_literal(p_tags) INTO v_inserted_at ; 
    v_query := 'COPY (SELECT * FROM '|| v_history_table || ' WHERE inserted_at = '|| quote_literal(v_inserted_at) || ' and tags = '|| quote_literal(p_tags) || ') TO ' 
                  || quote_literal(concat(v_dest_path,'/',v_output_file)) || ' DELIMITER' || quote_literal(',') || ' CSV HEADER'; 
    EXECUTE v_query;


   -- COPY pg_stat_all_indexes_history   TO '/rdsdbdata/tmp/snapshot-stats/pg_stat_all_indexes_history.csv'   DELIMITER ',' CSV HEADER;
   -- COPY pg_stat_database_history      TO '/rdsdbdata/tmp/snapshot-stats/pg_stat_database_history.csv'      DELIMITER ',' CSV HEADER;
   -- COPY pg_stat_bgwriter_history      TO '/rdsdbdata/tmp/snapshot-stats/pg_stat_bgwriter_history.csv'      DELIMITER ',' CSV HEADER;
END;
$$;




-- execute these only once to setup
SELECT destroy_snapshot_stats();
SELECT create_snapshot_stats();
SELECT pg_stat_reset();
SELECT snapshot_stats('00_before-initial-gather');


-- then, schedule a job at cron with the following:
-- SELECT snapshot_stats('01_gather-stats');

-- with pg_cron extension, the collection can be done automatically using the following:
-- create extension pg_cron;  -- remember to add 'pg_cron' in the 'shared_preload_library' parameter
-- SELECT cron.schedule('@hourly', $$SELECT snapshot_stats('01_pre-load_gather-stats');$$); -- for hourly gathering

