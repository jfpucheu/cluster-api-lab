#!/bin/bash
set -euo pipefail
# Script d'installation etcdctl
# Utilisé par etcd_migration.sh et etcd_restore_s3.sh

readonly ETCD_VER="v3.5.16"
readonly ETCD_URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz"

log() { echo -e "\033[0;32m✅ $1\033[0m"; }
err() { echo -e "\033[0;31m❌ $1\033[0m" >&2; exit "${2:-1}"; }
step() { echo -e "\n\033[1;33m==> $1\033[0m"; }

# Vérifie si etcdctl est déjà installé avec la bonne version
if command -v etcdctl &>/dev/null && [[ $(etcdctl version | head -n1 | awk '{print $3}') == "$ETCD_VER" ]]; then
    log "etcdctl ${ETCD_VER} déjà installé"
    exit 0
fi

step "Installation etcdctl ${ETCD_VER}"
curl -fsSL "$ETCD_URL" -o /tmp/etcd.tar.gz || err "Téléchargement échoué"
tar xzf /tmp/etcd.tar.gz -C /usr/local/bin --strip-components=1 "etcd-${ETCD_VER}-linux-amd64/etcdctl" "etcd-${ETCD_VER}-linux-amd64/etcd"
rm -f /tmp/etcd.tar.gz
log "etcd installé"
- path: /etc/kubernetes/etcd_migration.sh
owner: "root:root"
permissions: "0744"
content: |
#!/bin/bash
set -euo pipefail

readonly KUBEADM_FILE="/run/kubeadm/kubeadm.yaml"
log() { echo -e "\033[0;32m✅ $1\033[0m"; }
err() { echo -e "\033[0;31m❌ $1\033[0m" >&2; exit "${2:-1}"; }
step() { echo -e "\n\033[1;33m==> $1\033[0m"; }

validate_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || err "IP invalide: $1"
    local IFS='.'; read -ra O <<< "$1"
    for o in "${O[@]}"; do ((o <= 255)) || err "Octet > 255"; done
}

add_endpoint() {
    validate_ip "$2"
    ETCD_ENDPOINTS["$1"]="$2"
    ETCD_IPS+=("$2")
    ETCD_NAMES+=("$1")
    ETCD_ENDPOINTS_STR+="${ETCD_ENDPOINTS_STR:+,}https://$2:2379"
}

