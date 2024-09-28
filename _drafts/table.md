Since postgres 16 we have a new counter n_tup_newpage_upd which can help us to understand whether decrease fillfactor or not. 

maratos=# select * from pg_stat_all_tables where relname='walk_chains';
-[ RECORD 1 ]-------+------------------------------
relid               | 22476
schemaname          | public
relname             | test_table1
seq_scan            | 26967809
last_seq_scan       | 2023-09-17 09:36:43.234579+00
seq_tup_read        | 994246878
idx_scan            | 22180966033
last_idx_scan       | 2023-09-17 12:13:42.778964+00
idx_tup_fetch       | 93158275071
n_tup_ins           | 1716154350
n_tup_upd           | 2 77002832
n_tup_del           | 0
n_tup_hot_upd       | 824947285
n_tup_newpage_upd   | 704721648
n_live_tup          | 2970730246
n_dead_tup          | 21597108
n_mod_since_analyze | 2955188
n_ins_since_vacuum  | 14794600
last_vacuum         |
last_autovacuum     | 2023-09-16 00:57:45.10448+00
last_analyze        | 2023-09-17 10:07:10.92985+00
last_autoanalyze    | 2023-09-16 12:53:41.85893+00
vacuum_count        | 0
autovacuum_count    | 51
analyze_count       | 4
autoanalyze_count   | 220

SELECT
    schemaname,
    relname,
    n_tup_upd AS total_updates,
    n_tup_hot_upd,
    n_tup_newpage_upd,
    (n_tup_upd - n_tup_hot_upd - n_tup_newpage_upd) AS non_hot_samepage_upd,
    ROUND((n_tup_hot_upd::numeric / n_tup_upd) * 100, 2) AS hot_update_pct,
    ROUND((n_tup_newpage_upd::numeric / n_tup_upd) * 100, 2) AS newpage_update_pct,
    ROUND(((n_tup_upd - n_tup_hot_upd - n_tup_newpage_upd)::numeric / n_tup_upd) * 100, 2) AS non_hot_samepage_pct
FROM
    pg_stat_all_tables
WHERE
    relname = 'your_table_name';



Analyzing the Results
	•	HOT Updates: A high percentage of HOT updates is a good indicator, as they are the most efficient.
	•	Non-HOT Updates on a New Page: A high percentage of these updates may suggest the need to reduce the fillfactor to provide more free space on pages, allowing more updates to keep new row versions on the same page.
	•	Non-HOT Updates on the Same Page: While they require index updates, storing new row versions on the same page can be more efficient than moving to a new page.

Deciding Whether to Change fillfactor
	•	If newpage_update_pct is high: Consider reducing the fillfactor. This will leave more free space on pages, allowing more updates to store new row versions on the same page.
	•	If hot_update_pct is low: Check if you can reduce the number of updates to indexed columns or remove unnecessary indexes.    
```bash
• hot_update_pct ≈ (824,947,285 / 2,877,002,832) * 100 ≈ 28.68%
• newpage_update_pct ≈ (704,721,648 / 2,877,002,832) * 100 ≈ 24.49%
• non_hot_samepage_pct ≈ (1,347,333,899 / 2,877,002,832) * 100 ≈ 46.83%
Nearly half of the updates are non-HOT on the same page, which is not bad.
However, about 24.5% of updates result in rows moving to new pages. This is a significant portion. Consider reducing the fillfactor for this table to decrease the newpage_update_pct and increase the number of updates where new row versions remain on the same page.
```

n_tup_newpage_upd/n_tup_upd = NUMBER of tuples MOVed to another page (no space and fillfactor increase ?)