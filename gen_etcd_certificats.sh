#!/bin/bash
set -e
OUT=$PWD/etcd
mkdir -p $OUT && cd $OUT

# 1) CA
openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:4096
openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=etcd-ca/O=MyOrg" -out ca.crt

# 2) Server
openssl genpkey -algorithm RSA -out server.key -pkeyopt rsa_keygen_bits:2048
openssl req -new -key server.key -subj "/CN=etcd-server-node1/O=etcd" -out server.csr

cat > server-ext.cnf <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
IP.1  = 172.18.0.3
IP.2  = 172.18.0.4
IP.1  = 172.18.0.5
IP.2  = 127.0.0.1
EOF

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650 -sha256 -extfile server-ext.cnf

#kubectl create secret tls ${CLUSTER_NAME}-etcd  --cert=/etc/kubernetes/pki/etcd/ca.crt  --key=/etc/kubernetes/pki/etcd/ca.key --dry-run=client -o yaml >>  ${CLUSTER_NAME}-secret-bundle.yaml
kubectl create secret tls test-cluster-etcd --cert=ca.crt --key=ca.key --dry-run=client -o yaml > test-cluster-secret-bundle.yaml
echo "---" >>  test-cluster-secret-bundle.yaml

# Create etcd cert files if apiserver-etcd-client is not present in the clusters.
openssl genrsa -out apiserver-etcd-client.key 2048
openssl req -new -key apiserver-etcd-client.key -out apiserver-etcd-client.csr -subj "/CN=kube-apiserver-etcd-client"
openssl x509 -req -in apiserver-etcd-client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -extensions v3_ext -out apiserver-etcd-client.crt -days 365 -sha256

kubectl create secret tls test-cluster-apiserver-etcd-client --cert apiserver-etcd-client.crt --key apiserver-etcd-client.key --dry-run=client -o yaml >>  test-cluster-secret-bundle.yaml
#sed -i '' 's|type: kubernetes.io/tls|type: cluster.x-k8s.io/secret|g' "test-cluster-secret-bundle.yaml"

labels="  labels:\n    cluster.x-k8s.io/cluster-name: test-cluster"


{ while IFS= read -r line; do printf '%s\n' "$line"; [ "$line" = "metadata:" ] && printf '%b\n' "$labels"; done < test-cluster-secret-bundle.yaml; } > test.tmp & mv test.tmp test-cluster-secret-bundle.yaml

