## Creating the test env

### 1.	Create an RDS PostgreSQL instance (Free Tier)

```bash
# Create subnet group 
aws rds create-db-subnet-group \
    --db-subnet-group-name my-db-test-subnet-group \
    --db-subnet-group-description "DB Subnet Group - Test RDS Proxy" \
    --subnet-ids subnet-0cf57825fcf0c3cbd subnet-05a8a2c78756260ed subnet-04d9bd19692972917

# Create RDS PostgreSQL instance
aws rds create-db-instance \
    --db-instance-identifier my-postgres-db \
    --db-instance-class db.t2.micro \
    --engine postgres \
    --allocated-storage 20 \
    --master-username postgres \
    --master-user-password Olimpusc770 \
    --vpc-security-group-ids sg-03d01fa1d6883bfae \
    --db-subnet-group-name my-db-test-subnet-group \
    --multi-az false \
    --storage-type gp2 \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --tags Key=Name,Value=MyPostgresDB \
    --engine-version 16.3
```

### 2.	Create an RDS Proxy for the PostgreSQL instance

```bash

cd /Users/maratbogatyrev/Documents/repo/dataegret/dba-docs-internal/amazon-rds/rds-proxy-deploying-test/test_env

#Create an IAM Role for RDS Proxy
aws iam create-role \
    --role-name RDSProxyRole \
    --assume-role-policy-document file://rds-proxy-trust-policy.json

# Create policy for RDS Proxy
aws iam create-policy \
    --policy-name RDSProxySecretsAndKMSAccessPolicy \
    --policy-document file://rds-proxy-secrets-policy.json

# Attache policy to role
aws iam attach-role-policy \
    --role-name RDSProxyRole \
    --policy-arn arn:aws:iam::381492223649:policy/RDSProxySecretsAndKMSAccessPolicy


# Create secret in Secret Manager
aws secretsmanager create-secret \
    --name staging/test/user_test1 \
    --description "Credentials for My Postgres DB" \
    --secret-string '{"username":"user_test1","password":"wolf"}'

aws secretsmanager create-secret \
    --name staging/test/postgres \
    --description "Credentials for My Postgres DB Bla Bla" \
    --secret-string '{"username":"postgres","password":"admin_pass"}'

# Create the RDS Proxy
aws rds create-db-proxy \
    --db-proxy-name my-postgres-proxy \
    --engine-family POSTGRESQL \
    --auth "{
        \"AuthScheme\": \"SECRETS\",
        \"SecretArn\": \"arn:aws:secretsmanager:<region>:<account-id>:secret:<your-secret-name>\",
        \"IAMAuth\": \"DISABLED\"
    }" \
    --role-arn arn:aws:iam::<account-id>:role/RDSProxyRole \
    --vpc-subnet-ids subnet-0cf57825fcf0c3cbd subnet-05a8a2c78756260ed subnet-04d9bd19692972917 \
    --vpc-security-group-ids sg-03d01fa1d6883bfae \
    --require-tls \
    --idle-client-timeout 1800 \
    --debug    

#Example
aws rds create-db-proxy \
    --db-proxy-name my-postgres-proxy \
    --engine-family POSTGRESQL \
    --auth "[
        {
            \"AuthScheme\": \"SECRETS\",
            \"SecretArn\": \"arn:aws:secretsmanager:eu-north-1:381492223649:secret:staging/test/postgres\",
            \"IAMAuth\": \"DISABLED\"
        },
        {
            \"AuthScheme\": \"SECRETS\",
            \"SecretArn\": \"arn:aws:secretsmanager:eu-north-1:381492223649:secret:staging/test/user_test1\",
            \"IAMAuth\": \"DISABLED\"
        }
    ]" \
    --role-arn arn:aws:iam::381492223649:role/RDSProxyRole \
    --vpc-subnet-ids subnet-0cf57825fcf0c3cbd subnet-05a8a2c78756260ed subnet-04d9bd19692972917 \
    --vpc-security-group-ids sg-03d01fa1d6883bfae \
    --require-tls \
    --idle-client-timeout 1800 \
    --debug    

aws rds create-db-proxy \
    --db-proxy-name my-postgres-proxy \
    --engine-family POSTGRESQL \
    --auth '[{"AuthScheme":"SECRETS","SecretArn":"arn:aws:secretsmanager:eu-north-1:381492223649:secret:staging/test/postgres","IAMAuth":"DISABLED"},{"AuthScheme":"SECRETS","SecretArn":"arn:aws:secretsmanager:eu-north-1:381492223649:secret:staging/test/user_test1","IAMAuth":"DISABLED"}]' \
    --role-arn arn:aws:iam::381492223649:role/RDSProxyRole \
    --vpc-subnet-ids subnet-0cf57825fcf0c3cbd subnet-05a8a2c78756260ed subnet-04d9bd19692972917 \
    --vpc-security-group-ids sg-03d01fa1d6883bfae \
    --require-tls \
    --idle-client-timeout 1800 \
    --debug

aws rds create-db-proxy-target-group \
    --db-proxy-name my-postgres-proxy \
    --target-group-name default \
    --db-instance-identifiers my-postgres-db \
    --connection-pool-configuration "{\"ConnectionBorrowTimeout\":120,\"MaxConnectionsPercent\":50,\"MaxIdleConnectionsPercent\":50}"

aws rds register-db-proxy-targets \
    --db-proxy-name my-postgres-proxy \
    --target-group-name default \
    --db-instance-identifiers my-postgres-db
    
#check target - must be "State": "AVAILABLE"
aws rds describe-db-proxy-targets --db-proxy-name my-postgres-proxy
```
aws rds modify-db-proxy \
    --db-proxy-name my-postgres-proxy \
    --max-connections-percent 50 \
    --debug

