PostgreSQL Migration Blueprint: sweat_wallet_feed_items Table

This document outlines the migration process for converting the sweat_wallet_feed_items table into a partitioned table for better performance and scalability. We will:
✅ Add new columns (cache, resource_label)
✅ Reafctoring code
✅ Optimize indexing strategy
✅ Convert the table into a partitioned table
✅ Migrate existing data while ensuring a smooth transition



1. Modifying Table Schema (Before Index Updates) - DataEgret
- We will add two new columns to support additional metadata.
- A new index will be created concurrently to avoid locking.
```sql
ALTER TABLE sweat_wallet_feed_items ADD COLUMN cache jsonb;
ALTER TABLE sweat_wallet_feed_items ADD COLUMN resource_label character varying NOT NULL DEFAULT 'default';
   
```    

2. Reafctoring code - Sweatcoin 
- Refactor the code to have only one interface of adding new FeedItem records.
- Modify the SQL queries so that timestamp is always explicitly included when querying sweat_wallet_feed_items. This will leverage partitioning and improve query performance.
- Utilize the cache column in sweat_wallet_feed_items.

3. Change Indexes Schema on sweat_wallet_feed_items Table - DataEgret
- To improve query performance, we will drop unnecessary indexes and replace them with more efficient ones.
```sql
CREATE INDEX CONCURRENTLY idx_swfi_old_on_accountid_timestamp ON sweat_wallet_feed_items(account_id, "timestamp");
CREATE UNIQUE INDEX CONCURRENTLY idx_swfi_old_res_type_id_label_uniq ON sweat_wallet_feed_items(resource_type, resource_id, resource_label);


DROP INDEX CONCURRENTLY index_sweat_wallet_feed_items_on_account_id;
DROP INDEX CONCURRENTLY index_sweat_wallet_feed_items_on_resource_type_and_resource_id;
```
--ALTER TABLE sweat_wallet_feed_items DROP COLUMN id;

4. Creating Partitioned Table - DataEgret
```sql
    CREATE TABLE sweat_wallet_feed_items_partitioned (
        account_id     BIGINT NOT NULL,
        resource_id    BIGINT NOT NULL,
        "timestamp"    TIMESTAMP WITHOUT TIME ZONE NOT NULL,
        resource_type  sweat_wallet_feed_item_type NOT NULL,
        cache          JSONB,
        resource_label VARCHAR NOT NULL DEFAULT 'default'
    )
    PARTITION BY RANGE ("timestamp");

CREATE INDEX idx_swfi_on_accountid_timestamp ON sweat_wallet_feed_items_partitioned (account_id, "timestamp");
```    

5. Creating Time-Based Partitions - DataEgret
- We will create a partition for the next month (2025-XX)
- All future partitions will be created automatically using a cron job.
```sql
CREATE TABLE sweat_wallet_feed_items_partitioned_202503
    PARTITION OF sweat_wallet_feed_items_partitioned
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');

CREATE UNIQUE INDEX idx_swfi_202503_res_type_id_label_uniq ON sweat_wallet_feed_items_partitioned_202503 (resource_type, resource_id, resource_label);  
```    



6. Preparation for Cutover
Before performing the cutover to the partitioned table, we need to ensure that all existing data in sweat_wallet_feed_items falls within the correct time range. This CHECK constraint helps prevent long locking when attaching partitions.
```sql
ALTER TABLE public.sweat_wallet_feed_items ADD CONSTRAINT check_timestamp_range CHECK (timestamp >= '1970-01-01' AND timestamp < '2025-03-01') NOT VALID;
ALTER TABLE public.sweat_wallet_feed_items VALIDATE CONSTRAINT check_timestamp_range;
```


BEGIN;
INSERT INTO sweat_wallet_feed_items (account_id, resource_id, "timestamp", resource_type, cache, resource_label) VALUES (999999999996, 1001, '2025-02-19 02:02:02', 'Sweat::Wallet::Transfer', '{}', 'test_insert');
COMMIT;



