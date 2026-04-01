select now(),min(backend_xid::text::bigint), min(backend_xmin::text::bigint), max(backend_xid::text::bigint), max(backend_xmin::text::bigint) from pg_stat_activity;
