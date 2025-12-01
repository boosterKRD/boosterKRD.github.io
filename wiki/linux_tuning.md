---
layout: post
title: Linux Tuning 
date: 2025-07-10
---

Here I’m posting a series of mini-posts related to OS parameters that can be tuned to improve PostgreSQL performance.

1. [vm.dirty_*](#tuning-vmdirty_bytes-and-vmdirty_background_bytes-for-postgresql)
2. [HugePages (post coming soon)](#tuning-hugepages--for-postgresql)

# Tuning vm.dirty_bytes and vm.dirty_background_bytes for PostgreSQL

## Introduction

PostgreSQL writes most user data to disk through the operating system’s page cache — it doesn’t use O_DIRECT. 

When the system is under heavy write load — or when shared_buffers is too small to absorb changes — PostgreSQL has to frequently write buffers to the OS. This, in turn, increases pressure on the Linux page cache, where dirty pages may start accumulating.

If too many dirty pages pile up in the OS page cache and the kernel is forced to flush a large amount of dirty data under pressure, this can result in I/O stalls that negatively affect performance.

To help control this behavior, Linux provides several parameters that define when dirty memory should be flushed, and when the kernel must pause write activity to avoid memory pressure:

* vm.dirty_background_bytes
* vm.dirty_bytes
* vm.dirty_background_ratio
* vm.dirty_ratio
* vm.dirty_writeback_centisecs

These parameters define when the kernel should start flushing dirty memory in the background, and when it must forcefully block writing processes to prevent memory overload.

> Important: PostgreSQL doesn’t just passively rely on Linux’s background flush mechanisms. Many internal processes — especially the checkpointer and background writer — proactively trigger flushing of dirty data to disk.
> As a result, dirty pages are often flushed to disk before the kernel’s periodic timers (like vm.dirty_writeback_centisecs) are even triggered.
> However, if other non-PostgreSQL processes generate large volumes of dirty data without requesting flushes, or if the total write load is high, kernel thresholds such as vm.dirty_bytes still play a critical role in avoiding write stalls.

## Why You Might Care

The vm.dirty_* parameters discussed in this post are usually **not critical** for performance on most PostgreSQL clusters with typical workloads.
However, in large-scale deployments — such as high-throughput nodes or write-heavy systems — these settings become increasingly relevant.

Even if your workload performs well with the default values, it’s still important to understand how these parameters work, how they interact with PostgreSQL, and how to tune them if needed — for example, to avoid unpredictable I/O latency or inefficient disk flushing.

## Parameter Overview
**vm.dirty_background_bytes / vm.dirty_background_ratio**
This is the background flush threshold.
When the amount of dirty memory exceeds this value, the Linux kernel starts flushing dirty pages in the background. The kernel checks this condition every vm.dirty_writeback_centisecs (default = 500 = 5 seconds)

* Purpose: Spread out disk writes evenly over time to avoid I/O spikes
* Setting vm.dirty_background_bytes disables vm.dirty_background_ratio, and vice versa — only one of them can be active at a time.
* This thresholds only affects background flushing, not emergency flushes triggered by vm.dirty_bytes or dirty_ratio.

**vm.dirty_bytes / vm.dirty_ratio**
This is the hard upper limit.
If the amount of dirty memory exceeds this value, the kernel will **block all write() operations from user processes** until enough dirty pages are written to disk — this is known as a write stall.

* Purpose: Prevent the system from being overloaded with too much dirty data
* The system flushes aggressively at this point, and may experience delays

>Best practice: Use absolute values (*_bytes) instead of percentages (*_ratio). Memory size may vary across systems and environments, but your I/O thresholds should correlate with actual disk bandwidth — not available RAM.

## Checking System-Wide Write Activity

Before adjusting any kernel parameters, it's important to understand how much data your system actually writes — not just from PostgreSQL, but from all active processes.

Use the tools below to estimate:

1. Check current dirty and writeback memory totals
This shows how much data is currently dirty (in page cache) and how much is in the process of being flushed to disk:

```bash
egrep '^(Dirty|Writeback):' /proc/meminfo
```
Output fields:

- Dirty – Total dirty memory (not yet flushed).
- Writeback – Memory being actively written to disk.

2. Identify which processes are writing to disk
Accumulates total disk I/O per process — helps spot heavy background writers.
```bash
sudo iotop -ao
```

3. Inspect per-process I/O statistics
You can examine detailed I/O activity for specific PostgreSQL backends (e.g. checkpointer, bgwriter, client backend):
```bash 
# Replace <pid> with the actual process ID
# https://www.man7.org/linux/man-pages/man5/proc_pid_io.5.html
cat /proc/<pid>/io
```
Relevant fields:

- write_bytes – Total bytes physically written to disk by this process (i.e. flushed, not just written to page cache).
- cancelled_write_bytes – Bytes scheduled for write, but later skipped — e.g. if the kernel flushed them early, the file was deleted, or the process exited before writeback.

4. Compare dirty memory usage against kernel thresholds
This command shows how close the system is to hitting the write throttling limit (vm.dirty_bytes):

```bash
awk '/nr_dirty / {d=$2} /nr_dirty_threshold / {t=$2} END {printf "Dirty: %d | Threshold: %d | Used: %.2f%%\n", d, t, 100*d/t}' /proc/vmstat
```
Output shows:

- Dirty – Number of dirty pages in memory.
- Threshold – Maximum allowed before throttling starts.
- Used – Percentage of threshold currently consumed.

> ⚠️ If this value often gets close to 100%, it means the system is struggling to flush dirty memory fast enough. Possible actions:
> – Lower vm.dirty_background_bytes to trigger flushing earlier
> – Investigate disk I/O throughput — your disks may simply not keep up under load
> – Review overall write activity (e.g., via iotop -ao) — noisy neighbors may contribute

## (Optional) Estimating PostgreSQL Write Volume

While not required for tuning kernel parameters, it may be useful to estimate how much data PostgreSQL itself writes — for diagnostics, comparison, or curiosity.

by different PostgreSQL components:
### For PostgreSQL <=16
```sql
-- Note: These values are cumulative. Run the query twice with a pause (e.g. 60s) and subtract to get per-second rate.
-- Ideally, run during peak load periods to capture the maximum dirty data generation rate.
WITH data AS (
  SELECT 'checkpointer' AS source, buffers_checkpoint * current_setting('block_size')::int AS written_bytes
  FROM pg_stat_bgwriter
  UNION ALL
  SELECT 'bgwriter', buffers_clean * current_setting('block_size')::int
  FROM pg_stat_bgwriter
  UNION ALL
  SELECT 'backend', buffers_backend * current_setting('block_size')::int
  FROM pg_stat_bgwriter
  UNION ALL
  SELECT 'temp files', SUM(temp_bytes)
  FROM pg_stat_database
)
SELECT * FROM data
UNION ALL
SELECT 'TOTAL', SUM(written_bytes) FROM data;
```

**Column Descriptions**

| Column          | Meaning                                                                 |
|-----------------|-------------------------------------------------------------------------|
| `source`        | Write source: checkpointer, bgwriter, backend, or temp files            |
| `written_bytes` | Total bytes written by this source.                                     |

### For PostgreSQL >=17
```sql
-- Note: Cumulative values. To calculate write rate, run the query twice with a time gap and compare.
-- For more realistic tuning, collect the data during periods of high write activity.
SELECT
  backend_type,
  context,
  object,
  writes * op_bytes AS written_bytes,
  writebacks * op_bytes AS writeback_bytes
FROM pg_stat_io
WHERE object IN ('relation', 'temp relation')
  AND writes > 0
UNION ALL
SELECT
  'TOTAL' AS backend_type,
  NULL AS context,
  NULL AS object,
  SUM(writes * op_bytes) AS written_bytes,
  SUM(writebacks * op_bytes) AS writeback_bytes
FROM pg_stat_io
WHERE object IN ('relation', 'temp relation')
  AND writes > 0
ORDER BY backend_type;
```

**Column Descriptions**

| Column             | Meaning                                                                 |
|--------------------|-------------------------------------------------------------------------|
| `backend_type`     | Type of PostgreSQL process (e.g. checkpointer, client backend, etc.).   |
| `context`          | I/O context of the write (e.g. `normal`, `vacuum`, `bulkwrite`).         |
| `object`           | Type of object written (`relation` = table/index, `temp relation` = temp file). |
| `written_bytes`    | Total number of bytes written (dirtied) by this backend and object type. |
| `writeback_bytes`  | Number of bytes for which this backend triggered flushing to disk.       |

> To reset pg_stat_io statistics use the following query SELECT pg_stat_reset_shared('io');

## Summary

Tuning dirty memory settings isn’t always necessary — PostgreSQL already does a good job managing its own I/O. But in high-write environments, large deployments, or mixed-use servers, Linux defaults may not be optimal.

### Key Points

* Understand roles: PostgreSQL writes to page cache, Linux handles flushing
* Measure before tuning: check both PostgreSQL and system-wide activity
* Use absolute byte values for tuning dirty memory thresholds

### Tuning Hints
Use the following guidance to tune your dirty memory thresholds:

* vm.dirty_bytes: Set to 50–85% of your disk write bandwidth. Helps avoid sudden write stalls under high load.
* vm.dirty_background_bytes: Set to ≈25% of vm.dirty_bytes. Triggers background flushing early enough to prevent I/O bursts.
  

# Tuning HugePages for PostgreSQL