parse_endpoints() {
    declare -g -A ETCD_ENDPOINTS
    declare -g -a ETCD_IPS ETCD_NAMES
    declare -g ETCD_ENDPOINTS_STR=""
    local name="" ip=""
    
    for arg in "$@"; do
        # Format name:ip
        if [[ $arg =~ ^([^:]+):([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            add_endpoint "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        # Format ip seule
        elif [[ $arg =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            add_endpoint "etcd-node-$((${#ETCD_IPS[@]} + 1))" "$arg"
        # Format name:xxx
        elif [[ $arg =~ ^name:(.+)$ ]]; then
            name="${BASH_REMATCH[1]}"
        # Format ip:xxx
        elif [[ $arg =~ ^ip:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            ip="${BASH_REMATCH[1]}"
            [[ -n "$name" ]] && add_endpoint "$name" "$ip" && name="" || err "ip sans name: $arg"
        else
            err "Format invalide: $arg"
        fi
    done
    log "Endpoints: ${#ETCD_IPS[@]} nœuds (${ETCD_NAMES[*]})"
}

setup_env() {
    export ETCDCTL_API=3 ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt \
            ETCDCTL_CERT=/tmp/etcd-client.crt ETCDCTL_KEY=/tmp/etcd-client.key
}

gen_certs() {
    step "Génération certificats"
    openssl genrsa -out $ETCDCTL_KEY 2048 2>/dev/null
    openssl req -new -key $ETCDCTL_KEY -out /tmp/etcd-client.csr -subj "/CN=etcd-client" 2>/dev/null
    openssl x509 -req -in /tmp/etcd-client.csr -CA $ETCDCTL_CACERT \
        -CAkey /etc/kubernetes/pki/etcd/ca.key -CAcreateserial \
        -out $ETCDCTL_CERT -days 1 -sha256 2>/dev/null
    log "Certificats OK"
}

prekubeadm() {
    [[ -f "$KUBEADM_FILE" ]] || { echo "Pas de $KUBEADM_FILE"; return 0; }
    step "Pré-kubeadm avec ${#ETCD_IPS[@]} endpoints"
    gen_certs
    /etc/kubernetes/install_etcd.sh
    
    local ip=$(hostname -I | awk '{print $1}')
    local hn=$(hostname)
    local ic=""
    
    for name in "${ETCD_NAMES[@]}"; do
        ic+="${ic:+,}${name}=https://${ETCD_ENDPOINTS[$name]}:2380"
    done
    ic+=",${hn}=https://${ip}:2380"
    
    step "Ajout membre: ${hn}"
    etcdctl --endpoints="$ETCD_ENDPOINTS_STR" member add "$hn" --peer-urls="https://${ip}:2380" || err "Ajout échoué"
    sed -i "/initial-cluster-state:/a\      initial-cluster: ${ic}" "$KUBEADM_FILE"
    log "Config OK. Initial cluster: ${ic}"
}

postkubeadm() {
    [[ -f "$KUBEADM_FILE" ]] || { echo "Pas de $KUBEADM_FILE"; return 0; }
    step "Post-kubeadm avec ${#ETCD_IPS[@]} endpoints"
    
    local ip=$(hostname -I | awk '{print $1}')
    local le="https://${ip}:2379"
    local ep="${ETCD_ENDPOINTS_STR},${le}"
    
    sleep 5
    export KUBECONFIG=/etc/kubernetes/super-admin.conf
    
    step "Nettoyage ConfigMap"
    kubectl get cm -n kube-system kubeadm-config -o yaml > /tmp/kubeadm-config.yaml
    sed -i '/^[[:space:]]*initial-cluster:/d' /tmp/kubeadm-config.yaml
    kubectl apply -f /tmp/kubeadm-config.yaml
    
    step "Vérification synchronisation"
    local attempt=0
    while ((attempt < 30)); do
        echo "attempt: $attempt"
        local old_rev=$(etcdctl --endpoints="https://${ETCD_IPS[0]}:2379" endpoint status --write-out=simple 2>/dev/null | awk -F, '{print $8}' | tr -d ' ' || echo "")
        local new_rev=$(etcdctl --endpoints="$le" endpoint status --write-out=simple 2>/dev/null | awk -F, '{print $8}' | tr -d ' ' || echo "")
        echo "Rev ancien: $old_rev | nouveau: $new_rev"
        [[ -n "$old_rev" && -n "$new_rev" && "$old_rev" == "$new_rev" ]] && { log "Synchro OK (rev: $old_rev)"; break; }
        ((attempt++))
        [[ $attempt -eq 30 ]] && err "Timeout sync"
        sleep 10
    done
    
    local lid=$(etcdctl --endpoints="$ep" endpoint status --write-out=simple | awk -F, '$5==" true"{print $2}' | tr -d ' ')
    local oid=$(etcdctl --endpoints="$le" endpoint status --write-out=simple | awk -F, '{print $2}' | tr -d ' ')
    
    echo "Local ID: $oid | Leader ID: $lid"
    if [[ "$lid" != "$oid" ]]; then
        step "Transfert leadership"
        etcdctl --endpoints="$ep" move-leader "$oid" || err "Transfert échoué"
        sleep 2
        etcdctl --endpoints="$ep" endpoint status --write-out=table
    else
        log "Nouveau nœud déjà leader"
    fi
    
    step "Suppression nœuds master-*"
    local nodes=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name" | grep "master-" || true)
    if [[ -n "$nodes" ]]; then
        while IFS= read -r node; do
            [[ -n "$node" ]] && {
                step "Drain: ${node}"
                kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s || echo "⚠️ Échec drain"
                kubectl delete node "$node" || echo "⚠️ Échec delete"
                log "Nœud ${node} supprimé"
            }
        done <<< "$nodes"
    else
        log "Aucun master-* trouvé"
    fi
    
    sleep 10
    step "Suppression anciens membres etcd"
    local members=$(etcdctl --endpoints="$le" member list --write-out=simple)
    
    for old_ip in "${ETCD_IPS[@]}"; do
        local mid=$(echo "$members" | grep "$old_ip" | awk -F, '{print $1}' | tr -d ' ')
        if [[ -n "$mid" ]]; then
            step "Suppression IP ${old_ip} (ID: ${mid})"
            etcdctl --endpoints="$le" member remove "$mid" || err "Suppression ${mid} échouée"
            log "Membre ${mid} supprimé"
            sleep 5
        else
            echo "⚠️ Aucun membre avec IP ${old_ip}"
        fi
    done
    
    step "État final"
    etcdctl --endpoints="$le" endpoint status --write-out=table
    etcdctl --endpoints="$le" member list --write-out=table
    log "Migration terminée"
}

main() {
    [[ $EUID -eq 0 ]] || err "Root requis"
    [[ $# -ge 1 ]] || err "Usage: $0 [prekubeadm|postkubeadm] <endpoint1> ...\nFormat: name:ip ou ip\nEx: $0 prekubeadm etcd-01:10.0.0.1 10.0.0.2"
    
    local action="$1"
    shift
    
    case "$action" in
        prekubeadm|postkubeadm)
            [[ $# -ge 1 ]] || err "Au moins 1 endpoint requis"
            parse_endpoints "$@"
            setup_env
            $action
            ;;
        *) err "Use 'prekubeadm' ou 'postkubeadm'" 4 ;;
    esac
    log "Fin"
}

main "$@"