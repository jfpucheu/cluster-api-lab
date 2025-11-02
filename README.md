# Cluster API Lab - Migration etcd

Lab pour tester la migration etcd avec Cluster API et Kind.

## 🚀 Installation du Lab

### 1. Créer le cluster de management Kind

```bash
kind create cluster --config management-cluster-kind.yaml
```

### 2. Installer clusterctl

**Pour macOS (Intel):**
```bash
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.11.2/clusterctl-darwin-amd64 -o clusterctl
```

**Pour macOS (ARM/M1/M2):**
```bash
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.11.2/clusterctl-darwin-arm64 -o clusterctl
```

**Installation:**
```bash
chmod +x ./clusterctl
sudo mv ./clusterctl /usr/local/bin/clusterctl
clusterctl version
```

### 3. Initialiser Cluster API

```bash
export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure docker
```

### 4. Configurer etcd externe

**Générer les certificats etcd:**
```bash
./gen_etcd_certificats.sh
```

**Importer les secrets dans Kubernetes:**
```bash
kubectl apply -f etcd/test-cluster-secret-bundle.yaml
```

**Démarrer etcd externe:**
```bash
./start_etcd.sh
```

### 5. Créer le cluster de test

```bash
kubectl apply -f test-cluster-init-with-etcd.yaml
```

Attendre que le cluster soit prêt:
```bash
kubectl get cluster test-cluster
kubectl get kubeadmcontrolplane
```

## 🔄 Test de Migration etcd

### Récupérer le kubeconfig du cluster de test

```bash
clusterctl get kubeconfig test-cluster > test-cluster.kubeconfig
export KUBECONFIG=test-cluster.kubeconfig
```

### Identifier les control plane nodes

```bash
kubectl get nodes
kubectl get pods -n kube-system | grep etcd
```


### Vérifier la migration

```bash
# Vérifier l'état du cluster etcd
kubectl exec -n kube-system etcd-<node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list

# Vérifier la santé
kubectl get nodes
kubectl get pods -A
```

## 🧹 Nettoyage

```bash
# Supprimer le cluster de test
kubectl delete cluster test-cluster

# Supprimer le cluster Kind
kind delete cluster
```

## 📝 Fichiers du Lab

- `management-cluster-kind.yaml` - Configuration du cluster Kind
- `gen_etcd_certificats.sh` - Génération des certificats etcd
- `start_etcd.sh` - Démarrage de l'etcd externe
- `etcd/test-cluster-secret-bundle.yaml` - Secrets Kubernetes pour etcd
- `test-cluster-init-with-etcd.yaml` - Manifest du cluster de test
- `etcd_migration.sh` - Script de migration etcd

## ⚠️ Notes

- Le script de migration doit être exécuté en tant que **root**
- Vérifier que les IPs sont correctes avant la migration
- Toujours faire un backup etcd avant la migration en production
- Ce lab utilise Docker provider (non production)
