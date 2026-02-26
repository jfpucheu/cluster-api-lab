#!/bin/bash
set -e

# Configuration
NODE1=172.18.0.3
NODE2=172.18.0.4
NODE3=172.18.0.5
ETCD_VERSION=v3.5.24
REGISTRY=quay.io/coreos/etcd
OUT=$PWD/etcd

# Fonction pour générer les certificats
generate_certificates() {
    echo "=== Génération des certificats etcd ==="
    
    mkdir -p $OUT && cd $OUT

    # 1) CA
    echo "Génération du certificat CA..."
    openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:4096
    openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=etcd-ca/O=MyOrg" -out ca.crt

    # 2) Server
    echo "Génération du certificat serveur..."
    openssl genrsa -out etcd.key 4096

    cat > etcd-openssl.cnf <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
CN = etcd-cluster

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
IP.1  = ${NODE1}
IP.2  = ${NODE2}
IP.3  = ${NODE3}
IP.4  = 127.0.0.1
DNS.1 = etcd1
DNS.2 = etcd2
DNS.3 = etcd3

[ v3_ext ]
subjectAltName = DNS:kube-apiserver-etcd-client
EOF

    openssl req -new -key etcd.key -out etcd.csr -config etcd-openssl.cnf
    openssl x509 -req -in etcd.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out etcd.crt -days 3650 -extensions req_ext -extfile etcd-openssl.cnf

    # Création du secret bundle
    echo "Création du secret bundle Kubernetes..."
    kubectl create secret tls test-cluster-etcd --cert=ca.crt --key=ca.key --dry-run=client -o yaml > test-cluster-secret-bundle.yaml
    echo "---" >> test-cluster-secret-bundle.yaml

    # Certificat client pour l'API server
    echo "Génération du certificat client API server..."
    openssl genrsa -out apiserver-etcd-client.key 2048
    openssl req -new -key apiserver-etcd-client.key -out apiserver-etcd-client.csr -subj "/CN=kube-apiserver-etcd-client"
    openssl x509 -req -in apiserver-etcd-client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -extensions v3_ext -extfile etcd-openssl.cnf -out apiserver-etcd-client.crt -days 365 -sha256

    kubectl create secret tls test-cluster-apiserver-etcd-client --cert apiserver-etcd-client.crt --key apiserver-etcd-client.key --dry-run=client -o yaml >> test-cluster-secret-bundle.yaml

    # Ajout des labels
    labels="  labels:\n    cluster.x-k8s.io/cluster-name: test-cluster"
    { while IFS= read -r line; do printf '%s\n' "$line"; [ "$line" = "metadata:" ] && printf '%b\n' "$labels"; done < test-cluster-secret-bundle.yaml; } > test.tmp && mv test.tmp test-cluster-secret-bundle.yaml

    cd - > /dev/null
    echo "✓ Certificats générés dans: $OUT"
}

