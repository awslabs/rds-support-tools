-- setup
CREATE TABLE pg_stat_replication_slots_history AS SELECT * FROM pg_stat_replication_slots WITH NO DATA;
ALTER TABLE pg_stat_replication_slots_history ADD COLUMN inserted_at timestamp DEFAULT now();
ALTER TABLE pg_stat_replication_slots_history ADD COLUMN tags TEXT;


CREATE OR REPLACE FUNCTION snapshot_slot_stats(tag TEXT DEFAULT 'none')
RETURNS void
LANGUAGE PLPGSQL
AS
$$
DECLARE
  v_query TEXT;
  v_clock timestamp;

BEGIN
  v_clock := clock_timestamp();
  v_query := 'INSERT INTO pg_stat_replication_slots_history    SELECT *, '||quote_literal(v_clock)||','||quote_literal(tag)||' FROM pg_stat_replication_slots;';
  EXECUTE v_query;

END;
$$;


-- insert
SELECT snapshot_slot_stats('00_slot_sampling');
