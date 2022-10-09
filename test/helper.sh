#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

ROOT="$(dirname "${BASH_SOURCE[0]}")/.."

# check whether command is installed.
function cmd_exist() {
    local command="${1}"
    type "${command}" >/dev/null 2>&1
}

# Check dependencies is installed or not and exit if not
function check_dependencies() {
    local dependencies=("${@}")
    local not_installed=()
    for dependency in "${dependencies[@]}"; do
        if ! cmd_exist "${dependency}"; then
            not_installed+=("${dependency}")
        fi
    done

    if [[ "${#not_installed[@]}" -ne 0 ]]; then
        echo "Error: Some dependencies are not installed:"
        for dependency in "${not_installed[@]}"; do
            echo "  - ${dependency}"
        done
        exit 1
    fi
}

# build the image for the test
function build_image() {
    make VERSION=test REGISTRY=localtest images
}

# load the image into the kind cluster
function load_image() {
    local name="${1}"
    local image="${2}"
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
        docker pull "${image}"
    fi
    kind load docker-image "${image}" --name "${name}"
}

# create a kind cluster and load necessary images
function create_cluster() {
    local name="${1:-kind}"
    local version="${2:-v1.23.4}"

    kind create cluster --name "${name}" --image "docker.io/kindest/node:${version}"
    load_image "${name}" localtest/clustersynchro-manager-amd64:test
    load_image "${name}" localtest/apiserver-amd64:test
    load_image "${name}" docker.io/bitnami/postgresql:11.15.0-debian-10-r14
}

# delete the kind cluster
function delete_cluster() {
    local name="${1:-kind}"
    kind delete cluster --name "${name}"
}

# install the Clusterpedia into the kind cluster
function install_clusterpedia() {
    kubectl apply -f "${ROOT}/charts/clusterpedia/crds"
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm dependency build "${ROOT}/charts/clusterpedia"
    helm install clusterpedia "${ROOT}/charts/clusterpedia" \
        --namespace clusterpedia-system \
        --create-namespace \
        --wait \
        --set persistenceMatchNode=None \
        --set clustersynchroManager.image.registry=localtest \
        --set clustersynchroManager.image.repository=clustersynchro-manager-amd64 \
        --set clustersynchroManager.image.tag=test \
        --set apiserver.image.registry=localtest \
        --set apiserver.image.repository=apiserver-amd64 \
        --set apiserver.image.tag=test
    echo kubectl get all -n clusterpedia-system
    kubectl get all -n clusterpedia-system
}

# build pedia_cluster resources
function build_pedia_cluster() {
    local name="${1}"
    local kubeconfig="${2}"
    kubeconfig="$(echo "${kubeconfig}" | base64 | tr -d "\n")"
    cat <<EOF
apiVersion: cluster.clusterpedia.io/v1alpha2
kind: PediaCluster
metadata:
  name: ${name}
spec:
  kubeconfig: "${kubeconfig}"
  syncResources:
  - group: ""
    resources:
     - namespaces
     - pods
EOF
}

HOST_IP=""

# get the host IP for internal communication
function host_docker_internal() {
    if [[ "${HOST_IP}" == "" ]]; then
        # Need Docker 18.03
        HOST_IP=$(docker run --rm docker.io/library/alpine sh -c "nslookup host.docker.internal | grep 'Address' | grep -v '#' | grep -v ':53' | awk '{print \$2}' | head -n 1")

        if [[ "${HOST_IP}" == "" ]]; then
            # For Docker running on Linux used 172.17.0.1 which is the Docker-host in Docker’s default-network.
            HOST_IP="172.17.0.1"
        fi
    fi
    echo "${HOST_IP}"
}

TMPDIR="${TMPDIR:-/tmp/}"

# fake k8s tools
function fake_k8s() {
    if [[ ! -f "${TMPDIR}/fake-k8s.sh" ]]; then
        wget https://github.com/wzshiming/fake-k8s/raw/v0.1.1/fake-k8s.sh -O "${TMPDIR}/fake-k8s.sh"
    fi
    bash "${TMPDIR}/fake-k8s.sh" "${@}"
}

# create a control plane cluster and install the Clusterpedia
function create_control_plane() {
    local name="${1}"
    local version="${2}"
    create_cluster "${name}" "${version}"
    install_clusterpedia
}

# delete the control plane cluster
function delete_control_plane() {
    local name="${1}"
    delete_cluster "${name}"
}

# create a worker fake cluster
function create_data_plane() {
    local name="${1}"
    local version="${2:-v1.19.16}"
    local kubeconfig
    local pedia_cluster
    local ip

    fake_k8s create --name "${name}" --kube-version "${version}" --quiet-pull
    ip="$(host_docker_internal)"
    kubeconfig="$(kubectl --context="fake-k8s-${name}" config view --minify --raw | sed "s#/127.0.0.1:#/${ip}:#" || :)"
    if [[ "${kubeconfig}" == "" ]]; then
        echo "kubeconfig is empty"
        return 1
    fi
    pedia_cluster="$(build_pedia_cluster "${name}" "${kubeconfig}")"
    echo "${pedia_cluster}" | kubectl apply -f -
}

# delete the worker fake cluster
function delete_data_plane() {
    local name="${1}"

    kubectl delete PediaCluster "${name}"
    fake_k8s delete --name "${name}"
}
