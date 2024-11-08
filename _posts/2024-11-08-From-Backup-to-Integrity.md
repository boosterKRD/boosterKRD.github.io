---
layout: post
title: From Backup to Integrity - Leveraging WAL-G for PostgreSQL
date: 2024-11-08
---
**[Original post URL](https://dataegret.com/2024/11/from_backup_to_integrity_leveraging_wal-g_for_postgresql//)**

A key aspect of maintaining backup integrity is understanding data checksums. Without proper checksum validation, detecting data corruption becomes virtually impossible. Therefore, we will start with The Importance of Data Checksums.

<!--MORE-->

-----

## The Importance of Data Checksums
Ensuring data integrity is crucial for the reliability of any database system. Data checksum validation is essential for ensuring data integrity. Checksums help detect data corruption caused by hardware issues.

#### How PostgreSQL Calculates Checksums:
1. **During Page Writes**: PostgreSQL calculates the checksum each time a data page is written to disk. This ensures that any corruption occurring after the write can be detected during future reads.

2. **Verification During Reads**: Every time a page is read from disk into memory—whether by user queries or maintenance operations—PostgreSQL verifies the checksum to confirm data integrity.
If the checksum does not match, a warning is raised and recorded in the log. The log entry below indicates that a data page is corrupted, and the checksum does not match the expected value. Such logs can be conveniently captured and monitored using the [logerrors](https://github.com/munakoiso/logerrors) extension, which helps identify and track these errors for further analysis.

```bash 
WARNING: page verification failed, calculated checksum 24693 but expected 58183
```

Although enabling checksums does add extra overhead to the database, the general rule of thumb is to enable this option on every cluster via [initdb](https://www.postgresql.org/docs/current/app-initdb.html#APP-INITDB-DATA-CHECKSUMS). This practice is considered so important that, in PostgreSQL 18, there is a strong possibility that data checksum [will be enabled](https://www.postgresql.org/message-id/flat/CAKAnmmKwiMHik5AHmBEdf5vqzbOBbcwEPHo4-PioWeAbzwcTOQ@mail.gmail.com) by default.

However, remember that checksums are disabled by default in PostgreSQL through version 17, so you must enable them when creating a cluster. If data checksums are not enabled, PostgreSQL provides a tool called [pg_checksums](https://www.postgresql.org/docs/current/app-pgchecksums.html). This tool allows you to enable, disable, or verify checksums, but it only works when the cluster **is offline**.

<br>
ℹ️  TIPS: If you have a replica in the cluster, you can reduce downtime by enabling checksums on the replica first. Then, perform the switchover and enable checksums on the old primary last.
<br>
While enabling checksums provides a baseline for detecting corruption, additional proactive measures are necessary to ensure complete data integrity.

### Detecting Checksum Errors Proactively
To further enhance data integrity beyond routine read operations, proactive tools should be used for verifying the entire PGDATA directory. While PostgreSQL reports checksum errors when a corrupted page is read from disk, it only detects issues on pages that are actually accessed. This means that if a page is never read, any corruption present on it might go unnoticed.

One option is the pg_checksums tool, which can verify the checksums of the cluster directory. The images below shows examples of how checksum verification and enabling checksums are performed using the pg_checksums tool.


![integrity2](/assets/posts/integrity2.png)

However, as mentioned above, it only works when the database is offline, which may not be practical for production environments. This is where the backup system WAL-G comes to the rescue.

-----

## WAL-G: Ensuring Data Integrity in Backups

ℹ️ Note: Checksum verification during the backup process is available not only in WAL-G but also in other popular tools, such as pgBackRest and Barman.

WAL-G allows the verification of checksums of all data pages during the backup process without requiring downtime. By using the [--verify](https://wal-g.readthedocs.io/PostgreSQL/#page-checksums-verification) option when creating backups, WAL-G reads and verifies the checksum of every page it backs up. This ensures that any corrupted pages are detected, even if they are not frequently accessed in the running database. WAL-G produces logs that show if any issues arise during the process. It is crucial to monitor these logs for any WARNING or ERROR messages.

![integrity3](/assets/posts/integrity3.png)

Another option is [--wal-verify](https://wal-g.readthedocs.io/PostgreSQL/#wal-verify), which checks the integrity of WAL archives. This allows you to ensure that all necessary WAL files for point-in-time recovery are present. If any WAL files are missing in the chain, it will result in an inability to perform a successful point-in-time recovery.

![integrity4](/assets/posts/integrity4.png)

WAL-G performs an [integrity check](https://wal-g.readthedocs.io/PostgreSQL/#integrity) of WAL segments in three stages.

1. **MISSING_DELAYED**:

    During the first step, WAL-G analyzes the segments starting from the current LSN. It checks for missing segments in storage up to the limit set by the **WALG_INTEGRITY_MAX_DELAYED_WALS** variable (default is 0) and marks them as MISSING_DELAYED. The scan stops when the first existing segment is found.

    For example, if the value of **WALG_INTEGRITY_MAX_DELAYED_WALS** is 5, missing segments within the range from the current LSN to 5 segments back will be marked as MISSING_DELAYED. This indicates that PostgreSQL likely has not yet tried to archive them using archive_command.

2. **MISSING_UPLOADING**:

    In the second step, WAL-G continues scanning for missing segments. The scanning starts from the point where the previous scan (MISSING_DELAYED) ended. It checks for up to the number of segments specified by the **WALG_UPLOAD_CONCURRENCY** variable (default is 16). Missing segments found within this range are marked as MISSING_UPLOADING.

    For example, if the value of **WALG_UPLOAD_CONCURRENCY** is 5, up to 5 consecutive missing segments from the point where the second stage scan begins will be marked as MISSING_UPLOADING. WAL-G assumes they are still being uploaded.

3. **MISSING_LOST**:

    If WAL-G finds missing segments from storage that do not fall into either the MISSING_DELAYED or MISSING_UPLOADING categories, they will be marked as MISSING_LOST. This means that these segments have been lost and cannot be recovered.

The output of the integrity check provides information regarding the status of WAL segments in chronological order, grouped by timeline and status:
 - **OK**: Indicates that there are no missing segments.
 - **WARNING**: Indicates that some segments are missing, but they are not categorized as MISSING_LOST.
 - **FAILURE**: Indicates that there are segments marked as MISSING_LOST, which signifies a critical issue.

![integrity5](/assets/posts/integrity5.png)

Thus, with WAL-G, you can check the availability of segments based on the configured parameters. This process allows for reliable tracking of segment statuses and ensures a robust data recovery mechanism.


### Bug Fix in Checksum Verification

Recently, a [bug was identified in WAL-G’s checksum verification system up to v3.0.3](https://github.com/wal-g/wal-g/issues/1140). Files with unusual/non-standard sizes were excluded from the checksum verification, but a fix has already been prepared, and [the upcoming latest release](https://github.com/wal-g/wal-g/releases/) will warn users of potential issues. Remember to update WAL-G when [v3.0.4](https://github.com/wal-g/wal-g/releases/tag/v3.0.4) version is is out (the pre-release is there already) to benefit from these improvements.

![integrity6](/assets/posts/integrity6.png)

Additionally, there is a change in behaviour regarding checksum verification. When the –verify flag is set in the backup-push command, WAL-G will check whether data checksums are enabled. If checksums are disabled, the user will receive a warning, and verification will be skipped during the backup process.

```bash
WARNING: 2024/10/18 08:59:27.916554 data_checksum is disabled in the database.Skipping checksum validation, which may result in undetected data corruption.
```

-----

## Conclusions
To keep your data safe, you must:
1. Enable checksum validation on your database.
2. Monitor your backup process and set alerts for any issues.
3. It’s also important to have a dedicated system for restoring backups and performing checks.
4. Finally, always use the latest version of WAL-G to take advantage of all the latest features and bug fixes.

-----

## Disclaimer
It is common to see attempts to use **pg_dump** for checksum verification. The main idea behind using it is to force PostgreSQL to read the data, thereby checking the checksums. If pg_dump completes without errors, it suggests there is no corruption. However, this method has limitations due to two main issues that you should consider:

1. **Incomplete Coverage: pg_dump** may not capture all database objects (system tables may be excluded), and if these objects are corrupted, **pg_dump** will not detect it.

2. **Potential False Positives: pg_dump** reads data from the database where a page might reside in **Shared Buffer** (not dirty) and can retrieve it without issues. However, the version of that page on disk might contain corruption, which PostgreSQL will not detect, as it returns data from **Shared Buffer** without checking the checksum; checksums are verified only when reading pages from disk.

Given these points, it is advisable to utilize specialized solutions for checksum verification, such as WAL-G. These solutions are designed to ensure comprehensive integrity checks and are optimized for lower resource consumption, helping to detect corruption more effectively than **pg_dump** alone.