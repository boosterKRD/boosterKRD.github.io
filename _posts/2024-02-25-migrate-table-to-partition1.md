---
layout: post
title: Adding an Existing Table as a Large Partition in PostgreSQL (part 1)
date: 2024-02-25
---
There are many strategies for migrating a regular table to a partitioned table. Today, I’ll implement one of them. The main approach involves the following steps:

- Prepare the existing table: Add necessary columns and constraints.
- Create a new partitioned table: Set up the table with partitions.
- Add the old table as a partition: Integrate the existing table as a partition in the new structure.

ℹ️ This strategy is ideal when you know that in the foreseeable future, the old large partition will be removed as the data it contains will fall under the business retention period.

let's do it 
<!--MORE-->

-----

## Step 0: Setting Up the Test Environment
Before we start partitioning, let's create and populate the order_history table with some test data.
  ```sql
  DROP TABLE IF EXISTS public.order_history;
  DROP TABLE IF EXISTS public.order_history_parent;

  CREATE EXTENSION IF NOT EXISTS pgcrypto;

  CREATE TABLE public.order_history (
      order_id UUID NOT NULL,
      description text,
      user_id bigint,
      search_data JSONB,
      PRIMARY KEY (order_id)
  );

  INSERT INTO public.order_history (order_id, description, user_id, search_data)
  SELECT 
      gen_random_uuid(),
      'Order description ' || i,
      (random() * 1000000)::bigint,
      jsonb_build_object('search_term', 'term_' || i, 'timestamp', clock_timestamp())
  FROM generate_series(1, 1000000) AS s(i);

  CREATE INDEX order_history_user_id_idx ON public.order_history (((search_data ->> 'user_id')::text));
  CREATE INDEX order_history_order_id_idx ON public.order_history (((search_data ->> 'order_id')::text));
  CREATE INDEX order_history_hash_order_idx ON public.order_history (((search_data ->> 'hash_order')::text));
  ```
This code sets up a table with a million rows of randomly generated data. It also creates indexes on important fields within the search_data JSONB column.

## Step 1: Preparing the Table for Partitioning
  ```sql
  -- Set a timeout for the lock
  SET lock_timeout = '500ms';

  -- Add column with default value
  -- This command sets the default value for existing rows where the column has NULL values
  ALTER TABLE public.order_history ADD COLUMN create_at TIMESTAMP DEFAULT '2024-07-15 00:00:00';

  -- Change the default value of the column
  -- This command sets the default value for new rows that will be inserted
  ALTER TABLE public.order_history ALTER COLUMN create_at SET DEFAULT now();

  -- Check the default value
  SELECT pg_get_expr(adbin, 'public.order_history'::regclass::oid) FROM pg_attrdef;  --(for existing rows)
  SELECT attmissingval FROM pg_attribute WHERE attrelid = 'public.order_history'::regclass::oid AND attname = 'create_at'; --(for new rows)
  ```
This step ensures that all existing rows in the table get a default create_at value, while new rows will have the current timestamp.
ℹ️ INFO: The description can insert data with or without specifying the create_at column.

## Step 2: Migrating to a Partitioned Table
Let's do the final preparatory work before migration
  ```sql
  -- Set timeouts
  SET lock_timeout = '800ms';
  SET deadlock_timeout = '500ms';
  
  -- Temporarily add constraints on create_at
  ALTER TABLE public.order_history ADD CONSTRAINT check_create_at_range CHECK (create_at >= '2024-01-01' AND create_at < '2024-08-01') NOT VALID;
  ALTER TABLE public.order_history VALIDATE CONSTRAINT check_create_at_range;
  ALTER TABLE public.order_history ADD CONSTRAINT temp_check_not_null CHECK (create_at IS NOT NULL) NOT VALID;
  ALTER TABLE public.order_history VALIDATE CONSTRAINT temp_check_not_null;
  ```
  I added a CONSTRAINT to the order_history table with NOT VALID to avoid long locks when adding this table as a partition. Without NOT VALID, the database would check all existing rows for compliance with this constraint, which could take a significant amount of time and lead to table locks with ACCCESS EXCLUSEVE. Using NOT VALID allows us to skip this check when adding the constraint, and we can perform validation later with a command that locks the table in a more lenient mode, ACCESS SHARE.

  🚨 WARNING: The following SQL query must be executed within a transaction block.
  ```sql  
  BEGIN;

  -- Lock the table
  LOCK TABLE public.order_history_old IN ACCESS EXCLUSIVE MODE;

  -- Rename the old table
  ALTER TABLE public.order_history RENAME TO order_history_old;
  ALTER TABLE public.order_history_old ALTER COLUMN create_at SET NOT NULL;

  -- Create new partitioned table
  CREATE TABLE public.order_history (
      order_id  UUID NOT NULL,
      description text,
      user_id    bigint,
      search_data JSONB,
      create_at   TIMESTAMP WITHOUT TIME ZONE NOT NULL
  ) PARTITION BY RANGE (create_at);

  -- Create indexes on the parent table
  CREATE INDEX order_history_parent_user_id_idx ON public.order_history ((search_data ->> 'user_id'::text));
  CREATE INDEX order_history_parent_order_id_idx ON public.order_history((search_data ->> 'scoring_id'::text));
  CREATE INDEX order_history_parent_hash_order_idx ON public.order_history ((search_data ->> 'hash_order'::text));
  
  -- Attach the old table as a partition
  ALTER TABLE public.order_history ATTACH PARTITION public.order_history_old FOR VALUES FROM (MINVALUE) TO ('2024-08-01 00:00:00');

  -- Create new partitions
  CREATE TABLE public.order_history_2024_08 PARTITION OF public.order_history FOR VALUES FROM ('2024-08-01 00:00:00') TO ('2024-09-01 00:00:00');
  CREATE UNIQUE INDEX ON order_history_2024_08 (order_id);

  CREATE TABLE public.order_history_2024_09 PARTITION OF public.order_history FOR VALUES FROM ('2024-09-01 00:00:00') TO ('2024-10-01 00:00:00');
  CREATE UNIQUE INDEX ON order_history_2024_09 (order_id);

  CREATE TABLE public.order_history_2024_10 PARTITION OF public.order_history FOR VALUES FROM ('2024-10-01 00:00:00') TO ('2024-11-01 00:00:00');
  CREATE UNIQUE INDEX ON order_history_2024_10 (order_id);

  COMMIT;
  ```  

  This step involves renaming the existing table, creating a new partitioned table, and attaching the old table as a partition. New partitions are also created to manage data for future dates.


## Step 3: Dropping Old Partitions in the Future 
Once you no longer need the old partition (in some futere), you can detach and drop it.  
  ```sql
  ALTER TABLE order_history DETACH PARTITION order_history_old;
  DROP TABLE order_history_old;
  ```
This command removes the old partition from the table and deletes it, freeing up space.

## Conclusion
By following these steps, you've successfully converted a regular table into a partitioned one, allowing for better performance and easier management. This method minimizes long-term ACCESS EXCLUSIVE locks, ensuring a smoother migration process.

