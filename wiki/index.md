---
layout: post
title: Index in PostgrSQL
date: 2024-08-25
---
# Table of Contents
0. [Time when stats was reset ](#0-time-when-stats-was-reset)
1. [Indexes info with definition](#1-indexes-info-with-definition)
   - [Output](#output-1)
2. [Identifying unused indexes](#2-identifying-unused-indexes)
3. [Duplicate indexes](#3-duplicate-indexes)
   - [Additional SQL queries for analyzing](#additional-sql-queries-for-analyzing)
   - [Output](#output-3)
<!--MORE-->

-----
## 0. TIME WHEN STATS WAS RESET
```sql
    select
        sd.stats_reset::timestamptz(0),
        ((extract(epoch from now()) - extract(epoch from sd.stats_reset))/86400)::int as days
    from pg_stat_database sd
    where datname = current_database();
```

## 1. INDEXES INFO
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
        --psui.last_idx_scan AS last_idx_scan, --since PG16
        pg_get_indexdef(i.indexrelid) AS index_def    
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_stat_user_indexes psui ON i.indexrelid = psui.indexrelid
    JOIN pg_stat_user_tables pstu ON pstu.relid = c.oid 
    --where c.relname = 'table_name'
    ORDER BY pg_relation_size(i.indexrelid) DESC;
```
### OUTPUT 1
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

## 2. IDENTIFYING UNUSED INDEXES
Indexes can introduce considerable overhead during table modifications, so it's important to remove them if they aren't being utilized for queries or enforcing constraints (such as ensuring uniqueness). Here’s how to identify such indexes:
```sql
    SELECT 
        relid::regclass AS table, 
        indexrelid::regclass AS index, 
        pg_size_pretty(pg_relation_size(indexrelid::regclass)) AS index_size, 
        idx_scan,
        pg_get_indexdef(pg_index.indexrelid) AS index_def
    FROM pg_stat_user_indexes 
    JOIN pg_index USING (indexrelid) 
    WHERE idx_scan = 0 AND indisunique IS FALSE
    order by pg_relation_size(indexrelid::regclass) DESC;
```
-----

## 3. DUPLICATE INDEXES
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
        i.indkey AS index_attributes,
        ii.indkey AS overlapping_index_attributes,
        pg_get_indexdef(i.indexrelid) AS index_def, 
        pg_get_indexdef(ii.indexrelid) AS overlapping_index_def
    FROM pg_index i
    JOIN pg_stat_user_indexes psui on psui.indexrelid=i.indexrelid
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
    JOIN pg_class ctii ON ii.indrelid=ctii.oid
    JOIN pg_class cii ON ii.indexrelid=cii.oid
    WHERE ct.relname NOT LIKE 'pg_%' AND
        NOT i.indisprimary AND (ci.relname < cii.relname OR i.indkey <> ii.indkey) 
    GROUP BY ni.nspname, ct.relname, ci.relname, i.indexrelid, ii.indexrelid, psui.idx_scan, psui2.idx_scan, pg_get_indexdef(i.indexrelid), i.indkey, cii.relname, pg_get_indexdef(ii.indexrelid), ii.indkey
    ORDER BY 1, 2, 3;
```
### ADDITIONAL SQL QUERIES FOR ANALYZING
```sql
    --This query shows the distribution of indexes in shared_buffers (Extension pg_buffercache is needed)
    SELECT  
    c.relname, pg_size_pretty(count(*) * 8192) AS buffered, 
    round(100.0 * count(*) / (SELECT setting FROM pg_settings WHERE name='shared_buffers')::integer,1) AS buffers_percent,
    round(100.0 * count(*) * 8192 / pg_relation_size(c.oid),1) AS percent_of_relation
    FROM    
    pg_class c
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
### OUTPUT 3
```text
    -[ RECORD 1 ]+------------------------------------------------------------------------------------------------------------------
    table_name                    | public.adventure_route
    index_name                    | adventure_route_index
    overlapping_index             | adventure_route_size_steps_index
    index_size                    | 16 kB
    overlapping_index_size        | 16 kB
    index_num_scan                | 0
    overlapping_index_num_scan    | 7
    index_attributes              | 2 3
    overlapping_index_attributes  | 2 3
    index_def                     | CREATE INDEX adventure_route_index ON public.adventure_route USING btree (size, steps)
    overlapping_index_def         | CREATE INDEX adventure_route_size_steps_index ON public.adventure_route USING btree (size, steps)
    -[ RECORD 2 ]+------------------------------------------------------------------------------------------------------------------
    table_name                    | public.order_completes
    index_name                    | index_order_completes_on_order_id
    overlapping_index             | order_completes_unique_index
    index_size                    | 139 MB
    overlapping_index_size        | 560 MB
    index_num_scan                | 0
    overlapping_index_num_scan    | 81116474288
    index_attributes              | 2
    overlapping_index_attributes  | 2 3 4
    index_def                     | CREATE INDEX index_order_completes_on_order_id ON public.order_completes USING btree (order_id)
    overlapping_index_def         | CREATE UNIQUE INDEX order_completes_unique_index ON public.order_completes USING btree (order_id, userable_id, userable_type)
```
-----




