# RDS password rotation 

## Step 1: Create an Amazon RDS PostgreSQL Instance Using AWS CLI

Creating an Amazon RDS PostgreSQL instance via the AWS CLI allows for automation and repeatability. Follow the steps below to set up your database instance using AWS CLI commands.

Prerequisites

	•	AWS CLI Installed: Ensure that the AWS CLI is installed on your machine. If not, install it by following the AWS CLI Installation Guide.
	•	AWS CLI Configured: Configure your AWS CLI with the necessary credentials and default region using aws configure.
	•	IAM Permissions: The IAM user or role you are using must have permissions to create RDS instances, security groups, and related resources.

Steps to Create the RDS Instance

1. Create a DB Subnet Group (If Not Already Created)

A DB subnet group is a collection of subnets that you may want to designate for your RDS instances in a VPC.

```bash
aws rds create-db-subnet-group \
    --db-subnet-group-name my-db-subnet-group \
    --db-subnet-group-description "My DB subnet group" \
    --subnet-ids {subnet-xxxx1 subnet-xxxx2}
```	
Note: Replace subnet-xxxx1 and subnet-xxxx2 with your actual subnet IDs within your VPC.

2. Create a VPC Security Group

If you don’t have a security group, create one to control inbound and outbound traffic for your RDS instance.
```bash
# Create a new security group
aws ec2 create-security-group \
    --group-name my-rds-sg \
    --description "Security group for RDS instance" \
    --vpc-id vpc-xxxx1
```
Note: Replace vpc-xxxx1 with your actual VPC ID.

3. Modify Security Group Inbound Rules

Add inbound rules to allow traffic on the PostgreSQL port (default 5432).
```bash
# Allow inbound PostgreSQL traffic from a specific IP
aws ec2 authorize-security-group-ingress \
    --group-id sg-xxxx1 \
    --protocol tcp \
    --port 5432 \
    --cidr <your-ip-address>/32
```
Note: 
 - Replace sg-xxxx1 with your security group ID.
 - Replace <your-ip-address> with your actual IP address or use 0.0.0.0/0.

4. Create the RDS PostgreSQL Instance

Use the following command to create your RDS instance:
```bash
aws rds create-db-instance \
    --db-instance-identifier my-postgres-instance \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --master-username postgres \
    --master-user-password YourMasterPassword \
    --allocated-storage 20 \
    --vpc-security-group-ids sg-12345678 \
    --db-subnet-group-name my-db-subnet-group \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --engine-version 13.4 \
    --storage-type gp2 \
    --auto-minor-version-upgrade \
    --multi-az \
    --publicly-accessible \
    --storage-encrypted \
    --copy-tags-to-snapshot \
    --deletion-protection \
    --tags Key=Name,Value=my-postgres-instance
```
Parameter Explanations:
	•	--db-instance-identifier: A unique name for your RDS instance (e.g., my-postgres-instance).
	•	--db-instance-class: The compute and memory capacity (e.g., db.t3.micro).
	•	--engine: The database engine (postgres for PostgreSQL).
	•	--master-username: The username for the master user (e.g., postgres).
	•	--master-user-password: A strong password for the master user.
	•	--allocated-storage: The amount of storage in GiB.
	•	--vpc-security-group-ids: Your security group ID(s).
	•	--db-subnet-group-name: The DB subnet group name created earlier.
	•	--backup-retention-period: Number of days to retain backups.
	•	--no-publicly-accessible: Specifies that the instance isn’t publicly accessible.
	•	--engine-version: The PostgreSQL engine version (e.g., 13.4).
	•	--storage-type: The storage type (e.g., gp2 for General Purpose SSD).
	•	--auto-minor-version-upgrade: Enables automatic minor version upgrades.
	•	--multi-az: Deploys the instance across multiple Availability Zones for high availability.
	•	--storage-encrypted: Encrypts the storage.
	•	--copy-tags-to-snapshot: Copies tags to snapshots.
	•	--deletion-protection: Prevents accidental deletion.
	•	--tags: Adds metadata tags to your instance.

Note: Adjust parameters according to your requirements. For a test environment, you might set --multi-az to false and --storage-encrypted to false.	


5. Verify the RDS Instance Creation

Check the status of your RDS instance:
```bash
aws rds describe-db-instances \
    --db-instance-identifier my-postgres-instance \
    --query 'DBInstances[0].DBInstanceStatus'
```
Note: Wait until the status changes to available.

