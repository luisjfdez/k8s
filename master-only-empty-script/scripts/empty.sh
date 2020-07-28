#!/bin/bash

# Arguments
NODE_INDEX=$1
UNIQUE_STRING=$2
API_LB_ENDPOINT="$3:6443"
ADMIN_USERNAME=$4
KUBERNETES_VERSION=$5
KUBERNETES_VERSION_CONFIG="${6:-stable}"

POD_SUBNET="10.244.0.0/16"
OVERLAY_CONF="https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
KUBEADM_CONF="kubeadm_config.yaml"
# Generate a 32 byte key from the unique string
CERTIFICATE_KEY=$(echo $UNIQUE_STRING | xxd -p -c 32 -l 32)
# Generate the bootstrap token from the unique string
# [a-z0-9]{6}\.[a-z0-9]{16}
BOOTSTRAP_TOKEN="${UNIQUE_STRING:0:6}"."${UNIQUE_STRING:6:16}"

echo "===== ARGS ===="
echo ${NODE_INDEX}
echo ${UNIQUE_STRING}
echo ${API_LB_ENDPOINT}
echo ${KUBERNETES_VERSION}
echo ${KUBERNETES_VERSION_CONFIG}
echo ${POD_SUBNET}
echo ${OVERLAY_CONF}
echo ${KUBEADM_CONF}
echo ${CERTIFICATE_KEY}
echo ${BOOTSTRAP_TOKEN}
