---
layout: post
title: Intentional Data Corruption for Backup Testing
date: 2023-08-18
---

Sometimes, when testing backup utilities like WAL-G, Pgbackrest, and others, it's necessary to intentionally corrupt data. This is because the features advertised by these tools don't always correctly verify checksum corruption, for example, as in the case of [WAL-G](https://github.com/wal-g/wal-g/issues/1140), where the tool fails to detect bad checksums when using the -v flag.

<!--MORE-->

-----

## Step-by-Step Guide to Corrupting Data
1. Create DB and Test Table
Let's create a test database and a table for future data corruption tests.
    ```bash
    sudo -u postgres psql -c "CREATE DATABASE maratos_db;"
    sudo -u postgres psql -d maratos_db -c "CREATE TABLE public.test_table (id INT4 NOT NULL,name VARCHAR) WITH (fillfactor = 100);"
    ```

2. Add Some Data
    ```bash
    sudo -u postgres psql -d maratos_db -c "INSERT INTO public.test_table (id, name) VALUES (1, 'MARAT'); INSERT INTO public.test_table (id, name) VALUES (2, 'OLGA'); INSERT INTO public.test_table (id, name) VALUES (3, 'MISHA');"
    ```

3. Locate the File in the PostgreSQL Data Directory
To find the file associated with our table, run the following command:
    ```sql
    sudo -u postgres psql -Atc "select format('%s/%s', current_setting('data_directory'), pg_relation_filepath('test_table'))" maratos_db
    ```
Example output:
    ```bash
    /data/pg_data/postgres/base/16495/16707
    ```

4. Create a Checkpoint
Run the following command to create a checkpoint:
    ```sql
    sudo -u postgres psql -c "checkpoint" maratos_db
    ```

5. Check for Data in the File
Use hexdump tool to view the file's contents:
    ```bash
    hexdump -C /data/pg_data/postgres/base/16495/16513
    ```

6. Corrupt Data in the File
    ```bash
    echo -n "Hello1" | dd conv=notrunc oflag=seek_bytes seek=8000 bs=6 count=1 of=/var/lib/postgresql/16/main/base/16495/16513
    ```

7. Check the Data in the File Again
Check the file contents again with hexdump:
    ```bash
    hexdump -C /data/pg_data/postgres/base/16495/16707
    ```

8. Restart PostgreSQL and Access the Data
Restart PostgreSQL and attempt to access the data, then make a backup with WAL-G etc:
    ```bash
    systemctl restart postgresql
    ```