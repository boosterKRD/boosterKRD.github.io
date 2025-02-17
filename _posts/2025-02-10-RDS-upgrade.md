---
layout: post
title: How to Update RDS PostgreSQL with Minimal Downtime
date: 2025-02-10
---
## Disclaimer
When working with Amazon RDS for PostgreSQL, minimizing downtime during updates is essential to maintain high availability. 
One of the most effective ways to achieve this is by using the **Blue/Green deployment technique**.  
Although AWS introduced this [feature](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html) for PostgreSQL in December 2023, it still has some limitations that may prevent you from fully leveraging it:
 - RDS Proxy is not currently supported.
 - Instances with subscriptions can’t use it.
 - Your database must have the last minor version 
 - You don’t get a built-in rollback option after cutover, so reverting to the old version without losing data isn’t possible.

Though AWS is steady improving this process ,it remains not fully transparent. For example, although AWS [warns](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-considerations.html) that DDL commands are not allowed:  
    `If Amazon RDS detects a DDL change in the blue environment, your green databases enter a state of Replication degraded ...`  
In practice, a command like CREATE TABLE XXX IF NOT EXISTS (the schema was not changed because the table already existed) triggered no errors and allowed the switchover to start. However, during the switchover, it unexpectedly rolled back, causing brief downtime with no logs explaining why. In this case, the culprit was identified only through testing ...

