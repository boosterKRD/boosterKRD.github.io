---
layout: post
title: Vacuum Tuning and Monitoring in PostgreSQL
date: 2024-09-01
---

Table of Contents
1. [Database max Xid age](#1-database-max-xid-age)
2. [Tables max Xid age](#2-tables-max-xid-age)
3. [Vacuum process](#3-vacuum-process)
4. [Show live dead tuples info](#4show-live-and-dead-tulpes-info)
5. [Show oldest Xmin](#4-show-oldest-xmin)
6. [Show active queries](#5-show-active-queries)
7. [Get vacuum info from PG logs](#6-get-vacuum-info-from-pg-logs)
8. [Posts for reading](#7-posts-for-reading)

<!--MORE-->
-----

## 1. Database max Xid age
This query helps monitor the transaction ID (Xid) age for each database. It provides the percentage of Xids used toward wraparound and when emergency autovacuum might trigger.
```sql
    WITH max_age AS (
        SELECT 2000000000 AS max_old_xid, setting AS autovacuum_freeze_max_age 
        FROM pg_catalog.pg_settings 
        WHERE name = 'autovacuum_freeze_max_age'
    )
    , per_database_stats AS ( 
        SELECT datname, m.max_old_xid::int, m.autovacuum_freeze_max_age::int, age(d.datfrozenxid) AS oldest_current_xid 
        FROM pg_catalog.pg_database d 
        JOIN max_age m ON (true) 
        WHERE d.datallowconn
    )
    SELECT *, 
        (oldest_current_xid/max_old_xid::float)*100 AS pctTowardsWraparound, 
        (oldest_current_xid/autovacuum_freeze_max_age::float)*100 AS pctTowardsEmergencyAutovac
    FROM per_database_stats;
```
    Example Output
    ```bash
    datname   | max_old_xid | autovacuum_freeze_max_age | oldest_current_xid | pctTowardsWraparound | pctTowardsEmergencyAutovac
    ----------+-------------+---------------------------+--------------------+--------------------------+--------------------------------
    pgbench   |  2000000000 |                 200000000 |          194605622  |              9.7        |       97.3
    postgres  |  2000000000 |                 200000000 |          177798673  |              8.9        |       88.9
    ```

## 2. Tables max Xid age
This query helps track the age of transaction IDs for individual tables, giving you insight into potential wraparound issues.
```sql
    SELECT tab.oid::regclass tab, age(relfrozenxid) xid_age,
        (age(relfrozenxid)*1.0/current_setting('autovacuum_freeze_max_age')::int)::numeric(10,3) distance,
        round(pg_table_size(tab.oid)::numeric/1024/1024) size_mb,
        CASE WHEN n_live_tup > 0 THEN round(n_dead_tup*100.0/(n_live_tup+n_dead_tup), 2) END dead_pct,
        n_live_tup AS rows_count,
        last_vacuum, last_autovacuum 
    FROM pg_class tab
    LEFT JOIN pg_stat_user_tables sut ON sut.relid=tab.oid
    WHERE tab.relkind IN ('r','t','m')
    AND NOT tab.relnamespace::regnamespace::text ~ '^pg_|inform'
    ORDER BY distance DESC, pg_table_size(tab.oid) DESC limit 100;
```
    Example Output
    ```bash
        tab                 |  xid_age  | distance | size_mb | dead_pct | rows_count | last_vacuum |        last_autovacuum
    ----------------------------------------+-----------+----------+---------+----------+------------+-------------+-------------------------------
    test_table1             | 195527773 |    0.978 |      13 |     0.32 |     138170 |             | 2024-08-21 19:16:05.680525+00
    test_table2             | 194128785 |    0.971 |      34 |     0.10 |     234027 |             | 2024-08-21 19:34:52.042495+00
    ```

## 3. Vacuum process
This query shows the progress of active vacuum processes, including the amount of data scanned and vacuumed.
```sql
SELECT p.pid, 
       date_trunc('second', now() - a.xact_start) AS dur, 
       coalesce(wait_event_type ||'.'|| wait_event, 'f') AS wait, 
       CASE
          WHEN a.query ~* '^autovacuum.*to prevent wraparound' THEN 'wraparound'
          WHEN a.query ~* '^vacuum' THEN 'user'
          ELSE 'regular' 
       END AS mode,
       p.datname AS dat,
       p.relid::regclass AS tab,
       p.phase,
       round((p.heap_blks_total * current_setting('block_size')::int)/1024.0/1024) AS tab_mb,
       round(pg_total_relation_size(relid)/1024.0/1024) AS ttl_mb,
       round((p.heap_blks_scanned * current_setting('block_size')::int)/1024.0/1024) AS scan_mb,
       round((p.heap_blks_vacuumed * current_setting('block_size')::int)/1024.0/1024) AS vac_mb,
       (100 * p.heap_blks_scanned / nullif(p.heap_blks_total, 0)) AS scan_pct,
       (100 * p.heap_blks_vacuumed / nullif(p.heap_blks_total, 0)) AS vac_pct,
       p.index_vacuum_count AS ind_vac_cnt,
       round(p.num_dead_tuples * 100.0 / nullif(p.max_dead_tuples, 0), 1) AS max_tuple_pct
  FROM pg_stat_progress_vacuum p 
  JOIN pg_stat_activity a USING (pid) 
ORDER BY dur DESC;
```
    Example Output
    ```bash
    pid  |   dur    | wait |  mode  |  dat         |  tab  | phase              | tab_mb | ttl_mb | scan_mb | vac_mb | scan_pct | vac_pct | ind_vac_cnt | max_tuple_pct 
    -----+----------+------+--------+--------------+-------+--------------------+--------+--------+---------+--------+----------+---------+-------------+---------
    55  | 15:43:13 | f    | freeze | testdb       | test2 | vacuuming indexes  | 21043  | 31043  |  542747 | 502365 |       88 |      82 |           1 | 100.0
    ```

## 4. Show live and dead tulpes info
This query show number of live/dead tuples in the tables.
```sql
SELECT relname, last_seq_scan, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum 
FROM pg_stat_all_tables 
WHERE relname='test_table';
```

## 5. Show oldest Xmin
This query identifies the oldest transaction's Xmin across several processes, helping prevent Xmin wraparound.
```sql
 WITH bits AS (
  SELECT
    (
      SELECT backend_xmin
      FROM pg_stat_activity
      WHERE backend_type IS DISTINCT FROM 'walsender'
        AND backend_type IS DISTINCT FROM 'autovacuum worker'
      ORDER BY age(backend_xmin) DESC NULLS LAST
      LIMIT 1
    ) AS xmin_pg_stat_activity,
    (
      SELECT xmin
      FROM pg_replication_slots
      ORDER BY age(xmin) DESC NULLS LAST
      LIMIT 1
    ) AS xmin_pg_replication_slots,
    (
      SELECT backend_xmin
      FROM pg_stat_replication
      ORDER BY age(backend_xmin) DESC NULLS LAST
      LIMIT 1
    ) AS xmin_pg_stat_replication,
    (
      SELECT transaction
      FROM pg_prepared_xacts
      ORDER BY age(transaction) DESC NULLS LAST
      LIMIT 1
    ) AS xmin_pg_prepared_xacts
)
SELECT *,
  age(xmin_pg_stat_activity) AS xmin_pg_stat_activity_age,
  age(xmin_pg_replication_slots) AS xmin_pg_replication_slots_age,
  age(xmin_pg_stat_replication) AS xmin_pg_stat_replication_age,
  age(xmin_pg_prepared_xacts) AS xmin_pg_prepared_xacts_age,
  greatest(
    age(xmin_pg_stat_activity),
    age(xmin_pg_replication_slots),
    age(xmin_pg_stat_replication),
    age(xmin_pg_prepared_xacts)
  ) AS xmin_horizon_age
FROM bits;
```
    Example Output
    ```bash
    -[ RECORD 1 ]-------------------------+-----------
    xmin_pg_stat_activity                 | 3493602218
    xmin_pg_replication_slots             |
    xmin_catalog_pg_replication_slots     |
    xmin_pg_prepared_xacts                |
    xmin_pg_stat_activity_age             | 727
    xmin_pg_replication_slots_age         |
    xmin_catalog_pg_replication_slots_age |
    xmin_pg_prepared_xacts_age            |
    xmin_horizon_age                      | 727
    ```

## 6. Show active queries
This query shows long-running active queries in the database.
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
```
    Example Output
    ```bash
    ts_age              | state  |        query_age    |       change_age    | datname  | pid | usename | waiting | client_addr | client_port | query
    ----------------------+--------+--------------------+---------------------+----------+-----+---------+---------+-------------+-------------+-------------------------------------------
    5 days 01:51:55.487  | active | 5 days 01:51:55.487| 5 days 01:51:55.482 | testdb   |  84 |         | f       |             |
    ```

## 7. Get vacuum info from PG logs
```bash
grep -A 20 -e 'vacuum of table "database.schema.table_name"' -e 'to prevent wraparound of table "database.schema.table_name"' postgresql-XXXX-XX-XX.log
```

## 8. Posts for Reading
Here are some great resources for understanding and tuning autovacuum in PostgreSQL:
- [Auto Vacuum Tuning in PostgreSQL](https://medium.com/helpshift-engineering/auto-vacuum-tuning-in-postgresql-3408f8b62ad8)
- [Tuning Autovacuum for Best Postgres Performance](https://resources.pganalyze.com/pganalyze_Tuning_autovacuum_for_best_Postgres_performance.pdf)
- [Tuning PostgreSQL autovacuum](https://www.cybertec-postgresql.com/en/tuning-autovacuum-postgresql/)
