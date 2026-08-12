---
layout: post
title: Huge Pages in PostgreSQL
date: 2026-07-28
---

Your server keeps a **page table** — a structure in RAM whose only job is to describe where other memory lives. Every process has its own, with one 8-byte entry per 4 KB page it has actually touched. In PostgreSQL every connection gets its own backend, and every backend is a separate OS process — so each one keeps a private description of the same `shared_buffers`. The more memory you give the database and the more connections you run, the more RAM disappears into simply describing memory you already own. On a production box that is routinely **10–20 GB**.

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

The arithmetic is short. With the default 4 KB page size:

```
shared_buffers ÷ 4 KB × 8 bytes = page table, per backend
```

For a 32 GB `shared_buffers` that is ~8.4 million entries (8,388,608 exactly), or **64 MB per backend**. Nothing shares it — page tables are per-process, so the total can scale linearly with your connection count.[^scaling]

That gives the **ceiling** — what it costs if every backend has read all of `shared_buffers`:

| Backends | 32 GB `shared_buffers` | 64 GB `shared_buffers` |
|---------:|-----------------------:|-----------------------:|
| 10 | 0.62 GB | 1.25 GB |
| 100 | 6.25 GB | 12.50 GB |
| 300 | 18.75 GB | 37.50 GB |
| 600 | 37.50 GB | 75.00 GB |

With 2 MB huge pages the same 32 GB needs 16,384 entries — roughly **128 KB per backend**, 512× less.