7. Migration Cutover Process - DataEgret
```sql
SET lock_timeout = '800ms';
SET deadlock_timeout = '500ms';

BEGIN;

  -- Lock the table to prevent data inconsistencies
  LOCK TABLE public.sweat_wallet_feed_items IN ACCESS EXCLUSIVE MODE;

  -- Rename the old table for backup purposes
  ALTER TABLE public.sweat_wallet_feed_items RENAME TO old_sweat_wallet_feed_items;

  -- Promote the partitioned table to be the main table
  ALTER TABLE sweat_wallet_feed_items_partitioned RENAME TO sweat_wallet_feed_items;

  -- Remove the 'id' column from the old table (no longer needed)
  -- ALTER TABLE old_sweat_wallet_feed_items DROP COLUMN id;
  -- DROP SEQUENCE IF EXISTS sweat_wallet_feed_items_id_seq;

  -- Attach the old data as a old partition
  ALTER TABLE sweat_wallet_feed_items ATTACH PARTITION old_sweat_wallet_feed_items FOR VALUES FROM (MINVALUE) TO ('2025-03-01');

COMMIT;
```  


EXPLAIN (ANALYZE, BUFFERS, COSTS false) SELECT "sweat_wallet_feed_items".*  FROM "sweat_wallet_feed_items"
WHERE 
 "sweat_wallet_feed_items"."resource_id" = 3333
 AND "sweat_wallet_feed_items"."resource_type" = 'Sweat::Wallet::Transfer'
LIMIT 1000;

 Limit  (cost=0.57..2.79 rows=1 width=36) (actual time=0.026..0.027 rows=1 loops=1)
   Buffers: shared hit=5
   ->  Index Scan using index_sweat_wallet_feed_items_on_resource_type_and_resource_id on sweat_wallet_feed_items  (cost=0.57..2.79 rows=1 width=36) (actual time=0.025..0.025 rows=1 loops=1)
         Index Cond: ((resource_type = 'Sweat::Wallet::Transfer'::sweat_wallet_feed_item_type) AND (resource_id = 1000000))
         Buffers: shared hit=5
 Planning Time: 0.096 ms
 Execution Time: 0.065 ms
(7 rows)

QUERY PLAN
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=0.57..8.59 rows=1 width=36) (actual time=0.038..0.039 rows=1 loops=1)
   Buffers: shared hit=5
   ->  Index Scan using index_sweat_wallet_feed_items_on_resource_type_and_resource_id2 on sweat_wallet_feed_items  (cost=0.57..8.59 rows=1 width=36) (actual time=0.037..0.037 rows=1 loops=1)
         Index Cond: ((resource_id = 1000000) AND (resource_type = 'Sweat::Wallet::Transfer'::sweat_wallet_feed_item_type))
         Buffers: shared hit=5
 Planning Time: 0.103 ms
 Execution Time: 0.064 ms
(7 rows)

SET random_page_cost = 1.1;

EXPLAIN (ANALYZE, BUFFERS ) SELECT "sweat_wallet_feed_items".*
FROM "sweat_wallet_feed_items"
WHERE
  "sweat_wallet_feed_items"."account_id" = 3031929
ORDER BY "sweat_wallet_feed_items"."timestamp" DESC
LIMIT 10;

EXPLAIN (ANALYZE, BUFFERS ) 
SELECT "sweat_wallet_feed_items".* FROM "sweat_wallet_feed_items" WHERE "sweat_wallet_feed_items"."account_id" = 34834 
AND "sweat_wallet_feed_items"."resource_type" = 'Sweat::Wallet::Claim::Event::Record' AND "sweat_wallet_feed_items"."resource_id" = 13511077 LIMIT 10


EXPLAIN (ANALYZE, BUFFERS, COSTS false ) SELECT "sweat_wallet_feed_items".*
FROM "sweat_wallet_feed_items"
WHERE
  "sweat_wallet_feed_items"."account_id" = 10037
  AND "sweat_wallet_feed_items"."resource_type" NOT IN ('Sweat::Wallet::Trade::OrderlyOrder', 'Sweat::Wallet::TopUpTransaction', 'DailyDraw', 'Sweat::Wallet::Claim::Event::Record')
   AND "sweat_wallet_feed_items"."timestamp" < '2025-02-15 10:36:25.01953' 
ORDER BY "sweat_wallet_feed_items"."timestamp" DESC
LIMIT 10;

