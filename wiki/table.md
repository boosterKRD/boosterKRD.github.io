---
layout: post
title: Useful Index Commands
date: 2024-08-25
---
# Table of Contents

1. [Table Size Info](#1-table-size-info)
2. [Table Bloat Info](#1-table-bloat-info)
   - [SQL-based: get information about tables bloat](#11-sql-based-get-information-about-tables-bloat)
   - [Pgstattuple-based: get information about tables bloat](#12-pgstattuple-based-get-information-about-tables-bloat)
<!--MORE-->

-----

## 1. Table Size Info
```sql
SELECT
  n.nspname  AS schema_name,
  c.relname  AS table_name,
  pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
  pg_size_pretty(pg_relation_size(c.oid))       AS heap_size,
  pg_size_pretty(pg_indexes_size(c.oid))        AS index_size,
  pg_size_pretty(
    CASE WHEN c.reltoastrelid <> 0 THEN pg_total_relation_size(c.reltoastrelid)
    ELSE 0 END ) AS toast_size,
  ROUND(
    CASE WHEN pg_relation_size(c.oid) > 0 THEN (pg_total_relation_size(c.reltoastrelid)::numeric / NULLIF(pg_relation_size(c.oid),0)) * 100
    ELSE 0 END, 1) AS toast_percent_of_heap
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 50;
```

## 2. Table Bloat Info

## 2.1 SQL-based: get information about tables bloat
```sql
SELECT current_database(), schemaname, tblname, bs*tblpages AS real_size,
  fillfactor,
  CASE WHEN tblpages - est_tblpages_ff > 0
    THEN (tblpages-est_tblpages_ff)*bs
    ELSE 0
  END AS table_waste,
  CASE WHEN tblpages > 0 AND tblpages - est_tblpages_ff > 0
    THEN 100 * (tblpages - est_tblpages_ff)/tblpages::float
    ELSE 0
  END AS total_waste_percent, is_na
FROM (
  SELECT ceil( reltuples / ( (bs-page_hdr)/tpl_size ) ) AS est_tblpages,
    ceil( reltuples / ( (bs-page_hdr)*fillfactor/(tpl_size*100) ) ) AS est_tblpages_ff,
    tblpages, fillfactor, bs, tblid, schemaname, tblname, heappages, is_na
  FROM (
    SELECT
      ( 4 + tpl_hdr_size + tpl_data_size + (2*ma)
        - CASE WHEN tpl_hdr_size%ma = 0 THEN ma ELSE tpl_hdr_size%ma END
        - CASE WHEN ceil(tpl_data_size)::int%ma = 0 THEN ma ELSE ceil(tpl_data_size)::int%ma END
      ) AS tpl_size, bs - page_hdr AS size_per_block, (heappages) AS tblpages, heappages,
       reltuples, bs, page_hdr, tblid, schemaname, tblname, fillfactor, is_na
    FROM (
      SELECT
        tbl.oid AS tblid, ns.nspname AS schemaname, tbl.relname AS tblname, tbl.reltuples,
        tbl.relpages AS heappages, 
        coalesce(substring(
          array_to_string(tbl.reloptions, ' ')
          FROM 'fillfactor=([0-9]+)')::smallint, 100) AS fillfactor,
        current_setting('block_size')::numeric AS bs,
        CASE WHEN version()~'mingw32' OR version()~'64-bit|x86_64|ppc64|ia64|amd64' THEN 8 ELSE 4 END AS ma,
        24 AS page_hdr,
        23 + CASE WHEN MAX(coalesce(s.null_frac,0)) > 0 THEN ( 7 + count(s.attname) ) / 8 ELSE 0::int END
           + CASE WHEN bool_or(att.attname = 'oid' and att.attnum < 0) THEN 4 ELSE 0 END AS tpl_hdr_size,
        sum( (1-coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 0) ) AS tpl_data_size,
        bool_or(att.atttypid = 'pg_catalog.name'::regtype)
          OR sum(CASE WHEN att.attnum > 0 THEN 1 ELSE 0 END) <> count(s.attname) AS is_na
      FROM pg_attribute AS att
        JOIN pg_class AS tbl ON att.attrelid = tbl.oid
        JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
        LEFT JOIN pg_stats AS s ON s.schemaname=ns.nspname
          AND s.tablename = tbl.relname AND s.inherited=false AND s.attname=att.attname
      WHERE NOT att.attisdropped
        AND tbl.relkind in ('r','m')
      GROUP BY 1,2,3,4,5,6,7,8
      ORDER BY 2,3
    ) AS s
  ) AS s2
) AS s3
WHERE schemaname not in ('information_schema','pg_catalog') 
--and tblname in ('XXX')
ORDER BY total_waste_percent DESC;
```

## 2.2 Pgstattuple-based: get information about tables bloat
Find the Largest Tables and Indexes in the Selected Database

```sql
SELECT 
    nspname,
    relname,
    CASE relkind
        WHEN 'r' THEN 'Table'
        WHEN 'i' THEN 'Index'
        WHEN 'm' THEN 'Materialized View'
        ELSE 'Other'
    END AS reltype,
    pg_size_pretty(pg_table_size(C.oid)) AS table_size,
    pg_size_pretty(pg_indexes_size(C.oid)) AS index_size,
    pg_size_pretty(pg_total_relation_size(C.oid)) AS total_size
FROM pg_class C
LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
WHERE nspname NOT IN ('pg_catalog', 'information_schema')
  AND nspname !~ '^pg_toast'
  AND relkind IN ('r', 'i', 'm')
ORDER BY pg_total_relation_size(C.oid) DESC
LIMIT 20;
```

If you want to check multiple tables combine their names using the pipe | symbol.  
Example:**orders|customers|payments**

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;

\prompt 'This utility will read tables with given mask using pgstattuple extension and return top 20 bloated tables.\nWARNING: without table mask query will read all available tables which could cause I/O spikes.\nPlease enter mask for table name (check all tables if nothing is specified): ' tablename

select table_name,
pg_size_pretty(relation_size + toast_relation_size) as total_size,
pg_size_pretty(toast_relation_size) as toast_size,
round(greatest(((relation_size * fillfactor/100)::numeric - tuple_len) / greatest((relation_size * fillfactor/100)::numeric, 1) * 100, 0)::numeric, 1) AS table_waste_percent,
pg_size_pretty((relation_size * fillfactor/100 - tuple_len)::bigint) AS table_waste,
round((((relation_size * fillfactor/100) + toast_relation_size - (tuple_len + toast_tuple_len))::numeric / greatest((relation_size * fillfactor/100) + toast_relation_size, 1)::numeric) * 100, 1) AS total_waste_percent,
pg_size_pretty(((relation_size * fillfactor/100) + toast_relation_size - (tuple_len + toast_tuple_len))::bigint) AS total_waste
from (
    select
    (case when n.nspname = 'public' then format('%I', c.relname) else format('%I.%I', n.nspname, c.relname) end) as table_name,
    (select  approx_tuple_len  from pgstattuple_approx(c.oid)) as tuple_len,
    pg_relation_size(c.oid) as relation_size,
    (case when reltoastrelid = 0 then 0 else (select  approx_tuple_len  from pgstattuple_approx(c.reltoastrelid)) end) as toast_tuple_len,
    coalesce(pg_relation_size(c.reltoastrelid), 0) as toast_relation_size,
    coalesce((SELECT (regexp_matches(reloptions::text, E'.*fillfactor=(\\d+).*'))[1]),'100')::real AS fillfactor
    from pg_class c
    left join pg_namespace n on (n.oid = c.relnamespace)
    where nspname not in ('pg_catalog', 'information_schema')
    and nspname !~ '^pg_toast' and nspname !~ '^pg_temp' and relkind in ('r', 'm') and (relpersistence = 'p' or not pg_is_in_recovery())
    --put your table name/mask here
    and relname ~ :'tablename'
) t
order by total_waste_percent desc
limit 20;
```

-----
