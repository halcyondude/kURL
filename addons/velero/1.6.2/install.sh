
function velero_pre_init() {
    if [ -z "$VELERO_NAMESPACE" ]; then
        VELERO_NAMESPACE=velero
    fi
    if [ -z "$VELERO_LOCAL_BUCKET" ]; then
        VELERO_LOCAL_BUCKET=velero
    fi
}

function velero() {
    local src="$DIR/addons/velero/$VELERO_VERSION"
    local dst="$DIR/kustomize/velero"

    cp "$src/kustomization.yaml" "$dst/"

    velero_binary

    velero_install "$src" "$dst"

    velero_patch_restic_privilege "$src" "$dst"

    velero_kotsadm_restore_config "$src" "$dst"

    velero_patch_http_proxy "$src" "$dst"

    velero_change_storageclass "$src" "$dst"

    kubectl apply -k "$dst"

    kubectl label -n default --overwrite service/kubernetes velero.io/exclude-from-backup=true
}

function velero_join() {
    velero_binary
}

function velero_install() {
    local src="$1"
    local dst="$2"

    # Pre-apply CRDs since kustomize reorders resources. Grep to strip out sailboat emoji.
    $src/assets/velero-v${VELERO_VERSION}-linux-amd64/velero install --crds-only | grep -v 'Velero is installed'

    local resticArg="--use-restic"
    if [ "$VELERO_DISABLE_RESTIC" = "1" ]; then
        resticArg=""
    fi

    # TODO (dans): find a better place to put this
    determine_velero_pvc_size

    # TODO (dans): detect if we need to use object store or pvc
    local bslArgs="--no-default-backup-location"
    if ! kubernetes_resource_exists "$VELERO_NAMESPACE" backupstoragelocation default; then
        bslArgs="--provider aws --bucket $VELERO_LOCAL_BUCKET --backup-location-config region=us-east-1,s3Url=${OBJECT_STORE_CLUSTER_HOST},publicUrl=http://${OBJECT_STORE_CLUSTER_IP},s3ForcePathStyle=true"
    fi

    velero_credentials

    # TODO (dans): where does this function go?
    velero_migrate_from_object_store

    $src/assets/velero-v${VELERO_VERSION}-linux-amd64/velero install \
        $resticArg \
        $bslArgs \
        --plugins velero/velero-plugin-for-aws:v1.2.0,velero/velero-plugin-for-gcp:v1.2.0,velero/velero-plugin-for-microsoft-azure:v1.2.0,replicated/local-volume-provider:v0.1.0,$KURL_UTIL_IMAGE \
        --secret-file velero-credentials \
        --use-volume-snapshots=false \
        --namespace $VELERO_NAMESPACE \
        --dry-run -o yaml > "$dst/velero.yaml"

    rm velero-credentials
}

function velero_already_applied() {
    local src="$DIR/addons/velero/$VELERO_VERSION"
    local dst="$DIR/kustomize/velero"

    # The kustomize.yaml will be added by one of the methods below.

    # TODO (dans): add kustomize.yaml
    velero_change_storageclass "$src" "$dst" true

    # TODO (dans): there is probably a bug here when we don't change the bsl location during a migration
    # velero_migrate_from_rook_ceph

    # TODO (dans): where does this function go?
    velero_migrate_from_object_store "$src" "$dst"

    # TODO (dans): this probably need to be a kustomize file now
    # This should only be applying the configmap if required
    if [ -f "$dst/kustomization.yaml" ]; then
        kubectl apply -k "$dst"
    fi

    # TODO (dans): wait for migration to finish and verify that the velero backups match? 
    # This would be really hard since you can't force a sync of backup CRs, and in practive I couldn't find a way to tell
    # that is was done with a sync.
}

# The --secret-file flag must always be used so that the generated velero deployment uses the
# cloud-credentials secret. Use the contents of that secret if it exists to avoid overwriting
# any changes. Else if a local object store (Ceph/Minio) is configured, use its credentials.
function velero_credentials() {
   if kubernetes_resource_exists "$VELERO_NAMESPACE" secret cloud-credentials; then
       kubectl -n velero get secret cloud-credentials -ojsonpath='{ .data.cloud }' | base64 -d > velero-credentials
       return 0
    fi

    if [ -n "$OBJECT_STORE_CLUSTER_IP" ]; then
        try_1m object_store_create_bucket "$VELERO_LOCAL_BUCKET"
    fi

    cat >velero-credentials <<EOF
[default]
aws_access_key_id=$OBJECT_STORE_ACCESS_KEY
aws_secret_access_key=$OBJECT_STORE_SECRET_KEY
EOF
}