6. Retrieve the Endpoint Address
You’ll need the endpoint to connect to your database:
```bash
aws rds describe-db-instances \
    --db-instance-identifier my-postgres-instance \
    --query 'DBInstances[0].Endpoint.Address'
```


## Step 2: Create a Secret for rotator_admin and test_user in AWS Secrets Manager Using AWS CLI
Creating a secret for rotator_admin and test_user involves storing the database credentials securely in AWS Secrets Manager. The **rotator_admin** user will be used by the Lambda rotation function to manage password rotations for **test_user**.

2.1 Set the password you want to use for the rotator_admin user. Ensure you choose a strong password and handle it securely.  
```bash
ROTATOR_ADMIN_PASSWORD='XXXXX'
TEST_USER_PASSWORD='XXXXX'
```
Note: Replace 'XXXXX' with a secure password of your choice. 

2.2 Create the Secrets in AWS Secrets Manager  
```bash
aws secretsmanager create-secret \
    --name rotator_admin_secret \
    --description "Secret for rotator_admin user" \
    --secret-string "{\"username\":\"rotator_admin\",\"password\":\"$ROTATOR_ADMIN_PASSWORD\",\"engine\":\"postgres\",\"host\":\"$RDS_ENDPOINT\",\"port\":$RDS_PORT,\"dbname\":\"postgres\"}" \
    --tags Key=Name,Value=rotator_admin_secret

aws secretsmanager create-secret \
    --name test_user_secret \
    --description "Secret for test_user with automatic rotation" \
    --secret-string "{\"username\":\"test_user\",\"password\":\"$TEST_USER_PASSWORD\",\"engine\":\"postgres\",\"host\":\"$RDS_ENDPOINT\",\"port\":$RDS_PORT,\"dbname\":\"postgres\"}" \
    --tags Key=Name,Value=test_user_secret    
```
Explanation of Parameters:
	•	--name: The name of the secret (rotator_admin_secret).
	•	--description: A description for the secret.
	•	--secret-string: A JSON string containing the credentials and connection details.
	•	Make sure to escape the double quotes properly.
	•	--tags: Optional tags to help identify your secret.

2.3 Confirm the Secret Creation  
Verify that the secret has been created:
```bash
aws secretsmanager describe-secret --secret-id rotator_admin_secret
aws secretsmanager describe-secret --secret-id test_user_secret
```	

## Step 3: Deploy the Rotation Lambda Function
We’ll deploy the rotation Lambda function using the AWS Serverless Application Repository and AWS CloudFormation.

1. Retrieve the ARN of rotator_admin_secret  
```bash
ROTATOR_ADMIN_SECRET_ARN=$(aws secretsmanager describe-secret \
    --secret-id rotator_admin_secret \
    --query 'ARN' \
    --output text)
```

2. Generate the CloudFormation Template URL  
```bash
TEMPLATE_URL=$(aws serverlessrepo create-cloud-formation-template \
    --application-id arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationMultiUser \
    --semantic-version 1.0.60 \
    --query 'TemplateUrl' \
    --output text)
```
Note: Adjust the --application-id and --semantic-version if necessary.

3. Deploy the CloudFormation Stack  
Replace the placeholders with your actual values:
	•	<your-region>: Your AWS region (e.g., eu-north-1).
	•	<your-security-group-ids>: The security group IDs for your VPC.
	•	<your-subnet-ids>: The subnet IDs where your Lambda function should run.

> INFO:
	•	The subnets and security groups must allow the Lambda function to communicate with both the RDS instance and AWS Secrets Manager.
	•	Incorrect configuration can lead to connectivity issues, preventing the Lambda function from performing password rotations.
	The main rules are:
	•	Subnets (vpcSubnetIds):  
		•	Same VPC: The subnets must be in the same VPC as your RDS instance.
		•	Private Subnets: Ideally, use private subnets that have:
			•	Network access to your RDS instance.
			•	Internet access through a NAT Gateway for AWS Secrets Manager calls, or a VPC Endpoint for AWS Secrets Manager (IGW does not work with Lambda).
		•	Different Subnets: You can use different subnets from those used by the RDS instance, as long as they meet the above criteria.
	•	Security Groups (vpcSecurityGroupIds):
		•	New Security Group: It’s recommended to create a new security group for the Lambda function to have fine-grained control.
		•	Permissions:
			•	Outbound Rules: Allow outbound traffic to the RDS instance on port 5432 (PostgreSQL) and to AWS Secrets Manager on port 443 (HTTPS).
			•	Inbound Rules: Generally, Lambda functions don’t need inbound rules unless they are invoked by services within your VPC.	

