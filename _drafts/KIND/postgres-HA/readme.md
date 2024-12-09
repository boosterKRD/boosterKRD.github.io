# Recipe for Deploying a PostgreSQL Cluster with High Availability (HA) in Kubernetes

This recipe describes how to deploy PostgreSQL with a Primary instance and two Replicas in Kubernetes using ConfigMap, Secret, and pg_basebackup for automatic replication setup.

Table of Contents
1.	[Create ConfigMaps for primary and replica instancesъ(#step-1-create-configmaps-for-postgresqlconf)
2.	[Create a Secret to store the replication password](#step-2-create-a-secret-for-storing-the-password)
3.	[Apply StatefulSets for primary and replica instances using pg_basebackup for automated replication](#step-3-create-statefulsets-for-primary-and-replica-instances)
4.	[Configure Headless Services to enable connectivity between instances](#step-4-create-headless-services-for-primary-and-replica-instances)

## Step 0: Create k8s cluster
```bash
kind delete cluster --name kind
kind create cluster --config cluster.yaml
kubectl config get-contexts
```

## Step 1: Create ConfigMaps for postgresql.conf
1.1 Create ConfigMaps for Primary and Replica
- Create the file [postgresql-primary.conf](postgresql-primary.conf) with the necessary primary settings.
- Create the file [postgresql-replica.conf](postgresql-replica.conf) with the necessary replica settings.
- Create the file [ppg_hba.conf](pg_hba.conf) with the necessary pg_hba settings.
- Create ConfigMaps for the primary and replica anв pg_hba:
```bash
kubectl create configmap postgres-primary-config --from-file=postgresql.conf=./postgresql-primary.conf
kubectl create configmap postgres-replica-config --from-file=postgresql.conf=./postgresql-replica.conf
kubectl create configmap postgres-init-script --from-file=init-user-replicator.sql=./init-user-replicator.sql
kubectl create configmap postgres-primary-pghba --from-file=pg_hba.conf=./pg_hba.conf
```

## Step 2: Create a Secret for Storing the Password
Create a Secret to store the password for the replicator user, avoiding the need to specify it in plain text:
```bash
kubectl create secret generic postgres-replica-secret --from-literal=replicator-password=replicatorpassword
```

## Step 3: Create StatefulSets for Primary and Replica Instances
- Configuration for [statefulset-primary.yaml](statefulset-primary.yaml) (primary instance)
- Configuration for [statefulset-replica.yaml](statefulset-replica.yaml) (replica instances)
- Apply the StatefulSets:
```bash
kubectl apply -f statefulset-primary.yaml
kubectl get pods
kubectl logs postgres-primary-0
#kubectl delete pod postgres-replica-0
```

<!-- ## Step 4: Create Headless Services for Primary Instances
- Configuration for [service-primary.yaml](service-primary.yaml) (primary Service)
- Apply the services:
```bash
kubectl apply -f service-primary.yaml
``` -->

## Step 5: Create StatefulSets for Replica Instances
- Configuration for [statefulset-primary.yaml](statefulset-primary.yaml) (primary instance)
- Configuration for [statefulset-replica.yaml](statefulset-replica.yaml) (replica instances)
- Apply the StatefulSets:
```bash
kubectl apply -f statefulset-replica.yaml
kubectl get pods
kubectl logs  postgres-replica-0
kubectl logs postgres-replica-0 -c init-pgbasebackup
kubectl logs postgres-replica-0 -c check-data-dir
kubectl logs postgres-replica-0 -c postgres
kubectl describe pod postgres-replica-0

kubectl get service
kubectl exec -it postgres-primary-0 -- psql -U postgres
SELECT * FROM pg_stat_replication;
CREATE TABLE replication_test (id SERIAL PRIMARY KEY, name TEXT);INSERT INTO replication_test (name) VALUES ('Test Data');

kubectl exec -it postgres-replica-0 -- psql -U postgres
SELECT * FROM replication_test;
```

<!-- 
## Step 6: Create Headless Services for Replica Instances
- Configuration for [service-replica.yaml](service-replica.yaml) (replica Service)
- Apply the services:
```bash
kubectl apply -f service-replica.yaml -->
```