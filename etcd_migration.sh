#!/bin/bash
set -euo pipefail

# Configuration
readonly ETCD_VER="v3.5.21"
readonly ETCD_URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz"
readonly KUBEADM_FILE="/run/kubeadm/kubeadm.yaml"

log() { echo -e "\033[0;32m✅ $1\033[0m"; }
err() { echo -e "\033[0;31m❌ $1\033[0m" >&2; exit "${2:-1}"; }
step() { echo -e "\n\033[1;33m==> $1\033[0m"; }

validate_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || err "IP invalide"
    local IFS='.'; read -ra O <<< "$1"
    for o in "${O[@]}"; do ((o <= 255)) || err "Octet IP > 255"; done
}

setup_env() {
    export ETCDCTL_API=3 ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt \
            ETCDCTL_CERT=/tmp/etcd-client.crt ETCDCTL_KEY=/tmp/etcd-client.key
}

gen_certs() {
    step "Génération certificats"
    ETCDCTL_CACERT_KEY=/etc/kubernetes/pki/etcd/ca.key 
    openssl genrsa -out $ETCDCTL_KEY 2048 2>/dev/null
    openssl req -new -key $ETCDCTL_KEY -out /tmp/etcd-client.csr -subj "/CN=etcd-client" 2>/dev/null
    openssl x509 -req -in /tmp/etcd-client.csr -CA $ETCDCTL_CACERT -CAkey $ETCDCTL_CACERT_KEY \
        -CAcreateserial -out $ETCDCTL_CERT -days 1 -sha256 2>/dev/null
    log "Certificats OK"
}

install_etcd() {
    command -v etcdctl &>/dev/null && [[ $(etcdctl version | head -n1 | awk '{print $3}') == "$ETCD_VER" ]] && return
    step "Installation etcdctl ${ETCD_VER}"
    curl -fsSL "$ETCD_URL" -o /tmp/etcd.tar.gz || err "Téléchargement échoué"
    tar xzf /tmp/etcd.tar.gz -C /usr/local/bin --strip-components=1 "etcd-${ETCD_VER}-linux-amd64/etcdctl" "etcd-${ETCD_VER}-linux-amd64/etcd"
    rm -f /tmp/etcd.tar.gz
    log "etcd installé"
}

prekubeadm() {
    [[ -f "$KUBEADM_FILE" ]] || { echo "Pas de $KUBEADM_FILE (normal si pas 1er CP)"; return 0; }
    step "Pré-kubeadm avec IP: $1"
    gen_certs
    install_etcd
    
    local ip=$(hostname -I | awk '{print $1}')
    local hn=$(hostname)
    
    step "Ajout membre etcd"
    etcdctl --endpoints="https://$1:2379" member add "$hn" --peer-urls="https://${ip}:2380" || err "Ajout membre échoué"
    
    sed -i "/initial-cluster-state:/a\      initial-cluster: nodeold=https://$1:2380,${hn}=https://${ip}:2380" "$KUBEADM_FILE"
    log "Config pré-kubeadm OK. Démarrez kubeadm maintenant"
}

postkubeadm() {
    [[ -f "$KUBEADM_FILE" ]] || { echo "Pas de $KUBEADM_FILE (normal si pas 1er CP)"; return 0; }
    step "Post-kubeadm avec IP: $1"
    
    local ip=$(hostname -I | awk '{print $1}')
    local le="https://${ip}:2379"
    local ep="https://$1:2379,${le}"
    
    step "Nettoyage ConfigMap"
    kubectl get cm -n kube-system kubeadm-config -o yaml > /tmp/kubeadm-config.yaml
    sed -i '/^[[:space:]]*initial-cluster:/d' /tmp/kubeadm-config.yaml
    kubectl apply -f /tmp/kubeadm-config.yaml
    
    step "État cluster"
    etcdctl --endpoints="$ep" endpoint status --write-out=table
    
    local lid=$(etcdctl --endpoints="$ep" endpoint status --write-out=simple | awk -F, '$5==" true"{print $2}'  | tr -d ' ')
    local oid=$(etcdctl --endpoints="$le" endpoint status --write-out=simple | awk -F, '{print $2}'  | tr -d ' ')
    
    echo "Local ID: $oid | Leader ID: $lid"
    
    if [[ "$lid" != "$oid" ]]; then
        step "Transfert leadership"
        etcdctl --endpoints="$ep" move-leader "$oid" || err "Transfert échoué"
        sleep 2
        etcdctl --endpoints="$ep" endpoint status --write-out=table
    fi
    
    step "Suppression ancien membre"
    etcdctl --endpoints="$ep" member remove "$lid" || err "Suppression échouée"
    etcdctl --endpoints="$ep" endpoint status --write-out=table
    log "Migration terminée"
}

main() {
    [[ $# -eq 2 ]] || err "Usage: $0 [prekubeadm|postkubeadm] <IP>"
    [[ $EUID -eq 0 ]] || err "Exécuter en root"
    
    validate_ip "$2"
    setup_env
    
    case "$1" in
        prekubeadm) prekubeadm "$2" ;;
        postkubeadm) postkubeadm "$2" ;;
        *) err "Option invalide. Utilisez 'prekubeadm' ou 'postkubeadm'" 4 ;;
    esac
    
    log "Script terminé"
}
main "$@"