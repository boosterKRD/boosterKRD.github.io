https://habr.com/ru/companies/postgrespro/articles/503008/
1. Acquires an exclusive lock on the tuple to be updated.
2. If xmax and information bits show that the row is locked, requests a lock on the xmax transaction ID.
3. Writes its own xmax and sets the required information bits.
4. Releases the tuple lock.



#transaction1
BEGIN;
LOCK TABLE maratos IN ACCESS EXCLUSIVE MODE;
COMMIT;

#transaction2
select count(*) from maratos;

#transaction3

EXPLAIN (ANALYZE, BUFFERS)     
SELECT DISTINCT 
    b.datname, 
    b.pid AS blocking_pid, 
    b.query AS blocking_query
FROM 
    pg_stat_activity AS a 
JOIN 
    pg_locks bl ON bl.pid = ANY(pg_blocking_pids(a.pid)) 
JOIN 
    pg_stat_activity AS b ON bl.pid = b.pid 
WHERE 
    a.wait_event_type = 'Lock' 
    AND bl.granted = true;
          datname          | blocking_pid |                blocking_query
---------------------------+--------------+----------------------------------------------
 customers-identity-mz-uae |      1459993 | LOCK TABLE maratos IN ACCESS EXCLUSIVE MODE;    

SELECT a.datname, a.pid, b.pid AS blocking_pid, a.query as blocked_query, b.query as bloking_query FROM pg_stat_activity AS a JOIN pg_stat_activity AS b ON b.pid = ANY(pg_blocking_pids(a.pid)) where a.wait_event_type='Lock';
          datname          |   pid   | blocking_pid |         blocked_query         |                bloking_query
---------------------------+---------+--------------+-------------------------------+----------------------------------------------
 customers-identity-mz-uae | 1459526 |      1459524 | select count(*) from maratos; | LOCK TABLE maratos IN ACCESS EXCLUSIVE MODE;

SELECT blocked_locks.pid     AS blocked_pid,
         blocked_activity.usename  AS blocked_user,
         blocking_locks.pid     AS blocking_pid,
         blocking_activity.usename AS blocking_user,
         blocked_activity.query    AS blocked_statement,
         blocking_activity.query   AS current_statement_in_blocking_process,
blocked_activity.state as  blocked_state,
blocking_activity2.state as  blocking_state,
'User: ' || blocked_activity.usename  || ' Client_IP: ' || blocked_activity.client_addr || ' App_name: ' || blocked_activity.application_name || ' Query_start: ' || blocked_activity.query_start as blocked_info,
               'User: ' || blocking_activity2.usename  || ' Client_IP: ' || blocking_activity2.client_addr || ' App_name: ' || blocking_activity2.application_name || ' Query_start: ' || blocking_activity2.query_start as blocking_info
   FROM  pg_catalog.pg_locks         blocked_locks
    JOIN pg_catalog.pg_stat_activity blocked_activity  ON blocked_activity.pid = blocked_locks.pid
    JOIN pg_catalog.pg_locks         blocking_locks
                              JOIN pg_catalog.pg_stat_activity blocking_activity2  ON blocking_activity2.pid = blocking_locks.pid
        ON blocking_locks.locktype = blocked_locks.locktype
        AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE
        AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
        AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
        AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
        AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
        AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
        AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
        AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
        AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
        AND blocking_locks.pid != blocked_locks.pid
    JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
   WHERE NOT blocked_locks.GRANTED;


 blocked_pid | blocked_user | blocking_pid | blocking_user |       blocked_statement       |    current_statement_in_blocking_process     | blocked_state |   blocking_state    |                                             blocked_info                                             |                                            blocking_info
-------------+--------------+--------------+---------------+-------------------------------+----------------------------------------------+---------------+---------------------+------------------------------------------------------------------------------------------------------+------------------------------------------------------------------------------------------------------
     1459526 | dataegret    |      1459524 | dataegret     | select count(*) from maratos; | LOCK TABLE maratos IN ACCESS EXCLUSIVE MODE; | active        | idle in transaction | User: dataegret Client_IP: 10.165.129.8/32 App_name: psql Query_start: 2024-08-09 16:51:41.490771+00 | User: dataegret Client_IP: 10.165.129.8/32 App_name: psql Query_start: 2024-08-09 16:51:39.022044+00