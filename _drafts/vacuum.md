https://medium.com/helpshift-engineering/auto-vacuum-tuning-in-postgresql-3408f8b62ad8
https://resources.pganalyze.com/pganalyze_Tuning_autovacuum_for_best_Postgres_performance.pdf
https://www.cybertec-postgresql.com/en/tuning-autovacuum-postgresql/

https://github.com/aws-samples/aurora-and-database-migration-labs/tree/master/Code/PGPerfStatsSnapper/SQLs



## Database max Xid age
```sql
WITH max_age AS (
    SELECT 2000000000 as max_old_xid, setting AS autovacuum_freeze_max_age 
    FROM pg_catalog.pg_settings 
    WHERE name = 'autovacuum_freeze_max_age' )
,per_database_stats AS ( 
    SELECT datname, m.max_old_xid::int, m.autovacuum_freeze_max_age::int, age(d.datfrozenxid) AS oldest_current_xid 
    FROM pg_catalog.pg_database d 
    JOIN max_age m ON (true) 
    WHERE d.datallowconn ) 
SELECT *, (oldest_current_xid/max_old_xid::float) AS percentTowardsWraparound, (oldest_current_xid/autovacuum_freeze_max_age::float) AS percentTowardsEmergencyAutovac
FROM per_database_stats;
      datname       | max_old_xid | autovacuum_freeze_max_age | oldest_current_xid | percenttowardswraparound | percenttowardsemergencyautovac
--------------------+-------------+---------------------------+--------------------+--------------------------+--------------------------------
 pgbench            |  2000000000 |                 200000000 |          194605622 |              0.097302811 |       0.97302811
 postgres           |  2000000000 |                 200000000 |          177798673 |             0.0888993365 |       0.888993365
 testdb             |  2000000000 |                 200000000 |          196840480 |               0.09842024 |       0.9842024
 template1          |  2000000000 |                 200000000 |          198580272 |              0.099290136 |       0.99290136
```

## Tables max Xid age
```sql
SELECT tab.oid::regclass tab, age(relfrozenxid) xid_age,
       (age(relfrozenxid)*1.0/current_setting('autovacuum_freeze_max_age')::int)::numeric(10,3) distance,
       round(pg_table_size(tab.oid)::numeric/1024/1024) size_mb,
       CASE WHEN n_live_tup>0 THEN round(n_dead_tup*100.0/(n_live_tup+n_dead_tup), 2) END dead_pct
  FROM pg_class tab
  LEFT JOIN pg_stat_user_tables sut ON sut.relid=tab.oid
 WHERE tab.relkind IN ('r','t','m')
   AND NOT tab.relnamespace::regnamespace::text ~ '^pg_|inform'
 ORDER BY distance DESC LIMIT 20;

tab      |  xid_age   | distance | size_mb | dead_pct 
------------------------------+------------+----------+
 test1   | 1414237641 |    7.071 |  111864 |    63.44
 test2   |  199550621 |    0.998 |   21043 |     0.00
 test3   |  196112618 |    0.981 |   41758 |     0.00
 test4   |  192220327 |    0.961 |   91622 |     0.00
```

## Vacuum process
```sql
 SELECT p.pid
     , date_trunc('second',now() - a.xact_start)                                      AS dur
     , coalesce(wait_event_type ||'.'|| wait_event, 'f')                              AS wait
     , CASE
        WHEN a.query ~*'^autovacuum.*to prevent wraparound' THEN 'wraparound'
        WHEN a.query ~*'^vacuum' THEN 'user'
        ELSE 'regular' END                                                            AS mode
     , p.datname                                                                      AS dat
     , p.relid::regclass                                                              AS tab
     , p.phase
     , round((p.heap_blks_total * current_setting('block_size')::int)/1024.0/1024)    AS tab_mb
     , round(pg_total_relation_size(relid)/1024.0/1024)                               AS ttl_mb
     , round((p.heap_blks_scanned * current_setting('block_size')::int)/1024.0/1024)  AS scan_mb
     , round((p.heap_blks_vacuumed * current_setting('block_size')::int)/1024.0/1024) AS vac_mb
     , (100 * p.heap_blks_scanned / nullif(p.heap_blks_total,0))                      AS scan_pct
     , (100 * p.heap_blks_vacuumed / nullif(p.heap_blks_total,0))                     AS vac_pct
     , p.index_vacuum_count                                                           AS ind_vac_cnt
     , round(p.num_dead_tuples * 100.0 / nullif(p.max_dead_tuples, 0),1)              AS dead_pct
  FROM pg_stat_progress_vacuum p 
  JOIN pg_stat_activity a using (pid) ORDER BY dur DESC;

 pid |   dur    | wait |  mode  |     dat      |  tab  |       phase       | tab_mb | ttl_mb | scan_mb | vac_mb | scan_pct | vac_pct | ind_vac_cnt | dead_pct 
-----+----------+------+--------+--------------+-------+-------------------+--------+--------+------- -+--------+----------+---------+-------------+---------
  55 | 15:43:13 | f    | freeze | brigit-plaid | test2 | vacuuming indexes | 21043  | 31043  |  542747 | 502365 |       88 |      82 |           1 | 100.0
```

