sudo -u postgres psql -d sweatcoin  -c "SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();"
sudo -u postgres psql -d sweatcoin -c "SELECT pg_stat_reset();"
sudo -u postgres psql -d sweatcoin  -c "SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();"

 select 
    schemaname || '.' || relname,
    pg_size_pretty(pg_relation_size(relname::text)),
    n_tup_ins,
    n_tup_del,
    n_tup_upd,
    n_tup_hot_upd,
    CASE
        WHEN n_tup_upd > 0 THEN
            ROUND((n_tup_hot_upd::numeric / n_tup_upd::numeric) * 100, 2)
        ELSE
            NULL
    END AS hot_update_percentage,    
    CASE
        WHEN n_tup_ins > 0 THEN
            ROUND((n_tup_upd::numeric / n_tup_ins::numeric) * 100, 2)
        ELSE
            NULL
    END AS update_to_insert_percentage,    
    n_tup_newpage_upd,
    CASE
        WHEN n_tup_upd > 0 THEN
            ROUND((n_tup_newpage_upd::numeric / n_tup_upd::numeric) * 100, 2)
        ELSE
            NULL
    END AS newpage_update_percentage    
    from pg_stat_user_tables 
    order by n_tup_upd DESC,  pg_relation_size(relname::text) DESC
    ;