Considering the issues outlined above, performing a manual (self-crafted) Blue/Green deployment gives you more control. It allows you to bypass some restrictions if you do not face basic [limitations](https://www.postgresql.org/docs/17/logical-replication-restrictions.html) that require logical replication.  
The following guide explains a step-by-step approach to achieve minimal downtime (roughly 10–20 seconds, regardless of the database size) when updating your database. Since the process involves quite a few commands, automating these steps (e.g., with Python scripts) helps reduce the risk of human error.

<!--MORE-->

-----

## Blue/Green Deployment Strategy
BLUE and GREEN represent two separate database environments used to minimize downtime during updates:
 - BLUE (Current Database): This is the active database instance currently serving application traffic. It remains in use while the new environment is being prepared.
 - GREEN (New Database Instance): This is a copy of the database (created from a snapshot of BLUE) where the new PostgreSQL version is applied.  
This approach minimizes downtime by ensuring that application traffic is switched only after GREEN is fully synchronized, maintained, and tested.  
Rollback is also possible, as long as replication from GREEN back to BLUE is still active.  

<img src="/assets/posts/aws_blue.jpg" alt="Blue/Green Deployment" width="35%">

In a nutshell, the strategy behind this update process is:
  1.  [Prepare the BLUE Database](#1-prepare-the-blue-database)
  2.  [Create a Database Snapshot](#2-create-a-database-snapshot)
  3.  [Modify the Database Snapshot](#3-modify-the-database-snapshot)
  4.  [Restore the Database Snapshot](#4-restore-the-database-snapshot)
  5.  [Prepare the GREEN](#5-prepare-the-green)
  6.  [Check Queries](#6-check-queries)
  7.  [Compare Database Objects](#7-compare-database-objects)
  8.  [Advance and Start a Subscription in the GREEN](#8-advance-and-start-a-subscription-in-the-green)
  9.  [Maintain the GREEN](#9-maintain-the-green)
  10. [Cutover to the GREEN](#10-cutover-to-the-green)
  11. [Final Query Checks](#11-final-query-checks)
  12. [Accept Connections on the GREEN](#12-accept-connections-on-the-green)
  13. [ROLLBACK. Cutover from GREEN to BLUE](#rollback-cutover-from-green-to-blue)

## **1. Prepare the BLUE Database**
### 1.1 Creating a Role on the BLUE
  ```sql
  CREATE USER pgrepuser WITH password 'pgrepuser_PASSWORD';
  GRANT rds_replication TO pgrepuser;
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgrepuser;
  GRANT CONNECT ON DATABASE {cluster_datname} TO pgrepuser;
  ```
  This block of code creates a new user (pgrepuser) in the BLUE database with the necessary permissions to perform replication. The user is granted the rds_replication role, along with permissions to select from all tables in the public schema and to connect to the specified database. Ensure that the rds.logical_replication parameter is set to 1.

### 1.2 Creating a Publication on the BLUE
  ```sql
  CREATE PUBLICATION {cluster_publication_name} FOR ALL TABLES;
  ```  
  This command creates a publication on the BLUE database that includes all tables. This publication will be used to replicate data to the GREEN database during the logical replication process.

### 1.3 Creating a Logical Replication Slot on the BLUE
  ```sql
  SELECT pg_create_logical_replication_slot('{cluster_repl_slot}', 'pgoutput');
  ```  
<br>
<div style="border-left: 5px solid red; padding: 10px; background-color: #fff3cd; color: #856404;">
  🚨<span style="font-size:1.2em;">WARNING:</span> Pay special attention to DDL changes, as they may not only come externally from connected applications but also be triggered internally by the database itself. This includes:
  <ul>
    <li><strong>Extensions</strong> such as <code>pg_cron</code> and similar job schedulers that can execute DDL commands.</li>
    <li><strong>Stored procedures and functions</strong> that modify schema objects.</li>
  </ul>
</div>
<br>

## **2. Create a Database Snapshot**
  ```bash
  aws rds create-db-snapshot --db-instance-identifier {BLUE_instance_identifier} --db-snapshot-identifier {GREEN_snapshot_identifier} --region {cluster_region}
  
  aws rds wait db-snapshot-completed --db-instance-identifier {BLUE_instance_identifier} --db-snapshot-identifier {GREEN_snapshot_identifier} --region {cluster_region}
  ```
  This block of code handles the creation of a database snapshot for the BLUE database instance. The process involves the following steps:
  * First command creates a new RDS snapshot of the BLUE database instance ({BLUE_instance_identifier}) with the specified snapshot identifier ({GREEN_snapshot_identifier}).
  * Second command waits for the snapshot to be fully created and available using the aws rds wait db-snapshot-completed command. 

## **3. Modify the Database Snapshot**
  ```bash
  aws rds modify-db-snapshot --db-snapshot-identifier {GREEN_snapshot_identifier} --engine-version {GREEN_engine_version} --region {cluster_region}

  aws rds wait db-snapshot-available --db-snapshot-identifier {GREEN_snapshot_identifier} --region {cluster_region}
  ```
  This block of code handles the modification of an existing RDS database snapshot to a new engine version. You can perform multiple snapshot modifications. For instance, upgrade to the latest minor version and then leap to the final major version.
  * First command modifies the snapshot to the specified engine version (e.g., 16.7).
  * Second command waits for the snapshot to be available and updated using the aws rds wait db-snapshot-available command. 

## **4. Restore the Database Snapshot**
The following process set up a new (GREEN) instance.
  ```bash
   aws rds restore-db-instance-from-db-snapshot \
      --db-instance-identifier {GREEN_instance_identifier} \
      --db-snapshot-identifier {GREEN_snapshot_identifier} \
      --db-parameter-group-name {GREEN_parameter_group} \
      --region {cluster_region} \
      --db-instance-class {GREEN_instance_class} \
      --multi-az \
      --db-subnet-group-name {cluster_subnet_group} \
      --vpc-security-group-ids {cluster_vpc_security_group_ids} \
      --enable-iam-database-authentication \
      --no-publicly-accessible

  aws rds wait db-instance-available --db-instance-identifier {GREEN_instance_identifier} --region {cluster_region}
  ```
  This block of code handles the restoration of a new database instance from a previously created and already modified snapshot. 
  * First command restore a new RDS instance from the snapshot identified by {GREEN_snapshot_identifier}. This command includes parameters such as the instance class ({GREEN_instance_class}), parameter group ({GREEN_parameter_group}), VPC security groups ({cluster_vpc_security_group_ids}), and subnet group ({cluster_subnet_group}). It also enables IAM database authentication and ensures the instance is not publicly accessible.  
  ℹ️  INFO: You should adjust the parameters to meet the requirements and needs of your cluster (the parameters above are used for demonstration purposes).  
  * Second command waits for the new database instance to become available using the aws rds wait db-instance-available command. 

## **5. Prepare the GREEN**
  ```sql
  DO $$ 
  DECLARE 
  user_name text;
  BEGIN 
  FOR user_name IN (SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'rds%' AND rolname IN ({cluster_user_list}))  
  LOOP
      EXECUTE 'ALTER USER ' || user_name || ' WITH NOLOGIN;'; 
  END LOOP; 
  END $$;
  ```
  This block of code sets the NOLOGIN  status for specific users in the database. The users are identified from a list (cluster_user_list), and the action (NOLOGIN) is applied to each user. This is typically done to prevent or allow specific users from logging into the database during upgrade. This helps prevent a split-brain.

### 5.1 Creating a Subscription on the GREEN
  ```sql
  CREATE SUBSCRIPTION {cluster_subscription_name} CONNECTION 'host={BLUE_instance_identifier}.XXX.{cluster_region}.rds.amazonaws.com port={cluster_port} dbname={cluster_datname} user=pgrepuser password=pgrepuser_PASSWORD' PUBLICATION {cluster_publication_name}
  WITH (copy_data = false, create_slot = false, enabled = false, connect = true, slot_name = '{cluster_repl_slot}');
  ```
  This command creates a subscription on the GREEN database to replicate data from the BLUE database. The subscription connects to the BLUE database using a specified connection string and subscribes to a publication created in first step. 
<br>
ℹ️ INFO: The subscription is initially created with copy_data set to false and enabled set to false, meaning data replication will not start until the subscription is explicitly enabled. Also, ensure that the GREEN database has network access to the BLUE database on the required port (e.g., 5432).
<br>

## **6. Check Queries**
This section advances the replication origin for the subscription on the GREEN database to the specified LSN ({GREEN_last_lsn}). This ensures that replication begins from the correct point

### 6.1 Check if pgrepuser role exists in the BLUE
  ```sql
  SELECT EXISTS (
    SELECT 1
    FROM pg_roles r, pg_auth_members m, pg_roles r2
    WHERE r.oid = m.member AND r2.oid = m.roleid AND r.rolname = 'pgrepuser' AND r2.rolname = 'rds_replication'
  ) AS "exists";
  ```
### 6.2 Check if the publication with the specified name and attributes exists in the BLUE
  ```sql
  SELECT EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = '<cluster_publication_name>' and puballtables and pubinsert and pubupdate and pubdelete and pubtruncate
  ) AS "exists";
  ```
- Check if wal_level is set to logical in the BLUE
  ```sql
  SELECT EXISTS (
    SELECT 1 from pg_settings where name = 'wal_level' and setting='logical'
  ) AS "exists";
  ```
- Check if the subscription with the specified name exists in the GREEN
  ```sql
  SELECT EXISTS (
    SELECT * FROM pg_subscription WHERE subname = '<cluster_subscription_name>'
  ) AS "exists";
  ```
If you have any other specific requirements or need additional checks, feel free to add them and use!

## **7. Compare Database Objects**
Compare objects between the BLUE and GREEN databases to ensure that no changes (such as DDL commands that alter the schema) occurred in the BLUE database during the snapshot restore process.
How you choose to compare the objects between the two databases is up to you, but at a minimum, you should compare the following objects:
  ```sql
  --Tables, Indexes, Views, Materialized, Constraints, Sequences, Columns
  SELECT table_name FROM information_schema.tables WHERE table_schema IN ('XXX');
  SELECT indexname FROM pg_indexes WHERE schemaname IN ('XXX');
  SELECT viewname FROM pg_views WHERE schemaname IN ('XXX');
  SELECT matviewname FROM pg_matviews WHERE schemaname IN ('XXX');
  SELECT conname FROM pg_constraint WHERE connamespace = (SELECT oid FROM pg_namespace WHERE nspname IN ('XXX'));
  SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema IN ('XXX');
  SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns where table_schema IN ('XXX') ORDER BY table_name, ordinal_position;
  ```
<br>

-----
 
<br>
ℹ️  INFO: Half the work is done, and we don't need to rush, but we should remember that because of the step where we created the publication on the BLUE instance (step 1), WAL files are accumulating on the BLUE instance, leading to increasing disk space usage on the BLUE instance.

<div style="border-left: 5px solid red; padding: 10px; background-color: #fff3cd; color: #856404;">
  🚨<span style="font-size:1.2em;">IMPORTANT:</span> This is the most critical and responsible step — read carefully. (If you’re tired, take a break, grab some ☕ or a 🍻) — but make sure you understand the text that follows.
  <ul>
    <li>Get the RDS instance logs for the time when the restore was executed on the GREEN, and find the LSN from the first line with "<span style="color:red;">Redo done at XXX/XXXXXXX</span>." There will be a second "<span style="color:red;">Redo done</span>" after the modify command and possibly more, but you must grab only the FIRST one. Take it and store it in your notes.</li>
  </ul>
</div>
<br>

-----

<br>

## **8. Advance and start a subscription in the GREEN**
I performed such updates in 2023 and 2024 with PostgreSQL versions 14 and 15, and on AWS at thosetime, the subscription needs to be shifted by LSN + 1 byte. So, make sure to add 1 byte to the {GREEN_last_lsn} value you copied from the logs and use the new value below.
  ```sql
  --This command retrieves the external_id associated with a specific subscription on the GREEN database. The external_id is necessary for advancing the replication origin to a specific LSN.
  SELECT 'pg_'||oid::text AS external_id FROM pg_subscription WHERE subname = '{cluster_subscription_name}';

  --Advancing the Subscription on the Target (GREEN)
  SELECT pg_replication_origin_advance('{external_id}','{GREEN_last_lsn}');

  --Enable a subcription 
  ALTER SUBSCRIPTION {cluster_subscription_name} ENABLE;

  --Check replication lag on BLUE
  SELECT slot_name, (pg_current_wal_lsn() - confirmed_flush_lsn) AS lsn_distance FROM pg_replication_slots;
  ```

## **9. Maintain the GREEN**
After the previous step where we enabled logical replication, you need to:
### 9.1 Check the replication lag
### 9.2 Run maintenance commands 
  ```sql
  VACUUM FULL; --optional, but why not
  ANALYZE;
  --and any other necessary maintenance operations.
  ```

## **10. Cutover to the GREEN**
In this step, we switch over the database traffic from the BLUE instance to the GREEN instance by performing several crucial tasks, including checking replication lag, disabling user access and terminating active connections on BLUE, reconfiguring the replication setup, and synchronizing sequences.
### 10.1 Checking Replication Lag on the BLUE
This query checks the replication lag on the BLUE database to ensure that all changes have been replicated from BLUE to GREEN before proceeding with the cutover.
  ```sql
  SELECT slot_name, (pg_current_wal_lsn() - confirmed_flush_lsn) AS lsn_distance FROM pg_replication_slots;
  ```

### 10.2 Set User Login to NOLOGIN and Terminate User Connections on the BLUE
This block first sets the users listed in {cluster_user_list} to NOLOGIN status on the BLUE database, preventing them from accessing it. It then forcibly terminates any active connections for these users to prevent a split-brain scenario during the cutover.
  ```sql
  DO $$ 
  DECLARE 
  user_name text;
  BEGIN 
  FOR user_name IN (SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'rds%' AND rolname IN ({cluster_user_list}))
  LOOP
      -- Set user login to NOLOGIN
      EXECUTE 'ALTER USER ' || user_name || ' WITH NOLOGIN;';
      
      -- Terminate active user connections
      EXECUTE 'SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.usename = ''' || user_name || ''';';
  END LOOP; 
  END $$;
  ```

### 10.3 Disable and Drop Subscription on the GREEN
This command disables and drops the subscription on the GREEN database.
  ```sql
  --Disable and Drop Subscription
  ALTER SUBSCRIPTION {cluster_subscription_name} DISABLE;
  ALTER SUBSCRIPTION {cluster_subscription_name} SET (slot_name = NONE);
  DROP SUBSCRIPTION {cluster_subscription_name};
  ```

### 10.4 Drop Replication Slot on the BLUE  
  ```sql
  SELECT pg_drop_replication_slot('{cluster_repl_slot}');
  ```
<br>
ℹ️  INFO: Steps 5 and 6 are designed to give us the option to perform a rollback during the cutover. After the traffic is switched, logical replication will continue applying changes to the BLUE database, allowing us to switch back as long as replication between the servers is active.

### 10.5 Create Logical Replication Slot on the GREEN
This query creates a new logical replication slot on the GREEN database to prepare for replication from the BLUE
  ```sql
  SELECT pg_create_logical_replication_slot('{cluster_repl_slot}', 'pgoutput');
  ```  

### 10.6 Create Subscription on the BLUE 
This command creates a new subscription on the BLUE, enabling replication from the GREEN database.
  ```sql
  CREATE SUBSCRIPTION {cluster_subscription_name} CONNECTION 'host={GREEN_instance_identifier}.XXX.{cluster_region}.rds.amazonaws.com port=5432 dbname={cluster_datname} user=pgrepuser password=pgrepuser_PASSWORD' PUBLICATION {cluster_publication_name}
  WITH (
      copy_data = false,
      create_slot = false,
      enabled = true,
      connect = true,
      slot_name = '{cluster_repl_slot}'
  );
  ```

### 10.7 Syncing Sequences Manually
The logical replication protocol does not synchronize sequences, so you need to handle this synchronization manually. I automated this in an update script, and here is an example of the commands (you should test them as I haven't used them myself).
This command exports the current sequence values from the BLUE and applies them to the GREEN database, ensuring that sequences are synchronized across both databases.
  ```bash
  psql -h BLUE_host -U username -d BLUE_db -t -A -F ',' -c "SELECT 'SELECT setval(' || quote_literal(sequence_schema || '.' || sequence_name) || ', ' || last_value || ', true);' FROM information_schema.sequences JOIN pg_sequences ON pg_sequences.schemaname = information_schema.sequences.sequence_schema 
  AND pg_sequences.sequencename = information_schema.sequences.sequence_name" > sync_sequences.sql
  
  psql -h GREEN_host -U username -d GREEN_db -f sync_sequences.sql
  ```

## 11. Final Query Checks
Before finalizing the cutover to the GREEN database, it's crucial to ensure that all configurations and subscriptions are correctly set up and operational. Run the following queries to perform these final checks:
### 11.1 Check if the pgrepuser Role Exists in the GREEN
  ```sql
  SELECT EXISTS (
    SELECT 1
    FROM pg_roles r, pg_auth_members m, pg_roles r2
    WHERE r.oid = m.member AND r2.oid = m.roleid AND r.rolname = 'pgrepuser' AND r2.rolname = 'rds_replication'
  ) AS "exists";
  ```
### 11.2 Verify the Publication in the GREEN
This query checks whether the publication with the specified name and attributes exists in the GREEN database (for rollback).
  ```sql
  SELECT EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = '{cluster_publication_name}' AND puballtables AND pubinsert AND pubupdate AND pubdelete AND pubtruncate
  ) AS "exists";
  ```
### 11.3 Ensure wal_level is Set to Logical in the GREEN 
  ```sql
  SELECT EXISTS (
    SELECT 1 FROM pg_settings WHERE name = 'wal_level' AND setting='logical'
  ) AS "exists";
  ```
### 11.4 Check for the Existence of the Subscription in the BLUE
This query verifies the presence of the subscription in the BLUE database, which is necessary for ensuring replication between BLUE and GREEN instances (for rollback).
  ```sql
  SELECT EXISTS (
    SELECT * FROM pg_subscription WHERE subname = '{cluster_subscription_name}'
  ) AS "exists";
  ``` 
ℹ️  INFO: Ensure that all queries return the expected results before moving on to the final steps of the cutover process.

## 12. Accept Connections on the GREEN
After verifying that the GREEN database is fully operational and all checks have passed, the next step is to allow user connections to the GREEN database and redirect traffic from the BLUE instance.
### 12.1 Set User Login Permissions
Enable login permissions for users who were previously set to NOLOGIN during the upgrade process.
  ```sql
  DO $$ 
  DECLARE 
  user_name text;
  BEGIN 
  FOR user_name IN (SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'rds%' AND rolname IN ({{cluster_user_list}}))  
  LOOP
      EXECUTE 'ALTER USER ' || user_name || ' WITH LOGIN;'; 
  END LOOP; 
  END $$;
  ```

### 12.2 Redirect Application Traffic to the GREEN
Update your application's database connection strings to point to the GREEN database. This step involves updating the DNS or configuration settings in your application to ensure that all new connections are directed to the GREEN instance.


-----
<br>
<div style="border-left: 5px solid red; padding: 10px; background-color: #fff3cd; color: #856404;">
  🚨<span style="font-size:1.2em;">IMPORTANT:</span> To ensure a successful ROLLBACK to the BLUE instance, it is recommended to refrain from executing DDL commands after the cutover and to verify that the application is functioning correctly with the new PostgreSQL version.

  If the application is working well on the new version, you should:
  <ul>
    <li>Delete the replication slot on GREEN</li>
    <li>Delete the BLUE instance</li>
  </ul>
  However, if you need to roll back to the previous version without losing data, please follow  <a href="#rollback-cutover-from-GREEN-to-BLUE-database">the ROLLBACK instructions below</a>.
</div>

<br>
-----

## **ROLLBACK. Cutover from GREEN to BLUE**
For a ROLLBACK, you can essentially repeat the steps from Step 10 but in reverse, performing a cutover from the GREEN to the BLUE database. This process includes checking replication lag, disabling user access, terminating active connections, reconfiguring the replication setup, and synchronizing sequences.

### 1. Checking Replication Lag on the GREEN
This query checks the replication lag on the BLUE database to ensure that all changes have been replicated from GREEN to BLUE before proceeding with the cutover.
  ```sql
  SELECT slot_name, (pg_current_wal_lsn() - confirmed_flush_lsn) AS lsn_distance FROM pg_replication_slots;
  ```

### 2. Set User Login to NOLOGIN and Terminate User Connections on the GREEN
This block first sets specific users to NOLOGIN status on the GREEN database, preventing them from accessing the database. It then forcibly terminates any active connections for these users to prevent a "split-brain" scenario during the cutover.
  ```sql
  DO $$ 
  DECLARE 
  user_name text;
  BEGIN 
  FOR user_name IN (SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'rds%' AND rolname IN ({cluster_user_list}))
  LOOP
      -- Set user login to NOLOGIN
      EXECUTE 'ALTER USER ' || user_name || ' WITH NOLOGIN;';
      
      -- Terminate active user connections
      EXECUTE 'SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.usename = ''' || user_name || ''';';
  END LOOP; 
  END $$;
  ```

### 3. Disable and Drop Subscription on the BLUE
This command disables and drops the subscription on the BLUE database.
  ```sql
  --Disable and Drop Subscription
  ALTER SUBSCRIPTION {cluster_subscription_name} DISABLE;
  ALTER SUBSCRIPTION {cluster_subscription_name} SET (slot_name = NONE);
  DROP SUBSCRIPTION {cluster_subscription_name};
  ```

### 4. Syncing Sequences Manually
The logical replication protocol does not synchronize sequences, so you need to handle this synchronization manually. I automated this in an update script, and here is an example of the commands (you should test them as I haven't used them myself).
This command exports the current sequence values from the BLUE and applies them to the GREEN database, ensuring that sequences are synchronized across both databases.
  ```bash
  psql -h GREEN_host -U username -d GREEN_db -t -A -F ',' -c "SELECT 'SELECT setval(' || quote_literal(sequence_schema || '.' || sequence_name) || ', ' || last_value || ', true);' FROM information_schema.sequences JOIN pg_sequences ON pg_sequences.schemaname = information_schema.sequences.sequence_schema 
  AND pg_sequences.sequencename = information_schema.sequences.sequence_name" > sync_sequences_green.sql
  
  psql -h BLUE_host  -U username -d BLUE_db -f sync_sequences_green.sql
  ```

### 5. Set User Login Permissions on BLUE
  ```sql
  DO $$ 
  DECLARE 
  user_name text;
  BEGIN 
  FOR user_name IN (SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'rds%' AND rolname IN ({cluster_user_list}))  
  LOOP
      EXECUTE 'ALTER USER ' || user_name || ' WITH LOGIN;'; 
  END LOOP; 
  END $$;
  ```
### 6. Redirect Application Traffic to the BLUE
Update your application's database connection strings to point back to the BLUE database. This step involves updating the DNS or configuration settings in your application to ensure that all new connections are directed to the BLUE instance again.