---
layout: post
title: logerrors extension
date: 2023-06-21
---
There is a client, XXXXX (used as an example here!).
They generate unique entries in pg_stat_statements (it's unclear why their queryid is unique, but the fact is they generate a lot of entries, and the limit of 10,000 entries is not enough). As a result, dealloc is called up to 3,000 -4000 times a day, with each cycle cleaning 500 entries/rows.
More than a million INSERTs into pg_stat_statements are performed daily  (500*3500=1750000).
1. PostgreSQL expert Andres Freund noted in his tweet that frequent dealloc operations can lead to significant delays and performance issues. I haven't verified this claim myself, but here's the link.
2. According to the source code (I should note that I'm not an expert and don't even know the difference between C and C++), it uses:
- **LWLOCK EXCLUSIVE:**
    - During [reset_stat](https://github.com/postgres/postgres/blob/05ffe9398b758bbb8d30cc76e9bbc638dab2d477/contrib/pg_stat_statements/pg_stat_statements.c#L2538)
    - When [inserting](https://github.com/postgres/postgres/blob/05ffe9398b758bbb8d30cc76e9bbc638dab2d477/contrib/pg_stat_statements/pg_stat_statements.c#L1310) a new entry. 
- **SpinLock or shared LWLOCK:**
    - [Updating](https://github.com/postgres/postgres/blob/05ffe9398b758bbb8d30cc76e9bbc638dab2d477/contrib/pg_stat_statements/pg_stat_statements.c#L1347) an entry
    - [Deallocating](https://github.com/postgres/postgres/blob/05ffe9398b758bbb8d30cc76e9bbc638dab2d477/src/backend/utils/hash/dynahash.c#L1301) entries (at least there's no EXCLUSIVE here)
If I understood the source code correctly (I do not know С at all), the high frequency of new entries being written to pg_stat_statements can impact all queries to the database. This is because, before they can update data in pg_stat_statements, they will have to wait for the lock to be released (EXCLUSIVE) by those performing INSERT operations. The same issue occurs with reset_stat, but reset is done infrequently, whereas INSERT operations happen many times per second.

In my example with the "kartinki" client, it essentially doesn't matter what pg_stat_statements.max is set to (they generate 2 million queries).
However, if a client generates 7000 unique queries (more than 5000) and you set pg_stat_statements.max to 5000, it would be worse. After reaching the 5000 limit, the deallocation process starts to delete all rows  (which uses a shared lock—no problem), but new query started inserting instead of updating requiring an exclusive lock, which will be a problem.
<!--MORE-->

-----


EXAMPLES
The next examples provide to us the information that since 95 days where were 13910662 deallocs  and it's equal 3 mln deleted/inserted rows. (one dealloc remove 500 rows)
example_db=> select * from pg_stat_statements_info;
```sql
 dealloc  |          stats_reset
----------+-------------------------------
 13910662 | 2024-05-07 12:19:05.670805+00
```

example_db=> select userid,queryid, calls, query from pg_stat_statements order by calls limit 10;
```sql
- SELECT id, full_name, birth_date, created_at, expiry_date, _updated_at, nationality, country, removed_at, user_id FROM clients WHERE user_id IN ($1) AND removed_at IS null LIMIT $2
- SELECT nationality, expiry_date, id, user_id, birth_date, created_at, removed_at, country, _updated_at, full_name FROM clients WHERE user_id IN ($1) AND removed_at IS null LIMIT $2
- SELECT user_id, id, removed_at, _updated_at, full_name, birth_date, created_at, nationality, expiry_date, country FROM clients WHERE user_id IN ($1) AND removed_at IS null LIMIT $2
- SELECT expiry_date, id, _updated_at, birth_date, country, user_id, created_at, full_name, nationality, removed_at FROM clients WHERE user_id IN ($1) AND removed_at IS null LIMIT $2
```






