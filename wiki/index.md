---
layout: post
title: Useful Index Commands
date: 2024-08-25
---
# Table of Contents
1. [Stats Reset Time](#1-stats-reset-time)
2. [Indexes Info](#2-indexes-info)
   - [Output](#output-2)
3. [Identifying Unused Indexes](#3-identifying-unused-indexes)
4. [Duplicate Indexes](#4-duplicate-indexes)
   - [Additional SQL Queries for Analyzing](#additional-sql-queries-for-analyzing)
   - [Output](#output-4)
5. [Invalid Indexes](#5-invalid-indexes)
6. [Index Create/Reindex Progress](#6-index-create-or-reindex-progress)
7. [Index Bloat Info v1](#7-index-bloat-info-v1)
8. [Index Bloat Info v2](#8-index-bloat-info-v2)
9. [Reset Index Stat](#9-reset-index-stat)
10. [Column Value Frequency Analysis](#10-column-value-frequency-analysis)  
   - [Column Statistics and Selectivity](#column-statistics-and-selectivity) 
   - [Column Most Common Values and Frequencies Analysis](#column-most-common-calues-and-frequencies-analysis)  
   - [Calculating Estimated Row Count](#calculating-estimated-row-сount)  
<!--MORE-->

-----
## 1. Stats Reset Time
```sql
select
    sd.stats_reset::timestamptz(0),
    ((extract(epoch from now()) - extract(epoch from sd.stats_reset))/86400)::int as days
from pg_stat_database sd
where datname = current_database();
```

## 2. Indexes Info
Table & index sizes along which indexes are being scanned and how many tuples are fetched. 
[About idx_tup_fetch and idx_tup_read](https://dev.to/dm8ry/postgresql-how-do-you-find-potentially-ineffective-indexes-6gp)

```sql
SELECT 
    n.nspname || '.' || c.relname AS table_name, 
    c.reltuples::bigint AS num_rows,
    COALESCE(pstu.seq_scan, 0) AS seq_scan_count, 
    --pstu.last_seq_scan AS last_seq_scan_, --since PG 16
    pg_size_pretty(pg_relation_size(c.oid)) AS table_size, 
    i.indexrelid::regclass AS index_name,
    pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
    CASE WHEN i.indisprimary THEN 'Y' ELSE 'N' END AS "primary",
    CASE WHEN i.indisunique THEN 'Y' ELSE 'N' END AS "unique",
    COALESCE(psui.idx_scan, 0) AS number_of_scans,
    COALESCE(psui.idx_tup_fetch, 0) AS rows_fetched,
    COALESCE(psui.idx_tup_read, 0) AS rows_returned,
    CASE WHEN COALESCE(psui.idx_tup_read, 0) > 0 THEN
        ROUND((COALESCE(psui.idx_tup_fetch, 0)::numeric / COALESCE(psui.idx_tup_read, 0)) * 100, 2)
    ELSE
        NULL
END AS index_efficiency_percent,        
    CASE
        WHEN (psai.idx_blks_hit + psai.idx_blks_read) > 0
        THEN ROUND((psai.idx_blks_hit::numeric / (psai.idx_blks_hit + psai.idx_blks_read)) * 100, 2)
        ELSE NULL
    END AS index_hit_ratio_percent,
    CASE
        WHEN (psai.idx_blks_hit + psai.idx_blks_read) > 0 AND psui.idx_scan > 0
        THEN ROUND(((psai.idx_blks_hit + psai.idx_blks_read)) / psui.idx_scan, 2)
        ELSE NULL
    END AS page_per_scan,  
    psai.idx_blks_hit AS index_blks_hit,
    psai.idx_blks_read AS index_blks_read,
    --psui.last_idx_scan AS last_idx_scan, --since PG16
    pg_get_indexdef(i.indexrelid) AS index_def    
FROM pg_index i
JOIN pg_class c ON c.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_stat_user_indexes psui ON i.indexrelid = psui.indexrelid
JOIN pg_statio_all_indexes psai ON psai.indexrelid = i.indexrelid
JOIN pg_stat_user_tables pstu ON pstu.relid = c.oid 
--where c.relname = 'table_name'
ORDER BY pg_relation_size(i.indexrelid) DESC;
```
### Output 2
```text
-[ RECORD 1 ]---+-------------------------------------------
table_name               | public.order_events
num_rows                 | 1878214784
seq_scan_count           | 65
table_size               | 224 GB
index_name               | order_events_event_id_unique_index
index_size               | 51 GB
primary                  | N
unique                   | Y
number_of_scans          | 2912495951
rows_fetched             | 914291469
rows_returned            | 1590927712
index_efficiency_percent | 57.47
index_def                | CREATE UNIQUE INDEX order_events_event_id_unique_index ON public.order_events USING btree (event_id)
```
-----

## 3. Identifying Unused Indexes
Indexes can introduce considerable overhead during table modifications, so it's important to remove them if they aren't being utilized for queries or enforcing constraints (such as ensuring uniqueness). Here’s how to identify such indexes:
```sql
SELECT s.schemaname,
       s.relname AS tablename,
       s.indexrelname AS indexname,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       pg_get_indexdef(i.indexrelid) AS index_def,
       t.n_tup_ins AS inserts,
       t.n_tup_upd AS updates,
       t.n_tup_del AS deletes
FROM pg_catalog.pg_stat_user_indexes s
   JOIN pg_catalog.pg_index i ON s.indexrelid = i.indexrelid
   JOIN pg_catalog.pg_stat_user_tables t ON s.relname = t.relname AND s.schemaname = t.schemaname
WHERE s.idx_scan = 0
  AND 0 <> ALL (i.indkey)
  AND NOT i.indisunique
  AND NOT EXISTS
         (SELECT 1 FROM pg_catalog.pg_constraint c
          WHERE c.conindid = s.indexrelid) 
  AND NOT EXISTS
         (SELECT 1 FROM pg_catalog.pg_inherits AS inh
          WHERE inh.inhrelid = s.indexrelid)
ORDER BY pg_relation_size(s.indexrelid) DESC;

```
-----

## 4. Duplicate Indexes
Get a list of potential duplicate indexes, then manually analyze this list, taking into account the number of scans and  the queries from 'pg_stat_statements'
```sql
SELECT 
    ni.nspname || '.' || ct.relname AS table_name, 
    ci.relname AS index_name,
    cii.relname AS overlapping_index, 
    pg_size_pretty(pg_relation_size(i.indexrelid)) as index_size,
    pg_size_pretty(pg_relation_size(ii.indexrelid)) as overlapping_index_size,
    psui.idx_scan as index_num_scan,
    psui2.idx_scan as overlapping_index_num_scan,
    psui.last_idx_scan AS index_last_scan_time, --since PG 16
    psui2.last_idx_scan AS overlapping_index_last_scan, --since PG 16
    CASE 
        WHEN (psai.idx_blks_hit + psai.idx_blks_read) > 0 
        THEN ROUND((psai.idx_blks_hit::numeric / (psai.idx_blks_hit + psai.idx_blks_read)) * 100, 2) 
        ELSE NULL 
    END AS index_hit_ratio_percent,
    CASE 
        WHEN (psai2.idx_blks_hit + psai2.idx_blks_read) > 0 
        THEN ROUND((psai2.idx_blks_hit::numeric / (psai2.idx_blks_hit + psai2.idx_blks_read)) * 100, 2) 
        ELSE NULL 
    END AS overlapping_index_hit_ratio_percent,
    psai.idx_blks_hit AS index_blks_hit,
    psai2.idx_blks_hit AS overlapping_index_blks_hit,
    psai.idx_blks_read AS index_blks_read,
    psai2.idx_blks_read AS overlapping_index_blks_read,
    i.indkey AS index_attributes,
    ii.indkey AS overlapping_index_attributes,
    pg_get_indexdef(i.indexrelid) AS index_def, 
    pg_get_indexdef(ii.indexrelid) AS overlapping_index_def
FROM pg_index i
JOIN pg_stat_user_indexes psui on psui.indexrelid=i.indexrelid
JOIN pg_statio_all_indexes psai ON psai.indexrelid = i.indexrelid
JOIN pg_class ct ON i.indrelid=ct.oid
JOIN pg_class ci ON i.indexrelid=ci.oid
JOIN pg_namespace ni ON ci.relnamespace=ni.oid
JOIN pg_index ii ON ii.indrelid=i.indrelid AND
    ii.indexrelid != i.indexrelid AND
    (array_to_string(ii.indkey, ' ') || ' ') LIKE (array_to_string(i.indkey, ' ') || ' %') AND
    (array_to_string(ii.indcollation, ' ')  || ' ') LIKE (array_to_string(i.indcollation, ' ') || ' %') AND
    (array_to_string(ii.indclass, ' ')  || ' ') LIKE (array_to_string(i.indclass, ' ') || ' %') AND
    (array_to_string(ii.indoption, ' ')  || ' ') LIKE (array_to_string(i.indoption, ' ') || ' %') AND
    NOT (ii.indkey::integer[] @> ARRAY[0]) AND
    NOT (i.indkey::integer[] @> ARRAY[0]) AND
    i.indpred IS NULL AND
    ii.indpred IS NULL AND
    CASE WHEN i.indisunique THEN ii.indisunique AND array_to_string(ii.indkey, ' ') = array_to_string(i.indkey, ' ') ELSE true END
JOIN pg_stat_user_indexes psui2 on psui2.indexrelid=ii.indexrelid
JOIN pg_statio_all_indexes psai2 ON psai2.indexrelid = ii.indexrelid
JOIN pg_class ctii ON ii.indrelid=ctii.oid
JOIN pg_class cii ON ii.indexrelid=cii.oid
WHERE ct.relname NOT LIKE 'pg_%' AND
    NOT i.indisprimary AND (ci.relname < cii.relname OR i.indkey <> ii.indkey) 
GROUP BY ni.nspname, ct.relname, ci.relname, i.indexrelid, ii.indexrelid, psui.idx_scan, 
psui.last_idx_scan, --since PG 16
psui2.last_idx_scan, --since PG 16
psui2.idx_scan, psai.idx_blks_hit, psai.idx_blks_read, psai2.idx_blks_hit, psai2.idx_blks_read, pg_get_indexdef(i.indexrelid), i.indkey, cii.relname, pg_get_indexdef(ii.indexrelid), ii.indkey
ORDER BY 1, 2, 3;
```
### Additional SQL Queries for Analyzing
```sql
--This query shows the distribution of indexes in shared_buffers (Extension pg_buffercache is needed)
SELECT  
    c.relname, pg_size_pretty(count(*) * 8192) AS buffered, 
    round(100.0 * count(*) / (SELECT setting FROM pg_settings WHERE name='shared_buffers')::integer,1) AS buffers_percent,
    round(100.0 * count(*) * 8192 / pg_relation_size(c.oid),1) AS percent_of_relation
FROM pg_class c
INNER JOIN pg_buffercache b ON b.relfilenode = c.relfilenode
INNER JOIN pg_database d ON (b.reldatabase = d.oid AND d.datname = current_database())
INNER JOIN  pg_namespace n ON c.relnamespace = n.oid
WHERE 
    c.relname IN ('index_name1', 'index_name2') and
    n.nspname NOT IN ('pg_catalog', 'information_schema') 
GROUP BY c.oid, c.relname
ORDER BY 3 DESC;

--Getting all queries that involve a table with indexes and the indexed columns for further analysis, you can use the following steps:
select * from pg_stat_statements where  lower(query) like '%select%' and query like '%marathons_group_weekly_participants%' and query like '%participation_id%'  order by calls DESC;
```
### Output 4
```text
`-[ RECORD 1 `+----------------------------------------------------------------------------
`table_name                    | public.adventure_route
`index_name                    | adventure_route_index
`overlapping_index             | adventure_route_size_steps_index
`index_size                    | 16 kB
`overlapping_index_size        | 16 kB
`index_num_scan                | 0
`overlapping_index_num_scan    | 7
`index_attributes              | 2 3
`overlapping_index_attributes  | 2 3
`index_def                     | CREATE INDEX adventure_route_index ON public`adventure_route USING btree (size, steps)
`overlapping_index_def         | CREATE INDEX adventure_route_size_steps_index ON`public.adventure_route USING btree (size, steps)
`-[ RECORD 2 `+-------------------------------------------------------------------------------
`table_name                    | public.order_completes
`index_name                    | index_order_completes_on_order_id
`overlapping_index             | order_completes_unique_index
`index_size                    | 139 MB
`overlapping_index_size        | 560 MB
`index_num_scan                | 0
`overlapping_index_num_scan    | 81116474288
`index_attributes              | 2
`overlapping_index_attributes  | 2 3 4
`index_def                     | CREATE INDEX index_order_completes_on_order_id`ON public.order_completes USING btree (order_id)
`overlapping_index_def         | CREATE UNIQUE INDEX order_completes_unique_index ON public.order_completes USING btree (order_id, userable_id, userable_type)
```

## 5. Invalid Indexes
```sql
SELECT indexrelid::regclass, indrelid::regclass,indisvalid,indisready FROM pg_index i WHERE i.indisvalid IS FALSE;
```

## 6. Index Create or Reindex Progress
```sql
SELECT 
    now()::TIME(0), 
    a.query, 
    p.phase, p.blocks_total, p.blocks_done, p.tuples_total, p.tuples_done,
    ai.schemaname, ai.relname, ai.indexrelname
FROM pg_stat_progress_create_index p 
JOIN pg_stat_activity a ON p.pid = a.pid
LEFT JOIN pg_stat_all_indexes ai on ai.relid = p.relid AND ai.indexrelid = p.index_relid;
 ```

## 7. Index Bloat Info v1
```sql
SELECT current_database() as tag_dbname, nspname as tag_schema, tblname astag_table_name, idxname  as tag_index_name, 
quote_ident(nspname) || '.' || quote_ident(tblname) as tag_table_full_name,
quote_ident(nspname) || '.' || quote_ident(idxname) as tag_index_full_name,
(bs*(relpages))::bigint AS pgib_real_size,
fillfactor as pgib_fillfactor,
CASE WHEN relpages > est_pages_ff THEN bs*(relpages-est_pages_ff) ELSE 0 END ASpgib_bloat_size,
round(100 * (relpages-est_pages_ff)::float / relpages) AS pgib_bloat_pct,
--CASE when is_na then 1 else 0 end  as pgib_inexact
CASE when is_na or round(100 * (relpages-est_pages_ff)::float / relpages) < 0then 1 else 0 end  as pgib_inexact
FROM (
SELECT coalesce(1 +
        ceil(reltuples/floor((bs-pageopqdata-pagehdr)/(4+nulldatahdrwidth)::float)), 0 -- ItemIdData size + computed avg size of a tuple (nulldatahdrwidth)
    ) AS est_pages,
    coalesce(1 +
        ceil(reltuples/floor((bs-pageopqdata-pagehdr)*fillfactor/(100*(4+nulldatahdrwidth)::float))), 0
    ) AS est_pages_ff,
    bs, nspname, tblname, idxname, relpages, fillfactor, is_na
FROM (
    SELECT maxalign, bs, nspname, tblname, idxname, reltuples, relpages, idxoid, fillfactor,
            ( index_tuple_hdr_bm +
                maxalign - CASE -- Add padding to the index tuple header to align on MAXALIGN
                WHEN index_tuple_hdr_bm%maxalign = 0 THEN maxalign
                ELSE index_tuple_hdr_bm%maxalign
                END
            + nulldatawidth + maxalign - CASE -- Add padding to the data to align on MAXALIGN
                WHEN nulldatawidth = 0 THEN 0
                WHEN nulldatawidth::integer%maxalign = 0 THEN maxalign
                ELSE nulldatawidth::integer%maxalign
                END
            )::numeric AS nulldatahdrwidth, pagehdr, pageopqdata, is_na
    FROM (
        SELECT n.nspname, i.tblname, i.idxname, i.reltuples, i.relpages,
            i.idxoid, i.fillfactor, current_setting('block_size')::numeric AS bs,
            CASE -- MAXALIGN: 4 on 32bits, 8 on 64bits (and mingw32 ?)
                WHEN version() ~ 'mingw32' OR version() ~ '64-bit|x86_64|ppc64|ia64|amd64' THEN 8
                ELSE 4
            END AS maxalign,
            /* per page header, fixed size: 20 for 7.X, 24 for others */
            24 AS pagehdr,
            /* per page btree opaque data */
            16 AS pageopqdata,
            /* per tuple header: add IndexAttributeBitMapData if some cols are null-able */
            CASE WHEN max(coalesce(s.null_frac,0)) = 0
                THEN 2 -- IndexTupleData size
                ELSE 2 + (( 32 + 8 - 1 ) / 8) -- IndexTupleData size + IndexAttributeBitMapData size ( max num filed per index + 8 - 1 /8)
            END AS index_tuple_hdr_bm,
            /* data len: we remove null values save space using it fractionnal part from stats */
            sum( (1-coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 1024)) AS nulldatawidth,
            max( CASE WHEN i.atttypid = 'pg_catalog.name'::regtype THEN 1 ELSE 0 END ) > 0 AS is_na
        FROM (
            SELECT ct.relname AS tblname, ct.relnamespace, ic.idxname, ic.attpos, ic.indkey, ic.indkey[ic.attpos], ic.reltuples, ic.relpages, ic.tbloid, ic.idxoid, ic.fillfactor,
                coalesce(a1.attnum, a2.attnum) AS attnum, coalesce(a1.attname, a2.attname) AS attname, coalesce(a1.atttypid, a2.atttypid) AS atttypid,
                CASE WHEN a1.attnum IS NULL
                THEN ic.idxname
                ELSE ct.relname
                END AS attrelname
            FROM (
                SELECT idxname, reltuples, relpages, tbloid, idxoid, fillfactor, indkey,
                    pg_catalog.generate_series(1,indnatts) AS attpos
                FROM (
                    SELECT ci.relname AS idxname, ci.reltuples, ci.relpages, i.indrelid AS tbloid,
                        i.indexrelid AS idxoid,
                        coalesce(substring(
                            array_to_string(ci.reloptions, ' ')
                            from 'fillfactor=([0-9]+)')::smallint, 90) AS fillfactor,
                        i.indnatts,
                        pg_catalog.string_to_array(pg_catalog.textin(
                            pg_catalog.int2vectorout(i.indkey)),' ')::int[] AS indkey
                    FROM pg_catalog.pg_index i
                    JOIN pg_catalog.pg_class ci ON ci.oid = i.indexrelid
                    WHERE ci.relam=(SELECT oid FROM pg_am WHERE amname = 'btree')
                    AND ci.relpages > 0
                ) AS idx_data
            ) AS ic
            JOIN pg_catalog.pg_class ct ON ct.oid = ic.tbloid
            LEFT JOIN pg_catalog.pg_attribute a1 ON
                ic.indkey[ic.attpos] <> 0
                AND a1.attrelid = ic.tbloid
                AND a1.attnum = ic.indkey[ic.attpos]
            LEFT JOIN pg_catalog.pg_attribute a2 ON
                ic.indkey[ic.attpos] = 0
                AND a2.attrelid = ic.idxoid
                AND a2.attnum = ic.attpos
            ) i
            JOIN pg_catalog.pg_namespace n ON n.oid = i.relnamespace
            JOIN pg_catalog.pg_stats s ON s.schemaname = n.nspname
                                    AND s.tablename = i.attrelname
                                    AND s.attname = i.attname
            GROUP BY 1,2,3,4,5,6,7,8,9,10,11
    ) AS rows_data_stats
) AS rows_hdr_pdg_stats
) AS relation_stats
where nspname not in ('information_schema','pg_catalog')
ORDER BY bs*(relpages)::bigint  DESC  nulls last limit 200;
```

## 8. Index Bloat Info v2
```sql
\prompt 'Find top 100 bloated indexes.\n⚠️ No mask = scan all (I/O spike).\nIndex name mask (empty = all): ' indexname

with indexes as (
    select * from pg_stat_user_indexes
)
select table_name,
pg_size_pretty(table_size) as table_size,
index_name,
pg_size_pretty(index_size) as index_size,
idx_scan as index_scans,
round((free_space*100/index_size)::numeric, 1) as waste_percent,
pg_size_pretty(free_space) as waste
from (
    select (case when schemaname = 'public' then format('%I', p.relname) else format('%I.%I', schemaname, p.relname) end) as table_name,
    indexrelname as index_name,
    (select (case when avg_leaf_density = 'NaN' then 0
        else greatest(ceil(index_size * (1 - avg_leaf_density / (coalesce((SELECT (regexp_matches(reloptions::text, E'.*fillfactor=(\\d+).*'))[1]),'90')::real)))::bigint, 0) end)
        from pgstatindex(p.indexrelid::regclass::text)
    ) as free_space,
    pg_relation_size(p.indexrelid) as index_size,
    pg_relation_size(p.relid) as table_size,
    idx_scan
    from indexes p
    join pg_class c on p.indexrelid = c.oid
    join pg_index i on i.indexrelid = p.indexrelid
    where pg_get_indexdef(p.indexrelid) like '%USING btree%' and
    i.indisvalid and (c.relpersistence = 'p' or not pg_is_in_recovery()) and
    --put your index name/mask here
    indexrelname ~ :'indexname'
) t
order by free_space desc
limit 100;
```

## 9. Reset Index Stat
```sql
select pg_stat_reset_single_table_counters(indexrelid) 
from pg_stat_all_indexes 
where indexrelname = 'INDEX_NAME';
```
-----

## 10. Column Value Frequency Analysis
This section describes SQL queries and techniques for analyzing column value frequencies to estimate row counts for specific values in a PostgreSQL database and selectivity. This data is useful for understanding the effectiveness of both existing and newly created indexes.

## Column Statistics and Selectivity
This query provides important statistics about the columns in a table, including correlation, selectivity, and the number of distinct values (n_distinct).
- Correlation: In PostgreSQL, correlation refers to how closely the physical order of rows in a table matches the ordering of values in a specific column. The correlation value ranges from -1 to 1
```sql
SELECT 
    cl.reltuples,
    attname,
    correlation,
    n_distinct,
    CASE 
      WHEN n_distinct < 0 THEN -n_distinct
      WHEN n_distinct = -1 THEN 1.0
      ELSE n_distinct / NULLIF(cl.reltuples, 0)
    END AS selectivity
FROM pg_stats pg_s
JOIN pg_class cl ON pg_s.tablename = cl.relname
JOIN pg_namespace n ON n.oid = cl.relnamespace AND n.nspname = pg_s.schemaname
WHERE pg_s.schemaname = 'public' AND pg_s.tablename = 'test_table'
ORDER BY ABS(correlation) DESC;
```
### Output 10.1
```text
 reltuples |         attname          |  correlation  |  n_distinct   |   selectivity
-----------+--------------------------+---------------+---------------+-----------------
       413 | relpersistence           |             1 |             1 |    0.0024213076
       413 | relchecks                |             1 |             1 |    0.0024213076
```
This query retrieves statistics for each column of the specified table (test_table), such as the number of rows (reltuples), column name (attname), correlation between columns, number of distinct values (n_distinct), and calculates the selectivity based on the ratio of distinct values to the total number of rows. The results are ordered by the absolute value of correlation to highlight the most significant relationships.


## Column Most Common Values and Frequencies Analysis
This query provides detailed statistics for the status column in the test_table table. It displays the most common values in the column, their respective frequencies. This information helps in understanding the distribution and relationships of values within the column.
```sql
SELECT
    tablename,
    attname,
    (most_common_vals::text::text[])[idx] AS most_common_val,
    (most_common_freqs::text::text[])[idx] AS most_common_freq
FROM (
    SELECT
        tablename,
        attname,
        most_common_vals,
        most_common_freqs,
        generate_subscripts(most_common_vals, 1) AS idx
    FROM pg_stats
    WHERE tablename = 'test_table'
    AND attname = 'status'
) AS subquery;

### Output 10.2
```text
    tablename  |    attname     | most_common_val | most_common_freq
    ------------+----------------+-----------------+------------------
    tracks     | track_type     | 1               | 0.49191666
    tracks     | track_type     | 45              | 0.22131667
    tracks     | track_type     | 19              | 0.10068333
    tracks     | track_type     | 4               | 0.038886666
```

## Calculating Estimated Row Count
To estimate the number of rows for a specific value in a column, you can use the following SQL query:
```sql
--Replace 'specific_value' with the value you want to check.
SELECT s.tablename, s.attname as column, s.most_common_freqs[
    array_position((s.most_common_vals::text::text[]), 'specific_value')
    ] as estimated_rows
FROM pg_class 
JOIN pg_stats s ON s.tablename = relname
WHERE s.tablename = 'your_table_name' AND s.attname = 'your_column_name';
```
### Output 10.3
```text
tablename       | column           | estimated_rows
----------------+------------------+-----------
your_table_name | your_column_name | 33312323
```
