---
layout: post
title: Huge Pages in PostgreSQL
date: 2026-07-27
---

Huge pages are often described as a general PostgreSQL accelerator. They are not. They solve one specific problem: the cost of translating virtual addresses to physical ones. That cost is invisible in any query plan, it is paid on every memory access, and in PostgreSQL it grows with `shared_buffers` multiplied by the number of backends. This post explains where the overhead comes from, how to measure it on your own server, and when huge pages are worth the operational trouble — and when they are not.

<!--MORE-->

-----

## Table of Contents

1. [Introduction](#1-introduction)
2. [How address translation works](#2-how-address-translation-works)
3. [Why this is specifically a PostgreSQL problem](#3-why-this-is-specifically-a-postgresql-problem)
4. [What happens on a page access](#4-what-happens-on-a-page-access)
5. [Measuring the effect](#5-measuring-the-effect)
6. [Explicit vs Transparent huge pages](#6-explicit-vs-transparent-huge-pages)
7. [PostgreSQL configuration](#7-postgresql-configuration)
8. [Connection poolers as partial mitigation](#8-connection-poolers-as-partial-mitigation)
9. [Trade-offs and when it does not help](#9-trade-offs-and-when-it-does-not-help)
10. [Conclusion](#10-conclusion)

---

## 1. Introduction

Every memory access your backend makes uses a virtual address. The CPU has to turn that into a physical address before it can read anything. This translation is cached in hardware, and when the cache misses, the CPU walks a tree of page tables in memory to find the answer.

With the default 4 KB page size, a 16 GB `shared_buffers` region is described by more than four million separate translation entries — **per backend**. Huge pages replace those 4 KB units with 2 MB ones, cutting the number of entries by a factor of 512.

The benefit therefore scales with two things:

- **how much shared memory you have** — a 1 GB `shared_buffers` has little to gain
- **how many backends touch it** — each process pays the cost independently

If both numbers are large, huge pages remove real overhead. If either is small, they are a rounding error, and the rest of this article explains why.

```
backends: 312
total:    9784.4 MB
per proc: 31.4 MB
```

`PageTables` in `/proc/meminfo` is the system-wide total; `VmPTE` in `/proc/<pid>/status` is the per-process figure. Both are world-readable, so no `sudo` is needed.

Now look at the number:

- **A few hundred MB** — huge pages are not your problem. Read the rest for background, but spend your effort elsewhere.
- **Several GB** — you are paying a real and permanent memory tax to describe memory you already own, and it is worth working through a migration to huge pages.

Re-run the same command after any change. It is the single cheapest before/after check in this article.

---

## 2. How address translation works

Only the minimum needed to follow the rest.

**Pages.** Memory is managed in fixed-size units. On x86-64 the default is 4 KB. Every virtual page needs an entry in a page table that says which physical page it maps to.

**The page table is a tree.** x86-64 uses a four-level structure. Resolving one address that is not cached means walking that tree — several dependent memory reads before the CPU even begins the access you actually asked for. Under virtualization it is worse, because the guest's walk is itself translated.

**The TLB caches translations.** The Translation Lookaside Buffer is a small, very fast cache of recent translations. On a typical modern core:

| Level | Entries (approximate) |
|-------|----------------------|
| L1 data TLB | ~64 |
| L2 shared TLB (STLB) | ~1500–2000 |

A hit is essentially free. A miss triggers the page walk above. The important number is **TLB reach** — how much memory those entries can cover at once:

- 2048 entries × 4 KB = **8 MB**
- 2048 entries × 2 MB = **4 GB**

With 4 KB pages, a backend scanning a 16 GB buffer pool misses the TLB constantly, because 8 MB of reach cannot cover the working set.

**Minor page faults.** A fault is not always disk I/O. If the physical page already exists in memory and the process simply has no page-table entry pointing at it, the kernel fills in the entry and returns. That is a *minor* fault — no I/O, but a trap into the kernel on every first touch. This distinction matters a lot in the next section.

<img src="/assets/posts/hugepages-01-translation.svg" alt="Fig. 1 — address translation path" width="85%">

*Fig. 1 — the address translation path. The highlighted branch is the subject of this article.*

---

## 3. Why this is specifically a PostgreSQL problem

PostgreSQL uses a process-per-connection model. Every backend is a separate OS process created by `fork()`, not a thread. This single design fact causes everything below.

**Each process has its own page table.** All backends map the same physical `shared_buffers`, but each one needs its own private set of translation entries describing it. One physical region, N sets of page tables.

This produces three consequences.

**Consequence 1 — page tables scale with backends.**

Total page-table memory grows as `backends × shared_buffers / page_size`. A thread-based engine shares one address space and simply does not have this linear term. In PostgreSQL it is unavoidable.

**Consequence 2 — warm-up is not shared.** This is the non-obvious one.

Backend A touches an address inside `shared_buffers`. It takes a fault, the kernel fills in A's page-table entry, and subsequent accesses are cheap. Backend B then touches *the same address*, backed by *the same physical page* — and still takes a minor fault, because B's page table is empty at that location. The work A did buys B nothing.

> 🧠 A backend forked from the postmaster inherits a copy of the postmaster's page tables. But the postmaster never touches most of the buffer pool data area during startup — it allocates the region and initializes control structures, not the buffers themselves. So in practice each new backend starts cold and faults its way in from scratch.

**Consequence 3 — the TLB is not shared either.**

TLB entries are tagged per address space. Context switching between backends means the incoming process cannot use the outgoing one's entries. PCID tagging avoids a full flush, but it does not let two processes share translations — it only avoids throwing them away.

<img src="/assets/posts/hugepages-02-process-model.svg" alt="Fig. 2 — process model" width="95%">

*Fig. 2 — three backends, three independent page tables, one physical `shared_buffers`.*

There is one mechanism that partially breaks this isolation — page-table sharing for hugetlb mappings. It is covered in [section 6](#6-explicit-vs-transparent-huge-pages).

---

## 4. What happens on a page access

Take a concrete setup: `shared_buffers = 16GB`, 10 connected clients, so 10 backends.

1. The postmaster maps 16 GB of shared anonymous memory. This reserves *address space* only — no physical pages are allocated yet.
2. A backend is forked. For the buffer pool region its page table is effectively empty.
3. Executing a query requires a data page, so the backend touches an address inside `shared_buffers`.
4. The CPU checks the TLB — **miss**.
5. The page walk runs — the entry is **not present**.
6. A page fault traps into the kernel. The kernel finds the page in the shared memory object, fills in the entry, and returns. This is a **minor fault** — no disk I/O.
7. The instruction retries. Now it is a TLB hit, and every later access to this page is cheap.

<img src="/assets/posts/hugepages-03-fault-path.svg" alt="Fig. 3 — the fault path" width="90%">

*Fig. 3 — steps 3 through 7. The loop back to step 3 shows that only the first access to a page is expensive.*

### The numbers

This is where the argument is either made or lost.

| | 4 KB pages | 2 MB huge pages |
|---|---|---|
| Entries for 16 GB | **4,194,304** | **8,192** |
| Page table per backend | **~32 MB** | **~64 KB** |
| Faults to fully warm one backend | 4,194,304 | 8,192 |
| TLB reach (2048 entries) | 8 MB | 4 GB |

*Fig. 4 — the same 16 GB of physical memory, described two different ways.*

Each entry is 8 bytes, so 4,194,304 × 8 B = 32 MB of leaf page-table entries per backend. That is 512× more than the 64 KB needed with 2 MB pages. (Higher tree levels add well under 1% and are ignored here; the 32 MB figure is what `VmPTE` will report.)

Multiplied across backends, the totals stop being negligible:

<img src="/assets/posts/hugepages-05-scaling.svg" alt="Fig. 5 — page table totals by backend count" width="90%">

*Fig. 5 — page-table overhead by backend count, on a logarithmic scale. At 500 backends the page tables describing a 16 GB buffer pool approach the size of the buffer pool itself.*

And the fault count for the 10-backend case: warming all ten backends against that same 16 GB region costs roughly **42 million minor faults** with 4 KB pages, versus about **82,000** with 2 MB pages. Same memory, same data, same queries.

---

## 5. Measuring the effect

Do not take any of the above on faith for your own hardware. Measure it.

### Per-process page table size

```bash
# VmPTE is the page-table memory for this process
grep -E 'VmPTE|VmHWM|HugetlbPages' /proc/<backend_pid>/status
```

### System-wide huge page state

```bash
grep -E 'HugePages_|Hugepagesize|Hugetlb|ShmemHugePages' /proc/meminfo
```

`HugePages_Total` is what you reserved, `HugePages_Free` what is unused, `HugePages_Rsvd` what is promised but not yet faulted in. `Hugetlb` is the total bytes locked away.

### The shared segment itself

```bash
pmap -x <backend_pid> | sort -k2 -n -r | head
grep -A 20 'rw-s' /proc/<backend_pid>/smaps | grep -E 'Size|Rss|KernelPageSize'
```

`KernelPageSize` on the shared segment tells you definitively whether the mapping is backed by huge pages.

### Hardware counters under load

```bash
perf stat -e dTLB-load-misses,dtlb_load_misses.walk_active,minor-faults \
  -p <backend_pid> -- sleep 60
```

Run the **same workload** before and after, on the same machine, with the same `shared_buffers`. A before/after pair on one box is the only comparison worth publishing — absolute numbers from someone else's hardware tell you nothing.

### What the numbers actually rest on

Note what *does not* need a benchmark. The per-backend page-table size is arithmetic, not measurement: `shared_buffers / page_size × 8 bytes`. The `VmPTE` check from [section 1](#1-introduction) will match that calculation on any running server.

The TLB miss rate and its effect on CPU time are a different matter — those genuinely depend on hardware, workload, and access pattern, and cannot be derived from first principles. A controlled before/after run on a dedicated Vagrant stand is pending for this article, and I would rather leave that gap visible than fill it with numbers I have not measured.

<!-- TODO(vagrant-stand): build the Vagrant test stand and run the before/after
     comparison — same workload, same shared_buffers, huge pages off vs on.
     Capture: dTLB-load-misses, dtlb_load_misses.walk_active, minor-faults, VmPTE.
     Then add a "Test environment" table (CPU / kernel / PG version / shared_buffers /
     backends / pgbench invocation) and a measured before/after chart as Fig. 6,
     renumbering PMD sharing -> Fig. 7 and pooler -> Fig. 8. -->


### What this looks like in production

Two observations from real systems, offered as orders of magnitude rather than benchmarks:

> 🧠 **From production.** With `shared_buffers = 32GB` and 300–600 backends, total page-table memory typically lands in the **10–20 GB** range.
>
> The arithmetic ceiling is higher — 64 MB per fully warmed backend, so 18.8 GB at 300 backends and 37.5 GB at 600. The same 32 GB with 2 MB pages needs 128 KB per backend: **75 MB total at 600 backends**, versus tens of gigabytes.

> 🧠 **On CPU time.** Better TLB hit rates have shown a **5–10% reduction in CPU usage** on memory-resident workloads. Treat that as a ceiling, not a promise — the type of workload matters more than any other single factor here, and an I/O-bound system will show nothing at all.

### What drives a backend's page-table size

A backend's page table grows with **how much of `shared_buffers` it has read over its entire lifetime** — not with how much it is reading right now. Entries accumulate and are never given back while the process lives. Two factors set the pace.

**Lifetime.** The longer a backend stays connected, the more of the pool it has had the opportunity to touch. A connection held open for hours ratchets steadily toward the ceiling.

**Query pattern.** A narrowly specialized backend that only ever reads one small table stays cheap indefinitely, no matter how long it lives.

In practice the second factor rarely rescues you. The typical application connects as one or two database users, opens hundreds of connections, and then sends queries against *every* table over that same set of connections. There is no partitioning of work by connection, so each backend drifts toward touching most of the pool, and the total climbs toward the arithmetic ceiling.

The one thing that meaningfully changes this is **how your driver or pool chooses which connection sends the next query**:

- If it distributes queries evenly across the whole pool — round-robin, or always picking the longest-idle connection — every backend eventually reads most of `shared_buffers`, and every backend ends up hot.
- If it prefers the connections it used most recently, traffic concentrates on a small working subset. Only those become hot; the rest stay cold, keep small page tables, and are eventually closed by an idle timeout.

> ℹ️ **INFO:** Pool documentation is inconsistent about naming this. The behaviour that keeps backends cold is the stack-like one — most-recently-used connection reused first, often labelled **LIFO** or **MRU**. The behaviour that warms every backend is queue-like — **FIFO** or round-robin. Check what your specific driver does rather than trusting the acronym, and confirm it by comparing `VmPTE` across your backends: an even spread means every backend is hot, a wide spread means only a subset is.

---

## 6. Explicit vs Transparent huge pages

Two different mechanisms, routinely confused.

**Explicit huge pages (hugetlbfs)** are reserved up front via `vm.nr_hugepages`. The memory is carved out of the general pool at reservation time and dedicated to huge pages. It is never swapped, never split, and never subject to runtime defragmentation stalls. This is what PostgreSQL's `huge_pages` setting uses.

**Transparent Huge Pages (THP)** are assembled opportunistically by the kernel and the `khugepaged` daemon. No configuration is needed, which is the appeal — but the kernel may have to compact and defragment memory to produce a 2 MB page, and that work can happen synchronously in the middle of your query.

> ⚠️ **WARNING:** The long-standing recommendation for database workloads is `transparent_hugepage/enabled = never` or `madvise`, and `defrag = never`. Synchronous compaction stalls show up as unexplained multi-hundred-millisecond latency spikes that appear in no query plan.

THP can also back shared memory, controlled by `/sys/kernel/mm/transparent_hugepage/shmem_enabled`. This is closer to what PostgreSQL needs than anonymous THP, but it is still opportunistic — there is no guarantee the mapping actually gets huge pages, and no error if it does not. Explicit reservation gives you a guarantee; THP gives you a probability.

### Page-table sharing

There is a second, less-discussed benefit of hugetlb mappings. A PMD entry covers exactly 2 MB — the same size as a huge page. That makes it possible for multiple processes mapping the same shared hugetlb region to share the PMD-level page table itself, rather than each maintaining a private copy.

Where this applies, it partially breaks the process isolation described in [section 3](#3-why-this-is-specifically-a-postgresql-problem): page-table work done by one backend becomes visible to others, instead of every backend faulting in the same region independently.

> ℹ️ **INFO:** The conditions for PMD sharing — alignment, mapping flags, and kernel version — have changed repeatedly across kernel releases. Verify the behaviour on your own kernel by comparing `VmPTE` across backends rather than assuming it applies.

<img src="/assets/posts/hugepages-06-pmd-sharing.svg" alt="Fig. 6 — PMD sharing" width="80%">

*Fig. 6 — private upper levels, one shared PMD table.*

---

## 7. PostgreSQL configuration

### `huge_pages`

| Value | Behaviour |
|-------|-----------|
| `try` | Use huge pages if possible, silently fall back to 4 KB otherwise (default) |
| `on` | Require huge pages; **refuse to start** if unavailable |
| `off` | Never use huge pages |

> ⚠️ **WARNING:** `try` is the default, and that is exactly the problem. If your reservation is wrong, too small, or lost after a reboot, PostgreSQL starts normally and quietly runs without huge pages. You get no error and no log entry to alert you — only the performance you were trying to avoid. Use `on` in production once you have verified the reservation, so a misconfiguration fails loudly at startup rather than silently at runtime.

### Sizing the reservation

Since PostgreSQL 15 you can ask the server exactly how many huge pages it needs, without starting it:

```bash
postgres -D /var/lib/postgresql/data -C shared_memory_size_in_huge_pages
# e.g. 8256
```

Then reserve that many, plus a small margin:

```bash
sysctl -w vm.nr_hugepages=8300
# persist it
echo 'vm.nr_hugepages = 8300' >> /etc/sysctl.d/99-postgresql.conf
```

Verify before restarting PostgreSQL:

```bash
grep HugePages_Total /proc/meminfo
```

### `huge_page_size`

Available since PostgreSQL 14. Leave it at `0` to use the system default (2 MB on x86-64) unless you have a specific reason.

1 GB pages reduce the entry count further, but they **cannot be reserved reliably at runtime** — memory is usually too fragmented by then. They require kernel command-line parameters and a reboot:

```
hugepagesz=1G hugepages=20
```

They also make sizing coarse: with 1 GB granularity you round `shared_buffers` up to the next gigabyte and lose the remainder.

### NUMA

On multi-socket machines, reserving with `vm.nr_hugepages` distributes pages across nodes, but not necessarily the way you want. Check per node:

```bash
cat /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages
```

If a node is short, backends running there will fail to get local huge pages and end up with remote memory access — trading a translation problem for a latency problem.

---

## 8. Connection poolers as partial mitigation

A pooler helps with this problem even if you never enable huge pages, because it attacks the other term in the multiplication.

**It caps the number of backends.** The overhead is `backends × shared_buffers / page_size`, and `pool_size` puts a ceiling on the first term. 500 clients through a pooler with `pool_size = 30` produce 30 backends, not 500 — roughly 960 MB of page tables instead of 15.6 GB. Page-table growth becomes a function of pool size, not of how many clients your application happens to open.

**Transaction mode keeps backends hot.** Server connections are reused far more densely, so each backend's working set stays warm and its translations stay resident. Fewer backends each doing more work is a better shape for the TLB than many backends each touching a little.

**`server_lifetime` recycles bloated backends.** PgBouncer closes server connections after this interval (default 3600 s). A backend that has accumulated a large page table dies, and the page table dies with it. This works regardless of application behaviour, which matters for legacy clients that hold connections open forever.

> 🧠 **The honest caveat:** recycling throws away a *warm* page table along with the bloated one. Too aggressive a `server_lifetime` buys you a steady stream of re-faults, plus fork cost, plus a cold local catalog cache on every new backend. It is a trade between steady-state page-table size and fault frequency — not a free win.

`server_idle_timeout` does the same thing driven by idleness rather than age, and is generally the cheaper of the two.

<img src="/assets/posts/hugepages-07-pooler.svg" alt="Fig. 7 — pooler effect" width="90%">

*Fig. 7 — the same `shared_buffers` underneath both, but a very different number of page tables above it.*

The takeaway: **a pooler reduces the scale of the problem, huge pages reduce the cost per unit.** They are orthogonal, and together the issue disappears — 30 backends at 64 KB each is not worth thinking about.

For practical pooler setup and monitoring, see [Effective PgBouncer monitoring using Odarix]({% post_url 2024-10-01-Effective-PgBouncer-monitoring-using-Odarix %}) and [AWS RDS Proxy for PostgreSQL]({% post_url 2026-01-18-aws-rds-proxy-postgresql %}).

---

## 9. Trade-offs and when it does not help

**What you gain**

- Fewer TLB misses, and far fewer page walks
- Dramatically smaller page tables — 512× fewer entries for the same memory
- Shared memory can never be swapped out

**What it costs**

- Reserved memory leaves the general pool. It will not show as free, and the page cache cannot use it — even when PostgreSQL is stopped.
- `huge_pages = on` turns a bad reservation into a startup failure. That is the correct behaviour, but it must be part of your provisioning and reboot procedure.
- Runtime reservation can fail on a fragmented system. Reserve at boot.
- It does nothing for backend-local memory — `work_mem`, `maintenance_work_mem`, catalog and plan caches are all still 4 KB pages.

**When the effect is negligible**

- **Small `shared_buffers`.** A few GB fits within reasonable TLB reach; there is little to fix.
- **Few connections.** With 10 backends the total page-table overhead is around 300 MB. Real, but rarely your bottleneck.
- **I/O-bound workloads.** If you are waiting on storage, saving nanoseconds on address translation changes nothing. Huge pages help when data is in memory and the CPU is the constraint.

---

## 10. Conclusion

Huge pages are a narrow optimisation with a clear mechanism. They do not make PostgreSQL faster in general — they remove address-translation overhead, and that overhead only matters when `shared_buffers` is large and many backends are working against it in memory.

**Rollout checklist**

1. Confirm the workload is memory-resident and CPU-bound, not I/O-bound.
2. Set `transparent_hugepage/enabled` to `never` or `madvise`, and `defrag` to `never`.
3. Measure first: `VmPTE` per backend, and `perf stat` counters under your real workload.
4. Get the exact requirement with `postgres -C shared_memory_size_in_huge_pages`.
5. Reserve at boot with a margin, and persist it in `/etc/sysctl.d/`.
6. On NUMA machines, verify the per-node distribution.
7. Set `huge_pages = on` — not `try` — so a broken reservation fails loudly.
8. Restart, then confirm `KernelPageSize` on the shared segment and a drop in `HugePages_Free`.
9. Re-measure the same workload and compare against step 3.
10. Add `HugePages_Free` to monitoring, and re-verify after every reboot and kernel upgrade.

If you already run a connection pooler, do that first. Capping backend count is easier to deploy, needs no reboot, and attacks the same multiplication from the other side.

### References

- [PostgreSQL: Resource Consumption — `huge_pages`, `huge_page_size`](https://www.postgresql.org/docs/current/runtime-config-resource.html)
- [PostgreSQL: Managing Kernel Resources — huge pages](https://www.postgresql.org/docs/current/kernel-resources.html#LINUX-HUGE-PAGES)
- [Linux kernel: HugeTLB pages](https://docs.kernel.org/admin-guide/mm/hugetlbpage.html)
- [Linux kernel: Transparent Hugepage Support](https://docs.kernel.org/admin-guide/mm/transhuge.html)
- [PgBouncer configuration — `server_lifetime`, `server_idle_timeout`](https://www.pgbouncer.org/config.html)
