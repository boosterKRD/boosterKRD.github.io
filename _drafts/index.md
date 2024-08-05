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
