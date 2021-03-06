#!/bin/bash

# Arguments
NODE_INDEX=$1
UNIQUE_STRING=$2
API_LB_ENDPOINT="$3:6443"
ADMIN_USERNAME=$4
KUBERNETES_VERSION=$5
KUBERNETES_VERSION_CONFIG="${6:-stable}"
INSTALL_MODE="${7:-gpu}"

GPU_INSTALL="yes"
if [ "${INSTALL_MODE}" != "gpu" ]
then
  GPU_INSTALL=""
fi

if [ ! -z "$GPU_INSTALL" ]
then
  echo "install gpu mode"
else
  echo "install cpu mode"
fi

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
echo ${INSTALL_MODE}
echo ${GPU_INSTALL}

if [ ! -z "$GPU_INSTALL" ]
then
  echo "install gpu mode"
  # Installation
  echo "===== update package database ====="
  sudo apt-get update \
    && echo "## Pass: updated package database" \
    || { echo "## Fail: failed to update package database" ; exit 1 ; }

  sudo apt-get purge nvidia* -y
  sudo apt-get autoremove -y
  sudo apt-get autoclean -y
  sudo rm -rf /usr/local/cuda*

  sudo apt-key adv --fetch-keys http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub
  echo "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64 /" | sudo tee /etc/apt/sources.list.d/cuda.list

  sudo apt-get update -y
  # This step takes 10+ minutes
  sudo apt-get -o Dpkg::Options::="--force-overwrite" install -y cuda-10-0 cuda-drivers \
    && echo "## Pass: cuda packages installed" \
    || { echo "## Fail: failed to install cuda packages" ; exit 1 ; }
else
  echo "install cpu mode"
fi

# Installation
echo "===== update package database ====="
sudo apt-get update \
  && echo "## Pass: updated package database" \
  || { echo "## Fail: failed to update package database" ; exit 1 ; }


echo "===== install prereq packages ====="
sudo apt-get install -y apt-transport-https curl \
  && echo "## Pass: prereq packages installed" \
  || { echo "## Fail: failed to install prereq packages" ; exit 1 ; }


echo "===== install Docker ====="
sudo apt-get install -y docker.io \
  && echo "## Pass: installed docker" \
  || { echo "## Fail: failed to install docker" ; exit 1 ; }

echo "===== add gpg key for Google ====="
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add - \
  && echo "## Pass: added GPG key for Google repository" \
  || { echo "## Fail: failed to add GPG key for Google repository" ; exit 1 ; }

echo "===== add Kubernetes repository ====="
cat << EOF | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF

echo "===== update package database ====="
sudo apt-get update \
  && echo "## Pass: updated package database" \
  || { echo "## Fail: failed to update package database" ; exit 1 ; }

## Needed for flannel
sudo modprobe br_netfilter
sudo su -c 'echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.conf'
sudo su -c 'echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.conf'
sudo /sbin/sysctl -p /etc/sysctl.conf

echo "===== install Kubernetes components using specified version ====="
if [ "$KUBERNETES_VERSION" = "latest" ]; then
  sudo apt-get install -y kubelet kubeadm kubectl \
    && echo "## Pass: Install latest version of Kubernetes components" \
    || { echo "## Fail: failed to install latest version of Kubernetes components" ; exit 1 ; }
else
  sudo apt-get install -y kubelet=${KUBERNETES_VERSION} kubeadm=${KUBERNETES_VERSION} kubectl=${KUBERNETES_VERSION} \
    && echo "## Pass: Install ${KUBERNETES_VERSION} version of Kubernetes components" \
    || { echo "## Fail: failed to install ${KUBERNETES_VERSION} version of Kubernetes components" ; exit 1 ; }
fi

# Fix warning 1
sudo systemctl enable docker.service \
  && echo "## Pass: Apply fix for kubeadm init warning" \
  || { echo "## Fail: failed to apply fix for kubeadm init warning" ; exit 1 ; }

# Add docker data disk as external
disk_symlink=$(sudo ls -l /dev/disk/azure --recursive | grep "lun0")
disk_symlink_reference=$(echo $disk_symlink | awk '{match($0,"lun0 -> ([^ ]+)",a)}END{print a[1]}')
disk_symname=$(echo $disk_symlink_reference | awk '{match($0,"(../)+([^ ]+)",a)}END{print a[2]}')
arch_fdisk_name="/dev/${disk_symname}"
# Format disk
(echo n; echo p; echo 1; echo ; echo ; echo w) | sudo fdisk ${arch_fdisk_name}
arch_fdisk_partition=${arch_fdisk_name}1
# Mount disk
sudo mkfs -t ext4 ${arch_fdisk_partition}
# Get disk UUID
disk_uuid=$(sudo blkid -s UUID -o value ${arch_fdisk_partition})