### 3.Create an EC2 instance

```bash
aws ec2 create-key-pair --key-name my-key-pair --query 'KeyMaterial' --output text > my-key-pair.pem

chmod 400 my-key-pair.pem

# Create EC2
aws ec2 run-instances \
    --image-id ami-08eb150f611ca277f \
    --count 1 \
    --instance-type t3.micro \
    --key-name my-key-pair \
    --subnet-id subnet-05a8a2c78756260ed \
    --security-group-ids sg-03d01fa1d6883bfae \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=MyEC2Instance}]' \
    --associate-public-ip-address \
    --placement "AvailabilityZone=eu-north-1a" \
    --region eu-north-1
```

### 4. Connect to EC2
```bash
EC2_ENDPOINT=$(aws ec2 describe-instances \
    --instance-ids i-04f7ffdf02f9840fd \
    --query 'Reservations[*].Instances[*].PublicIpAddress' \
    --output text)
echo $EC2_ENDPOINT

ssh -i my-key-pair.pem ubuntu@$EC2_ENDPOINT
sudo su
sudo sysctl -w net.ipv4.tcp_keepalive_time=3
sudo sysctl -w net.ipv4.tcp_keepalive_intvl=1
sudo sysctl -w net.ipv4.tcp_keepalive_probes=2


# Create users in RDS PostgreSQL

#Get RDS_ENDPOINT
RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier maratos \
    --query "DBInstances[0].Endpoint.Address" \
    --output text)
echo $RDS_ENDPOINT

psql -h maratos.ch4ssweuqhqv.eu-north-1.rds.amazonaws.com -U postgres
    CREATE ROLE user_test1 WITH LOGIN PASSWORD 'wolf';
    GRANT rds_superuser TO user_test1;

#Try to connect from ec2 to RDS directly using user_test1
psql -h maratos.ch4ssweuqhqv.eu-north-1.rds.amazonaws.com -U user_test1 -d postgres

# Get RDS Proxy Endpoint
RDS_PROXY_ENDPOINT=$(aws rds describe-db-proxies \
    --db-proxy-name my-postgres-proxy \
    --query "DBProxies[0].Endpoint" \
    --output text)
echo $RDS_PROXY_ENDPOINT

my-postgres-proxy.proxy-ch4ssweuqhqv.eu-north-1.rds.amazonaws.com
#Try to connect from ec2 to RDS via RDS-PROXY  using user_test1
psql -h my-postgres-proxy.proxy-ch4ssweuqhqv.eu-north-1.rds.amazonaws.com -U user_test1 -d postgres



aws secretsmanager update-secret --secret-id staging/test/user_test1 --secret-string '{"username":"user_test1","password":"wolf"}'



aws rds reboot-db-instance --db-instance-identifier maratos --force-failover




















bash rds_test_connect.sh
python3 rds_test_connect2.py



#Install psql
psql -h maratos.ch4ssweuqhqv.eu-north-1.rds.amazonaws.com -U postgres

sudo apt-get install -y postgresql-client

# Connect to Postgres via Proxy 
psql -h maratos-proxy.proxy-ch4ssweuqhqv.eu-north-1.rds.amazonaws.com -U postgres
psql -h maratos-proxy.proxy-ch4ssweuqhqv.eu-north-1.rds.amazonaws.com -U marat -d postgres


ALTER USER marat WITH PASSWORD 'wolfik';


select pid , usename, state_change, state from pg_stat_activity where usename='marat' or usename='postgres';
```
