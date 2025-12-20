---
layout: post
title: AWS RDS Proxy for PostgreSQL
date: 2026-01-18
---

This overview does not compare RDS Proxy and other poolers. It is only focused on describing RDS Proxy so that readers can compare it on their own with other open-source connection poolers.

> ℹ️ **INFO:** For testing purposes, you can use an [example](https://github.com/boosterKRD/boosterKRD.github.io/tree/main/tests/rds-proxy-deploying-test/deploy.md) of deploying a test RDS Proxy.

<!--MORE-->

-----

## Table of Contents

1. [Overview](#overview)
2. [Configuration](#configuration)
   - [Pooler Options](#pooler-options)
   - [Authentication Options](#authentication-options)
   - [Security Options](#security-options)
3. [Multiplexing and Pinned Connections](#multiplexing-and-pinned-connections)
4. [Extended Protocol and Prepared Statements](#extended-protocol-and-prepared-statements)
5. [Monitoring](#monitoring)
6. [Pros and Cons](#pros-and-cons)
7. [Pricing](#pricing)
8. [Additional Resources](#additional-resources)

---

## Overview

![RDS Proxy](/assets/images/basic-rds-proxy.png)


### How It Works

RDS Proxy maintains a pool of database connections in a "ready-to-use" state. It continuously monitors these connections, refreshing or creating new ones as necessary. Note that RDS Proxy manages the number of connections it keeps in the server pool automatically, based on the current workload (DBAs do not have the ability to control this).

When a **transaction** request is made, RDS Proxy retrieves a connection from the pool and uses it to execute the transaction.

RDS Proxy multiplexes connections at transaction boundaries and falls back to pinned sessions when session-level state is required. By default, connections are reusable after a transaction, meaning the same connection may be used by different, unrelated components.

This ability to reuse connections for multiple transactions increases RDS Proxy's efficiency, enabling it to handle more connections than the database typically supports. Ultimately, RDS Proxy scales as required, with the database's limitations becoming the bottleneck.

RDS Proxy makes applications more resilient to database failures by automatically connecting to a standby DB instance while preserving application connections.

---

## Configuration

RDS Proxy has a few configurable parameters, which are grouped into the sections below.

### Pooler Options

- **Idle client connection timeout**: The amount of time a client connection can remain idle before the proxy disconnects it. The minimum is 1 minute and the maximum is 8 hours.
- **Connection pool maximum connections**: This parameter is a percentage of the maximum DB connection limit, controlling how many connections RDS Proxy can establish with the database.
- **Connection borrow timeout**: The timeout for borrowing a DB connection from the pool. It's similar to PgBouncer's [query_wait_timeout](https://www.pgbouncer.org/config.html#query_wait_timeout) parameter.
- **Initialization query**: A list of SQL statements to set up the initial session state for each connection.

### Authentication Options

- **Secrets Manager secrets**: List of users' secrets which allow to connect to RDS Proxy.
- **Client authentication type**: Supports MD5 or SHA-256 authentication methods for client connections to the proxy.
- **IAM authentication**: You can use IAM authentication to connect to the proxy, **in addition** to specifying database credentials.
  - **Not Allowed**: Clients can connect without IAM authentication using secrets to access both RDS Proxy and PostgreSQL.
  - **Required**: Clients must use IAM authentication to connect to RDS Proxy and a secret to connect to the database. The diagram below illustrates how this mode works:

![IAM Authentication Schema](/assets/images/rds-proxy-with-iam.png)

### Security Options

- **Require Transport Layer Security**: Enforces the use of TLS for connections between **RDS Proxy and the database**, ensuring that all traffic between them is encrypted.

Additionally, TLS can also be enforced between **the application and RDS Proxy** by [specifying the required settings](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.howitworks.html#rds-proxy-security.tls) on the client side (--ssl-mode). To download the TLS certificate for RDS Proxy, use this [link](https://www.amazontrust.com/repository/).

---

## Multiplexing and Pinned Connections

As mentioned earlier, RDS Proxy uses transactional multiplexing to efficiently manage connections to the database. However, certain operations in your application can cause connections to become **pinned**, meaning they are dedicated exclusively to a single client session and cannot be shared with other sessions. This reduces the effectiveness of connection pooling because pinned connections cannot be reused by other clients until they are unpinned.

### Conditions That Cause Pinning

Connections become pinned when the application performs operations that require session-level state to be maintained across multiple transactions. Common actions that cause pinning include:

- **Using Temporary Tables**: Creating or manipulating temporary tables within a session.
- **Session-Level Variables**: Modifying or relying on session variables or settings.
- **Prepared Statements (SQL-level)**: Using `PREPARE`, `EXECUTE`, `DEALLOCATE` SQL commands.
- **Specific SQL Features**: Utilizing features like cursors, advisory locks, or other session-dependent functions.

You can find the full list of conditions that cause pinning for RDS for PostgreSQL in the AWS [documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html#rds-proxy-pinning.postgres).

### Impact of Pinned Connections

A high number of pinned connections can significantly degrade the performance benefits of RDS Proxy. Since pinned connections cannot be shared, the proxy's ability to efficiently multiplex connections is reduced.

When you consider the opportunity to use RDS Proxy for a client, it's essential to research their workload to determine if there are conditions that could cause a large number of pinned connections. A significant number of pinned connections can negate all the advantages of using RDS Proxy.

Fortunately, AWS provides a metric for monitoring the number of pinned connections (`DatabaseConnectionsCurrentlySessionPinned`).

---

## Extended Protocol and Prepared Statements

This is an important section for developers using PostgreSQL drivers that support Extended Protocol (e.g., pgx, pq in Go, npgsql in .NET, asyncpg in Python, node-postgres in Node.js).

### RDS Proxy and Prepared Statements

RDS Proxy **detects** prepared statements (both SQL-level and protocol-level) and causes the connection to become **pinned** when they are used. This is documented in the [AWS RDS Proxy documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html#rds-proxy-pinning.postgres):

> "Using PREPARE, DISCARD, DEALLOCATE, or EXECUTE commands to manage prepared statements" — causes pinning

Here's how RDS Proxy behaves with different scenarios:

| Scenario | RDS Proxy Behavior |
|----------|-------------------|
| SQL `PREPARE`/`EXECUTE` commands | **Pinning** |
| Protocol-level named prepared statements (e.g., pgx cached) | **Pinning** |
| Protocol-level unnamed prepared statements | May cause **Pinning** |
| Simple Protocol (no prepared statements) | ✅ No pinning |

### Why Prepared Statements Cause Pinning

When RDS Proxy detects that a client is using prepared statements:

1. The connection becomes **pinned** to that specific client session
2. The connection cannot be reused by other clients (multiplexing is disabled)
3. The connection remains pinned for the duration of the session
4. This significantly reduces the efficiency of connection pooling

**Why this matters:** If your application heavily uses prepared statements, RDS Proxy's main advantage (connection multiplexing) is lost, and you may not benefit from using it.

### Comparison with PgBouncer

Unlike RDS Proxy, **PgBouncer 1.21+** (released October 2023) supports protocol-level prepared statements in transaction mode via the `max_prepared_statements` setting. PgBouncer intercepts Parse/Bind/Execute messages and automatically recreates prepared statements on the appropriate backend, allowing connection reuse without pinning.

| Feature | RDS Proxy | PgBouncer 1.21+ |
|---------|-----------|-----------------|
| SQL `PREPARE`/`EXECUTE` | **Pinning** (no multiplexing) | ❌ Not supported |
| Protocol-level named prepared statements | **Pinning** (no multiplexing) | ✅ Supported with multiplexing |
| Protocol-level unnamed prepared statements | May cause **Pinning** (no multiplexing) | ✅ Supported with multiplexing |
| Simple Protocol | ✅ No pinning | ✅ Works |

**Bottom line:** If you need to use RDS Proxy with applications that heavily use prepared statements, you'll face a choice:
1. Accept connection pinning (losing RDS Proxy's main benefit)
2. Switch to Simple Protocol (losing binary format and plan caching benefits)
3. Consider using PgBouncer 1.21+ instead, which supports prepared statements without pinning

---

## Monitoring

CloudWatch collects the metrics for RDS Proxy such as:

- **DatabaseConnectionsBorrowLatency**: The time in microseconds that it takes for the proxy to get a database connection.
- **DatabaseConnectionsCurrentlyBorrowed**: The current number of database connections in the borrow state.
- **DatabaseConnectionsCurrentlySessionPinned**: The number of database connections pinned due to client operations that change session state. A consistently high value usually means that RDS Proxy provides little to no benefit for the workload.
- **DatabaseConnections**: The current number of database connections.
- **ClientConnections**: The current number of client connections.

See the [full list of RDS Proxy metrics](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.monitoring.html).

### Enhanced Logging

AWS provides 'activate enhanced logging' which enables detailed logging for monitoring and troubleshooting purposes. This is a way to track pinned connections:

```text
2024-10-12T17:20:40 [WARN] [proxyEndpoint=default] [clientConnection=2125203372]
The client session was pinned to the database connection [dbConnection=1953961465]
for the remainder of the session. The proxy can't reuse this connection until the
session ends. Reason: SQL changed session settings that the proxy doesn't track.
Consider moving session configuration to the proxy's initialization query.
Digest: "set search_path to $1,$2,$3".
```

---

## Pros and Cons

### Pros

1. **Integrated with AWS Ecosystem**: RDS Proxy is fully managed by AWS and seamlessly integrates with RDS and Aurora databases, eliminating the need to deploy and manage additional infrastructure. High availability and failover handling are provided out of the box.

2. **Reduced Downtime During Failovers and Switchover**: RDS Proxy can reduce downtime in case of an instance failure or switchover during minor upgrade. It maintains client connections during failovers, reducing application disruptions.
   - In standard RDS PostgreSQL **Multi-AZ DB Instance**, the switchover process is typically observed in the 20–40 second range, primarily due to DNS endpoint changes.
   - RDS Proxy can reduce failover time to around 10-15 seconds by using internal connections and avoiding the wait for DNS changes.
   - In **RDS Multi-AZ DB cluster** switchover typically occurs within 35 seconds, but with RDS Proxy it can be reduced significantly, often to a few seconds.

   > **INFO:** The same fast switchover can be achieved on **RDS Multi-AZ DB cluster** with PgBouncer as well if PgBouncer is patched by [AWS patch](https://github.com/awslabs/pgbouncer-fast-switchover). [Read more](https://aws.amazon.com/blogs/database/fast-switchovers-with-pgbouncer-on-amazon-rds-multi-az-deployments-with-two-readable-standbys-for-postgresql/)

3. **Better Scaling**: Efficiently handles spikes in application traffic by pooling and reusing connections, preventing the database from being overwhelmed by connection requests.

### Cons

1. **VPC-Only Access**: RDS Proxy can be used only within a Virtual Private Cloud (VPC) and cannot be publicly accessible from the internet.

2. **Limited Configuration Options**: Offers limited configurability, providing few parameters for modification compared to other connection poolers like PgBouncer.

3. **No Multiplexing with Protocol-Level Prepared Statements**: Unlike PgBouncer 1.21+, RDS Proxy does not support connection multiplexing when protocol-level prepared statements are used, which leads to session pinning and may require application-level changes.

4. **Additional Cost**: RDS Proxy is not free. AWS charges for its usage based on the number of vCPUs of the database instance. See the [Pricing section](#pricing) for details.

---

## Pricing

RDS Proxy pricing is based on the capacity of the underlying database.

For detailed pricing information, refer to the [AWS RDS Proxy Pricing](https://aws.amazon.com/rds/proxy/pricing/).

- Aurora Serverless v2: billed per ACU-hour (typically around $0.015 per ACU hour)
- Provisioned instances: billed per vCPU-hour (typically around $0.015 per vCPU hour, with a minimum charge for 2 vCPUs)

**Example:**

If you are running an Amazon RDS PostgreSQL `t2.small` instance with 1 vCPU and have enabled RDS Proxy, billing is calculated using the minimum of 2 vCPUs.

For a 30-day month:
- Total vCPU-hours: 2 vCPUs × 24 hours/day × 30 days = 1,440 vCPU-hours
- Total cost: $0.015 × 1,440 = **$21.60**

---

## Additional Resources

- [Using Amazon RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html)
- [Using TLS/SSL with RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.howitworks.html#rds-proxy-security.tls)
- [Using Amazon RDS Proxy with AWS Lambda](https://aws.amazon.com/blogs/compute/using-amazon-rds-proxy-with-aws-lambda/)
- [Amazon Relational Database Service Proxy FAQs](https://aws.amazon.com/rds/proxy/faqs/)
- [AWS RDS Proxy Deep Dive: What is it and when to use it](https://www.learnaws.org/2020/12/13/aws-rds-proxy-deep-dive/)
- [IAM database authentication for MariaDB, MySQL, and PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html)
- [Setting up database credentials in AWS Secrets Manager for RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-secrets-arns.html)
- [Fast switchovers with PgBouncer on Amazon RDS Multi-AZ deployments](https://aws.amazon.com/blogs/database/fast-switchovers-with-pgbouncer-on-amazon-rds-multi-az-deployments-with-two-readable-standbys-for-postgresql/)
- [PgBouncer 1.21.0 - Prepared Statements Support](https://www.pgbouncer.org/2023/10/pgbouncer-1-21-0)