function velero_patch_restic_privilege() {
    local src="$1"
    local dst="$2"

    if [ "${VELERO_DISABLE_RESTIC}" = "1" ]; then
        return 0
    fi

    if [ "${K8S_DISTRO}" = "rke2" ] || [ "${VELERO_RESTIC_REQUIRES_PRIVILEGED}" = "1" ]; then
        render_yaml_file "$src/restic-daemonset-privileged.yaml" > "$dst/restic-daemonset-privileged.yaml"
        insert_patches_strategic_merge "$dst/kustomization.yaml" restic-daemonset-privileged.yaml
    fi
}

function velero_binary() {
    local src="$DIR/addons/velero/$VELERO_VERSION"

    if ! kubernetes_is_master; then
        return 0
    fi

    if [ ! -f "$src/assets/velero.tar.gz" ] && [ "$AIRGAP" != "1" ]; then
        mkdir -p "$src/assets"
        curl -L "https://github.com/vmware-tanzu/velero/releases/download/v${VELERO_VERSION}/velero-v${VELERO_VERSION}-linux-amd64.tar.gz" > "$src/assets/velero.tar.gz"
    fi

    pushd "$src/assets"
    tar xf "velero.tar.gz"
    if [ "$VELERO_DISABLE_CLI" != "1" ]; then
        cp velero-v${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/velero
    fi
    popd
}

function velero_kotsadm_restore_config() {
    local src="$1"
    local dst="$2"

    render_yaml_file "$src/tmpl-kotsadm-restore-config.yaml" > "$dst/kotsadm-restore-config.yaml"
    insert_resources "$dst/kustomization.yaml" kotsadm-restore-config.yaml
}

function velero_patch_http_proxy() {
    local src="$1"
    local dst="$2"

    if [ -n "$PROXY_ADDRESS" ]; then
        render_yaml_file "$src/tmpl-velero-deployment-proxy.yaml" > "$dst/velero-deployment-proxy.yaml"
        insert_patches_strategic_merge "$dst/kustomization.yaml" velero-deployment-proxy.yaml
    fi

    if [ -n "$PROXY_ADDRESS" ] && [ "$VELERO_DISABLE_RESTIC" != "1" ]; then
        render_yaml_file "$src/tmpl-restic-daemonset-proxy.yaml" > "$dst/restic-daemonset-proxy.yaml"
        insert_patches_strategic_merge "$dst/kustomization.yaml" restic-daemonset-proxy.yaml
    fi
}

# If this cluster is used to restore a snapshot taken on a cluster where Rook or OpenEBS was the 
# default storage provisioner, the storageClassName on PVCs will need to be changed from "default"
# to "longhorn" by velero
# https://velero.io/docs/v1.6/restore-reference/#changing-pvpvc-storage-classes
function velero_change_storageclass() {
    local src="$1"
    local dst="$2"
    local disable_kustomization="$3"

    if kubectl get sc longhorn &> /dev/null && \
    [ "$(kubectl get sc longhorn -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')" = "true" ]; then
        render_yaml_file "$src/tmpl-change-storageclass.yaml" > "$dst/change-storageclass.yaml"
        if [ -z "$disable_kustomization" ]; then
            insert_resources "$dst/kustomization.yaml" change-storageclass.yaml
        fi
    fi
}

function velero_migrate_from_rgw() {
    # TODO (dans): update the backupstorage location to point to minio
    velero-velero_credentials

    rm velero-credentials

}


function velero_migrate_from_object_store() {
    local src="$1"
    local dst="$2"

    if [ -n "$ROOK_VERSION" ] || [ -n "$MINIO_VERSION" ]; then # if there is still an object store, don't migrate
        return
    fi

    # TODO (dans): this doeesn't support minio in a non-standard namespace
    if ! kubernetes_resource_exists rook-ceph deployment rook-ceph-rgw-rook-ceph-store-a || ! kubernetes_resource_exists minio deployment minio; then # if an object store isn't installed don't migrate
        return
    fi

    printf "\n${YELLOW}Installer has detected an object store was removed. Migrating internal snapshot data to a Persistent Volume.${NC}\n"

    if kubernetes_resource_exists rook-ceph deployment rook-ceph-rgw-rook-ceph-store-a; then 
        echo "Previous installation of Rook Ceph detected."
        export INTERNAL_S3_HOST="rook-ceph-rgw-rook-ceph-store.rook-ceph"
        export INTERNAL_S3_ACCESS_KEY_ID=$(kubectl -n rook-ceph get secret rook-ceph-object-user-rook-ceph-store-kurl -o yaml | grep AccessKey | head -1 | awk '{print $2}' | base64 --decode)
        export INTERNAL_S3_ACCESS_KEY_SECRET=$(kubectl -n rook-ceph get secret rook-ceph-object-user-rook-ceph-store-kurl -o yaml | grep SecretKey | head -1 | awk '{print $2}' | base64 --decode)
    else 
        echo "Previous installation of Minio detected."
        export INTERNAL_S3_HOST="minio.minio"
        export INTERNAL_S3_ACCESS_KEY_ID=$(kubectl -n minio get secret minio-credentials -ojsonpath='{ .data.MINIO_ACCESS_KEY }' | base64 --decode)
        export INTERNAL_S3_ACCESS_KEY_SECRET=$(kubectl -n minio get secret minio-credentials -ojsonpath='{ .data.MINIO_SECRET_KEY }' | base64 --decode)
    fi

    # Sets $VELERO_PVC_SIZE
    determine_velero_pvc_size

    # If this is run through `velero_already_applied`, we need to create base kustomization file
    if [ ! -f "$dst/kustomization.yaml" ];then
        cp "$src/kustomization.yaml" "$dst/"
    fi

    # TODO (dans): figure out if there is enough space create a new volume with all the snapshot data

    # Create a storage class that sets the volume reclaim policy to RETAIN
    # This assumes that only longhorn is the only valid provider, and no one has modified the original storage class
    cp "$src/internal-snaps-sc.yaml" "$dst/internal-snaps-sc.yaml"
    insert_resources "$dst/kustomization.yaml" internal-snaps-sc.yaml

    # create the PVC
    render_yaml_file "$src/tmpl-internal-snaps-pvc.yaml" > "$dst/internal-snaps-pvc.yaml"
    insert_resources "$dst/kustomization.yaml" s3-migration-secret.yaml

    # create secret for migration init container to pull from object store
    render_yaml_file "$src/tmpl-s3-migration-secret.yaml" > "$dst/s3-migration-secret.yaml"
    insert_resources "$dst/kustomization.yaml" s3-migration-secret.yaml

    # create configmap that holds the migration script
    render_yaml_file "$src/tmpl-s3-migration-configmap.yaml" > "$dst/s3-migration-configmap.yaml"
    insert_resources "$dst/kustomization.yaml" s3-migration-configmap.yaml

    # TODO (dans): add patch to add init container for migration
    insert_patches_strategic_merge "$dst/kustomization.yaml" "$src/patches/s3-migration-patch.yaml"

    # TODO (dans): add patch to add the pvc in the correct location for the velero deployment

    # TODO (dans): add patch to add the pvc in the correct location for the restice daemonset

    # TODO (dans): Update the BackupstorageLocation

    migrate_rgw_to_minio
    export DID_MIGRATE_ROOK_OBJECT_STORE="1"

}

function registry_pvc_exists() {
    kubectl -n "${VELERO_NAMESPACE}" get pvc velero-internal-snapshots &>/dev/null
}

# if the PVC size has already been set we should not reduce it
function determine_velero_pvc_size() {
    local velero_pvc_size="50Gi"
    if velero_pvc_exists; then
        velero_pvc_size=$( kubectl get pvc -n "${VELERO_NAMESPACE}" velero-internal-snapshots -o jsonpath='{.spec.resources.requests.storage}')
    fi

    export VELERO_PVC_SIZE=$velero_pvc_size
}

# Useful stuff
    # if [ "$will_migrate_pvc" = "1" ]; then
    #     logWarn "Registry will migrate from object store to pvc"
    #     try_1m registry_pvc_migrated
    #     logSuccess "Registry migration complete"
    # fi
