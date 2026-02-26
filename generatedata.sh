#!/bin/bash

export ETCDCTL_CACERT=/Users/jeff/dev/cluster-api-lab/etcd/ca.crt
export ETCDCTL_CERT=/Users/jeff/dev/cluster-api-lab/etcd/apiserver-etcd-client.crt
export ETCDCTL_KEY=/Users/jeff/dev/cluster-api-lab/etcd/apiserver-etcd-client.key
export ETCDCTL_ENDPOINTS="https://127.0.0.1:2379"

# --- Configuration ---
TARGET_SIZE_MB=700        # Taille cible en MB
VALUE_SIZE=1048576         # 1 MB par valeur (limite etcd = 1.5 MB)
PARALLEL_JOBS=20           # Nombre d'écritures en parallèle
TOTAL_KEYS=$(( TARGET_SIZE_MB ))  # 1024 clefs pour 1 GB

echo "=== Génération de données dans etcd ==="
echo "Cible: ${TARGET_SIZE_MB} MB | Valeur: ${VALUE_SIZE} octets | Clefs: ${TOTAL_KEYS} | Parallélisme: ${PARALLEL_JOBS}"

# Génère une valeur de 1 MB dans un fichier (évite "Argument list too long")
VALUE_FILE=/tmp/etcd-gendata-value.bin
head -c "$VALUE_SIZE" /dev/urandom | base64 | head -c "$VALUE_SIZE" > "$VALUE_FILE"

# Écriture en parallèle avec log de progression
START=$(date +%s)
seq 1 "$TOTAL_KEYS" | xargs -P "$PARALLEL_JOBS" -I{} bash -c '
    etcdctl put "key:{}" < "'"$VALUE_FILE"'" > /dev/null 2>&1
    i={}
    if ((i % 100 == 0)); then
        echo "  ℹ️  ${i}/'"$TOTAL_KEYS"' clefs écrites..."
    fi
'
END=$(date +%s)
DURATION=$((END - START))
rm -f "$VALUE_FILE"
echo "✓ ${TOTAL_KEYS} key/value générées (~${TARGET_SIZE_MB} MB) en ${DURATION}s"

# Simule des données type config app
for env in dev staging prod; do
    for app in frontend backend worker; do
        etcdctl put "config/${env}/${app}/replicas" "$((RANDOM % 5 + 1))" > /dev/null
        etcdctl put "config/${env}/${app}/port" "$((8000 + RANDOM % 1000))" > /dev/null
        etcdctl put "config/${env}/${app}/log_level" "info" > /dev/null
    done
done
echo "✓ Données type config/env/app générées"

# Simule des données type service discovery
for i in $(seq 1 5); do
    etcdctl put "services/web/instance-${i}" "{\"ip\":\"10.0.0.${i}\",\"port\":$((8080 + i)),\"healthy\":true}" > /dev/null
done
echo "✓ Données type service discovery générées"

# Vérifier la sync après insertion
echo ""
echo "=== Raft Applied Index par noeud ==="
for node_ip in 172.18.0.3 172.18.0.4 172.18.0.5; do
    export ETCDCTL_ENDPOINTS="https://${node_ip}:2379"
    applied_index=$(etcdctl endpoint status --write-out=json 2>/dev/null | jq -r '.[0].Status.raftAppliedIndex')
    echo "  ${node_ip} -> raftAppliedIndex: ${applied_index}"
done

echo ""
echo "=== Données insérées ==="
export ETCDCTL_ENDPOINTS="https://172.18.0.3:2379"
etcdctl get --prefix "" --keys-only
