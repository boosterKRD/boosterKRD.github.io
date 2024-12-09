### Step 1: Install the Kind Command Line Tool
--brew install kind
# For M1 / ARM Macs
[ $(uname -m) = arm64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.25.0/kind-darwin-arm64
chmod +x ./kind
mv ./kind /usr/local/bin/kind


### Step 2: Create a Cluster Using a YAML File
cluster.yaml
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kind
nodes:
- role: control-plane
  extraPortMappings:
    ## expose port 31380 of the node to port 80 on the host
  - containerPort: 31080
    hostPort: 80
    ## expose port 31443 of the node to port 443 on the host
  - containerPort: 31443
    hostPort: 443
```

Then execute:
```bash
kind create cluster --config /Users/maratbogatyrev/Documents/repo/BoosterKRD/boosterKRD.github.io/_drafts/KIND/cluster.yaml
kubectl config get-contexts
kind delete cluster --name kind
```

### Provision PostgreSQL 17
```bash 
kubectl apply -f /Users/maratbogatyrev/Documents/repo/BoosterKRD/boosterKRD.github.io/_drafts/KIND/postgresql-deployment.yaml
kubectl apply -f /Users/maratbogatyrev/Documents/repo/BoosterKRD/boosterKRD.github.io/_drafts/KIND/postgres-client.yaml
kubectl exec -it postgres-client -- bash
psql -h postgres-service -U postgres -d postgres -W 
```

### Other show commands
```bash
kubectl get deployments
kubectl get pods
kubectl get svc
kubectl logs postgresql-5fc66557d-8w6t6
kubectl describe pod postgresql-5fc66557d-hl8tq
kubectl cluster-info
kubectl port-forward service/postgresql 3232:5432 
psql -h localhost -p 3232 -U postgres -W
kubectl exec -it postgresql-5fc66557d-k5qrk -- bash
```




if postgresql-deployment.yaml is changed
```bash
kubectl apply -f /Users/maratbogatyrev/Documents/repo/BoosterKRD/boosterKRD.github.io/_drafts/KIND/postgresql-deployment.yaml
kubectl get deployments
kubectl get svc postgresql
kubectl delete pod postgresql-5fc66557d-lx8qp
kubectl get pods
```