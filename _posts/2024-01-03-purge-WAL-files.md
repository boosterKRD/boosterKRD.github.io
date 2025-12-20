---
layout: post
title: Freeing Up Disk Space in PostgreSQL by Deleting WAL Files
date: 2024-01-03
---

It's crucial to avoid running out of disk space in PGDATA, but if it does happen, we have several options to manage the situation.

<!--MORE-->

-----

### Option A (Increase partition size)

Increase the capacity of the partition where PGDATA is located. This article does not cover the method for increasing the size.


### Option B (Remove unnecessary WAL files)

⚠️ **Important:**

This approach determines which WAL files are no longer required by the current primary instance only.
However, these WAL files may still be needed by:

- streaming replicas
- logical replication

Before removing WAL files, ensure there are no active replicas or replication slots that still require them.

> In real-world emergency situations with severe disk pressure, I have encountered cases where it was necessary to choose the lesser evil — temporarily sacrificing logical replication in order to keep the primary instance running and avoid a complete PostgreSQL outage.
> This is an extreme measure and should be taken only with full awareness of the consequences.

-----

1. Find the last checkpoint's REDO WAL file (WAL files before it are no longer needed)
    ```bash
    [root@db-server ~]# pg_controldata -D /var/lib/pgsql/13/data | grep "REDO WAL"
    Latest checkpoint's REDO WAL file:    000000010000006000000010
    ```
2. Get the entire list of WAL files created before the last checkpoint using the `-n` option to print the names of the files that should be removed to stdout (without actually deleting them).
    ```bash
    [root@db-server ~]# pg_archivecleanup -n /var/lib/pgsql/13/data/pg_wal 000000010000006000000010
    /var/lib/pgsql/13/data/pg_wal/000000010000005F0000006B
    /var/lib/pgsql/13/data/pg_wal/000000010000005F0000003D
    /var/lib/pgsql/13/data/pg_wal/000000010000005D000000D9
    /var/lib/pgsql/13/data/pg_wal/000000010000005E00000027
    /var/lib/pgsql/13/data/pg_wal/000000010000005E000000F7
    /var/lib/pgsql/13/data/pg_wal/000000010000005E00000093
    /var/lib/pgsql/13/data/pg_wal/000000010000005E0000000C
    /var/lib/pgsql/13/data/pg_wal/000000010000005E00000022
    ...
    ...
    ...
    ```
3. Ensure that the files from the above list are present in your archive storage (local directory, S3, or other location).

    Example for S3:
    ```bash
    [root@db-server ~]# aws s3 ls s3://your-bucket/backup/wal_archive/ --endpoint-url=https://storage.yandexcloud.net --profile prod | grep 000000010000006000000010
    2021-10-26 10:45:05      62643 000000010000006000000010.br
    ```
    > ℹ️ **INFO:** If the files are missing in your archive storage (S3, local archive directory, or other storage location), upload them manually using any available method. In case of Point-In-Time Recovery (PITR), all WAL file chains must be present in your archive storage.

4. Delete the unnecessary WAL files to free up disk space
    ```bash
    [root@db-server ~]# pg_archivecleanup /var/lib/pgsql/13/data/pg_wal 000000010000006000000010
    pg_archivecleanup: keeping WAL file "/var/lib/pgsql/13/data/pg_wal/000000010000006000000010" and later
    ```