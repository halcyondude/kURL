
function goldpinger() {
    local src="$DIR/addons/goldpinger/3.2.0-4.1.1"
    local dst="$DIR/kustomize/goldpinger"


    cp -r "$src/" "$dst/"

    if [ -n "${PROMETHEUS_VERSION}" ]; then
        insert_resources "$dst/kustomization.yaml" servicemonitor.yaml
    fi

    kubectl apply -k "$dst/"

    echo "Waiting for Goldpinger  Daemonset to be ready"
    spinner_until 180 goldpinger_daemonset

}

function goldpinger_daemonset() {
    local desired=$(kubectl get daemonsets -n kurl goldpinger --no-headers | tr -s ' ' | cut -d ' ' -f2)
    local ready=$(kubectl get daemonsets -n kurl goldpinger --no-headers | tr -s ' ' | cut -d ' ' -f4)

    if [ "$desired" = "$ready" ] ; then
        return 0
    fi
    return 1
}
