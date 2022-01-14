#!/bin/env bash


## Variables can be defined at the environment 
## To protect the password use:
##    read PGPASSWORD; export PGPASSWORD


# PGUSER=""  
# PGHOST=""
# PGDATABASE="tempate1"
# PGPASSWORD=""



psql_cmd=`whereis psql`


$psql_cmd -t --csv -f ../sql/repl-session.sql  >> stat-repl.log  2>&1 & 
$psql_cmd -t --csv -f ../sql/repl-slots.sql  >> repl-slots.log  2>&1 & 
$psql_cmd -t --csv -f ../sql/repl-wal-receiver.sql   >> repl-wal-receiver.log  2>&1 & 
$psql_cmd -t --csv -f ../sql/repl-xmin-from-activity.sql   >> repl-xmin-from-activity.log  2>&1 & 
$psql_cmd -t --csv -f ../sql/repl-database-conflicts.sql   >> repl-database-conflicts.log  2>&1 & 
$psql_cmd -t --csv -f ../sql/stat-archiver.sql   >> stat-archiver.log  2>&1 & 
