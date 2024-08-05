---
layout: post
title: logerrors extension
date: 2023-06-21
---
XXX

<!--MORE-->

-----

[GitHub - munakoiso/logerrors ](https://github.com/munakoiso/logerrors)
Extension for PostgreSQL for collecting statistics about messages in logfile.
Configuration variables:
- logerrors.interval - Time between writing statistic to buffer (ms). Default of 5s, max of 60s;
- logerrors.intervals_count - Count of intervals in buffer. Default of 120, max of 360. During this count of intervals messages doesn't dropping from statistic;
- logerrors.excluded_errcodes - Excluded error codes separated by ",".

[Creating Debian/Ubuntu .deb packages](https://www.iodigital.com/en/history/intracto/creating-debianubuntu-deb-packages)

Так как пакетов для данной tools не предусмотрено (свойственно для многих проектов под эгидой yandex) то Нужно сделать deb пакеты самим, описание процесса ниже
Install on UBUNTU
```bash
apt-get install checkinstall
apt install postgresql-server-dev-13
wget https://github.com/munakoiso/logerrors/archive/refs/tags/v1.1.tar.gz
tar -xzvf v1.1.tar.gz
cd logerrors-1.1/
sudo checkinstall
#Пакето создан, можно его устанавливать везде
dpkg -i logerrors_1.1-1_amd64.deb
dpkg -r logerrors #UNINSTALL
```

Install on CENTOS
```bash
yum install logerrors_13
ИЛИ из исходников
export PATH="$PATH:/usr/pgsql-13/bin/"
yum install postgresql13-devel -y
yum install redhat-rpm-config -y
tar -xzvf v1.1.tar.gz
cd logerrors-1.1
make 
make install
```

Usage
```sql
shared_preload_libraries = 'logerrors'
CREATE EXTENSION logerrors
select * from  pg_log_errors_stats()
select * from pg_slow_log_stats()
select pg_log_errors_reset();
```

After creating extension you can call pg_log_errors_stats() function in psql (without any arguments).
```bash
    postgres=# select * from pg_log_errors_stats();
     time_interval |  type   |       message        | count
    ---------------+---------+----------------------+-------
                   | WARNING | TOTAL                |     0
                   | ERROR   | TOTAL                |     3
               600 | ERROR   | ERRCODE_SYNTAX_ERROR |     3
                 5 | ERROR   | ERRCODE_SYNTAX_ERROR |     2
                   | FATAL   | TOTAL                |     0
```
In output you can see 4 columns:
```bash
time_interval: how long (in seconds) has statistics been collected.
type: postgresql type of message (now supports only these: warning, error, fatal).
message: code of message from log_hook. (or 'TOTAL' for total count of that type messages)
count: count of messages of this type at this time_interval in log.
```

To get number of lines in slow log call pg_slow_log_stats():
```bash
    postgres=# select * from pg_slow_log_stats();
     slow_count |         reset_time
    ------------+----------------------------
              1 | 2020-06-13 00:19:31.084923
    (1 row)
```

To reset all statistics use
```bash
 select pg_log_errors_reset();
```


  # TELEGRAF query
  #ERROR code Syntax Error or Access Rule Violation
  [[inputs.postgresql_extensible.query]]
  sqlquery="select CURRENT_TIMESTAMP(0)::TIMESTAMP as q_time, type as error_level, lower(replace(message,'ERRCODE_','')) as error_msg, count as errors_by_name_count from pg_log_errors_stats() where time_interval>10;"
  version=901
  withdbname=false
  tagvalue=""

#ERROR code Syntax Error or Access Rule Violation
  [[inputs.postgresql_extensible.query]]
  sqlquery="select type as error_level, lower(replace(message,'ERRCODE_','')) as error_msg, count as errors_by_name from pg_log_errors_stats() where time_interval>10;"
  version=901
  withdbname=false
  tagvalue=""


  #ERROR code Syntax Error or Access Rule Violation
  [[inputs.postgresql_extensible.query]]
  sqlquery="select type as error_level, lower(replace(message,'ERRCODE_','')) as error_msg, count as errors_my3_count from pg_log_errors_stats() where time_interval>10 and message IN ('ERRCODE_DIVISION_BY_ZERO', 'ERRCODE_UNDEFINED_TABLE', 'ERRCODE_UNDEFINED_COLUMN');"
  version=901
  withdbname=false
  tagvalue=""

  #ERROR code stat
  [[inputs.postgresql_extensible.query]]
  sqlquery="select type as error_level, count as errors3_total_count from  pg_log_errors_stats() where message='TOTAL';"
  version=901
  withdbname=false
  tagvalue=""