# Fonction pour démarrer le cluster etcd
start_cluster() {
    echo "=== Démarrage du cluster etcd ==="
    
    # Génération des certificats si nécessaire
    if [ ! -d "$OUT" ] || [ ! -f "$OUT/ca.crt" ] || [ ! -f "$OUT/etcd.crt" ]; then
        echo "Les certificats n'existent pas, génération..."
        generate_certificates
    else
        echo "Les certificats existent déjà, utilisation des certificats existants"
    fi

    # Vérifier si les conteneurs existent déjà
    for node in etcd1 etcd2 etcd3; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${node}$"; then
            echo "Arrêt et suppression du conteneur existant: $node"
            docker stop $node 2>/dev/null || true
            docker rm $node 2>/dev/null || true
        fi
    done

    # Démarrage etcd1
    echo "Démarrage de etcd1..."
    docker run -td \
      -p 2379:2379 \
      -p 2380:2380 \
      --network kind \
      --volume ${PWD}/etcd:/etcd-pki \
      --name etcd1 ${REGISTRY}:${ETCD_VERSION} \
      /usr/local/bin/etcd \
      --cert-file=/etcd-pki/etcd.crt \
      --key-file=/etcd-pki/etcd.key \
      --trusted-ca-file=/etcd-pki/ca.crt \
      --peer-cert-file=/etcd-pki/etcd.crt \
      --peer-key-file=/etcd-pki/etcd.key \
      --peer-trusted-ca-file=/etcd-pki/ca.crt \
      --experimental-initial-corrupt-check=true \
      --client-cert-auth=false \
      --peer-client-cert-auth=true \
      --data-dir=/etcd1-data --name=etcd1 \
      --initial-advertise-peer-urls=https://${NODE1}:2380 \
      --listen-peer-urls=https://${NODE1}:2380 \
      --advertise-client-urls=https://${NODE1}:2379 \
      --listen-client-urls=https://${NODE1}:2379,https://127.0.0.1:2379 \
      --initial-cluster=etcd1=https://${NODE1}:2380,etcd2=https://${NODE2}:2380,etcd3=https://${NODE3}:2380 \
      --initial-cluster-state=new

    sleep 2

    # Démarrage etcd2
    echo "Démarrage de etcd2..."
    docker run -td \
      --network kind \
      --volume ${PWD}/etcd:/etcd-pki \
      --name etcd2 ${REGISTRY}:${ETCD_VERSION} \
      /usr/local/bin/etcd \
      --cert-file=/etcd-pki/etcd.crt \
      --key-file=/etcd-pki/etcd.key \
      --trusted-ca-file=/etcd-pki/ca.crt \
      --peer-cert-file=/etcd-pki/etcd.crt \
      --peer-key-file=/etcd-pki/etcd.key \
      --peer-trusted-ca-file=/etcd-pki/ca.crt \
      --experimental-initial-corrupt-check=true \
      --client-cert-auth=false \
      --peer-client-cert-auth=true \
      --data-dir=/etcd2-data --name=etcd2 \
      --initial-advertise-peer-urls=https://${NODE2}:2380 \
      --listen-peer-urls=https://${NODE2}:2380 \
      --advertise-client-urls=https://${NODE2}:2379 \
      --listen-client-urls=https://${NODE2}:2379,https://127.0.0.1:2379 \
      --initial-cluster=etcd1=https://${NODE1}:2380,etcd2=https://${NODE2}:2380,etcd3=https://${NODE3}:2380 \
      --initial-cluster-state=new

    sleep 2

    # Démarrage etcd3
    echo "Démarrage de etcd3..."
    docker run -td \
      --network kind \
      --volume ${PWD}/etcd:/etcd-pki \
      --name etcd3 ${REGISTRY}:${ETCD_VERSION} \
      /usr/local/bin/etcd \
      --cert-file=/etcd-pki/etcd.crt \
      --key-file=/etcd-pki/etcd.key \
      --trusted-ca-file=/etcd-pki/ca.crt \
      --peer-cert-file=/etcd-pki/etcd.crt \
      --peer-key-file=/etcd-pki/etcd.key \
      --peer-trusted-ca-file=/etcd-pki/ca.crt \
      --experimental-initial-corrupt-check=true \
      --client-cert-auth=false \
      --peer-client-cert-auth=true \
      --data-dir=/etcd3-data --name=etcd3 \
      --initial-advertise-peer-urls=https://${NODE3}:2380 \
      --listen-peer-urls=https://${NODE3}:2380 \
      --advertise-client-urls=https://${NODE3}:2379 \
      --listen-client-urls=https://${NODE3}:2379,https://127.0.0.1:2379 \
      --initial-cluster=etcd1=https://${NODE1}:2380,etcd2=https://${NODE2}:2380,etcd3=https://${NODE3}:2380 \
      --initial-cluster-state=new

    echo "✓ Cluster etcd démarré avec succès"
    echo ""
    echo "Status des conteneurs:"
    docker ps --filter name=etcd --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# Fonction pour vérifier le statut du cluster
check_cluster() {
    echo "=== Statut du cluster etcd ==="

    ETCDCTL_FLAGS="--cacert=${OUT}/ca.crt --cert=${OUT}/etcd.crt --key=${OUT}/etcd.key"
    ENDPOINTS="https://${NODE1}:2379,https://${NODE2}:2379,https://${NODE3}:2379"

    echo ""
    echo "--- Endpoint status ---"
    etcdctl ${ETCDCTL_FLAGS} --endpoints="${ENDPOINTS}" endpoint status --write-out=table

    echo ""
    echo "--- Endpoint health ---"
    etcdctl ${ETCDCTL_FLAGS} --endpoints="${ENDPOINTS}" endpoint health

    echo ""
    echo "--- Raft Applied Index par noeud ---"
    for node_ip in ${NODE1} ${NODE2} ${NODE3}; do
        applied_index=$(etcdctl ${ETCDCTL_FLAGS} --endpoints="https://${node_ip}:2379" endpoint status --write-out=json 2>/dev/null | jq -r '.[0].Status.raftAppliedIndex')
        echo "  ${node_ip} -> raftAppliedIndex: ${applied_index}"
    done

    echo ""
    echo "--- Member list ---"
    etcdctl ${ETCDCTL_FLAGS} --endpoints="${ENDPOINTS}" member list
}

# Fonction pour arrêter le cluster etcd
stop_cluster() {
    echo "=== Arrêt du cluster etcd ==="
    
    for node in etcd1 etcd2 etcd3; do
        if docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
            echo "Arrêt de $node..."
            docker stop $node
            docker rm $node
        else
            echo "$node n'est pas en cours d'exécution"
        fi
    done
    
    echo "✓ Cluster etcd arrêté"
}

# Fonction d'aide
show_help() {
    cat << EOF
Usage: $0 {cert|certs|start|stop|check}

Options:
  cert, certs     Génère uniquement les certificats SSL/TLS pour etcd
  start           Génère les certificats (si nécessaire) et démarre le cluster etcd
  stop            Arrête et supprime tous les conteneurs etcd
  check, status   Vérifie le statut du cluster et la sync via raft applied index

Exemples:
  $0 cert              # Génère les certificats
  $0 start             # Démarre le cluster (génère les certificats si besoin)
  $0 check             # Vérifie la sync du cluster
  $0 stop              # Arrête le cluster

Configuration:
  NODE1: ${NODE1}
  NODE2: ${NODE2}
  NODE3: ${NODE3}
  ETCD_VERSION: ${ETCD_VERSION}
  Répertoire certificats: ${OUT}

EOF
}

# Menu principal
case "${1:-}" in
    cert|certs)
        generate_certificates
        ;;
    start)
        start_cluster
        ;;
    stop)
        stop_cluster
        ;;
    check|status)
        check_cluster
        ;;
    -h|--help|help)
        show_help
        ;;
    *)
        echo "Erreur: Option invalide '${1:-}'"
        echo ""
        show_help
        exit 1
        ;;
esac