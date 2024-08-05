---
layout: post
title: How to BlueGreen Postgres with Patroni
date: 2023-12-05
---

We have a configured cluster with Patroni, >=2 nodes. The task is to preserve the state of the database before deployment and, in case of failure, roll back to it.

The working and tested algorithm is as follows:

<!--MORE-->

-----


1. **Stop replication on one of the slaves during deployment:**
    ```sql
    psql# select pg_xlog_replay_pause();
    ```
The instance will be in read-only mode, will receive WAL-segments, but will not apply them.

2. Record the XID on the master before deployment:
    ```sql
    psql# select txid_current();
    ```
For example, 283473094.

3. Monitor the lag:
    * On the master:    
    ```sql
    SELECT *, pg_xlog_location_diff(s.sent_location, s.replay_location) AS byte_lag 
    FROM pg_stat_replication s;
    ```
    * On the slave (in seconds):    
    ```sql
    SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::INT;
    ```
4. If everything is OK and the deployment was successful, resume applying WAL on the slave:
    ```sql
    psql# select pg_xlog_replay_resume();
    ```
5. If things go wrong and you need to revert the cluster to its pre-deployment state, follow these steps to match the state of the slave with the disabled replay:
    5.1 Stop the Patroni service on the slave.
    5.2 Modify the configurations on the slave to recover to the necessary XID that was recorded before deployment:
    * postgresql.conf
    ```ini
    hot_standby = 'off'
    ```
    * recovery.conf
    ```ini
    # Uncomment the following lines and add recovery_target_xid:
    #primary_slot_name = '10_144_193_197'
    restore_command = 'cp ../wal_archive/%f %p'
    #recovery_target_timeline = 'latest'
    recovery_target_xid='283473094'
    #standby_mode = 'on'
    #primary_conninfo = 'user=replicator password=EedCyzger4% host=10.144.193.196 port=5432 sslmode=prefer sslcompression=1 application_name=10.144.193.197'
    ```
    5.3 Start the slave in standalone mode, for example:
    ```ini
    pg_ctl -D /u01/data/pgdata start -o "-p 5432"
    ```
    The log should indicate that recovery reached the specified XID:
    ```yaml
    <2019-07-04 11:17:02.803 MSK> LOG: consistent recovery state reached at 19E/45017E28
    <2019-07-04 11:17:02.803 MSK> LOG: recovery stopping after commit of transaction 283473094, time 2019-07-04 11:13:59.869785+03
    ```
    5.4 Delete the cluster configuration (on the master):
    ```bash
    patronictl -c /etc/patroni/postgres.yml remove cluster-pgsql
    ```
    Stop the Patroni service on the master as usual:
    ```bash
    systemctl stop patroni
    ```
    Start Patroni on the slave where the blue-green database is running:
    ```bash   
    systemctl start patroni  
    ```    
    The slave will become the new master and the only node in the cluster.

    5.5 Delete and clean the pg_data on the old master (everything, including configs and WALs). Start Patroni, and it will bootstrap from the new master.

