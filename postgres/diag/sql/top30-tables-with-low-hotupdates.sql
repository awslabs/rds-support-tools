


WITH t as (SELECT  relname, n_tup_ins, n_tup_del  , n_tup_upd, n_tup_hot_upd, n_dead_tup, n_live_tup,
                   round((n_tup_hot_upd::numeric / nullif((n_tup_hot_upd + n_tup_upd),0)::numeric)*100.0,2) as perc_hot
              FROM pg_stat_all_tables
)
SELECT  relname, n_tup_ins, n_tup_del,  n_tup_upd, n_tup_hot_upd, n_dead_tup, n_live_tup, perc_hot as "% HOT"
  FROM t
 WHERE  perc_hot < 80
  ORDER BY n_live_tup desc limit 30;
