---
layout: post
title: How Golang Talks to PostgreSQL (Simple vs Extended Protocol)
date: 2025-12-20
---

Most articles about PostgreSQL's Extended Protocol focus on the ability to parse and plan a query once and reuse it — and that's important. But they often overlook another powerful feature: **binary format** for data transfer. That's what I want to explore in detail in this article, and how it's handled by the two main PostgreSQL libraries in Go: **pgx** and **pq**.

But first, let's review the basics of the PostgreSQL wire protocol and the key differences between Simple and Extended Protocol.

<!--MORE-->

-----

## Table of Contents

- [Protocol Overview](#protocol-overview)
- [Binary vs Text Format](#binary-vs-text-format)
- [Real-World Test: Measuring Network Traffic with strace](#real-world-test-measuring-network-traffic-with-strace)
- [Driver Comparison: pgx vs pq](#driver-comparison-pgx-vs-pq)
- [Why Binary Format Matters in the Real World](#why-binary-format-matters-in-the-real-world)
- [Conclusion](#conclusion)

## Protocol Overview

PostgreSQL supports two main client protocols: Simple Query Protocol and Extended Query Protocol. The difference between them affects both performance and flexibility when working with PostgreSQL from Go.

The Simple Protocol sends the entire SQL statement as a single string, and PostgreSQL runs all steps — Parse, Analyze, Rewrite, Plan, and Execute — in a single round. It's easy to use but not optimized for reusing queries, since all steps are repeated on every call.

The Extended Protocol, on the other hand, splits the process into separate steps: Parse, Bind, and Execute. This allows better reuse of parsed and planned queries, reducing server workload. It also supports binary format for both input and output, which can significantly improve performance and reduce memory usage, especially for large datasets.

Extended Protocol also enables prepared statements. These help reduce overhead by separating query parsing and planning from execution. However, PostgreSQL does not reuse a plan immediately. Instead, it runs the query up to five times with different parameters, collecting custom plans. After that, it may decide to switch to a generic plan, which is based on average parameter values. This choice depends on internal cost estimation.

> 🧠 As a DBA, you can control this behavior using the `plan_cache_mode` setting, which [allows you to force](https://postgresqlco.nf/doc/en/param/plan_cache_mode/) generic or custom plan usage.
>
> There is a known issue with generic/custom plan selection when working with partitioned tables. In addition, query planning can be negatively affected by data skew and uneven data distribution. The authors of [pg_mentor](https://github.com/danolivo/pg_mentor) extension are trying to address these problems — I recommend checking it out for a deeper understanding.

---

## Binary vs Text Format

Within Extended Protocol, the client can control the data transfer format — for each parameter and each result column, you can specify whether to use text format or binary format. This can significantly reduce the amount of data sent over the network, avoid expensive text parsing on the client side, and lower serialization overhead — especially when working with types like UUID, INT, BOOL, BYTEA, TIMESTAMP, and others.

By default, most drivers use text format. However, pgx allows you to easily switch to binary format, which improves performance with large data volumes or frequently executed queries.

In the PostgreSQL documentation, these formats are called:
- **Text format** — format code = 0
- **Binary format** — format code = 1

This is officially described in the [PostgreSQL Frontend/Backend Protocol: Message Formats](https://www.postgresql.org/docs/current/protocol-message-formats.html), in the Bind message specification:

> "The parameter format codes. Each must presently be zero (text) or one (binary)."
>
> "The result-column format codes. Each must presently be zero (text) or one (binary)."

So binary format is not a separate protocol — it's a capability within Extended Protocol, controlled via format codes at the Bind and Execute level.

Here's a comparison of how much space different PostgreSQL data types use in text vs binary format:

| Data Type | Example Value | Text Format | Binary Format |
|-----------|---------------|-------------|---------------|
| UUID | 550e8400-e29b-41d4-a716-446655440000 | 36 bytes | 16 bytes |
| INTEGER | 1234567890 | 10 bytes | 4 bytes |
| BIGINT | 9223372036854775807 | 19 bytes | 8 bytes |
| BOOLEAN | TRUE | 4 bytes | 1 byte |
| TIMESTAMP | 2024-04-02 19:23:00.123456+00 | 29 bytes | 8 bytes |
| BYTEA | \xDEADBEEF | 10 bytes | 4 bytes |
| TEXT | Hello, world! | 13 bytes | 13 bytes |

As shown above, using binary format can reduce payload size dramatically — for example, a UUID shrinks from 36 to 16 bytes. This matters when dealing with large result sets or frequent queries.

---

## Real-World Test: Measuring Network Traffic with strace

To verify this in practice, I measured actual bytes transferred from PostgreSQL using `strace` on Linux.

**Test setup:**
- Table with 100,000 rows
- Columns: 2× UUID, 2× TIMESTAMP, INTEGER, BIGINT, BOOLEAN
- Query: `SELECT id, user_id, created_at, updated_at, val_int, val_big, val_bool FROM test_data`

**Results:**

| Driver | Protocol | Bytes Read | Difference |
|--------|----------|------------|------------|
| pgx | simple | 17.7 MB | baseline |
| pgx | extended | 9.6 MB | **−46%** ✅ |
| pq | simple | 17.8 MB | baseline |
| pq | extended | 17.8 MB | no change |

**Key takeaways:**
- **pgx with Extended Protocol** saved 8.1 MB (46%) thanks to binary format
- **pq showed no improvement** — it receives results as text even with Extended Protocol
- Biggest savings came from UUID (36→16 bytes) and TIMESTAMP (26→8 bytes)

🔗 Test code: [github.com/boosterKRD/boosterKRD.github.io](https://github.com/boosterKRD/boosterKRD.github.io/tree/main/tests/golang-postgresql-binary-protocol/README.md)

---

## Why Binary Format Matters in the Real World

Even if a query returns just one row, using binary format can make a real difference — especially when that row has multiple non-text columns like UUID, BIGINT, TIMESTAMP, or BYTEA.

A single SELECT with 5–7 such fields in text format can easily generate 2–3 times more data than the same query in binary format. This increases:

- **Network traffic** (more bytes to send)
- **CPU load on PostgreSQL and PgBouncer** (more to serialize and buffer)
- **Client-side CPU and memory usage** (more parsing, more allocations, more GC)

With binary format, pgx can deserialize values with fewer allocations and less CPU overhead — directly into native Go types.

> 💡 For apps running thousands of queries per second, or handling large result sets, these savings add up quickly.

---

## Driver Comparison: pgx vs pq

### PGX

pgx [uses](https://pkg.go.dev/github.com/jackc/pgx/v5#QueryExecMode) Extended Protocol by default (`QueryExecModeCacheStatement`), fully supports binary format, and provides fine-grained control over the protocol.

**pgx: Query Execution Modes**

| QueryExecMode                             | Protocol | Round-Trips | Prepared | Named | Plan Cache | Short Description                                                         |
| ----------------------------------------- | -------- | ----------- | -------- | ----- | ---------- | ------------------------------------------------------------------------- |
| `QueryExecModeCacheStatement` *(default)* | Extended | 2 → 1       | ✅        | ✅     | ✅          | Named prepared statements; Parse+Describe first, then 1 RT (cached)       |
| `QueryExecModeCacheDescribe`              | Extended | 2 → 1       | ⚠️        | ❌     | ❌          | Caches metadata only; Parse+Describe first, then 1 RT; no named statements|
| `QueryExecModeDescribeExec`               | Extended | 2           | ⚠️        | ❌     | ❌          | Parse+Describe, then Bind+Execute; always 2 round-trips                   |
| `QueryExecModeExec`                       | Extended | 1           | ❌        | ❌     | ❌          | Extended protocol with text encoding; infers param types from Go types    |
| `QueryExecModeSimpleProtocol`             | Simple   | 1           | ❌        | ❌     | ❌          | Client-side parameter interpolation                                       |

### PQ

lib/pq uses the Simple Query Protocol for queries without parameters. When query parameters are present, it uses the Extended Query Protocol for parameter binding, but without exposing prepared statements or statement caching. As a result, each parameterized query incurs a full Parse → Bind → Execute cycle on the server. Query results are always received in text format, making lib/pq less efficient when working with large volumes or complex data types.

**lib/pq: Query Execution Model**

| Mode               | Protocol | Round-Trips | Prepared | Named | Plan Cache | Short Description                                          |
| ------------------ | -------- | ----------- | -------- | ----- | ---------- | ---------------------------------------------------------- |
| *(no parameters)*  | Simple   | 1           | ❌        | ❌     | ❌          | Simple Query Protocol; query and results are text-based    |
| *(with parameters)*| Extended | 2-3         | ❌        | ❌     | ❌        | Parse → Bind → Execute every query; results are still text |

### **Driver Capabilities Overview**

| Feature | pgx | pq |
|---------|-----|-----|
| Default Protocol | Extended | Simple |
| Supports Extended? | ✅ Full | ⚠️ Partial |
| Binary Parameters | ✅ Yes | ✅ Partial (bytea, time.Time) |
| Binary Results | ✅ Yes | ❌ No (always text) |
| Control Over Protocol | ✅ Fine-grained | ❌ Limited |
| AfterConnect Hook | ✅ Yes | ❌ No |
| Use in High-Perf Apps | ✅ Recommended | ⚠️ Not optimal |

> ⚠️ **Note:** pq is simple and stable, but lacks flexibility and performance optimizations like binary decoding. For large data sets or real-time systems, pgx is the better choice.

---

## Conclusion

**1. Use pgx** — it's the better choice for performance-critical applications in Go.

**2. Extended Protocol gives you real advantages:**
- Binary results (less network traffic)
- Prepared statements (skip Parse/Plan phases on repeated queries)

**3. But Extended Protocol is not a silver bullet:**

- **Extra round trips.** If your library doesn't support or isn't configured for named cached statements, you still run the Plan phase every time — plus you pay for additional round trips, which can negate all benefits.

- **Unique queries problem.** If your workload generates thousands or tens of thousands of unique queries, prepared statements won't help — each query is parsed and planned only once anyway.

* **Connection pooler compatibility.** Not all poolers work correctly with Extended Protocol or named prepared statements. For example, AWS RDS Proxy doesn't support Extended Protocol at all — it will cause connection pinning or errors. PgBouncer 1.21+ supports prepared statements in transaction pooling mode. Older versions of PgBouncer require `QueryExecModeExec` or `QueryExecModeSimpleProtocol` to avoid "prepared statement does not exist" errors. Test your specific pooler configuration separately.

> **Extended Protocol and binary format are powerful optimizations, but you need to understand your workload and infrastructure to get the full benefit.**
