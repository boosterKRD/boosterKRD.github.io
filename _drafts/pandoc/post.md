---
title: "Sweatcoin - PgBouncer upgrade"
author: Data Egret (Marat Bogatyrev, Stefan Fercot)
date: "2024-07-05"
...

# Introduction

Back in April, the Sweatcoin team asked to upgrade the version of the current PgBouncer (`1.12.0`) servers because they'd like to ultimately try using prepared statements in the transaction mode (available since `1.21.0`). Since another big task (PG upgrade) was going on at that time too, we've waited for the new Ubuntu LTS release to install the new servers.

Our team has dedicated substantial time and resources to enhancing this PgBouncer setup, ensuring a more efficient and reliable experience. We are excited to share some significant updates regarding these recent efforts, and we are confident that these advancements will greatly benefit maintenance operations and enhance overall system performance.

---

# Activity summary

In order to use multiple PgBouncer processes together to serve on 1 PG host, multiple PgBouncer instances have been configured on the old servers to run using a systemd service template. This approach required explicit service management commands to start, stop, and monitor the PgBouncer service instances. With the latest PgBouncer releases, it is now recommended to use systemd socket activation.
With this setup, the PgBouncer service is controlled by systemd sockets, which automatically start the PgBouncer service when a connection request is detected. This method simplifies management and have other benefits.

After thorough research and testing of this new setup, we investigated the current load of the PgBouncers servers to figure out how many processes would still be needed.
Then, to prepare the configuration we've also checked all the pools definitions (users, pool sizes,...) across each PgBouncer groups and PG databases.
And we've also suggested to use the fully qualified domain name of the PG hosts (`*.sweatco.cc`) to avoid maintaining a local `/etc/hosts` file.

Once done, the new nodes were installed with `Ubuntu 24.04 LTS` and `PgBouncer 1.22.1`.
Proper new dashboards have also been created in Odarix to allow for more significant monitoring after the upgrade.

