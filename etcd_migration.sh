#!/bin/bash
set -euo pipefail
# Configuration
readonly KUBEADM_FILE="/run/kubeadm/kubeadm.yaml"
log() { echo -e "\033[0;32m✅ $1\033[0m"; }
err() { echo -e "\033[0;31m❌ $1\033[0m" >&2; exit "${2:-1}"; }
step() { echo -e "\n\033[1;33m==> $1\033[0m"; }
validate_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || err "IP invalide: $1"
    local IFS='.'; read -ra O <<< "$1"
    for o in "${O[@]}"; do ((o <= 255)) || err "Octet IP > 255"; done
}
get_array_length() {
    local -n arr=$1
    echo "${arr[@]}" | wc -w
}
parse_endpoints() {
    declare -g -A ETCD_ENDPOINTS
    declare -g -a ETCD_IPS
    declare -g -a ETCD_NAMES
    declare -g ETCD_ENDPOINTS_STR=""
    local name=""
    local ip=""
    for arg in "$@"; do
        if [[ $arg =~ ^([^:]+):([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            name="${BASH_REMATCH[1]}"
            ip="${BASH_REMATCH[2]}"
            validate_ip "$ip"
            ETCD_ENDPOINTS["$name"]="$ip"
            ETCD_IPS+=("$ip")
            ETCD_NAMES+=("$name")
            [[ -n "$ETCD_ENDPOINTS_STR" ]] && ETCD_ENDPOINTS_STR+=","
            ETCD_ENDPOINTS_STR+="https://${ip}:2379"
            name=""
            ip=""
        elif [[ $arg =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            local count=$(get_array_length ETCD_IPS)
            name="etcd-node-$((count + 1))"
            ip="$arg"
            validate_ip "$ip"
            ETCD_ENDPOINTS["$name"]="$ip"
            ETCD_IPS+=("$ip")
            ETCD_NAMES+=("$name")
            [[ -n "$ETCD_ENDPOINTS_STR" ]] && ETCD_ENDPOINTS_STR+=","
            ETCD_ENDPOINTS_STR+="https://${ip}:2379"
            name=""
            ip=""
        elif [[ $arg =~ ^name:(.+)$ ]]; then
            name="${BASH_REMATCH[1]}"
        elif [[ $arg =~ ^ip:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            ip="${BASH_REMATCH[1]}"
            if [[ -n "$name" ]]; then
                validate_ip "$ip"
                ETCD_ENDPOINTS["$name"]="$ip"
                ETCD_IPS+=("$ip")
                ETCD_NAMES+=("$name")
                [[ -n "$ETCD_ENDPOINTS_STR" ]] && ETCD_ENDPOINTS_STR+=","
                ETCD_ENDPOINTS_STR+="https://${ip}:2379"
                name=""
                ip=""
            else
                err "Format endpoint invalide: $arg (ip sans name)"
            fi
        else
            err "Format endpoint invalide: $arg"
        fi
    done
    local count=$(get_array_length ETCD_IPS)
    log "Endpoints parsés: $count nœuds (${ETCD_NAMES[*]})"
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

prekubeadm() {
    [[ -f "$KUBEADM_FILE" ]] || { echo "Pas de $KUBEADM_FILE (normal si pas 1er CP)"; return 0; }
    local count=$(get_array_length ETCD_IPS)
    step "Pré-kubeadm avec $count endpoints existants"
    gen_certs
    /etc/kubernetes/install_etcd.sh
    local ip=$(hostname -I | awk '{print $1}')
    local hn=$(hostname)
    # Construction de l'initial-cluster avec tous les anciens membres
    local initial_cluster=""
    for name in "${ETCD_NAMES[@]}"; do
        member_ip="${ETCD_ENDPOINTS[$name]}"
        [[ -n "$initial_cluster" ]] && initial_cluster+=","
        initial_cluster+="${name}=https://${member_ip}:2380"
    done
    # Ajout du nouveau membre
    [[ -n "$initial_cluster" ]] && initial_cluster+=","
    initial_cluster+="${hn}=https://${ip}:2380"
    step "Ajout membre etcd: ${hn}"
    etcdctl --endpoints="$ETCD_ENDPOINTS_STR" member add "$hn" --peer-urls="https://${ip}:2380" || err "Ajout membre échoué"
    sed -i "/initial-cluster-state:/a\      initial-cluster: ${initial_cluster}" "$KUBEADM_FILE"
    log "Config pré-kubeadm OK. Démarrez kubeadm maintenant"
    log "Initial cluster: ${initial_cluster}"
}

postkubeadm() {
    [[ -f "$KUBEADM_FILE" ]] || { echo "Pas de $KUBEADM_FILE (normal si pas 1er CP)"; return 0; }
    local count=$(get_array_length ETCD_IPS)
    step "Post-kubeadm avec $count anciens endpoints"
    local ip=$(hostname -I | awk '{print $1}')
    local le="https://${ip}:2379"
    local ep="${ETCD_ENDPOINTS_STR},${le}"
    sleep 5
    export KUBECONFIG=/etc/kubernetes/super-admin.conf
    step "Nettoyage ConfigMap"
    kubectl get cm -n kube-system kubeadm-config -o yaml > /tmp/kubeadm-config.yaml
    sed -i '/^[[:space:]]*initial-cluster:/d' /tmp/kubeadm-config.yaml
    kubectl apply -f /tmp/kubeadm-config.yaml
    step "État cluster initial"
    step "Vérification synchronisation avec anciens nœuds"
    local max_attempts=30
    local attempt=0
    while ((attempt < max_attempts)); do
        local first_old_ip="${ETCD_IPS[0]}"
        local old_rev=$(etcdctl --endpoints="https://${first_old_ip}:2379" endpoint status --write-out=simple 2>/dev/null | awk -F, '{print $4}' | tr -d ' ' || echo "")
        local new_rev=$(etcdctl --endpoints="$le" endpoint status --write-out=simple 2>/dev/null | awk -F, '{print $4}' | tr -d ' ' || echo "")
        echo "Révision ancien: $old_rev | Révision nouveau: $new_rev"
        if [[ -n "$old_rev" && -n "$new_rev" && "$old_rev" == "$new_rev" ]]; then
            log "Nœuds synchronisés (révision: $old_rev)"
            break
        fi
        ((attempt++))
        [[ $attempt -eq $max_attempts ]] && err "Timeout: nœuds non synchronisés après 5 min"
        sleep 10
    done
    # Récupération de l'ID du leader et du nouveau nœud
    local lid=$(etcdctl --endpoints="$ep" endpoint status --write-out=simple | awk -F, '$5==" true"{print $2}' | tr -d ' ')
    local oid=$(etcdctl --endpoints="$le" endpoint status --write-out=simple | awk -F, '{print $2}' | tr -d ' ')
    echo "Local ID: $oid | Leader ID: $lid"
    if [[ "$lid" != "$oid" ]]; then
        step "Transfert leadership vers nouveau nœud"
        etcdctl --endpoints="$ep" move-leader "$oid" || err "Transfert échoué"
        sleep 2
        etcdctl --endpoints="$ep" endpoint status --write-out=table
    else
        log "Le nouveau nœud est déjà leader"
    fi
    step "Suppression des noeuds Kubernetes avec 'master-' dans le nom"
    local master_nodes=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name" | grep "master-" || true)
    if [[ -n "$master_nodes" ]]; then
        while IFS= read -r node_name; do
            if [[ -n "$node_name" ]]; then
                step "Drain et suppression du noeud Kubernetes: ${node_name}"
                kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s || echo "⚠️  Échec drain noeud ${node_name}"
                kubectl delete node "$node_name" || echo "⚠️  Échec suppression noeud ${node_name}"
                log "Noeud ${node_name} drainé et supprimé"
            fi
        done <<< "$master_nodes"
    else
        log "Aucun noeud avec 'master-' trouvé"
    fi
    log "Attente stabilisation cluster (10s)..."
    sleep 10
    step "Suppression des anciens membres etcd"
    # Récupérer tous les membres du cluster
    local members_output=$(etcdctl --endpoints="$le" member list --write-out=simple)
    # Supprimer chaque ancien membre basé sur son IP
    for old_ip in "${ETCD_IPS[@]}"; do
        # Trouver l'ID du membre correspondant à cette IP
        local member_id=$(echo "$members_output" | grep "$old_ip" | awk -F, '{print $1}' | tr -d ' ')

        if [[ -n "$member_id" ]]; then
            step "Suppression membre avec IP ${old_ip} (ID: ${member_id})"
            etcdctl --endpoints="$le" member remove "$member_id" || err "Suppression membre ${member_id} échouée"
            log "Membre ${member_id} supprimé"
            sleep 5  # Pause entre suppressions
        else
            echo "⚠️  Aucun membre trouvé avec IP ${old_ip}"
        fi
    done
    step "État final du cluster"
    etcdctl --endpoints="$le" endpoint status --write-out=table
    etcdctl --endpoints="$le" member list --write-out=table
    log "Migration terminée - tous les anciens membres ont été supprimés"
}

main() {
    [[ $EUID -eq 0 ]] || err "Exécuter en root"

    [[ $# -ge 1 ]] || err "Usage: $0 [prekubeadm|postkubeadm] <endpoint1> [endpoint2] [...]\n Format: name:ip ou simplement ip\n Ou bien paires consécutives name:etcd-01 ip:10.163.3.58\n Exemple: $0 prekubeadm etcd-01:10.163.3.58 etcd-02:10.163.3.113 etcd-03:10.163.3.178"

    local action="$1"
    shift
    case "$action" in
        prekubeadm|postkubeadm)
            [[ $# -ge 1 ]] || err "Les actions 'prekubeadm' et 'postkubeadm' nécessitent au moins un endpoint"
            parse_endpoints "$@"
            setup_env
            case "$action" in
                prekubeadm) prekubeadm ;;
                postkubeadm) postkubeadm ;;
            esac
            ;;
        *)
            err "Option Error. Use 'prekubeadm' ou 'postkubeadm'" 4
            ;;
    esac
    log "End of Script"
}
main "$@"