> 🧠 **From production.** With `shared_buffers = 32GB` and 300–600 backends, total page-table memory typically lands in the **10–20 GB** range, well below the ceiling above. With 2 MB pages that same fleet needs **75 MB total at 600 backends**.
>
> CPU usage drops by roughly **5–20%** — better TLB hit rates, and fewer page faults as a result. But the bigger win is simpler than that: **several gigabytes of RAM come back.** The OS can use them for its cache, or you can spend them on a larger `shared_buffers`.
>
> The effect is biggest while `shared_buffers` is still **empty and filling up**, because then every access is a first touch. A [change in Linux 7.0](https://read.thecoder.cafe/p/linux-broke-postgresql) showed this clearly in 2026: on a server with a very large `shared_buffers` and huge pages off, PostgreSQL became about two times slower. The fuel was first-touch faults on an empty pool; a scheduler change made it possible to preempt a backend in the middle of one while it held a buffer-allocation spinlock, and every other backend spun waiting for it. Huge pages removed the faults, and the regression went away.
>
> *A detailed walkthrough is in [How it works under the hood](#3-how-it-works-under-the-hood) below.*

---

## 2. Measure your own server

Before changing anything, find out what this is actually costing you:

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

That is a real server: **18.2 GB of RAM spent on page tables**, across 602 postgres processes, at 31 MB each.

`PageTables` in `/proc/meminfo` is the system-wide figure; `VmPTE` in `/proc/<pid>/status` is per process. The two should very nearly agree on a database host, and here they do — 18.3 GB system-wide against 18.2 GB from PostgreSQL alone, leaving about 100 MB for everything else on the box. If your numbers diverge by much more than that, something other than PostgreSQL is using the memory and is worth finding first.

Then decide:

- **A few hundred MB** — huge pages are not your problem. Spend the effort elsewhere.
- **Several GB** — you are paying a permanent memory tax to describe memory you already own, and a migration is worth working through. That RAM comes back to the page cache and the rest of the system, which helps whatever your workload looks like — an I/O-bound server may be I/O-bound precisely because those gigabytes went into page tables instead of caching data.

---

## 3. How it works under the hood

The mechanics — virtual addressing, the TLB, why a fault happens on memory that is already resident, and what a 2 MB page changes — are covered in a separate interactive explainer:

**[→ Why PostgreSQL spends gigabytes on page tables](/howtoworks_hugepages.html)**

It walks through the address translation path, the per-process page table problem, and the first-touch fault step by step, with an explorer where you can put in your own `shared_buffers` and backend count.

The short version, if you only want the conclusions:

<!-- REVIEW: "four-level walk" — on Ice Lake+ / Sapphire Rapids with LA57 the walk is five levels,
     and paging-structure caches often short-circuit the upper levels rather than going to RAM.
     Options: leave as-is, or "up to a four-level walk (five with LA57)". Decide later. -->
- Every memory access needs a virtual→physical translation. The CPU caches recent ones in the **TLB** — roughly 2000 entries — and every miss costs a four-level walk through the page table in RAM. How much memory those entries cover is what changes:
  - **With 4 KB pages** — 2000 × 4 KB = **8 MB**. A 32 GB `shared_buffers` overruns that constantly, so misses are the normal case.
  - **With 2 MB pages** — 2000 × 2 MB = **4 GB**. Still not the whole pool, but enough that a backend's working set mostly stays translated, and misses become the exception.
- **Every connection gets its own backend, and every backend is a separate OS process** — not a thread. So each one carries a private page table. Backend B faults on a page backend A already faulted in, because B's own table is empty there. In practice, warm-up is not shared.
- The faults are **minor** — no disk I/O, just a brief switch into the kernel to fill in the missing entry. That is why the cost hides so well: no I/O wait to point at, no slow query to blame.

---

## 4. PostgreSQL configuration

### `huge_pages`

The [`huge_pages` setting](https://www.postgresql.org/docs/current/runtime-config-resource.html) takes three values:

| Value | Behaviour |
|-------|-----------|
| `try` | Use huge pages if possible, silently fall back to 4 KB otherwise (default) |
| `on` | Require huge pages; **refuse to start** if unavailable |
| `off` | Never use huge pages |

`on` fails loudly at startup if the reservation is missing. `try` always starts, but can fall back to 4 KB pages without telling you — so **if you use `try`, monitor separately that huge pages are actually in use.**[^try]

Since PostgreSQL 17 that check is a one-liner — [`huge_pages_status`](https://pgpedia.info/h/huge_pages_status.html) reports what the server actually got, rather than what it asked for:

```sql
SHOW huge_pages_status;   -- on | off | unknown
```

Alert on anything other than `on`.[^status] On older versions, `/proc/meminfo` gets you most of the way from the OS side — it shows whether the pool is being used, though not by whom:

```bash
grep -E 'HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugetlb' /proc/meminfo
```

<div style="margin:-12px 0 22px;border-left:3px solid #b5e853;border-radius:0 8px 8px 0;overflow:hidden;background:#0d0d0d">
  <div style="font-family:Menlo,Consolas,monospace;font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;color:#b5e853;padding:6px 14px;background:rgba(181,232,83,.09)">output</div>
  <pre style="margin:0;padding:12px 14px;background:transparent;border:0;border-radius:0;color:#d5dae2;font-size:13px;line-height:1.6;overflow-x:auto">HugePages_Total:   17000        <span style="color:#8b949e"># pool reserved: 17000 × 2 MB = 33.2 GB</span>
HugePages_Free:      232        <span style="color:#b5e853"># 99% taken → PostgreSQL got them ✓</span>
HugePages_Rsvd:       40        <span style="color:#8b949e"># mapped, not yet touched (subset of Free)</span>
Hugetlb:        34816000 kB     <span style="color:#8b949e"># 33.2 GB locked away from the rest of the OS</span></pre>
</div>

Two ways this goes wrong. If `Total` is `0`, you never reserved a pool at all. If `Total` is large but `Free` is the same as `Total` and `Rsvd` is `0`, the pool exists and PostgreSQL simply did not take it.

### Sizing the reservation

PostgreSQL documents [the whole procedure](https://www.postgresql.org/docs/current/kernel-resources.html#LINUX-HUGE-PAGES), but the short version is this. Since PostgreSQL 15 the server tells you exactly how many huge pages it needs — no guessing from `shared_buffers`. On a running server:

```sql
SHOW shared_memory_size_in_huge_pages;   -- e.g. 16808
```

This parameter is computed at startup, so `postgres -C` can read it **only while the server is shut down** — against a live instance it fails on the `postmaster.pid` lock rather than printing a value:

```bash
# server must be stopped
postgres -D /var/lib/postgresql/data -C shared_memory_size_in_huge_pages
```

Reserve that many plus a small margin — but no more than you need. The pool is managed through [`vm.nr_hugepages`](https://docs.kernel.org/admin-guide/mm/hugetlbpage.html). Reserved huge pages leave the general pool entirely: they never show as free, the page cache cannot use them, and that stays true even while PostgreSQL is stopped. The setting that counts is the one applied at boot, when memory is least fragmented:

```bash
echo 'vm.nr_hugepages = 17000' > /etc/sysctl.d/99-postgresql-hugepages.conf
```

`sysctl -w` applies the same value immediately and is useful for testing on a live machine, but it is the unreliable path: on a fragmented system the kernel hands back **fewer pages than requested, without reporting an error**. Always read back what you actually got:

```bash
sysctl -w vm.nr_hugepages=17000
grep HugePages_Total /proc/meminfo    # must equal 17000 — anything lower is a partial allocation
```

If it comes back short, memory is already too fragmented to satisfy the request at runtime. Before reaching for a reboot, give the kernel a better chance: stop PostgreSQL, drop the page cache, compact memory, then ask again. With the largest consumer gone and the cache released, the request often goes through:

```bash
systemctl stop postgresql
sync; echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
sysctl -w vm.nr_hugepages=17000
grep HugePages_Total /proc/meminfo    # check again
```

Still short — **reboot the machine**, and the value you wrote to `99-postgresql-hugepages.conf` above will be applied early in boot, while memory is still largely unfragmented.

On a multi-socket server, check `vm.zone_reclaim_mode` first. When it is `1`, the kernel reclaims memory from the local node — dropping page cache — instead of using free memory on another node. It is a bit mask, and the higher bits are worse: `2` also writes dirty pages out, `4` also swaps. For a database that is exactly backwards:

```bash
sysctl vm.zone_reclaim_mode      # must be 0
echo 'vm.zone_reclaim_mode = 0' > /etc/sysctl.d/99-postgresql-numa.conf
```

Modern kernels default to `0`, but older ones switched it on automatically when the NUMA distance was high, so it is worth confirming rather than assuming.

### `huge_page_size`

[Available since PostgreSQL 14](https://www.postgresql.org/docs/current/runtime-config-resource.html). Leave it at `0` for the system default — 2 MB on x86-64. 1 GB pages exist but bring their own problems.[^gb]

### Transparent Huge Pages

[THP](https://docs.kernel.org/admin-guide/mm/transhuge.html) is a different mechanism and not a substitute for explicit reservation. It is best-effort: the kernel gives you huge pages when it can and may take them back later, and depending on your kernel settings the work of producing them can cause latency spikes. Check what you have — the current value is the one in brackets:

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled   # e.g. [always] madvise never
cat /sys/kernel/mm/transparent_hugepage/defrag
```

Set `enabled` to `never`; `defrag` then has nothing to act on. These are sysfs knobs, **not sysctls** — `/etc/sysctl.d/` will not persist them, and the change is lost on reboot:

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

To make it permanent, add `transparent_hugepage=never` to the kernel command line. `madvise` is also acceptable, but then `defrag` starts to matter again and has no cmdline equivalent — persist it through a tuned profile or a systemd unit.

---

## 5. Aside: a pooler may be enough

> ℹ️ **An aside, not part of the rollout above.** The cost is `backends × shared_buffers ÷ page_size`. Everything above shrinks the third term. A pooler caps the first instead — with no reboot, no kernel tuning and no reserved memory. If you do not run one yet, start there rather than with huge pages.

**`pool_size` caps backends.** 500 clients through a pool of 30 produce 30 backends, not 500 — at 32 GB `shared_buffers`, roughly 1.9 GB of page tables instead of 31 GB. Growth becomes a function of pool size, not of how many connections your application opens.

**Transaction mode keeps backends hot.** Server connections are reused far more densely, so each backend's working set stays warm and its translations stay resident.

**Recycling kills bloated backends.** Poolers can close server connections after a set lifetime, and a backend with a large page table dies along with it. This works regardless of application behaviour, which matters for legacy clients that never close connections.[^recycle]

### One thing that decides how bad this gets

How your driver or pool picks the connection for the next query:

- **Spreads queries evenly** across the whole pool — round-robin, or always taking the longest-idle connection — and every backend eventually reads most of `shared_buffers`. All of them end up hot.
- **Prefers recently-used connections** and traffic concentrates on a small subset. Only those go hot; the rest stay cold with small page tables and get closed by an idle timeout.[^lifo]

**A pooler reduces the scale of the problem; huge pages reduce the cost per unit.** They are orthogonal, and together 30 backends at 128 KB each is not a number worth thinking about.

See also: [Effective PgBouncer monitoring using Odarix]({% post_url 2024-10-01-Effective-PgBouncer-monitoring-using-Odarix %}) and [AWS RDS Proxy for PostgreSQL]({% post_url 2026-01-18-aws-rds-proxy-postgresql %}).

---

## 6. Conclusion

Huge pages are a narrow optimisation with a clear mechanism. They do not make PostgreSQL faster in general — they remove address-translation overhead, and only for shared memory.[^local] Whether that is worth doing is not a judgement call: measure what your current workload actually spends on page tables, and decide whether that number is large enough to care about.

**Rollout checklist**

1. Measure — `grep '^PageTables' /proc/meminfo`. Happy with the number? Stop here.
2. Disable transparent huge pages.
3. Get the requirement — `SHOW shared_memory_size_in_huge_pages;` on the running server.
4. Reserve it at boot in `/etc/sysctl.d/`, plus a margin.
5. Multi-socket box — check `vm.zone_reclaim_mode = 0`.
6. Choose `huge_pages = on`, or `try` with an alert.
7. Restart. Confirm `HugePages_Free` dropped and `huge_pages_status` reads `on`.
8. Re-measure, compare with step 1.

---

## Notes

[^scaling]: The ceiling assumes every backend has read all of `shared_buffers`; 64 MB is the figure for a fully warmed one. A backend only allocates entries for pages it has actually touched, so its table grows with what it has read over its whole lifetime. The longer it lives the closer it drifts to the ceiling — unless it only ever queries a couple of small tables, in which case it stays cheap no matter how long it runs.


[^try]: With `try`, PostgreSQL asks for `MAP_HUGETLB` and, if that fails, silently retries the mapping without it. The server starts, looks healthy, and runs on 4 KB pages. The common ways to end up there: `vm.nr_hugepages` never set; set but too small after `shared_buffers` grew; or set with `sysctl -w` and never persisted to `/etc/sysctl.d/`, so it vanished at the last reboot.

[^status]: `huge_pages_status` was added in PostgreSQL 17 precisely because `try` gave no way to confirm the outcome. A running instance reports `on` or `off`. The third value, `unknown`, means the status could not be determined — you get it when the parameter is read with `postgres -C` against a stopped server, since nothing has been allocated yet.


[^gb]: 1 GB pages cut the entry count further, but they cannot be reserved reliably at runtime — memory is usually too fragmented by then — so they need kernel command-line parameters and a reboot: `hugepagesz=1G hugepages=36`, in that order. You must then also set `huge_page_size = 1GB` in PostgreSQL: without it the server asks for the 2 MB default, your gigabyte pool sits untouched, and with `huge_pages = try` it happens silently. Sizing gets coarse too — the whole shared memory segment rounds up to the next gigabyte, not just `shared_buffers`. On kernels 5.7+, `hugetlb_cma=` is a middle ground: the area is set aside at boot, but pages are allocated from it at runtime and the memory stays usable for movable allocations until then.



[^recycle]: Recycling throws away *warm* page tables along with bloated ones. Too short a lifetime buys a steady stream of re-faults, plus fork cost, plus a cold catalog cache on every new backend. It is a trade between steady-state table size and fault frequency, not a free win. Most poolers also offer an idle-based equivalent, which achieves the same thing driven by idleness rather than age and is usually the cheaper of the two. In PgBouncer these are [`server_lifetime` and `server_idle_timeout`](https://www.pgbouncer.org/config.html); other poolers use their own names for the same two ideas.

[^lifo]: Pool documentation is inconsistent about naming this. The behaviour that keeps backends cold is the stack-like one — most-recently-used connection reused first, often labelled **LIFO** or **MRU**. The queue-like behaviour — **FIFO** or round-robin — warms every backend. Check what your driver actually does rather than trusting the acronym, and confirm it by comparing `VmPTE` across backends: an even spread means all are hot, a wide spread means only a subset is.

[^local]: `work_mem`, `maintenance_work_mem`, catalog and plan caches are all still backed by 4 KB pages. Huge pages apply to the shared memory segment only.