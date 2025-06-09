---
layout: post
title: Linux Tuning 
date: 2025-06-09
---

Here I’m posting a series of mini-posts related to OS parameters that can be tuned to improve PostgreSQL performance.

1. [vm.dirty_*](#tuning-vmdirty_bytes-and-vmdirty_background_bytes-for-postgresql)
2. [HugePages (post coming soon)](#tuning-hugepages--for-postgresql)

# Tuning vm.dirty_bytes and vm.dirty_background_bytes for PostgreSQL

### Disclaimer
The vm.dirty_* parameters discussed in this mini-post are not critical for performance on most PostgreSQL clusters with typical workloads.
However, for large-scale deployments—heavy workloads, high-throughput nodes, or large clusters—every detail starts to matter, including these Linux dirty memory settings.

Even if your current workload performs well with the defaults, you should understand what these parameters do, how they interact with PostgreSQL’s write behavior, and how to tune them effectively when needed.

Let’s dive in.

PostgreSQL writes most user data to the OS page cache (it doesn’t use O_DIRECT). In some setups — for example, when shared_buffers is small or the checkpointer runs infrequently — dirty pages may accumulate in memory. If too many dirty pages accumulate and the kernel is forced to flush them all at once, it can cause sudden I/O stalls that affect overall performance.

To avoid such issues, it’s important not only to understand how Linux manages dirty memory and how PostgreSQL contributes to it, but also to configure these parameters properly (especially on systems with large amounts of RAM).
Linux provides the following parameters to control dirty memory flushing behavior:
* vm.dirty_background_bytes
* vm.dirty_bytes
* vm.dirty_background_ratio
* vm.dirty_ratio
* vm.dirty_writeback_centisecs
⸻

## Parameter overview
**vm.dirty_background_bytes / vm.dirty_background_ratio**
This is the background flush threshold.
When the amount of dirty memory exceeds this value, the Linux kernel starts flushing dirty pages in the background. The kernel checks this condition every vm.dirty_writeback_centisecs (default = 500 = 5 seconds)

* Purpose: Spread out disk writes evenly over time to avoid I/O spikes
* Setting vm.dirty_background_bytes disables vm.dirty_background_ratio, and vice versa — only one is active at a time.
* This thresholds only affects background flushing, not emergency flushes triggered by vm.dirty_bytes.

**vm.dirty_bytes / vm.dirty_ratio**
This is the hard upper limit.
If the amount of dirty memory exceeds this value, the kernel will **block all write() operations from user processes** until enough dirty pages are written to disk — this is known as a write stall (see explanation in kernel docs).

* Purpose: Prevent the system from being overloaded with too much dirty data
* The system flushes aggressively at this point, and may experience delays

> Note: It is considered best practice to configure dirty_background_bytes and dirty_bytes using absolute byte values rather than percentage-based settings like dirty_background_ratio and dirty_ratio. Memory size can vary across servers, environments, or after hardware upgrades, while these thresholds should not depend on RAM size. Instead, they should consistently correlate with the actual I/O bandwidth of your storage subsystem.

## Estimation of value of vm.dirty_* parameters

* Estimate how much dirty data PostgreSQL generates under normal workload
* Decide how high you can safely set vm.dirty_bytes (e.g., 2GB or 4GB)
* Adjust vm.dirty_background_bytes (e.g., 512MB or 1GB) to avoid long flushes
* Detect if client backends are doing too many writes (bad sign — check checkpointer and bgwriter settings)

With the following queries you can estimate how much dirty data has been written or flushed by different PostgreSQL components:
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
| `written_bytes` | Total bytes written by this source. Calculated using:                  |
|                 | - `checkpointer`: `buffers_checkpoint × block_size`                    |
|                 | - `bgwriter`: `buffers_clean × block_size`                             |
|                 | - `backend`: `buffers_backend × block_size`                            |
|                 | - `temp files`: SUM of `temp_bytes` from `pg_stat_database`            |

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

## Example Scenario
Let’s assume:
* Average write rate from PostgreSQL: 30 MB/s
* Kernel flush interval: 5 seconds (default vm.dirty_writeback_centisecs = 500)
* Disk bandwidth: 2 GB/s (NVMe)
* PostgreSQL is the primary disk user (no other services or tools are actively writing to disk)


### Step-by-step Calculation Example

Most data PostgreSQL writes comes from `shared_buffers`—either via the checkpointer, background writer, or client backends—and heavy temporary-file usage can also generate significant dirty I/O (monitor via `object = 'temp relation'` in `pg_stat_io`). These writes are what the vm.dirty_* settings are meant to manage. Other I/O types like WAL are handled separately and not included in our calculations.

> Note: To apply these calculations, you need to know your disk write bandwidth. You can use tools like fio, dd, or check your cloud provider specs.

| Metric                                           | Value        | Explanation                                                                 |
|--------------------------------------------------|--------------|-----------------------------------------------------------------------------|
| `TOTAL.written_bytes`  | 30 MB/s × 5 s = **150 MB** | Amount of dirty data (estimated earlier) generated during one `dirty_writeback_centisecs` interval. Used to size the `vm.dirty_*` thresholds below. |
| `vm.dirty_bytes`                      | **1.5–1.7 GB** | Set to 50–85% of disk write bandwidth (2 GB/s in this example). Helps avoid unexpected write stalls under high load. |
| `vm.dirty_background_bytes`           | **350–512 MB** | Can be simplified as ~25% of vm.dirty_bytes, but must not be less than the amount of dirty data generated during one flush interval (e.g., TOTAL.written_bytes). Its role is to start background flushing early enough to prevent spikes. |

### Optional: Tune Timer
Reduce vm.dirty_writeback_centisecs to 100–200 (1–2 s) to make the system flush more frequently.

> Be careful not to set vm.dirty_bytes too high, or Linux may delay flushing for too long, causing sudden I/O bursts.

## Cross-checking with OS Tools
While SQL queries help you estimate how much dirty data PostgreSQL produces, they only reflect PostgreSQL activity. If your system runs multiple services (e.g. logging daemons, ETL jobs, or other databases), these may also generate significant disk writes and affect dirty memory.

To get a complete picture of dirty memory usage on the system, use the following OS-level tools:

1. Check total dirty and writeback memory in the system (in kB):
Shows how much data is currently dirty or being written back to disk — across all processes.
```bash
grep Dirty /proc/meminfo
```

2. Identify which processes are writing to disk and how much I/O they generate:
Useful to detect non-PostgreSQL activity that may affect I/O behavior.
```bash
sudo iotop -ao 
```

3. Inspect per-process I/O statistics:
Provides detailed I/O counters for a given PID (e.g. checkpointer or background writer). Replace <pid> with the actual process ID.
```bash
# https://www.man7.org/linux/man-pages/man5/proc_pid_io.5.html
cat /proc/PID/io
```
Look for these fields:

* write_bytes: Total bytes written to disk by this process.
* cancelled_write_bytes: Bytes that were scheduled for write, but later skipped — for example, if the file was deleted before flushing, or if the kernel flushed the dirty pages early (e.g. due to reaching vm.dirty_background_bytes).

4. Compare current dirty memory to kernel thresholds:
Shows how close the system is to hitting the dirty memory limit, which can cause throttling of writes.
```bash
awk '/nr_dirty / {d=$2} /nr_dirty_threshold / {t=$2} END {printf "Dirty: %d | Threshold: %d | Used: %.2f%%\n", d, t, 100*d/t}' /proc/vmstat
```
Output:

* **Dirty** – Number of dirty pages in memory (not yet flushed to disk).
* **Threshold** – Maximum allowed dirty pages before the kernel starts throttling writes.
* **Used** – Percentage of the threshold currently used. Approaching 100% may result in forced flushing or write throttling.

# Tuning HugePages for PostgreSQL
