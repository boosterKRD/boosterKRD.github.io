---
layout: post
title: Huge Pages in PostgreSQL
date: 2026-08-23
---

Your server keeps a **page table** — a structure in RAM that only describes where other memory is located. Each process has its own, with one 8-byte entry for every 4 KB page it has actually used. In PostgreSQL, every connection has its own backend, and each backend is a separate OS process — so each one holds a private description of the same `shared_buffers`. The more memory you give the database and the more connections you run, the more RAM is used just to describe memory you already own. On a typical production server with 32 GB of `shared_buffers` and 600 backends, this can easily reach 10–20 GB: RAM wasted on describing RAM.

<!--MORE-->

-----

## Table of Contents

1. [The problem, in numbers](#1-the-problem-in-numbers)
2. [Measure your own server](#2-measure-your-own-server)
3. [How it works under the hood](#3-how-it-works-under-the-hood)
4. [PostgreSQL configuration](#4-postgresql-configuration)
5. [Aside: a pooler may be enough](#5-aside-a-pooler-may-be-enough)
6. [Conclusion](#6-conclusion)
7. [Notes](#notes)

---

## 1. The problem, in numbers

The calculation is simple. Linux uses **4 KB pages** by default, and the kernel needs one **8-byte entry** to describe every page a process has touched:

```
shared_buffers / 4 KB * 8 bytes = page table, per backend
```

With 32 GB of `shared_buffers`, that comes to about 8.4 million entries, or **64 MB per backend**. Nothing is shared — page tables are per-process, so the total can grow linearly with your connection count.[^scaling]

This gives the upper limit — the cost if every backend has read all of `shared_buffers`:

| Backends | 32 GB `shared_buffers` | 64 GB `shared_buffers` |
|---------:|-----------------------:|-----------------------:|
| 10 | 0.62 GB | 1.25 GB |
| 100 | 6.25 GB | 12.50 GB |
| 300 | 18.75 GB | 37.50 GB |
| 600 | 37.50 GB | 75.00 GB |

With 2 MB huge pages, the same 32 GB needs only 16,384 entries. That is roughly **128 KB per backend**, or 512x less.

> ℹ️ **A real case from production**. With `shared_buffers = 32GB` and **600 backends**, total page-table memory reached ~18 GB, or about 31 MB per backend. This is half the upper limit because no backend had touched all of `shared_buffers`. With 2 MB pages, the same setup needed only **75 MB total**.
>
> CPU usage also dropped by roughly **4-10%**. Note what this number does not include. The freed memory was not used by anything. There was *no* OS page cache either, because that server stored its data on ZFS and caching happened in the ARC. It simply remained unused. **Several gigabytes of RAM came back**, and using them for a larger `shared_buffers` or more room for the ZFS ARC should increase the gain even further. The 4-10% is what you get before that.

---

## 2. Measure your own server

Before you change anything, find out what it is actually costing you:

```bash
# 1. Page-table memory across the whole system
grep '^PageTables' /proc/meminfo
```

<div style="margin:-12px 0 22px;border-left:3px solid #b5e853;border-radius:0 8px 8px 0;overflow:hidden;background:#0d0d0d">
  <div style="font-family:Menlo,Consolas,monospace;font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;color:#b5e853;padding:6px 14px;background:rgba(181,232,83,.09)">output</div>
  <pre style="margin:0;padding:12px 14px;background:transparent;border:0;border-radius:0;color:#d5dae2;font-size:13px;line-height:1.6;overflow-x:auto">PageTables:     19215332 kB</pre>
</div>

```bash
# 2. Just PostgreSQL — total, and the average per process
awk '/VmPTE/ {t += $2; n++} END {if (n) printf "processes: %d\ntotal:     %.1f MB\nper proc:  %.1f MB\n", n, t/1024, t/n/1024}' \
    $(pgrep -x postgres | sed 's|.*|/proc/&/status|')
```

<div style="margin:-12px 0 22px;border-left:3px solid #b5e853;border-radius:0 8px 8px 0;overflow:hidden;background:#0d0d0d">
  <div style="font-family:Menlo,Consolas,monospace;font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;color:#b5e853;padding:6px 14px;background:rgba(181,232,83,.09)">output</div>
  <pre style="margin:0;padding:12px 14px;background:transparent;border:0;border-radius:0;color:#d5dae2;font-size:13px;line-height:1.6;overflow-x:auto">processes: 602
total:     18662.0 MB
per proc:  31.0 MB</pre>
</div>

This is a real server: **18.2 GB of RAM used for page tables** across 602 postgres processes, or 31 MB per process.

`PageTables` in `/proc/meminfo` shows the system-wide figure, while `VmPTE` in `/proc/<pid>/status` shows it per process. On a database host, the two should be almost the same, and here they are: 18.3 GB system-wide versus 18.2 GB from PostgreSQL alone. That leaves about 100 MB for everything else on the server. If your numbers differ by much more than that, something other than PostgreSQL is using the memory, and you should find it first.

Then decide:

- **A few hundred MB**: huge pages are not your problem. Spend your effort elsewhere.
- **Several GB**: you are paying a permanent memory tax to describe memory you already own, so a migration is worth the work. That RAM returns to the page cache and the rest of the system, which helps regardless of your workload. An I/O-bound server may be I/O-bound precisely because those gigabytes went into page tables instead of caching data.

---

## 3. How it works under the hood

The mechanics of virtual addressing, the TLB, why a fault can happen when memory is already resident, and what a 2 MB page changes are covered in a separate interactive explainer:

**[→ Why PostgreSQL spends gigabytes on page tables]({{ site.baseurl }}/assets/posts/howtoworks_hugepages.html)**

It walks through the address translation path, the page table problem for each process, and the first-touch fault step by step. It also includes an explorer where you can enter your own `shared_buffers` value and backend count.

The short version, if you only want the conclusions:

- Every memory access needs a virtual-to-physical translation. The CPU caches recent translations in the TLB, with roughly 2,000 entries. Every miss requires a four-level walk through the page table in RAM. The amount of memory those entries cover changes:
  - **With 4 KB pages**: 2000 * 4 KB = **8 MB**. A 32 GB `shared_buffers` pool exceeds that constantly, so misses are the normal case.
  - **With 2 MB pages**: 2000 * 2 MB = **4 GB**. This still does not cover the full pool, and misses do not disappear, but they happen much less often than with 4 KB pages.
- **Every connection gets its own backend, and every backend is a separate OS process**, not a thread. Each backend carries a private page table. Backend B faults on a page that backend A has already faulted in because B’s own table has no entry for it. In practice, warm-up is not shared.
- The faults are **minor**. There is no disk I/O, only a brief switch into the kernel to fill in the missing entry. That is why the cost is so easy to miss: there is no I/O wait to point at and no slow query to blame.

This is also where the **4-10%** CPU from the case above came from: address translation alone. The TLB started covering a useful share of the working set instead of missing constantly.

### The worst case: an empty `shared_buffers`

The effect is strongest while `shared_buffers` is still **empty and being filled**, because every access is a first touch. A [Linux 7.0 change](https://read.thecoder.cafe/p/linux-broke-postgresql) made this clear in 2026: on a server with a very large `shared_buffers` and huge pages disabled, PostgreSQL became about two times slower. First-touch faults on an empty pool were the fuel. A scheduler change allowed a backend to be preempted in the middle of one while it held a buffer-allocation spinlock, and every other backend then spun while waiting for it. Huge pages removed the faults, and the regression disappeared.

---

## 4. PostgreSQL configuration

### `huge_pages`

The [`huge_pages` setting](https://www.postgresql.org/docs/current/runtime-config-resource.html) takes three values:

| Value | Behaviour |
|-------|-----------|
| `try` | Use huge pages if possible, silently fall back to 4 KB otherwise (default) |
| `on` | Require huge pages; **refuse to start** if unavailable |
| `off` | Never use huge pages |

![What happens at startup, depending on the reservation and the setting](/assets/images/hugepages-outcomes.png)

`on` fails loudly at startup if the required reservation is missing. `try` always starts, but it can silently fall back to 4 KB pages. If you use `try`, monitor separately that huge pages are actually in use.[^try]

Since PostgreSQL 17, that check takes one line. [`huge_pages_status`](https://pgpedia.info/h/huge_pages_status.html) reports what the server actually got, not what it asked for:

```sql
SHOW huge_pages_status;   -- on | off | unknown
```

Alert on any value other than `on`.[^status] On older versions, `/proc/meminfo` gives you most of the answer from the OS side. It shows whether the pool is in use, but not which process is using it:

```bash
grep -E 'HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugetlb' /proc/meminfo
```

<div style="margin:-12px 0 22px;border-left:3px solid #b5e853;border-radius:0 8px 8px 0;overflow:hidden;background:#0d0d0d">
  <div style="font-family:Menlo,Consolas,monospace;font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;color:#b5e853;padding:6px 14px;background:rgba(181,232,83,.09)">output</div>
  <pre style="margin:0;padding:12px 14px;background:transparent;border:0;border-radius:0;color:#d5dae2;font-size:13px;line-height:1.6;overflow-x:auto">HugePages_Total:   17000        <span style="color:#8b949e"># pool reserved: 17000 * 2 MB = 33.2 GB</span>
HugePages_Free:      232        <span style="color:#b5e853"># 99% taken → PostgreSQL got them ✓</span>
HugePages_Rsvd:       40        <span style="color:#8b949e"># mapped, not yet touched (subset of Free)</span>
Hugetlb:        34816000 kB     <span style="color:#8b949e"># 33.2 GB locked away from the rest of the OS</span></pre>
</div>

There are two ways this can go wrong. If `Total` is `0`, you never reserved a pool. If `Total` is large but `Free` matches `Total` and `Rsvd` is `0`, the pool exists but PostgreSQL did not use it.

### Sizing the reservation

PostgreSQL documents [the full procedure](https://www.postgresql.org/docs/current/kernel-resources.html#LINUX-HUGE-PAGES), but the short version is this: since PostgreSQL 15, the server tells you exactly how many huge pages it needs, so there is no need to estimate them from `shared_buffers`. There are two ways to read this:

On a running server:

```sql
SHOW shared_memory_size_in_huge_pages;   -- e.g. 16808
```

On a stopped one:

```bash
postgres -D /var/lib/postgresql/data -C shared_memory_size_in_huge_pages
```

This parameter is calculated at startup, so `postgres -C` can read it **only when the server is shut down**. Against a running instance, it fails because of the `postmaster.pid` lock instead of printing a value.

Both commands read the number from the same real server. To see how each setting changes it, you can use a calculator:

**[→ How many huge pages does PostgreSQL need? The sizing calculator]({{ site.baseurl }}/assets/posts/howtoworks_shmem_sizing.html)**

> ℹ️ **About the calculator.** It uses the same formulas as the PostgreSQL source code. Compared with `postgres -C` on real PostgreSQL 17 and 18 servers, the difference is up to **0.33%**.

### Setting up huge pages in Linux

Take the number above, add **1-2%**, then round up to a number you can read at a glance. The pool is managed through [`vm.nr_hugepages`](https://docs.kernel.org/admin-guide/mm/hugetlbpage.html), and the important setting is the one applied at boot, when memory is least fragmented:

```bash
echo 'vm.nr_hugepages = 17000' >> /etc/sysctl.conf
```
`sysctl -w` applies the same value immediately and is useful for testing on a live machine, but it is not reliable. On a fragmented system, the kernel can provide **fewer pages than requested without reporting an error**. Always check what you actually received:

```bash
sysctl -w vm.nr_hugepages=17000
grep HugePages_Total /proc/meminfo    # must equal 17000 — anything lower is a partial allocation
```

If it returns fewer pages than requested, memory is already too fragmented to satisfy the request at runtime. Before you reboot, give the kernel a better chance: stop PostgreSQL, drop the page cache, compact memory, then try again. With the largest consumer gone and the cache released, the request often succeeds:

```bash
systemctl stop postgresql
sync; echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
sysctl -w vm.nr_hugepages=17000
grep HugePages_Total /proc/meminfo    # check again
```

![When a runtime reservation returns fewer pages than requested](/assets/images/hugepages-fragmentation.png)

Still short — **reboot the machine**, and the value you wrote to `/etc/sysctl.conf` above will be applied early in boot, while memory is still largely unfragmented.

> ⚠️ On a multi-socket server, check that `vm.zone_reclaim_mode` is `0`. When set to `1`, the kernel discards local page cache instead of using free memory from a neighbouring node. That costs a database far more than the remote access it avoids. 0 has been the kernel default since Linux 3.16, so this only matters for inherited machines and tuning profiles, not as a setting you would normally change.

### Transparent Huge Pages

[THP](https://docs.kernel.org/admin-guide/mm/transhuge.html) is a different mechanism and does not replace an explicit reservation. It works on a best-effort basis, so the kernel gives you huge pages when it can and may take them back later. The usual advice is to disable it. These are sysfs settings, **not sysctls**, so `/etc/sysctl.conf` will not persist them:

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled   # current value is the one in brackets
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

To make it permanent, add `transparent_hugepage=never` to the kernel command line.

> ℹ️ **About this advice**. “Turn off THP” has been repeated in article after article for decades. Now it appears in this one too. I have not tested it on a modern kernel. I think it matters much less today than it did ten years ago. I hope someone tests how THP and PostgreSQL behave on modern kernels.

---

## 5. Aside: a pooler may be enough

> ℹ️ Notes
>
> - Everything below assumes a pooler in transaction mode.
> - **An aside, not part of the rollout above.** Page table memory grows for two reasons: the number of backends you run and the size of the pages. Huge pages address the second. A pooler addresses the first, with no reboot, kernel tuning, or reserved memory. Neither replaces the other. A pooler cannot make a page table smaller, and huge pages cannot stop your application from opening 600 connections.

**`pool_size` caps the number of backends**. 500 clients through a pool of 30 create 30 backends, not 500. With 32 GB of `shared_buffers`, that is roughly 1.9 GB of page tables instead of 31 GB. Growth depends on the pool size, not on how many connections your application opens.

**Backends stay hot.** Server connections are reused much more often, so each backend’s working set stays warm and its translations remain resident. A server connection lives separately from the client connection that used it, so an application that constantly opens and closes connections does not pay for a new first touch every time. The same helps after a database restart: if the pool uses the most recently used connection first, only a few backends need to warm up.

**Recycling removes bloated backends.** Poolers can close server connections after a set lifetime, and the backend with its large page table disappears with the connection. This works regardless of application behaviour, which matters for legacy clients that never close connections.[^recycle]

**A pooler reduces the scale of the problem, while huge pages reduce the cost per unit**. They solve separate parts of the problem. Together, 30 backends at 128 KB each is not a number worth thinking about.

See also: [Effective PgBouncer monitoring using Odarix]({% post_url 2024-10-01-Effective-PgBouncer-monitoring-using-Odarix %}) and [AWS RDS Proxy for PostgreSQL]({% post_url 2026-01-18-aws-rds-proxy-postgresql %}).

---

## 6. Conclusion

Huge pages are a narrow optimisation with a clear mechanism. They do not make PostgreSQL faster in general. They remove address-translation overhead, and only for shared memory.[^local] Whether this is worth doing is not a judgement call. Measure how much your current workload spends on page tables, then decide whether that number is large enough to care about.

**Rollout checklist**

1. Measure — `grep '^PageTables' /proc/meminfo`. Happy with the number? Stop here.
2. Disable transparent huge pages.
3. Get the requirement — `SHOW shared_memory_size_in_huge_pages;` on the running server.
4. Reserve it at boot in `/etc/sysctl.conf`, plus a margin.
5. Multi-socket box — check `vm.zone_reclaim_mode = 0`.
6. Choose `huge_pages = on`, or `try` with an alert.
7. Restart if needed. Confirm `HugePages_Free` dropped and `huge_pages_status` reads `on`.
8. Re-measure, compare with step 1.

---

## Notes

[^scaling]: The upper limit assumes every backend has read all of `shared_buffers`; 64 MB is the figure for a fully warmed backend. A backend allocates entries only for pages it has actually touched, so its table grows with everything it has read over its lifetime. The longer it lives, the closer it gets to the upper limit.

[^try]: With `try`, PostgreSQL requests `MAP_HUGETLB` and, if that fails, silently retries the mapping without it. The server starts, looks healthy, and runs on 4 KB pages. This usually happens when `vm.nr_hugepages` was never set, when it is too small after `shared_buffers` grows, or when it was set with `sysctl -w` but never saved to `/etc/sysctl.conf`, so it disappeared at the last reboot.

[^status]: `huge_pages_status` was added in PostgreSQL 17 because `try` gave no way to confirm the result. A running instance reports either `on` or `off`. The third value, `unknown`, means the status could not be determined. You see it when reading the parameter with `postgres -C` against a stopped server, because nothing has been allocated yet.

[^recycle]: Recycling removes warm page tables along with bloated ones. If the lifetime is too short, you get a steady stream of re-faults, fork costs, and a cold catalog cache for every new backend. This is a trade-off between steady-state table size and fault frequency, not a free win. Most poolers also offer an idle-based equivalent. It does the same thing based on idleness rather than age and is usually the cheaper option. In PgBouncer, these are [`server_lifetime` and `server_idle_timeout`](https://www.pgbouncer.org/config.html); other poolers use different names for the same two ideas.

[^local]: `work_mem`, `maintenance_work_mem`, and catalog and plan caches still use 4 KB pages. Huge pages apply only to the shared memory segment.
