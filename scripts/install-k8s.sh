#!/usr/bin/env bash

################################################################################
# Version:             v1.0
# Description:         Install k8s cluster script
# Author:              Edward Guan
# Homepage:            https://github.com/guanwei
# Created Date:        2018-04-05 08:30
# Last Modified Date:  
################################################################################

if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script!"; exit 1
fi

enable_net_forward_and_disable_swap() {
    echo "### enable net forward and disable swap..."
    swapoff -a
    sed -i 's|\[^#\]* swap .*|#&|g' /etc/fstab

    cat > /etc/sysctl.d/k8s.conf <<-EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
EOF
    modprobe br_netfilter
    sysctl -p /etc/sysctl.d/k8s.conf
    free -m
}

set_proxy() {
    tee /etc/profile.d/proxy.sh <<-EOF
export http_proxy=$PROXY
export https_proxy=$PROXY
export no_proxy=$NO_PROXY
EOF
  source /etc/profile.d/proxy.sh
}

install_docker_on_ubuntu() {
    echo "### install docker..."
    apt-get update && apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    tee /etc/apt/sources.list.d/docker.list <<-EOF
deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable
EOF
    apt-get update && apt-get install -y docker-ce=$(apt-cache madison docker-ce | grep 17.03 | head -1 | awk '{print $3}')
    apt-mark hold docker-ce
    rm -f /etc/apt/sources.list.d/docker.list

    # let vagrant user can run docker command
    gpasswd -a vagrant docker

    # Docker从1.13版本开始调整了默认的防火墙规则，禁用了iptables filter表中FOWARD链，这样会引起Kubernetes集群中跨Node的Pod无法通信
    grep -q '^ExecStartPost=' /lib/systemd/system/docker.service &&
        sed -i 's|^ExecStartPost=.*|ExecStartPost=/sbin/iptables -P FORWARD ACCEPT|g' /lib/systemd/system/docker.service ||
        sed -i '/ExecStart=.*/aExecStartPost=/sbin/iptables -P FORWARD ACCEPT' /lib/systemd/system/docker.service
    
    # Set docker proxy
    mkdir -p /etc/systemd/system/docker.service.d
    tee /etc/systemd/system/docker.service.d/proxy.conf <<-EOF
[Service]
Environment="http_proxy=$http_proxy"
Environment="https_proxy=$https_proxy"
Environment="no_proxy=$no_proxy"
EOF
    systemctl daemon-reload
    systemctl restart docker

    docker info
}

install_kube_tools_on_ubuntu() {
    echo "### install kubelet, kubeadm, kubectl..."
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    tee /etc/apt/sources.list.d/kubernetes.list <<-EOF
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
    apt-get update && apt-get install -y kubelet kubeadm kubectl

    # set fail-swap-on=false for kubelet service
    grep -q "^Environment=\"KUBELET_EXTRA_ARGS=" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf &&
        sed -i "s|^Environment=\"KUBELET_EXTRA_ARGS=.*|Environment=\"KUBELET_EXTRA_ARGS=--fail-swap-on=false\"|g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf ||
        echo "Environment=\"KUBELET_EXTRA_ARGS=--fail-swap-on=false\"" >> /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    systemctl daemon-reload
    systemctl restart kubelet
}

install_k8s_python_client_on_ubuntu() {
    apt-get update && apt install -y python3-pip
    pip3 install --upgrade pip
    pip3 install kubernetes
}

