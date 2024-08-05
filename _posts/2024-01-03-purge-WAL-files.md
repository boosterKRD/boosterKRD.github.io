---
layout: post
title: Freeing Up Disk Space in PostgreSQL by Deleting WAL Files
date: 2024-01-03
---

It's crucial to avoid running out of disk space in PGDATA, but if it does happen, we have several options to manage the situation.

<!--MORE-->

-----

### Option A (Increase partition size)

Increase the capacity of the partition where the directory with WAL files is located. This article does not cover the method for increasing the size (not described).

-----

### Option B (Remove unnecessary WAL files)

1. Find the last WAL file after the checkpoint (WAL files before it are no longer needed)
    ```bash
    [root@mbogatyrev-test-new1-db-01 centos]# /usr/pgsql-13/bin/pg_controldata -D /data/pg_data/postgres | grep "REDO WAL"
    Latest checkpoint's REDO WAL file:    000000010000006000000010
    ```
2. Get the entire list of WAL files created before the last checkpoint using the -n option to print the names of the files that should be removed to stdout (without actually deleting them).
    ```bash
    [root@mbogatyrev-test-new1-db-01 centos]# /usr/pgsql-13/bin/pg_archivecleanup -n /data/pg_wal 000000010000006000000010
    /data/pg_wal/000000010000005F0000006B
    /data/pg_wal/000000010000005F0000003D
    /data/pg_wal/000000010000005D000000D9
    /data/pg_wal/000000010000005E00000027
    /data/pg_wal/000000010000005E000000F7
    /data/pg_wal/000000010000005E00000093
    /data/pg_wal/000000010000005E0000000C
    /data/pg_wal/000000010000005E00000022
    ...
    ...
    ...
    ```
3. Ensure that the files from the above list are present in the S3 storage.
    ```bash
    [root@mbogatyrev-test-new1-db-01 centos]# /usr/local/bin/aws s3 ls s3://pg-mbogatyrev-15102021-prod-ixwme2qh/backup/wal_005/ --endpoint-url=https://storage.yandexcloud.net --profile prod | grep 000000010000006000000010
    2021-10-26 10:45:05      62643 000000010000006000000010.br
    ```
    > ℹ️ **INFO:** If the files are missing on S3, upload them manually using any available method (in case of Point-In-Time Recovery (PITR), all WAL file chains must be on S3 storage).

4. Delete the unnecessary WAL files to free up disk space
    ```bash
    [root@mbogatyrev-test-new1-db-01 centos]# pg_archivecleanup -d /data/pg_wal 000000010000006000000010
    pg_archivecleanup: keeping WAL file "/data/pg_wal/000000010000006000000010" and later
    ```