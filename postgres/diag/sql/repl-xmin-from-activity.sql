select now(),min(backend_xid::text::int), min(backend_xmin::text::int), max(backend_xid::text::int), max(backend_xmin::text::int) from pg_stat_activity;