===
EXPLAIN (ANALYZE, BUFFERS, COSTS false ) SELECT "sweat_wallet_feed_items".*
FROM "sweat_wallet_feed_items"
WHERE "sweat_wallet_feed_items"."account_id" = 222
ORDER BY "sweat_wallet_feed_items"."timestamp" DESC
LIMIT 10;


EXPLAIN (ANALYZE, BUFFERS, COSTS false ) SELECT "sweat_wallet_feed_items".*
FROM "old_sweat_wallet_feed_items" as sweat_wallet_feed_items
WHERE "sweat_wallet_feed_items"."account_id" = 222
ORDER BY "sweat_wallet_feed_items"."timestamp" DESC
LIMIT 10;



select resource_id,resource_type from sweat_wallet_feed_items where id = 1000000

 Limit  (cost=22883.54..22883.61 rows=30 width=36) (actual time=23.885..23.895 rows=30 loops=1)
   Buffers: shared hit=19979
   ->  Sort  (cost=22883.54..22933.45 rows=19966 width=36) (actual time=23.878..23.883 rows=30 loops=1)
         Sort Key: "timestamp" DESC, id DESC
         Sort Method: top-N heapsort  Memory: 28kB
         Buffers: shared hit=19979
         ->  Index Scan using index_sweat_wallet_feed_items_on_account_id on sweat_wallet_feed_items  (cost=0.57..22293.85 rows=19966 width=36) (actual time=0.028..21.543 rows=19982 loops=1)
               Index Cond: (account_id = 18216)
               Buffers: shared hit=19979
 Planning Time: 0.306 ms
 Execution Time: 23.938 ms
(11 rows)

Limit  (cost=1.70..36.65 rows=30 width=36) (actual time=0.090..0.096 rows=30 loops=1)
Buffers: shared hit=35
->  Incremental Sort  (cost=1.70..23191.77 rows=19908 width=36) (actual time=0.089..0.091 rows=30 loops=1)
      Sort Key: "timestamp" DESC, id DESC
      Presorted Key: "timestamp"
      Full-sort Groups: 1  Sort Method: quicksort  Average Memory: 27kB  Peak Memory: 27kB
      Buffers: shared hit=35
      ->  Index Scan Backward using index_sweat_wallet_feed_items_on_account_id_and_timestamp on sweat_wallet_feed_items  (cost=0.57..22295.91 rows=19908 width=36) (actual time=0.033..0.074 rows=31 loops=1)
            Index Cond: (account_id = 18216)
            Buffers: shared hit=35
Planning Time: 0.128 ms
Execution Time: 0.126 ms
(12 rows)


CALLS | QUERIES      
46642 | SELECT "sweat_wallet_feed_items".* FROM "sweat_wallet_feed_items" WHERE 
        "sweat_wallet_feed_items"."account_id" = $1 
        AND "sweat_wallet_feed_items"."resource_type" = $2 
        AND "sweat_wallet_feed_items"."resource_id" = $3 
        LIMIT $4 /*line:/app/services/sweat/wallet/token_rewards/reward_processor.rb:55:in `block in create_feed_item'*/
51312 | 

EXPLAIN (ANALYZE, BUFFERS, COSTS false ) 
SELECT "sweat_wallet_feed_items".* FROM "sweat_wallet_feed_items" WHERE 
        "sweat_wallet_feed_items"."account_id" = 14551109
        AND "sweat_wallet_feed_items"."resource_type" NOT IN ('Sweat::Wallet::Trade::OrderlyOrder', 'Sweat::Wallet::TopUpTransaction', 'DailyDraw', 'Sweat::Wallet::Claim::Event::Record') 
        ORDER BY "sweat_wallet_feed_items"."timestamp" DESC
        LIMIT 10 ;
        /*action:index,line:/app/queries/sweat/wallet/api/v1/feed_aggregated_query.rb:27:in `run',namespaced_controller:sweat/wallet/api/v1/feed*/


begin;
EXPLAIN (ANALYZE, BUFFERS) UPDATE "addresses" AS a0 SET "last_seen" = '1739966829' WHERE (a0."id" = ANY('{2790905745}'));
rollback;

EXPLAIN (ANALYZE, BUFFERS) select * from addresses where id=2790905745; 
IL:  parameters: $1 = '1739966113', $2 = '{2978099104}'
