# Creating the test environment

---

## Table of Contents
1. [Creating the test environment](#creating-the-test-environment)
    1. [Define Variables](#1-define-variables)
    2. [Create an RDS PostgreSQL instance](#2-create-an-rds-postgresql-instance)
    3. [Create Secrets in AWS Secrets Manager](#3-create-secrets-in-aws-secrets-manager)
    4. [Create an IAM Role and Attach Policy for RDS Proxy](#4-create-an-iam-role-and-attach-policy-for-rds-proxy)
    5. [Create the RDS Proxy](#5-create-the-rds-proxy)
    6. [Create the RDS Proxy Target Group and Register Targets](#6-create-the-rds-proxy-target-group-and-register-targets)
    7. [Create an EC2 Instance](#7-create-an-ec2-instance)
    8. [Create Users in RDS PostgreSQL](#8-create-users-in-rds-postgresql)
    9. [Connect to the EC2 Instance](#9-connect-to-the-ec2-instance)
    10. [Connect to RDS via RDS Proxy](#10-connect-to-rds-via-rds-proxy)
2. [Final Step: Clean up Resources](#final-step-clean-up-resources)


### 1. Define Variables
---

> ℹ️ **INFO:**  Since we will use variables, all steps must be executed in a single CLI session.

### 1. Define Variables

First, define the variables that you’ll use throughout all the steps. Replace the placeholder values with your actual IDs:

```bash
# AWS Region and Account ID
export REGION="eu-north-1"         # Change
export ACCOUNT_ID="381492223649"   # Change

# Subnet IDs
export SUBNET_IDS=("subnet-0cf57825fcf0c3cbd" "subnet-05a8a2c78756260ed" "subnet-04d9bd19692972917") # Change

# Security Group ID
export SECURITY_GROUP_ID="sg-03d01fa1d6883bfae"

# RDS Subnet Group
export RDS_SUBNET_GROUP="my-db-test-subnet-group"

# RDS Instance Configuration
export RDS_INSTANCE_IDENTIFIER="my-postgres-db"
export MASTER_USERNAME="postgres"
export MASTER_PASSWORD="Olimpusc770"  # Consider using a more secure method to handle passwords
export VPC_SECURITY_GROUP_IDS=$SECURITY_GROUP_ID
export TAGS="Key=Name,Value=MyPostgresDB"

export IAM_POLICY_NAME="RDSProxySecretsAndKMSAccessPolicyTest"

# Secrets Manager Configuration
export SECRET_NAME1="staging/test/user_test1"
export SECRET_STRING1='{"username":"user_test1","password":"wolf"}'  
export SECRET_NAME2="staging/test/postgres"
export SECRET_STRING2='{"username":"postgres","password":"'"$MASTER_PASSWORD"'"}'  

# RDS Proxy Configuration
export RDS_PROXY_NAME="my-postgres-proxy2"
export ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

# Target Group Configuration
export TARGET_GROUP_NAME="default"
export CONNECTION_POOL_CONFIG='{"ConnectionBorrowTimeout":120,"MaxConnectionsPercent":50,"MaxIdleConnectionsPercent":50}'

# EC2 Configuration
export KEY_PAIR_NAME="my-key-pair2"
export EC2_IMAGE_ID="ami-08eb150f611ca277f"
export EC2_SUBNET_ID="subnet-05a8a2c78756260ed"
export EC2_SECURITY_GROUP_IDS=$SECURITY_GROUP_ID
export EC2_INSTANCE_TAG_NAME="MyEC2Instance"
```

### 2. Create an RDS PostgreSQL instance

```bash

cd amazon-rds/rds-proxy-deploying-test

# Create DB Subnet Group
aws rds create-db-subnet-group \
    --db-subnet-group-name $RDS_SUBNET_GROUP \
    --db-subnet-group-description "DB Subnet Group - Test RDS Proxy" \
    --subnet-ids ${SUBNET_IDS[@]} \
    --region $REGION

# Create RDS PostgreSQL Instance
aws rds create-db-instance \
    --db-instance-identifier $RDS_INSTANCE_IDENTIFIER \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --master-username $MASTER_USERNAME \
    --master-user-password $MASTER_PASSWORD \
    --allocated-storage 20 \
    --vpc-security-group-ids $VPC_SECURITY_GROUP_IDS \
    --db-subnet-group-name $RDS_SUBNET_GROUP \
    --backup-retention-period 7 \
    --multi-az true \    
    --no-publicly-accessible \
    --engine-version 16.4 \
    --storage-type gp2 \
    --auto-minor-version-upgrade \
    --publicly-accessible \
    --copy-tags-to-snapshot \
    --tags Key=Name,Value=my-postgres-instance \
    --region $REGION
```

### 3. Create Secrets in AWS Secrets Manager
```bash
# Create the secret 
SECRET_ARN1=$(aws secretsmanager create-secret \
    --name $SECRET_NAME1 \
    --description "Test secret" \
    --secret-string "$SECRET_STRING1" \
    --query 'ARN' \
    --output text \
    --region $REGION)
```

### 4. Create an IAM Role and Attach Policy for RDS Proxy
```bash

# Create IAM Role for RDS Proxy
aws iam create-role \
    --role-name $IAM_ROLE_NAME \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "rds.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }'

# Create IAM Policy for RDS Proxy
aws iam create-policy \
    --policy-name $IAM_POLICY_NAME \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "GetSecretValue",
                "Effect": "Allow",
                "Action": [
                    "secretsmanager:GetSecretValue"
                ],
                "Resource": [
                    "'"$SECRET_ARN1"'"
                ]
            },
            {
                "Sid": "DecryptSecretValue",
                "Effect": "Allow",
                "Action": [
                    "kms:Decrypt"
                ],
                "Resource": [
                    "arn:aws:kms:'"$REGION"':'"$ACCOUNT_ID"':key/c44c90fd-2418-44f3-a0a4-08f3914103de"
                ],
                "Condition": {
                    "StringEquals": {
                        "kms:ViaService": "secretsmanager.'"$REGION"'.amazonaws.com"
                    }
                }
            }
        ]
    }'
# # aws iam create-policy \
# #     --policy-name $IAM_POLICY_NAME \
# #     --policy-document file://files/rds-proxy-secrets-policy.json

# Attach Policy to Role
aws iam attach-role-policy \
    --role-name $IAM_ROLE_NAME \
    --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$IAM_POLICY_NAME
```

### 5. Create the RDS Proxy
```bash

# Create RDS Proxy
aws rds create-db-proxy \
    --db-proxy-name $RDS_PROXY_NAME \
    --engine-family POSTGRESQL \
    --auth "[{\"AuthScheme\":\"SECRETS\",\"SecretArn\":\"$SECRET_ARN1\",\"IAMAuth\":\"DISABLED\"}]" \
    --role-arn $ROLE_ARN \
    --vpc-subnet-ids ${SUBNET_IDS[@]} \
    --vpc-security-group-ids $SECURITY_GROUP_ID \
    --require-tls \
    --idle-client-timeout 1800 \
    --debug

# Wait until the RDS Proxy is created 
aws rds describe-db-proxies --db-proxy-name  $RDS_PROXY_NAME --region $REGION
```

### 6. Create the RDS Proxy Target Group and Register Targets
```bash 
# Register RDS Proxy Targets
aws rds register-db-proxy-targets \
    --db-proxy-name $RDS_PROXY_NAME \
    --target-group-name $TARGET_GROUP_NAME \
    --db-instance-identifiers $RDS_INSTANCE_IDENTIFIER \
    --region $REGION


aws rds modify-db-proxy-target-group \
    --db-proxy-name $RDS_PROXY_NAME \
    --target-group-name $TARGET_GROUP_NAME \
    --connection-pool-config "$CONNECTION_POOL_CONFIG" \
    --region $REGION
    
# Check Target State (should be AVAILABLE)
# The health state as "Description": "DBProxy Target is waiting for proxy to scale to desired capacity" is normal and you should wait 5-15 minutes 
#if the state is AVAILABLE, then go to the next step
aws rds describe-db-proxy-targets --db-proxy-name $RDS_PROXY_NAME --region $REGION
```

### 7. Create an EC2 Instance
Since the RDS Proxy is accessible only from the VPC, we create an EC2 instance to connect to the database via the RDS Proxy.

```bash
# Create Key Pair
rm -f files/my-key-pair2.pem
aws ec2 create-key-pair \
    --key-name $KEY_PAIR_NAME \
    --query 'KeyMaterial' \
    --output text > files/${KEY_PAIR_NAME}.pem \
    --region $REGION

chmod 400 files/${KEY_PAIR_NAME}.pem

# Run EC2 Instance
EC2_RUN_OUTPUT=$(aws ec2 run-instances \
    --image-id $EC2_IMAGE_ID \
    --count 1 \
    --instance-type t3.micro \
    --key-name $KEY_PAIR_NAME \
    --subnet-id $EC2_SUBNET_ID \
    --security-group-ids $EC2_SECURITY_GROUP_IDS \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$EC2_INSTANCE_TAG_NAME}]" \
    --associate-public-ip-address \
    --region $REGION)

# Extract EC2 Instance ID
EC2_INSTANCE_ID=$(echo $EC2_RUN_OUTPUT | grep -o '"InstanceId": "[^"]*' | awk '{print $2}' | tr -d '"')
```


### 8. Create Users in RDS PostgreSQL
```bash
# Get RDS Endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier $RDS_INSTANCE_IDENTIFIER \
    --query "DBInstances[0].Endpoint.Address" \
    --output text \
    --region $REGION)

echo "RDS Endpoint: $RDS_ENDPOINT"

# Connect to RDS PostgreSQL and create users
psql -h $RDS_ENDPOINT -U $MASTER_USERNAME -d postgres <<EOF
CREATE ROLE user_test1 WITH LOGIN PASSWORD 'wolf';
GRANT rds_superuser TO user_test1;
EOF
```

### 9. Connect to the EC2 Instance
```bash
# Wait for the instance to be running
aws ec2 wait instance-running --instance-ids $EC2_INSTANCE_ID --region $REGION

# Get Public IP Address of EC2 Instance
EC2_PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $EC2_INSTANCE_ID \
    --query 'Reservations[*].Instances[*].PublicIpAddress' \
    --output text \
    --region $REGION)

echo "EC2 Public IP: $EC2_PUBLIC_IP"

# SSH into EC2 Instance
ssh -i files/${KEY_PAIR_NAME}.pem ubuntu@$EC2_PUBLIC_IP

# Inside the EC2 Instance, adjust TCP keepalive settings
sudo bash -c 'echo "net.ipv4.tcp_keepalive_time=3" >> /etc/sysctl.conf'
sudo bash -c 'echo "net.ipv4.tcp_keepalive_intvl=1" >> /etc/sysctl.conf'
sudo bash -c 'echo "net.ipv4.tcp_keepalive_probes=2" >> /etc/sysctl.conf'
sudo sysctl -p

#Install psql
sudo apt-get install -y postgresql-client
```

### 10. Connect to RDS via RDS Proxy
```bash 
# Get RDS Proxy Endpoint
RDS_PROXY_ENDPOINT=$(aws rds describe-db-proxies \
    --db-proxy-name $RDS_PROXY_NAME \
    --query "DBProxies[0].Endpoint" \
    --output text \
    --region $REGION)

echo "RDS Proxy Endpoint: $RDS_PROXY_ENDPOINT"

# Test connection from EC2 to RDS via Proxy using user_test1
psql -h $RDS_PROXY_ENDPOINT -U user_test1 -d postgres
```

## Final Step: Clean up Resources
To completely clean up and delete all the AWS resources and objects created during this RDS password rotation setup, you can use the [following AWS CLI commands](clear_env.md).


## Other useful commands

```bash
aws rds reboot-db-instance --db-instance-identifier $RDS_INSTANCE_IDENTIFIER --force-failover
```