While the new PgBouncer nodes were ready to be used, PgBouncer [`1.23.0`](https://www.pgbouncer.org/changelog.html#pgbouncer-123x) has been released on July 3rd and after waiting for the community packages (from PGDG APT repositories) to be available, this new version has successfully been installed.

The plan forward is, now that `1.23.0` is installed, to let the Sweatcoin team add some traffic on the new PgBouncer servers and test it. During this transition period, both old and new nodes will be used. So we'll carefully monitor the number of connections on the PG hosts to avoid any major disruption. Once the traffic will be fully switched on the new servers, we'll have a closer look at the activity to investigate if more PgBouncers processes would be needed.

---

## New setup overview

### Diagrams

Here is an overview of the new setup, including listening ports and sockets numbers.

* **cdb** cluster

```
          Clients_RW                            Clients_RO 
              │                                     │ 
 ┌────────────▼──────────────┐       ┌──────────────▼──────────────┐ 
 │     PgBouncer-Primary     │       │      PgBouncer-Replica      │ 
 │         (Port 7432)       │       │         (Port 7433)         │ 
 │ 2 Processes (so_reuseport)│       │ 2 Processes (so_reuseport)  │  
 │   sockets 10001,10002     │       │   sockets 10101,10102       │ 
 └────────────┬──────────────┘       └─────────────-┬──────────────┘ 
              │                                     │ 
   ┌──────────▼──────────────┐          ┌──────────-▼─────────────┐ 
   │   Primary PostgreSQL    │          │   Replica PostgreSQL    │ 
   │        TCP 5432         │          │        TCP 5432         │  
   └─────────────────────────┘          └─────────────────────────┘
```

* **sdb0** cluster

```
          Clients_RW                            Clients_RO 
              │                                     │ 
 ┌────────────▼──────────────┐       ┌──────────────▼──────────────┐ 
 │     PgBouncer-Primary     │       │      PgBouncer-Replica      │ 
 │         (Port 9432)       │       │         (Port 9433)         │ 
 │ 1 Processes (so_reuseport)│       │ 1 Processes (so_reuseport)  │  
 │   sockets 30001           │       │   sockets 30101             │ 
 └────────────┬──────────────┘       └─────────────-┬──────────────┘ 
              │                                     │ 
   ┌──────────▼──────────────┐          ┌──────────-▼─────────────┐ 
   │   Primary PostgreSQL    │          │   Replica PostgreSQL    │ 
   │        TCP 5432         │          │        TCP 5432         │  
   └─────────────────────────┘          └─────────────────────────┘
```

* **sdb1** cluster

```
          Clients_RW                            Clients_RO 
              │                                     │ 
 ┌────────────▼──────────────┐       ┌──────────────▼──────────────┐ 
 │     PgBouncer-Primary     │       │      PgBouncer-Replica      │ 
 │         (Port 6432)       │       │         (Port 6433)         │ 
 │ 1 Processes (so_reuseport)│       │ 1 Processes (so_reuseport)  │  
 │   sockets 40001           │       │   sockets 40101             │ 
 └────────────┬──────────────┘       └─────────────-┬──────────────┘ 
              │                                     │ 
   ┌──────────▼──────────────┐          ┌──────────-▼─────────────┐ 
   │   Primary PostgreSQL    │          │   Replica PostgreSQL    │ 
   │        TCP 5432         │          │        TCP 5432         │  
   └─────────────────────────┘          └─────────────────────────┘
```

### Some interesting administration tasks

* Each sockets group has its own shared log file:

```bash
$ ls /var/log/postgresql
pgbouncer-sdb0-primary.log
pgbouncer-sdb0-replica.log
pgbouncer-sdb1-primary.log
pgbouncer-sdb1-replica.log
pgbouncer-sweatcoin-primary.log
pgbouncer-sweatcoin-replica.log
```

* Command to check the listening ports:

```bash
$ sudo netstat -tulnp | grep -E '7432|7433|9432|9433|6432|6433'
tcp        0      0 0.0.0.0:9433            0.0.0.0:*               LISTEN      1/init
tcp        0      0 0.0.0.0:9432            0.0.0.0:*               LISTEN      1/init
tcp        0      0 0.0.0.0:7433            0.0.0.0:*               LISTEN      1/init
tcp        0      0 0.0.0.0:7433            0.0.0.0:*               LISTEN      1/init
tcp        0      0 0.0.0.0:7432            0.0.0.0:*               LISTEN      1/init
tcp        0      0 0.0.0.0:7432            0.0.0.0:*               LISTEN      1/init
```

* Command to see what sockets are active:

```bash
$ sudo systemctl list-sockets | grep pgbouncer
# cdb
0.0.0.0:7432                          pgbouncer_primary@10001.socket      pgbouncer_primary@10001.service
0.0.0.0:7432                          pgbouncer_primary@10002.socket      pgbouncer_primary@10002.service
/run/postgresql/.s.PGSQL.10001        pgbouncer_primary@10001.socket      pgbouncer_primary@10001.service
/run/postgresql/.s.PGSQL.10002        pgbouncer_primary@10002.socket      pgbouncer_primary@10002.service
0.0.0.0:7433                          pgbouncer_replica@10102.socket      pgbouncer_replica@10102.service
0.0.0.0:7433                          pgbouncer_replica@10101.socket      pgbouncer_replica@10101.service
/run/postgresql/.s.PGSQL.10101        pgbouncer_replica@10101.socket      pgbouncer_replica@10101.service
/run/postgresql/.s.PGSQL.10102        pgbouncer_replica@10102.socket      pgbouncer_replica@10102.service
# sdb0
0.0.0.0:9432                          pgbouncer_sdb0_primary@30001.socket pgbouncer_sdb0_primary@30001.service
/run/postgresql/.s.PGSQL.30001        pgbouncer_sdb0_primary@30001.socket pgbouncer_sdb0_primary@30001.service
0.0.0.0:9433                          pgbouncer_sdb0_replica@30101.socket pgbouncer_sdb0_replica@30101.service
/run/postgresql/.s.PGSQL.30101        pgbouncer_sdb0_replica@30101.socket pgbouncer_sdb0_replica@30101.service
# sdb1
0.0.0.0:6532                          pgbouncer_sdb1_primary@40001.socket pgbouncer_sdb1_primary@40001.service
/run/postgresql/.s.PGSQL.40001        pgbouncer_sdb1_primary@40001.socket pgbouncer_sdb1_primary@40001.service
/run/postgresql/.s.PGSQL.40101        pgbouncer_sdb1_replica@40101.socket pgbouncer_sdb1_replica@40101.service
0.0.0.0:6533                          pgbouncer_sdb1_replica@40101.socket pgbouncer_sdb1_replica@40101.service
```

* To connect to PgBouncer administration console:

```bash
su - postgres
# cdb primary
psql -U pgbouncer -p 10001
psql -U pgbouncer -p 10002
# cdb replica
psql -U pgbouncer -p 10101
psql -U pgbouncer -p 10102
# sdb0 primary
psql -U pgbouncer -p 30001
# sdb0 replica
psql -U pgbouncer -p 30101
# sdb1 primary
psql -U pgbouncer -p 40001
# sdb1 replica
psql -U pgbouncer -p 40101
```

The access to the administration console let's you pause or resume the traffic on each processes for i.e. performing a database maintenance operation.

### Rolling version upgrade

In the future, thanks to the new signal management added in PgBouncer `1.23.0`, we would be able to perform a seamless rolling upgrade by performing the following steps.

* First of all, we'll need to mask the PgBouncer services to prevent auto-reloading after installation of the new version:

```bash
systemctl mask pgbouncer_primary@10001.service
systemctl mask pgbouncer_primary@10002.service
systemctl mask pgbouncer_replica@10101.service
systemctl mask pgbouncer_replica@10102.service
systemctl mask pgbouncer_sdb0_primary@30001.service
systemctl mask pgbouncer_sdb0_replica@30101.service
systemctl mask pgbouncer_sdb1_primary@40001.service
systemctl mask pgbouncer_sdb1_replica@40101.service
```

* Upgrade PgBouncer version using `apt-get install` command.

* Unmask the services:

```bash
systemctl unmask pgbouncer_primary@10001.service
systemctl unmask pgbouncer_primary@10002.service
systemctl unmask pgbouncer_replica@10101.service
systemctl unmask pgbouncer_replica@10102.service
systemctl unmask pgbouncer_sdb0_primary@30001.service
systemctl unmask pgbouncer_sdb0_replica@30101.service
systemctl unmask pgbouncer_sdb1_primary@40001.service
systemctl unmask pgbouncer_sdb1_replica@40101.service
```

* Have at least two or more PgBouncer processes running on the same port. To achieve seamless zero downtime when restarting we'd restart these processes one-by-one, thus leaving the others running to accept connections while one is being restarted.

In example, add another socket for `sdb0` primary:

```bash
systemctl start pgbouncer_sdb0_primary@30002.socket
```

* Stopping PgBouncer processes using the old version. It can be done either running `systemctl stop pgbouncer_sdb0_primary@30001.service` (for `sdb0` primary) or issuing the `SHUTDOWN WAIT_FOR_SERVERS` command.

* Start the stopped socket again and apply the same procedure to all sockets.
* Finally, stop the temporary sockets added specifically for this upgrade.

_Remark:_ This procedure would have to get validated once the next PgBouncer version will be released.