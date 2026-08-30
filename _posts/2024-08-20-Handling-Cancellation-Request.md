---
layout: post
title: Handling Cancellation Request 
date: 2024-08-20
---
**[Original post URL](https://dataegret.com/2024/08/handling_cancellation_request/)**


## Introduction
PgBouncer is a popular connection pooler for PostgreSQL that helps optimize database performance by reducing the number of open connections and improving overall efficiency. It's widely used in database clusters as a link between the client and the server, and often works alongside different load balancers. However, in some cases, issues with cancellation requests can arise. Let's explore when this problem occurs and how it can be solved.

### Table of Contents
1. [Introduction](#introduction)
2. [What is a Cancellation Request?](#what-is-a-cancellation-request)
3. [How Cancellation Requests Work in PostgreSQL](#how-cancellation-requests-work-in-postgresql)
4. [Issues with Cancellation Requests](#issues-with-cancellation-requests)
    1. [Load Balancer in Front of the Database Server](#load-balancer-in-front-of-the-database-server)
    2. [Using PgBouncer in so_reuseport Mode and/or Multiple PgBouncer Instances](#using-pgbouncer-in-so_reuseport-mode-andor-multiple-pgbouncer-instances)
5. [Proposed Solution](#proposed-solution)
6. [Testing the Peering Configuration](#testing-the-peering-configuration)
7. [Conclusion](#conclusion)

<!--MORE-->

-----

## What is a Cancellation Request?

The PostgreSQL protocol allows a client to interrupt a currently running query. This feature is known as [_Canceling Requests in Progress_](https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-CANCELING-REQUESTS). It’s useful when a query is taking too long to execute or is no longer needed (in psql, you can trigger such a request simply by pressing Ctrl+C). The most important part for us is that a **separate connection** **is created** to send a CancelRequest message with a secret key. This secret key is provided by the server at the start of the original connection and acts as a barrier to prevent external cancellations, as only the connection running the query has access to this key.

Even though a cancellation request is sent successfully, the server might not always process it in time if the query has already been completed.

For those interested in how cancellation requests can be handled programmatically, the post '[How to Terminate Database Query Using Context in Go](https://medium.com/@ankit1994skd/context-aware-query-d9b0275f5650)' provides an excellent example. This post shows how to use Go’s `context` package to manage and cancel long-running queries efficiently.

## How Cancellation Requests Work in PostgreSQL

Let’s break down the logic of how a cancellation request works step by step:

1. **Client Connection:** The client connects to the PostgreSQL server and receives a secret key.
2. **Sending a Query:** The client sends an SQL query to be executed by the server.
3. **Deciding to Cancel:** The client decides to cancel the ongoing query. This can happen for various reasons, such as a timeout or user intervention.
4. **Initiating the Cancellation:**
    * The client opens a new connection to the PostgreSQL server.
    * Through this **new connection**, the client sends a cancellation command along with the secret key that was provided by the server during the initial connection.
5. **Cancellation Outcome:**
    * If the cancellation is successful, the ongoing query (from step 2) will terminate prematurely and return an error.
    * If the server has already completed processing the query, the cancellation will have no visible effect.

## Issues with Cancellation Requests

When using PgBouncer and Load Balancers in various configurations, certain issues with cancellation requests can occur.

The common challenge in both scenarios described below is that the cancellation request might not reach the original process or instance handling the query, causing the request to be ignored.

### **1. Load Balancer in Front of the Database Server (e.g., NLB, HAProxy)**

Load balancers are typically used to distribute incoming requests across multiple database instances, often read replicas, to optimize resource usage and improve performance. This setup is particularly beneficial in read-heavy environments, where multiple replicas can serve read requests simultaneously, reducing the load on the primary database server.

![pgbouncer_1](/assets/posts/pgbouncer1.png)

In a scenario where a load balancer is placed in front of the database server, a cancellation request might be directed to a different database instance than the one processing the original query. This happens because the cancellation request opens a new TCP connection (step 3), which can be handled by any of the PostgreSQL replicas. When the cancellation request reaches a replica, it looks for the corresponding active query in its list. If it doesn’t find it (step 4), the cancellation request will be ignored.

The only reliable method to manage query cancellation in this setup is to implement server-side controls. Setting a `statement_timeout` and using the `pg_cancel_backend(pid)` function can help mitigate the challenge, but these approaches require careful management, monitoring, and are not flexible.

### **2. Using PgBouncer in so_reuseport Mode and/or Multiple PgBouncer Instances**

![pgbouncer_2](/assets/posts/pgbouncer2.png)

In this scenario, a cancellation request might be routed to the wrong PgBouncer process that is not handling the original query. Just like in setups with load balancers, this happens because the cancellation request opens a new TCP connection (step 4), which can be handled by any of the PgBouncer processes. When the cancellation request reaches PgBouncer, it looks for the corresponding active server connection in its list. If it doesn’t find it (step 5) (for example, if another PgBouncer process is handling the query), the cancellation request will be ignored.

**Proposed Solution**

In version 1.19.0 of PgBouncer, [peering](https://www.pgbouncer.org/config.html#section-peers) support was introduced, allowing PgBouncer processes to correctly handle cancellation requests. When a cancellation request is received for an unknown session, PgBouncer checks the secret key, which contains the ID of the PgBouncer process that originally handled the query. If the request has been forwarded through a load balancer to a different instance, it will be forwarded to the peer that owns the session.

[Here is an example](https://github.com/pgbouncer/pgbouncer/pull/666) configuration for three PgBouncer processes within one instance with so_reuseport, utilizing the peering feature to handle cancellation requests.

```java
##### pgbouncer1.ini
[databases]
postgres = host=localhost dbname=postgres

[pgbouncer]
peer_id=1
pool_mode=transaction
listen_addr=127.0.0.1
auth_type=trust
admin_users=jelte
auth_file=auth_file.conf
so_reuseport=1
unix_socket_dir=/tmp/pgbouncer1

[peers]
2 = host=/tmp/pgbouncer2
3 = host=/tmp/pgbouncer3
```

```java
##### pgbouncer2.ini
[databases]
postgres = host=localhost dbname=postgres

[pgbouncer]
peer_id=2
pool_mode=transaction
listen_addr=127.0.0.1
auth_type=trust
admin_users=jelte
auth_file=auth_file.conf
so_reuseport=1
unix_socket_dir=/tmp/pgbouncer2

[peers]
1 = host=/tmp/pgbouncer1
3 = host=/tmp/pgbouncer3
```

```java
##### pgbouncer3.ini
[databases]
postgres = host=localhost dbname=postgres

[pgbouncer]
peer_id=3
pool_mode=transaction
listen_addr=127.0.0.1
auth_type=trust
admin_users=jelte
auth_file=auth_file.conf
so_reuseport=1
unix_socket_dir=/tmp/pgbouncer3

[peers]
1 = host=/tmp/pgbouncer1
2 = host=/tmp/pgbouncer2
```

#### Testing the Peering Configuration

To test if peering is working correctly, you can run a long query in psql and then try to cancel it:

```java
select pg_sleep(20);
```

After starting the query, press Ctrl+C to send a cancellation request. If peering is configured correctly, the query will be successfully canceled.

## Conclusion

Peering support in PgBouncer, starting from version 1.19.0, solves the problem of query cancellations when using multiple PgBouncer instances in a cluster and/or a multi-process configuration (so_reuseport). This feature allows PgBouncer processes to forward cancellation requests to the correct process or instance, ensuring the system operates correctly.

Using peering in PgBouncer is an important step towards improving the performance and reliability of systems utilizing load balancing.

ℹ️ INFO: In PgBouncer version 1.21.0, the method of encoding the peer_id in the cancellation token was changed. This change breaks the cancellation of queries in clusters with different versions of PgBouncer. Therefore, it is important to ensure that all PgBouncer processes and instances in the cluster are updated to the same version to ensure proper cancellation of queries.
