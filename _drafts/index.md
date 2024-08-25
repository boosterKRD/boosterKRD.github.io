# Table of Contents

1. [Indexes info with definition](#1-indexes-info-with-definition)
2. [Identifying unused indexes](#2-identifying-unused-indexes)
3. [Duplicate indexes](#3-duplicate-indexes)
   - [Additional SQL queries for analyzing](#additional-sql-queries-for-analyzing)

## 1. INDEXES INFO WITH DEFINITION
```sql
    SELECT
        idx.tablename,
        idx.indexname,
        idx.indexdef,
        pg_size_pretty(pg_relation_size(idx.indexrelid)) AS index_size,
        COALESCE(psui.idx_scan, 0) AS number_of_scans,
        COALESCE(psui.idx_tup_fetch, 0) AS rows_fetched,
        COALESCE(psui.idx_tup_read, 0) AS rows_returned
    FROM
        pg_indexes idx
    LEFT JOIN
        pg_stat_user_indexes psui ON idx.indexrelid = psui.indexrelid
    WHERE
        idx.schemaname = 'public' -- and idx.tablename = 'accounts'
    ORDER BY 
        idx.tablename,
        idx.indexname;
```
- **OUTPUT**
```text

    tablename   | indexname               |    indexdef
    +-----------------------------------------------------------------------------------------------------------------------------
    accounts    | accounts_email_key      | CREATE UNIQUE INDEX accounts_email_key ON public.accounts USING btree (email)
    accounts    | accounts_pkey           | CREATE UNIQUE INDEX accounts_pkey ON public.accounts USING btree (user_id)
    accounts    | accounts_username_key   | CREATE UNIQUE INDEX accounts_username_key ON public.accounts USING btree (username)
    actor       | actor_pkey              | CREATE UNIQUE INDEX actor_pkey ON public.actor USING btree (actor_id)
    actor       | idx_actor_first_name    | CREATE INDEX idx_actor_first_name ON public.actor USING btree (first_name)
    actor       | idx_actor_last_name     | CREATE INDEX idx_actor_last_name ON public.actor USING btree (last_name)
```
-----

## 2. IDENTIFYING UNUSED INDEXES
Indexes can introduce considerable overhead during table modifications, so it's important to remove them if they aren't being utilized for queries or enforcing constraints (such as ensuring uniqueness). Here’s how to identify such indexes:
```sql
    SELECT 
        relid::regclass AS table, 
        indexrelid::regclass AS index, 
        pg_size_pretty(pg_relation_size(indexrelid::regclass)) AS index_size, 
        idx_tup_read, 
        idx_tup_fetch, idx_scan
    FROM pg_stat_user_indexes 
    JOIN pg_index USING (indexrelid) 
    WHERE 
        idx_scan = 0 AND indisunique IS FALSE
```
-----

## 3. DUPLICATE INDEXIES
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
-  Additional SQL queries for analyzing
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

- **OUTPUT**
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




=====
=====




psql command


\d table_name
\di

----

select 
    c.relnamespace::regnamespace as schema_name,
    c.relname as table_name,
    i.indexrelid::regclass as index_name,
    i.indisprimary as is_pk,
    i.indisunique as is_unique
from pg_index i
join pg_class c on c.oid = i.indrelid
where c.relname = 'merchant_localization';



----

Index summary
Here's a sample query to pull the number of rows, indexes, and some info about those indexes for each table.
SELECT
    pg_class.relname,
    pg_size_pretty(pg_class.reltuples::bigint)            AS rows_in_bytes,
    pg_class.reltuples                                    AS num_rows,
    COUNT(*)                                              AS total_indexes,
    COUNT(*) FILTER ( WHERE indisunique)                  AS unique_indexes,
    COUNT(*) FILTER ( WHERE indnatts = 1 )                AS single_column_indexes,
    COUNT(*) FILTER ( WHERE indnatts IS DISTINCT FROM 1 ) AS multi_column_indexes
FROM
    pg_namespace
    LEFT JOIN pg_class ON pg_namespace.oid = pg_class.relnamespace
    LEFT JOIN pg_index ON pg_class.oid = pg_index.indrelid
WHERE
    pg_namespace.nspname = 'public' AND
    pg_class.relkind = 'r'
GROUP BY pg_class.relname, pg_class.reltuples
ORDER BY pg_class.reltuples DESC;


----
Index size/usage statistics
Table & index sizes along which indexes are being scanned and how many tuples are fetched. See Disk Usage for another view that includes both table and index sizes.

SELECT
    t.schemaname,
    t.tablename,
    c.reltuples::bigint                            AS num_rows,
    pg_size_pretty(pg_relation_size(c.oid))        AS table_size,
    psai.indexrelname                              AS index_name,
    pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
    CASE WHEN i.indisunique THEN 'Y' ELSE 'N' END  AS "unique",
    psai.idx_scan                                  AS number_of_scans,
    psai.idx_tup_read                              AS tuples_read,
    psai.idx_tup_fetch                             AS tuples_fetched
FROM
    pg_tables t
    LEFT JOIN pg_class c ON t.tablename = c.relname
    LEFT JOIN pg_index i ON c.oid = i.indrelid
    LEFT JOIN pg_stat_all_indexes psai ON i.indexrelid = psai.indexrelid
WHERE
    t.schemaname NOT IN ('pg_catalog', 'information_schema') and  t.tablename = 'merchant_localization'
ORDER BY 1, 2;




https://www.enterprisedb.com/blog/effective-postgresql-monitoring-utilizing-pg-stat-all-tables-and-indexes-postgresql-16#:~:text=idx_tup_read%20is%20the%20number%20of,index%20scans%20using%20this%20index.


SELECT
	idxstat.schemaname as schema_name,
	idxstat.relname AS table_name,
	indexrelname AS index_name,
	idxstat.idx_scan AS index_scans_count,
    	idxstat.last_idx_scan AS last_idx_scan_timestamp,
	pg_size_pretty(pg_relation_size(idxstat.indexrelid)) AS index_size
FROM
	pg_stat_all_indexes AS idxstat
JOIN
    pg_index i ON idxstat.indexrelid = i.indexrelid
WHERE
    idxstat.schemaname not in ('pg_catalog','information_schema','pg_toast')
    AND NOT i.indisunique   -- is not a UNIQUE index
ORDER BY
	Idxstat.idx_scan ASC,
	Idxstat.last_idx_scan ASC;

SELECT
    	tabstat.schemaname AS schema_name,
tabstat.relname AS table_name,
tabstat.seq_scan AS tab_seq_scan_count,
    	tabstat.idx_Scan AS tab_index_scan_count,
    	tabstat.last_seq_scan AS tab_last_seq_scan_timestamp,
    	tabstat.last_idx_scan AS tab_last_idx_scan_timestamp,
	pg_size_pretty(pg_total_relation_size(tabstat.relid)) AS table_size
FROM
	pg_stat_all_tables AS tabstat
WHERE
tabstat.schemaname not in ('pg_catalog','information_schema','pg_toast')
ORDER BY
	tabstat.last_seq_scan ASC,
    	tabstat.last_idx_scan ASC;    


https://dev.to/dm8ry/postgresql-how-do-you-find-potentially-ineffective-indexes-6gp
about idx_tup_fetch and idx_tup_read