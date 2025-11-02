NODE1=172.18.0.3
NODE2=172.18.0.4
NODE3=172.18.0.5
ETCD_VERSION=v3.4.37
REGISTRY=quay.io/coreos/etcd
# available from v3.2.5
REGISTRY=gcr.io/etcd-development/etcd

docker run -td \
  -p 2379:2379 \
  -p 2380:2380 \
  --network kind \
  --volume ${PWD}/etcd:/etcd-pki \
  --name etcd1 ${REGISTRY}:${ETCD_VERSION} \
  /usr/local/bin/etcd \
  --cert-file=/etcd-pki/server.crt \
  --key-file=/etcd-pki/server.key \
  --trusted-ca-file=/etcd-pki/ca.crt \
  --peer-cert-file=/etcd-pki/server.crt \
  --peer-key-file=/etcd-pki/server.key \
  --peer-trusted-ca-file=/etcd-pki/ca.crt \
  --experimental-initial-corrupt-check=true \
  --client-cert-auth=false \
  --data-dir=/etcd-data --name node1 \
  --initial-advertise-peer-urls=https://${NODE1}:2380 \
  --listen-peer-urls=https://0.0.0.0:2380 \
  --advertise-client-urls=https://${NODE1}:2379 \
  --listen-client-urls=https://0.0.0.0:2379 \
  --initial-cluster=node1=https://${NODE1}:2380
#  --initial-cluster=node1=https://${NODE1}:2380,node2=https://${NODE2}:2380,node3=https://${NODE3}:2380
#  --volume=${DATA_DIR}:/etcd-data \

#sleep 2

#docker run -td \
#  --network kind \
#  --volume ${PWD}/etcd:/etcd-pki \
#  --name etcd2 ${REGISTRY}:${ETCD_VERSION} \
#  /usr/local/bin/etcd \
#  --cert-file=/etcd-pki/server.crt \
#  --key-file=/etcd-pki/server.key \
#  --trusted-ca-file=/etcd-pki/ca.crt \
#  --peer-cert-file=/etcd-pki/server.crt \
#  --peer-key-file=/etcd-pki/server.key \
#  --peer-trusted-ca-file=/etcd-pki/ca.crt \
#  --experimental-initial-corrupt-check=true \
#  --client-cert-auth=false \
#  --data-dir=/etcd-data --name node2 \
#  --initial-advertise-peer-urls=https://${NODE2}:2380 \
#  --listen-peer-urls=https://0.0.0.0:2380 \
#  --advertise-client-urls=https://${NODE2}:2379 \
#  --listen-client-urls=https://0.0.0.0:2379 \
#  --initial-cluster=node1=https://${NODE1}:2380,node2=https://${NODE2}:2380,node3=https://${NODE3}:2380
#  --volume=${DATA_DIR}:/etcd-data \

#sleep 2

#docker run -td \
#  --network kind \
#  --volume ${PWD}/etcd:/etcd-pki \
#  --name etcd3 ${REGISTRY}:${ETCD_VERSION} \
#  /usr/local/bin/etcd \
#  --cert-file=/etcd-pki/server.crt \
#  --key-file=/etcd-pki/server.key \
#  --trusted-ca-file=/etcd-pki/ca.crt \
#  --peer-cert-file=/etcd-pki/server.crt \
#  --peer-key-file=/etcd-pki/server.key \
#  --peer-trusted-ca-file=/etcd-pki/ca.crt \
#  --experimental-initial-corrupt-check=true \
#  --client-cert-auth=false \
#  --data-dir=/etcd-data --name node3 \
#  --initial-advertise-peer-urls=https://${NODE3}:2380 \
#  --listen-peer-urls=https://0.0.0.0:2380 \
#  --advertise-client-urls=https://${NODE3}:2379 \
#  --listen-client-urls=https://0.0.0.0:2379 \
#  --initial-cluster=node1=https://${NODE1}:2380,node2=https://${NODE2}:2380,node3=https://${NODE3}:2380
#  --volume=${DATA_DIR}:/etcd-data \