k8s_master_up() {
    echo "### set up k8s master..."
    kubeadm init --token $KUBE_TOKEN --token-ttl 0 --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$APISERVER_IP

    mkdir -p /home/vagrant/.kube
    cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
    chown -R vagrant:vagrant /home/vagrant/.kube

    grep -q "^export KUBECONFIG=" /root/.bashrc &&
        sed -i "s|^export KUBECONFIG=.*|export KUBECONFIG=/etc/kubernetes/admin.conf|g" /root/.bashrc ||
        echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /root/.bashrc
    export KUBECONFIG=/etc/kubernetes/admin.conf

    apt-get install -y bash-completion
    tee /etc/profile.d/kube_completion.sh <<-EOF
source <(kubectl completion bash)
EOF

    # 如果Node有多个网卡的话，参考flannel issues 39701，目前需要在kube-flannel.yml中使用--iface参数指定集群主机内网网卡的名称，否则可能会出现dns无法解析。
    iface=$(ifconfig | grep -B1 "inet addr:$APISERVER_IP" | awk '$1!="inet" && $1!="--" {print $1}')
    mkdir -p /data/k8s/flannel
    curl -fsSL https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml -o /data/k8s/flannel/kube-flannel.yml
    grep -q '^\s*- --iface=' /data/k8s/flannel/kube-flannel.yml &&
        sed -i "s|^\(\s*\)- --iface=.*|\1- --iface=$iface|g" /data/k8s/flannel/kube-flannel.yml ||
        sed -i '/^\(\s*\)- --kube-subnet-mgr/a \
        - --iface='$iface /data/k8s/flannel/kube-flannel.yml
    kubectl create -f /data/k8s/flannel/kube-flannel.yml

    # 部署 Ingress controller
    mkdir -p /data/k8s/ingress-nginx
    curl -fsSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/namespace.yaml -o /data/k8s/ingress-nginx/namespace.yaml
    curl -fsSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/default-backend.yaml -o /data/k8s/ingress-nginx/default-backend.yaml
    curl -fsSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/configmap.yaml -o /data/k8s/ingress-nginx/configmap.yaml
    curl -fsSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/tcp-services-configmap.yaml -o /data/k8s/ingress-nginx/tcp-services-configmap.yaml
    curl -fsSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/udp-services-configmap.yaml -o /data/k8s/ingress-nginx/udp-services-configmap.yaml
    curl -fsSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/rbac.yaml -o /data/k8s/ingress-nginx/rbac.yaml
    curl -fsSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/with-rbac.yaml -o /data/k8s/ingress-nginx/with-rbac.yaml
    grep -q '^\s*hostNetwork: ' /data/k8s/ingress-nginx/with-rbac.yaml &&
        sed -i "s|^\(\s*\)hostNetwork:.*|\1hostNetwork: true|g" /data/k8s/ingress-nginx/with-rbac.yaml ||
        sed -i '/^\(\s*\)containers:/i \
      hostNetwork: true' /data/k8s/ingress-nginx/with-rbac.yaml
    for yamlfile in namespace.yaml default-backend.yaml configmap.yaml tcp-services-configmap.yaml udp-services-configmap.yaml rbac.yaml with-rbac.yaml; do
        kubectl create -f /data/k8s/ingress-nginx/$yamlfile
    done

    kubectl cluster-info
    kubectl get cs
    kubectl get pods --all-namespaces
}

k8s_node_up() {
    echo "### set up k8s node..."
    kubeadm join --token $KUBE_TOKEN $APISERVER_IP:6443 --discovery-token-unsafe-skip-ca-verification
}

install_k8s_on_ubuntu() {
    enable_net_forward_and_disable_swap
    set_proxy
    install_docker_on_ubuntu
    install_kube_tools_on_ubuntu
    install_k8s_python_client_on_ubuntu
    case "$SERVER_TYPE" in
        master) k8s_master_up ;;
        node) k8s_node_up ;;
    esac
}

print_usage() {
    echo "Usage: $(basename "$0") [OPTIONS...]"
    echo ""
    echo "Options"
    echo "  [-h|--help]                     Prints a short help text and exists"
    echo "  [-s|--server] <master|node>     Set k8s server type"
    echo "  [-a|--apiserver] <ip>           Set k8s api server ip"
    echo "  [-t|--token] <token>            Set k8s cluster token"
    echo "  [-p|--proxy] <proxy>            Set proxy for server"
    echo "  [-n|--no-proxy] <no_proxy>      Set no proxy for server"
}

# read the options
temp=`getopt -o hs:a:t:p:n: --long help,server:,apiserver:token:proxy:no-proxy: -n $(basename "$0") -- "$@"`
if [ $? != 0 ]; then echo "terminating..." >&2 ; exit 1 ; fi
eval set -- "$temp"

# extract options and their arguments into variables.
while true; do
    case "$1" in
        -h|--help) print_usage ; exit 0 ;;
        -s|--server) SERVER_TYPE=$2 ; shift 2 ;;
        -a|--apiserver) APISERVER_IP=$2 ; shift 2 ;;
        -t|--token) KUBE_TOKEN=$2 ; shift 2 ;;
        -p|--proxy) PROXY=$2 ; shift 2 ;;
        -n|--no-proxy) NO_PROXY=$2 ; shift 2 ;;
        --) shift ; break ;;
        *) echo "internal error!" ; exit 1 ;;
    esac
done

echo "$SERVER_TYPE" | grep -qE "^master$|^node$" || {
    echo "-s|--server: must be master or node"; exit 1
}

if [ "$APISERVER_IP" == "" ]; then
    echo "-a|--apiserver: ip can not empty"; exit 1
fi

if [ "$KUBE_TOKEN" == "" ]; then
    echo "-t|--token: token can not empty"; exit 1
fi

if [ -r /etc/os-release ]; then
    lsb_dist=$(. /etc/os-release && echo "$ID")
    case $lsb_dist in
        ubuntu) install_k8s_on_ubuntu ;;
        centos) install_k8s_on_centos ;;
        *) echo "your system must be ubuntu/centos" ; exit 1 ;;
    esac
else
    echo "'/etc/os-release' file is not available"; exit 1
fi