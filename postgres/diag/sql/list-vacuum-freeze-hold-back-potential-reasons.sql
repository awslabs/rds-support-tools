 WITH report_xid_holders AS (
        SELECT
           (SELECT max(age(backend_xmin)) FROM pg_stat_activity  WHERE state != 'idle' )  AS max_age_running_xact
          ,(SELECT max(age(transaction)) FROM pg_prepared_xacts)                          AS max_age_prepared_xact
          ,(SELECT max(age(xmin)) FROM pg_replication_slots)                              AS max_age_replication_slot
          ,(SELECT max(age(catalog_xmin)) FROM pg_replication_slots)                      AS max_age_replication_slot_catalog_xmin
          ,(SELECT max(age(backend_xmin)) FROM pg_stat_replication)                       AS max_age_replica_xact
          ,(SELECT max(age(relfrozenxid)) FROM pg_class where relpersistence = 't')       AS max_age_temporary_table
          ,(SELECT max(age(relfrozenxid)) FROM pg_class where relkind = 't')              AS max_age_toast_relation
          ,(SELECT max(age(relfrozenxid)) FROM pg_class where relkind = 'r')              AS max_age_relation
          ,(SELECT max(age(relfrozenxid)) FROM pg_class where relkind = 'm')              AS max_age_materialized
       -- ,(SELECT max(age(feedback_xmin::text::xid)) FROM aurora_replica_status())       AS max_age_apg_replica_xact -- https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora_replica_status.html
)
SELECT   *
       , 2^31 - max_age_running_xact                  AS left_xids_running_xact
       , 2^31 - max_age_prepared_xact                 AS left_xids_prepared_xact
       , 2^31 - max_age_replication_slot              AS left_xids_replication_slot
       , 2^31 - max_age_replication_slot_catalog_xmin AS left_xids_replication_slot_catalog_xmin
       , 2^31 - max_age_replica_xact                  AS left_xids_replica_xact
       , 2^31 - max_age_temporary_table               AS left_xids_temporary_table
       , 2^31 - max_age_toast_relation                AS left_xids_toast_relation
       , 2^31 - max_age_relation                      AS left_xids_relation
       , 2^31 - max_age_materialized                  AS left_xids_materialized
    -- , 2^31 - max_age_apg_replica_xact              AS left_xids_apg_replica_xact
FROM report_xid_holders;
