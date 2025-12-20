---
layout: post
title: How to Handle Bloat in PostgreSQL
date: 2026-01-02
---

PostgreSQL tables and indexes tend to accumulate bloat over time due to how the MVCC model handles updates and deletes. This guide helps you detect and safely remove bloat using proven, production-ready techniques. It covers lightweight and in-depth analysis methods, explains when action is needed, and shows how to clean up bloated tables and indexes with minimal disruption — before performance or storage become a concern.

<!--MORE-->

-----

## How This Guide Can Help

If you're seeing storage grow faster than expected, or queries getting slower for no clear reason — bloat may be the cause.

This guide will help you:

- Spot and estimate bloat without impacting performance
- Decide when and how to act, using safe, production-friendly tools

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Why Bloat Happens](#2-why-bloat-happens)
3. [Estimating Bloat](#3-estimating-bloat)
   - 3.1 [Lightweight Methods (SQL)](#31-lightweight-estimation-sql-based)
   - 3.2 [In-depth Methods (pgstattuple)](#32-accurate-estimation-pgstattuple-based)
4. [Interpreting Results and Deciding When to Act](#4-interpreting-results-and-deciding-when-to-act)
5. [Fixing Bloat](#5-fixing-bloat)
   - 5.1 [Index-only Fix (REINDEX)](#51-rebuilding-indexes-with-reindex-concurrently)
   - 5.2 [Full Table Repack (pg_repack)](#52-repacking-tables-with-pg_repack)
6. [Safety Tips and Space Requirements](#6-safety-tips-and-space-requirements)
7. [Summary](#7-summary)

---

## 1. Introduction

PostgreSQL uses a Multi-Version Concurrency Control (MVCC) model to ensure high concurrency and data consistency. But this mechanism comes with a hidden cost: PostgreSQL does not immediately overwrite or remove rows that are updated or deleted. Instead, it creates new versions and leaves the old ones behind as "dead tuples" — invisible to queries, but still occupying disk space.

Over time, this leads to internal fragmentation, known as **bloat**.

Bloat affects both tables and indexes, and is especially harmful in high-velocity transactional systems. If left unmanaged, it gradually degrades database performance and increases operational costs.

### Consequences of Bloat

| Impact Area | Description |
|-------------|-------------|
| **Storage costs** | Bloated tables and indexes can consume 2–5× more space than needed, increasing storage and backup requirements |
| **Query performance** | More I/O is required to read the same amount of data; query execution becomes slower |
| **Maintenance efficiency** | Autovacuum works less efficiently, especially when scanning bloated indexes |

---

## 2. Why Bloat Happens

Bloat is a natural side effect of PostgreSQL's MVCC design. It accumulates due to:

- **Frequent UPDATEs and DELETEs** - each change creates a new row version and marks the old one as dead. If VACUUM doesn't clean it up in time, the space stays occupied.
- **Insufficient Autovacuum Frequency** - if autovacuum runs too rarely, PostgreSQL writes new data to fresh pages instead of reusing space, causing table growth.
- **Long-running Transactions** - they block VACUUM from reclaiming dead tuples by holding back the xmin horizon.
- **Mass DELETEs** - large batch deletions generate many dead rows at once, which can't be reused unless followed by INSERTs.

---

## 3. Estimating Bloat

Before you can fix bloat, you need to understand where it lives — and how bad it is. PostgreSQL doesn't track bloat explicitly, so you need to estimate it using either catalog-based queries or low-level inspection tools.

There are two main approaches:

### 3.1 Lightweight Estimation (SQL-based)

This method uses system catalog statistics (like `pg_stat_user_tables` and `pg_stats`) to estimate how much space is wasted in tables and indexes. These queries are safe to run even on busy production systems.

| Pros | Cons |
|------|------|
| Very fast and safe | Estimates only — results may be inaccurate if statistics are outdated |
| No impact on performance | Cannot detect TOAST bloat or deduplication in indexes |
| Can be automated and scheduled regularly | Index bloat estimation is especially unreliable for complex cases |

**Recommended scripts** by [ioguix](https://github.com/ioguix/pgsql-bloat-estimation):

- [Table bloat estimation](https://github.com/ioguix/pgsql-bloat-estimation/blob/master/table/table_bloat.sql) (non-superuser)
- [Index bloat estimation](https://github.com/ioguix/pgsql-bloat-estimation/blob/master/btree/btree_bloat.sql) (requires superuser)

### 3.2 Accurate Estimation (pgstattuple-based)

The [pgstattuple extension](https://www.postgresql.org/docs/current/pgstattuple.html) inspects the physical layout of tables and indexes to provide accurate bloat information. It has two modes of operation:

- **`pgstattuple()`** — performs a full-table scan and returns exact statistics for live tuples, dead tuples, and free space. Works for both tables and indexes.
- **`pgstattuple_approx()`** — a faster alternative that uses the visibility map to skip pages containing only visible tuples, returning approximate results. This function works only for tables, not indexes.

| Pros | Cons |
|------|------|
| Accurate low-level bloat data (for both tables and indexes) | Can generate significant I/O load, especially on large indexes |
| Includes TOAST bloat | May still read large parts of the table, depending on vacuum status |

I recommend using this method selectively — for the most critical tables and indexes only — and ideally during non-peak hours. Example scripts are available in the GitHub repository: [table_bloat_approx.sql](https://github.com/dataegret/pg-utils/blob/master/sql/table_bloat_approx.sql) for tables and [index_bloat.sql](https://github.com/dataegret/pg-utils/blob/master/sql/index_bloat.sql) for indexes.

> 💡 **Tip:** Start with lightweight estimation to identify likely candidates, then validate the most suspicious objects using `pgstattuple`.

---

## 4. Interpreting Results and Deciding When to Act

Once you have estimated the level of bloat in your tables and indexes, the next step is deciding what to do with that information. Not all bloat is equally harmful, and trying to remove every bit of it may waste time and resources.

### Recommended Thresholds

| Object Type | Threshold | Action |
|-------------|-----------|--------|
| **Tables** | > 20% bloat | Consider repacking |
| **Tables** | > several GB (even at lower %) | Action may still be justified |
| **Indexes** | > 40% bloat | Consider rebuilding |
| **Indexes** | 20–30% bloat (frequently scanned) | Consider rebuilding if query performance is degraded |

> 💡 **Tip:** These thresholds are not strict rules — context matters. For example, a 5 GB table with 50% bloat may be less critical than a 100 GB table with 20% bloat that's accessed constantly.

---

## 5. Fixing Bloat

Once you've identified bloated tables and indexes that require action, PostgreSQL provides several safe options to clean them up with minimal downtime.

I recommend starting with the least intrusive method that suits your situation, especially on production systems.

### 5.1 Rebuilding Indexes with REINDEX CONCURRENTLY

PostgreSQL's built-in `REINDEX CONCURRENTLY` command allows you to rebuild an index without blocking reads or writes.

**When to use:**

- You've identified bloated indexes (typically >40% bloat)
- The table itself is not bloated, or you want to avoid a full table rewrite
- You want a quick, safe fix with minimal impact on application queries

```sql
REINDEX INDEX CONCURRENTLY idx_users_email;
```

| Pros | Cons |
|------|------|
| Safe to use in production | Only applies to indexes (not tables) |
| No long locks on the table | Requires disk space for the new index copy |
| No external tools required | Slower than standard REINDEX due to concurrent safety |

> 💡 **Tip:** Focus on indexes that are frequently scanned or used in JOIN/WHERE conditions.

### 5.2 Repacking Tables with pg_repack

For bloated tables, [pg_repack](https://github.com/reorg/pg_repack) is the most reliable and widely used option. It rewrites the table and its indexes in the background, allowing continued read/write access during the operation.

**When to use:**

- Tables with significant bloat (>20%)
- Large tables that can't be locked for extended periods
- When you need to clean both the table and its indexes in one operation

```bash
pg_repack -d mydb -t bloated_table
```

| Pros | Cons |
|------|------|
| Cleans both tables and their indexes in one run | Requires installation of the pg_repack extension |
| Minimal locking (only at start/end of operation) | Needs additional disk space (typically 2–3× table size) |
| Supports parallel jobs and custom ordering | May briefly block DDLs or long-running queries |

I recommend running `pg_repack` directly on the database server via a terminal multiplexer (e.g., `tmux`, `screen`) to avoid session drops during long-running operations.

> ⚠️ **Warning:**
>
> - If you run pg_repack remotely and the connection drops (e.g., via SSH or load balancer), it can leave behind long-lived locks and block access to the table — especially with `--no-kill-backend`. See: [pg_repack issue](https://github.com/reorg/pg_repack/issues/456)
> - If a repack operation fails or is interrupted, use the documented cleanup steps to remove temporary objects before retrying. Don't skip cleanup — leftover objects can block future repack attempts.

---

## 6. Safety Tips and Space Requirements

Fixing bloat is safe — if done correctly. But repacking large tables or rebuilding large indexes can temporarily increase disk usage and create unexpected load on the system.

### 6.1 Disk Space Planning

Repacking and rebuilding objects require temporary space to hold the new copies.

| Scenario | Recommended Free Space |
|----------|----------------------|
| Standard operations | **2×** the size of the table or index |
| Very large tables | **3×** free space (accounts for temporary objects, WAL, sorting/buffering) |

### 6.2 Timing Recommendations

Even though `REINDEX CONCURRENTLY` and `pg_repack` are designed for online use, they can still:

- Increase I/O (especially for large objects)
- Delay autovacuum
- Create lock contention during short critical phases

**Best practices:**

- Run during maintenance windows when possible
- Process in small batches (e.g., one table/index at a time)
- Avoid peak traffic hours

### 6.3 Monitor Blocking and Sessions

During the critical locking phase at the start and end of `pg_repack`, queries that touch the same table will be blocked briefly.

**Recommendations:**

- Use `--wait-timeout` to control how long it waits for locks
- Consider `--no-kill-backend` if you prefer to wait rather than terminate conflicting sessions
- Actively monitor blocked queries (`pg_stat_activity`) during the operation

---

## 7. Summary

Bloat in PostgreSQL is a common but often overlooked issue that can silently degrade performance and waste disk space.

### Recommended Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│  1. ESTIMATE                                                    │
│     Use lightweight SQL queries or pgstattuple extension        │
├─────────────────────────────────────────────────────────────────┤
│  2. ANALYZE                                                     │
│     Apply thresholds: >20% for tables, >40% for indexes         │
├─────────────────────────────────────────────────────────────────┤
│  3. FIX                                                         │
│     Use REINDEX CONCURRENTLY (indexes) or pg_repack (tables)    │
└─────────────────────────────────────────────────────────────────┘
```

By following these steps, you can keep your PostgreSQL database lean, fast, and cost-efficient.

---

## Quick Reference

| Task | Tool | Command Example |
|------|------|-----------------|
| Estimate table bloat | SQL query | [ioguix table_bloat.sql](https://github.com/ioguix/pgsql-bloat-estimation) |
| Estimate index bloat | SQL query | [ioguix btree_bloat.sql](https://github.com/ioguix/pgsql-bloat-estimation) |
| Accurate bloat analysis | pgstattuple | `SELECT * FROM pgstattuple('table_name');` |
| Rebuild index online | PostgreSQL | `REINDEX INDEX CONCURRENTLY idx_name;` |
| Repack table online | pg_repack | `pg_repack -d dbname -t table_name` |