```bash
aws cloudformation create-stack \
    --stack-name pgpasslambda-stack \
    --template-url $TEMPLATE_URL \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters ParameterKey=functionName,ParameterValue=pgpasslambda \
                 ParameterKey=superuserSecretArn,ParameterValue=$ROTATOR_ADMIN_SECRET_ARN \
                 ParameterKey=endpoint,ParameterValue=https://secretsmanager.<your-region>.amazonaws.com/ \
                 ParameterKey=vpcSecurityGroupIds,ParameterValue=<your-security-group-ids> \
                 ParameterKey=vpcSubnetIds,ParameterValue=<your-subnet-ids>
```

Example with Actual Values:
```bash
aws cloudformation create-stack \
    --stack-name pgpasslambda-stack \
    --template-url $TEMPLATE_URL \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters ParameterKey=functionName,ParameterValue=pgpasslambda \
                 ParameterKey=superuserSecretArn,ParameterValue=$ROTATOR_ADMIN_SECRET_ARN \
                 ParameterKey=endpoint,ParameterValue=https://secretsmanager.eu-north-1.amazonaws.com/ \
                 ParameterKey=vpcSecurityGroupIds,ParameterValue=sg-03d01fa1d6883bfae \
                 ParameterKey=vpcSubnetIds,ParameterValue=subnet-05a8a2c78756260ed
```

4. Wait for the Stack Creation to Complete
```bash
aws cloudformation wait stack-create-complete --stack-name pgpasslambda-stack
```

5. Retrieve the ARN of the Rotation Lambda Function
```bash
ROTATION_LAMBDA_ARN=$(aws lambda get-function \
    --function-name pgpasslambda \
    --query 'Configuration.FunctionArn' \
    --output text)
```

## Step 4: Enable Automatic Rotation for test_user_secret
1. Enable Rotation on the Secret 
```bash
aws secretsmanager rotate-secret \
    --secret-id test_user_secret \
    --rotation-lambda-arn $ROTATION_LAMBDA_ARN \
    --rotation-rules AutomaticallyAfterDays=30
```
Explanation of Parameters:
	•	--secret-id: The name or ARN of your secret (test_user_secret).
	•	--rotation-lambda-arn: The ARN of the rotation Lambda function (pgpasslambda).
	•	--rotation-rules: Specifies the rotation schedule (every 30 days).

2. Confirm Rotation Configuration
```bash
aws secretsmanager describe-secret --secret-id test_user_secret
```


## Step 5: Create the test_user and rotator_admin in PostgreSQL
Now, we’ll create the necessary users in the PostgreSQL database via psql.
```sql
CREATE USER test_user WITH PASSWORD 'XXXXX';
CREATE USER rotator_admin WITH PASSWORD 'XXXXX' CREATEROLE;
GRANT rds_superuser TO rotator_admin;
```
Notes:
 - Replace XXXXX with the password you set in Secrets Manager for rotator_admin and test_user in [step 3](Step 3: Create a Secret for rotator_admin and test_user in AWS Secrets Manager Using AWS CLI).

## Step 6: Checking Network Settings for Lambda Access
Ensure that the Lambda function can access both the RDS instance and AWS Secrets Manager.
Lambda VPC Configuration:
	•	The Lambda function should be configured to run in the same VPC as your RDS instance.
	•	Use private subnets that have network access to the internet via a NAT Gateway or VPC endpoints.
	•	Create a VPC Endpoint for Secrets Manager (Optional):
	•	Navigate to the VPC Console.
	•	Click on Endpoints and then Create Endpoint.
	•	Service Name: Select com.amazonaws.<region>.secretsmanager.
	•	VPC: Choose your VPC.
	•	Subnets: Select the subnets where your Lambda function runs.
	•	Security Groups: Attach the appropriate security groups.
	•	Update Lambda Function’s Security Group:
	•	Ensure the security group allows outbound access to the RDS instance and Secrets Manager endpoint.

1. Verify Lambda Function’s VPC Configuration
Use the following AWS CLI command to check the Lambda function’s configuration:
```bash
aws lambda get-function-configuration \
    --function-name pgpasslambda \
    --query '{FunctionName:FunctionName, VpcConfig:VpcConfig}'
```
Notes:
	•	Ensure that the SubnetIds and SecurityGroupIds match the values you provided during deployment.
	•	Confirm that the VpcId corresponds to your VPC.