## Show oldex Xmin
```sql
WITH bits AS (
 SELECT (
     SELECT backend_xmin
     FROM pg_stat_activity
     ORDER BY age(backend_xmin) DESC nulls last limit 1
     ) AS xmin_pg_stat_activity
    ,(
     SELECT xmin
     FROM pg_replication_slots
     ORDER BY age(xmin) DESC nulls last limit 1
     ) AS xmin_pg_replication_slots
    ,(
     SELECT catalog_xmin
     FROM pg_replication_slots
     ORDER BY age(xmin) DESC nulls last limit 1
     ) AS xmin_catalog_pg_replication_slots
    ,(
     SELECT TRANSACTION
     FROM pg_prepared_xacts
     ORDER BY age(TRANSACTION) DESC nulls last limit 1
     ) AS xmin_pg_prepared_xacts
 )
SELECT *,
    age(xmin_pg_stat_activity) AS xmin_pg_stat_activity_age,
    age(xmin_pg_replication_slots) AS xmin_pg_replication_slots_age,
    age(xmin_catalog_pg_replication_slots) AS xmin_catalog_pg_replication_slots_age,
    age(xmin_pg_prepared_xacts) AS xmin_pg_prepared_xacts_age,
    greatest(age(xmin_pg_stat_activity), age(xmin_pg_replication_slots), age(xmin_catalog_pg_replication_slots), age(xmin_pg_prepared_xacts)) AS xmin_horizon_age
FROM bits;
```


## Show active query 
```sql
SELECT 
    (clock_timestamp() - pg_stat_activity.xact_start) AS ts_age,
    pg_stat_activity.state,
    (clock_timestamp() - pg_stat_activity.query_start) AS query_age,
    (clock_timestamp() - state_change) AS change_age,
    pg_stat_activity.datname,
    pg_stat_activity.pid,
    pg_stat_activity.usename,
    coalesce(wait_event_type = 'Lock', 'f') AS waiting,
    pg_stat_activity.client_addr,
    pg_stat_activity.client_port,
    pg_stat_activity.query
FROM 
    pg_stat_activity
WHERE
    (
        (clock_timestamp() - pg_stat_activity.xact_start > '00:00:00.1'::interval) 
        OR 
        (clock_timestamp() - pg_stat_activity.query_start > '00:00:00.1'::interval 
        AND state = 'idle in transaction (aborted)')
    )
    AND pg_stat_activity.pid <> pg_backend_pid()
ORDER BY 
    coalesce(pg_stat_activity.xact_start, pg_stat_activity.query_start);

 ts_age              | state  |        query_age    |       change_age    | datname  | pid | usename | waiting | client_addr | client_port |                                        query
--------------------------+--------+--------------------------+--------------------------+--------------+---------+---------+---------+-------------+-------------+--------------------------------------------------------------------------------------
 5 days 01:51:55.487 | active | 5 days 01:51:55.487 | 5 days 01:51:55.482 | testdb   |  84 |         | f       |             |             | autovacuum: VACUUM ANALYZE public.test2 (to prevent wraparound)
```



## ]КВЫ
The following query shows the number of "dead" tuples in a table named table1:

    SELECT relname, n_dead_tup, last_vacuum, last_autovacuum FROM 
    pg_catalog.pg_stat_all_tables 
    WHERE n_dead_tup > 0 and relname = 'table1';

