# Clean up the test environment

---

## Table of Contents

1. [Delete the EC2 Instance, SSH key](#1-delete-the-ec2-instance-ssh-key)
2. [Delete the RDS Proxy](#2-delete-the-rds-proxy)
3. [Delete the RDS Instance](#3-delete-the-rds-instance)
4. [Delete the Secrets from AWS Secrets Manager](#4-delete-the-secrets-from-aws-secrets-manager)
5. [Detach and Delete IAM Policies, Then Delete the IAM Role](#5-detach-and-delete-iam-policies-then-delete-the-iam-role)
6. [Delete the RDS Subnet Group](#6-delete-the-rds-subnet-group)
7. [Delete the CloudWatch Log Group](#7-delete-the-cloudwatch-log-group)
8. [Verify Deletion](#8-verify-deletion)

---

> ℹ️ **INFO:**:
>  - Order Matters: It’s important to delete resources in the order provided to avoid dependency issues.
>  - Wait for Deletions to Complete: Some AWS services take time to delete resources. Use the wait commands where provided.


### 1. Delete the EC2 Instance, SSH key 

```bash
# Get instance-ids by name
EC2_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$EC2_INSTANCE_TAG_NAME" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text \
    --region $REGION)

# Terminate the EC2 instance
aws ec2 terminate-instances --instance-ids $EC2_INSTANCE_ID --region $REGION

# Wait until the instance is terminated
aws ec2 wait instance-terminated --instance-ids $EC2_INSTANCE_ID --region $REGION

# Delete the key pair from AWS
aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME --region $REGION
```

### 2. Delete the RDS Proxy

```bash
# Delete the RDS Proxy named my-postgres-proxy
aws rds delete-db-proxy \
    --db-proxy-name $RDS_PROXY_NAME \
    --region $REGION

# Wait until the proxy is deleted - it must disappear from the list 
aws rds describe-db-proxies --query "DBProxies[*].DBProxyName"
```

### 3. Delete the RDS Instance

```bash
# Delete the RDS instance without creating a final snapshot
aws rds delete-db-instance \
    --db-instance-identifier $RDS_INSTANCE_IDENTIFIER \
    --skip-final-snapshot \
    --region $REGION

# Wait until the DB instance is deleted (5-30min)
aws rds wait db-instance-deleted --db-instance-identifier my-postgres-db
```

### 4. Delete the Secrets from AWS Secrets Manager

```bash
# Delete secrets
aws secretsmanager delete-secret --secret-id $SECRET_NAME1 --force-delete-without-recovery --region $REGION
aws secretsmanager delete-secret --secret-id $SECRET_NAME2 --force-delete-without-recovery --region $REGION
```

### 5. Detach and Delete IAM Policies, Then Delete the IAM Role

```bash
# Detach and delete policies
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$IAM_POLICY_NAME
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$IAM_POLICY_NAME

# Delete the IAM role
aws iam delete-role --role-name $IAM_ROLE_NAME
```

### 6. Delete the RDS Subnet Group
```bash
aws rds delete-db-subnet-group --db-subnet-group-name $RDS_SUBNET_GROUP --region $REGION
```

### 7. Delete the CloudWatch Log Group
```bash
# Delete log group in CloudWatch
aws logs delete-log-group --log-group-name "/aws/rds/proxy/${RDS_PROXY_NAME}" --region $REGION
```

### 8. Verify Deletion
```bash
# Check for any remaining EC2 instances
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running"

# Check for any remaining RDS instances
aws rds describe-db-instances

# Check for any remaining RDS proxies
aws rds describe-db-proxies

# Check for any remaining secrets
aws secretsmanager list-secrets --query "SecretList[*].Name"

# Check for any remaining IAM roles and policies
aws iam list-roles | grep $IAM_ROLE_NAME
aws iam list-policies | grep $IAM_POLICY_NAME
```