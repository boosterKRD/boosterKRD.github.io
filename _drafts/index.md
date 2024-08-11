SELECT
    tablename,
    indexname,
    indexdef
FROM
    pg_indexes
WHERE
    schemaname = 'public' 
    and   tablename = 'table_name';
ORDER BY
    tablename,
    indexname;


Output:

     tablename      |                      indexname                      |                                                                   indexdef
--------------------+-----------------------------------------------------+-----------------------------------------------------------------------------------------------------------------------------------------------
 accounts           | accounts_email_key                                  | CREATE UNIQUE INDEX accounts_email_key ON public.accounts USING btree (email)
 accounts           | accounts_pkey                                       | CREATE UNIQUE INDEX accounts_pkey ON public.accounts USING btree (user_id)
 accounts           | accounts_username_key                               | CREATE UNIQUE INDEX accounts_username_key ON public.accounts USING btree (username)
 actor              | actor_pkey                                          | CREATE UNIQUE INDEX actor_pkey ON public.actor USING btree (actor_id)
 actor              | idx_actor_first_name                                | CREATE INDEX idx_actor_first_name ON public.actor USING btree (first_name)
 actor              | idx_actor_last_name                                 | CREATE INDEX idx_actor_last_name ON public.actor USING btree (last_name)
...

----

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
where c.relname = 'test'



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
    t.schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2;




----
Duplicate indexes
Finds multiple indexes that have the same set of columns, same opclass, expression and predicate -- which make them equivalent. Usually it's safe to drop one of them, but I give no guarantees. :)

SELECT pg_size_pretty(sum(pg_relation_size(idx))::bigint) as size,
       (array_agg(idx))[1] as idx1, (array_agg(idx))[2] as idx2,
       (array_agg(idx))[3] as idx3, (array_agg(idx))[4] as idx4
FROM (
    SELECT indexrelid::regclass as idx, (indrelid::text ||E'\n'|| indclass::text ||E'\n'|| indkey::text ||E'\n'||
                                         coalesce(indexprs::text,'')||E'\n' || coalesce(indpred::text,'')) as key
    FROM pg_index) sub
GROUP BY key HAVING count(*)>1
ORDER BY sum(pg_relation_size(idx)) DESC;


or 

select 
    indrelid::regclass, array_accum(indexrelid::regclass) 
from 
    pg_index 
group by 
    indrelid, indkey 
having 
    count(*) > 1;

or

select 
    a.indrelid::regclass, a.indexrelid::regclass, b.indexrelid::regclass 
from 
    (select \*,array_to_string(indkey,' ') as cols from pg_index) a 
    join (select \*,array_to_string(indkey,' ') as cols from pg_index) b on 
        ( a.indrelid=b.indrelid and a.indexrelid > b.indexrelid 
        and 
            ( 
                (a.cols LIKE b.cols||'%' and coalesce(substr(a.cols,length(b.cols)+1,1),' ')=' ') 
                or 
                (b.cols LIKE a.cols||'%' and coalesce(substr(b.cols,length(a.cols)+1,1),' ')=' ') 
            ) 
        ) 
order by 
    indrelid;    

or

select 
    starelid::regclass, indexrelid::regclass, array_accum(staattnum), relpages, reltuples, array_accum(stadistinct) 
from 
    pg_index 
    join pg_statistic on (starelid=indrelid and staattnum = ANY(indkey)) 
    join pg_class on (indexrelid=oid) 
where 
    case when stadistinct < 0 then stadistinct > -.8 else reltuples/stadistinct > .2 end 
    and 
    not (indisunique or indisprimary) 
    and 
    (relpages > 100 or reltuples > 1000) 
group by 
    starelid, indexrelid, relpages, reltuples 
order by 
    starelid ;

----

Unused Indexes
Since indexes add significant overhead to any table change operation, they should be removed if they are not being used for either queries or constraint enforcement (such as making sure a value is unique). How to find such indexes:

SELECT 
    relid::regclass AS table, 
    indexrelid::regclass AS index, 
    pg_size_pretty(pg_relation_size(indexrelid::regclass)) AS index_size, 
    idx_tup_read, 
    idx_tup_fetch, 
    idx_scan
FROM 
    pg_stat_user_indexes 
    JOIN pg_index USING (indexrelid) 
WHERE 
    idx_scan = 0 
    AND indisunique IS FALSE
----


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