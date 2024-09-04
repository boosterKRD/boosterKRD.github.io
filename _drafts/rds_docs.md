Best practices for working with PostgreSQL
    https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.html#CHAP_BestPractices.PostgreSQL

Working with the PostgreSQL autovacuum on Amazon RDS for PostgreSQL
    https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Autovacuum.html    

Common DBA tasks for Amazon RDS for PostgreSQL
    https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.html    

Resource Consumption #
https://www.postgresql.org/docs/current/runtime-config-resource.html


log_fwd
https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Extensions.foreign-data-wrappers.html#CHAP_PostgreSQL.Extensions.log_fdw

Extension versions for Amazon RDS for PostgreSQL
    https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html#postgresql-extensions-16x

RDS for PostgreSQL DB instance parameter list
    https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Parameters.html

USER namagment
- rds_password 
    - To use restricted password management, your RDS for PostgreSQL DB instance must be running PostgreSQL 10.6 or higher with param rds.restrict_password_commands=1 **(requires a reboot)**.
        * rds_password gives permission to user to execute the fellowing SQL commands: 
        ```sql
        CREATE ROLE myrole WITH PASSWORD 'mypassword';
        CREATE ROLE myrole WITH PASSWORD 'mypassword' VALID UNTIL '2023-01-01';
        ALTER ROLE myrole WITH PASSWORD 'mypassword' VALID UNTIL '2023-01-01';
        ALTER ROLE myrole WITH PASSWORD 'mypassword';
        ALTER ROLE myrole VALID UNTIL '2023-01-01';
        ALTER ROLE myrole RENAME TO myrole2;
        ```
       With this feature active, attempting any of these SQL commands without the rds_password role permissions generates the following error:
       **ERROR: must be a member of rds_password to alter passwords**
    - If you grant rds_password privileges to database users that don't have rds_superuser privileges, you need to also grant them the CREATEROLE attribute to change password of other users.