2. Verify Security Group Rules
Check the outbound and inbound rules of the Lambda function’s security group (sg-XXXXX):
```bash
aws ec2 describe-security-groups \
    --group-ids sg-XXXXX \
    --query 'SecurityGroups[0].IpPermissionsEgress'

aws ec2 describe-security-groups \
    --group-ids sg-XXXXX \
    --query 'SecurityGroups[0].IpPermissions'    
```
Note: Ensure that outbound and inbound traffic is allowed to the RDS instance and AWS Secrets Manager endpoints.


## Step 7: Final check 
Manually trigger the rotation function to see if it can access the RDS instance and Secrets Manager:
```bash
aws secretsmanager rotate-secret --secret-id test_user_secret
```
Note: Monitor the CloudWatch logs for the Lambda function to check for any errors.




Conclusion

You’ve successfully set up automatic password rotation for a PostgreSQL user using AWS Secrets Manager and Lambda. The test_user credentials stored in Secrets Manager will now automatically rotate based on the schedule you set, enhancing the security of your database environment.	

Tips and Best Practices
	•	Secure Access: Always restrict security group rules to specific IP addresses or VPCs rather than using 0.0.0.0/0.
	•	Monitoring: Set up monitoring and alerts for your Lambda function to catch any rotation failures.
	•	Secrets Permissions: Ensure that the Lambda execution role has the necessary permissions to access Secrets Manager and RDS.
	•	Testing: Test the rotation manually to verify that everything works as expected.

References
	•	[AWS Secrets Manager Documentation](https://docs.aws.amazon.com/secretsmanager/)
	•	[AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)
	•	[Amazon RDS for PostgreSQL Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html)
	•	[AWS Documentation on VPC Endpoints for Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/vpc-endpoint-overview.html)




## Step 8: Create a VPC Endpoint for AWS Secrets Manager Using AWS CLI
[AWS Documentation on VPC Endpoints for Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/vpc-endpoint-overview.html)
1. Identify the Service Name for AWS Secrets Manager
Set the service name for AWS Secrets Manager in your region:
```bash
REGION=<your-region> # e.g., eu-north-1
SERVICE_NAME="com.amazonaws.${REGION}.secretsmanager"
```

2. Create a VPC Endpoint for AWS Secrets Manager
Use the following command to create the VPC Endpoint. This will enable your Lambda function to access AWS Secrets Manager within your VPC.
```bash
aws ec2 create-vpc-endpoint \
    --vpc-id <your-vpc-id> \
    --vpc-endpoint-type Interface \
    --service-name $SERVICE_NAME \
    --subnet-ids <your-subnet-ids> \
    --security-group-ids <vpce-sg-id> \
    --private-dns-enabled
```
Replace:
  - <your-vpc-id> with your VPC ID.
  - <your-subnet-ids> with your subnet IDs (comma-separated if multiple).
  - <vpce-sg-id> with the ID of an existing security group or create a new one (see below).

3. Update Security Group Rules
Ensure that the security group associated with the VPC Endpoint allows inbound traffic on port 443 from the Lambda function’s security group.
```bash
# Allow inbound HTTPS traffic from Lambda's security group
aws ec2 authorize-security-group-ingress \
    --group-id <vpce-sg-id> \
    --protocol tcp \
    --port 443 \
    --source-group <lambda-sg-id>
```

4. Verify the VPC Endpoint Creation
Ensure that the VPC Endpoint is created and in the available state:
```bash
aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-endpoint-type,Values=Interface" "Name=vpc-id,Values=<your-vpc-id>" \
    --query 'VpcEndpoints[?ServiceName==`'$SERVICE_NAME'`].[VpcEndpointId, State]' \
    --output table
```





===
5. Update Lambda Function’s Security Group (If Necessary)

If your Lambda function’s security group restricts outbound traffic, you need to allow outbound HTTPS traffic to AWS Secrets Manager.

# Allow outbound HTTPS traffic to the VPC Endpoint
aws ec2 authorize-security-group-egress \
    --group-id <lambda-sg-id> \
    --protocol tcp \
    --port 443 \
    --destination-prefix-list-ids $(aws ec2 describe-prefix-lists \
        --filters "Name=prefix-list-name,Values=com.amazonaws.${REGION}.secretsmanager" \
        --query 'PrefixLists[0].PrefixListId' \
        --output text)

	•	Replace <lambda-sg-id> with your Lambda function’s security group ID.


