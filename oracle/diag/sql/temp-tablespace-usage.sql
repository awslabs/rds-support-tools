
set lines 180
set wrap on
set head on
set pages 80
col username format a10
col program format a30
col module format a30
col status format a6
col osuser format a10
col server format a6


select * from 
(
	select 
        	s.sid,
        	s.username,
		substr(s.program,1,30) program, 
        	substr(s.osuser,1,15) osuser,
        	substr(s.module,1,30) module,
        	substr(s.status,1,6) status ,
        	logon_time,
        	s.sql_id,
        	u.contents,
        	round((u.blocks*8192)/(1024*1024)) segmegs
	from v$session s, v$sort_usage u
	where
	s.saddr= u.session_addr
	order by segmegs desc 
) where rownum <= 20 
;