# mount disk
sudo mkdir /data
sudo mount ${arch_fdisk_partition} /data
sudo mkdir /data/docker

# ensure mount stays after restart adding to fstab
disk_uuid_to_fstab="UUID=${disk_uuid}   /data  ext4    defaults,nofail   1  2)"
echo $disk_uuid_to_fstab | sudo tee -a /etc/fstab


if [ ! -z "$GPU_INSTALL" ]
then
  # Add the package repositories
  curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
  distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
  curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
  sudo apt-get update

  # Install nvidia-docker2 and reload the Docker daemon configuration
  sudo apt-get install -y nvidia-docker2
fi

if [ ! -z "$GPU_INSTALL" ]
then
  echo "install gpu mode"
cat << EOF | sudo tee /etc/docker/daemon.json
{
  "data-root": "/data/docker",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "default-runtime": "nvidia",
  "runtimes": {
      "nvidia": {
            "path": "/usr/bin/nvidia-container-runtime",
            "runtimeArgs": []
          }
    }
}
EOF
else
  echo "install cpu mode"
cat << EOF | sudo tee /etc/docker/daemon.json
{
  "data-root": "/data/docker",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
fi

sudo mkdir -p /etc/systemd/system/docker.service.d \
  && echo "## Pass: Apply fix for kubeadm init warning" \
  || { echo "## Fail: failed to apply fix for kubeadm init warning" ; exit 1 ; }

sudo systemctl daemon-reload \
  && echo "## Pass: reload daemon" \
  || { echo "## Fail: failed to reload daemon" ; exit 1 ; }

sudo systemctl restart docker \
  && echo "## Pass: restart docker" \
  || { echo "## Fail: failed to restart docker" ; exit 1 ; }


if [ "$NODE_INDEX" = "1" ]; then

  echo "===== Creating the cluster on the first node ====="

cat <<EOF >${KUBEADM_CONF}
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: "${BOOTSTRAP_TOKEN}"
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
certificateKey: "${CERTIFICATE_KEY}"
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
networking:
  podSubnet: "${POD_SUBNET}"
kubernetesVersion: "${KUBERNETES_VERSION_CONFIG}"
controlPlaneEndpoint: "${API_LB_ENDPOINT}"
EOF

  sudo kubeadm init --config ${KUBEADM_CONF} --upload-certs \
    && echo "## Pass: Initiale Kubenetes cluster" \
    || { echo "## Fail: failed to initialize Kubernetes cluster" ; exit 1 ; }

  # Apply network overlay
  sudo kubectl apply -f ${OVERLAY_CONF} --kubeconfig /etc/kubernetes/admin.conf \
    && echo "## Pass: Applied network overlay" \
    || { echo "## Fail: failed to apply network overlay" ; exit 1 ; }

  # Untaint the master
  sudo kubectl taint nodes $(hostname) node-role.kubernetes.io/master- --kubeconfig /etc/kubernetes/admin.conf

else

  echo "===== Adding an additional master to the cluster ====="

cat <<EOF >${KUBEADM_CONF}
apiVersion: kubeadm.k8s.io/v1beta2
kind: JoinConfiguration
controlPlane:
  certificateKey: "${CERTIFICATE_KEY}"
discovery:
  bootstrapToken:
    apiServerEndpoint: "${API_LB_ENDPOINT}"
    token: "${BOOTSTRAP_TOKEN}"
    unsafeSkipCAVerification: true
  timeout: 5m0s
EOF

  sudo kubeadm join --config ${KUBEADM_CONF} \
    && echo "## Pass: Join master to Kubenetes cluster" \
    || { echo "## Fail: failed to join master to Kubernetes cluster" ; exit 1 ; }

  # Untaint the master
  sudo kubectl taint nodes $(hostname) node-role.kubernetes.io/master- --kubeconfig /etc/kubernetes/admin.conf

fi

echo "===== Copy conf files to user context ====="


mkdir -p /home/$ADMIN_USERNAME/.kube \
  && echo "## Pass: Create .kube folder in home dir" \
  || { echo "## Fail: failed to create .kube folder in home dir" ; exit 1 ; }

sudo chown $(id -u $ADMIN_USERNAME):$(id -g $ADMIN_USERNAME) /home/$ADMIN_USERNAME/.kube

sudo cp -T -v /etc/kubernetes/admin.conf /home/$ADMIN_USERNAME/.kube/config \
  && echo "## Pass: Copy admin.conf to .kube" \
  || { echo "## Fail: failed to copy admin.conf to .kube" ; exit 1 ; }

sudo chown $(id -u $ADMIN_USERNAME):$(id -g $ADMIN_USERNAME) /home/$ADMIN_USERNAME/.kube/config \
  && echo "## Pass: Set permissions on .kube/config folder" \
  || { echo "## Fail: failed to set permissions on .kube/config folder" ; exit 1 ; }
