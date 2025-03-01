#!/bin/bash

set -euo pipefail

OS=$(uname)

GIT=$(which git)
OC=$(which oc)
KUBECTL=$(which kubectl)
MAKE=$(which make)

if [ "$OS" = 'Darwin' ]; then
  # for MacOS
  SED=$(which gsed)
  DATE=$(which gdate)
  BASE64=$(which gbase64)
else
  # for Linux and Windows
  SED=$(which sed)
  DATE=$(which date)
  BASE64=$(which base64)
fi

ORIGINAL_DIR=$(pwd)

DIR_NAME="$(dirname $0)"

KAS_FLEET_MANAGER_CODE_DIR="${DIR_NAME}/kas-fleet-manager-source"
KAS_FLEET_MANAGER_DEPLOY_ENV_FILE="${DIR_NAME}/kas-fleet-manager-deploy.env"

OBSERVABILITY_OPERATOR_K8S_NAMESPACE="managed-application-services-observability"
OBSERVABILITY_OPERATOR_DEPLOYMENT_NAME="observability-operator-controller-manager"

clone_kasfleetmanager_code_repository() {
  if [ -d "${KAS_FLEET_MANAGER_CODE_DIR}" ]; then
    CONFIGURED_GIT="${KAS_FLEET_MANAGER_GIT_URL}:${KAS_FLEET_MANAGER_GIT_REF}"
    CURRENT_GIT=$(cd "${KAS_FLEET_MANAGER_CODE_DIR}" && echo "$(${GIT} remote get-url origin):$(${GIT} rev-parse HEAD)")

    if [ "${CURRENT_GIT}" != "${CONFIGURED_GIT}" ] ; then
      echo "Refreshing KAS Fleet Manager code directory (current ${CURRENT_GIT} != configured ${CONFIGURED_GIT})"
      # Checkout the configured git ref and pull only if not in detached HEAD state (rc of symbolic-ref == 0)
      (cd ${KAS_FLEET_MANAGER_CODE_DIR} && \
        ${GIT} remote set-url origin ${KAS_FLEET_MANAGER_GIT_URL}
        ${GIT} fetch origin && \
        ${GIT} checkout ${KAS_FLEET_MANAGER_GIT_REF} && \
        ${GIT} symbolic-ref -q HEAD && \
        ${GIT} pull --ff-only || echo "Skipping 'pull' for detached HEAD")
    else
      echo "KAS Fleet Manager code directory is current, not refreshing"
    fi
  else
    echo "KAS Fleet Manager code directory does not exist. Cloning it..."
    ${GIT} clone "${KAS_FLEET_MANAGER_GIT_URL}" ${KAS_FLEET_MANAGER_CODE_DIR}
    (cd ${KAS_FLEET_MANAGER_CODE_DIR} && ${GIT} checkout ${KAS_FLEET_MANAGER_GIT_REF})
  fi

  if [ "${IMAGE_BUILD}" = "true" ] ; then
      (cd ${KAS_FLEET_MANAGER_CODE_DIR} && \
        make image/build/push/internal NAMESPACE=${KAS_FLEET_MANAGER_NAMESPACE} IMAGE_TAG=${IMAGE_TAG})

      IMAGE_REGISTRY='image-registry.openshift-image-registry.svc:5000'
      IMAGE_REPOSITORY=${KAS_FLEET_MANAGER_NAMESPACE}/kas-fleet-manager
  fi
}

create_kasfleetmanager_service_account() {
  KAS_FLEET_MANAGER_DEPLOYMENT_K8S_SERVICEACCOUNT="kas-fleet-manager"

  KAS_FLEET_MANAGER_SA_YAML=$(cat << EOF
---
kind: ServiceAccount
apiVersion: v1
metadata:
  name: ${KAS_FLEET_MANAGER_DEPLOYMENT_K8S_SERVICEACCOUNT}
  labels:
    app: ${KAS_FLEET_MANAGER_DEPLOYMENT_K8S_SERVICEACCOUNT}
EOF
)

  if [ -z "$(${KUBECTL} get sa ${KAS_FLEET_MANAGER_DEPLOYMENT_K8S_SERVICEACCOUNT} --ignore-not-found -o jsonpath=\"{.metadata.name}\" -n ${KAS_FLEET_MANAGER_NAMESPACE})" ]; then
    echo "KAS Fleet Manager service account does not exist. Creating it..."
    echo -n "${KAS_FLEET_MANAGER_SA_YAML}" | ${OC} apply -f - -n ${KAS_FLEET_MANAGER_NAMESPACE}
  fi
}


create_kasfleetmanager_pull_credentials() {
  KAS_FLEET_MANAGER_IMAGE_PULL_SECRET_NAME="kas-fleet-manager-image-pull-secret"
  if [ -z "$(${KUBECTL} get secret ${KAS_FLEET_MANAGER_IMAGE_PULL_SECRET_NAME} --ignore-not-found -o jsonpath=\"{.metadata.name}\" -n ${KAS_FLEET_MANAGER_NAMESPACE})" ]; then
    echo "KAS Fleet Manager image pull secret does not exist. Creating it..."
    ${OC} create secret docker-registry ${KAS_FLEET_MANAGER_IMAGE_PULL_SECRET_NAME} \
      --docker-server=${PULL_SECRET_REGISTRY} \
      --docker-username=${IMAGE_REPOSITORY_USERNAME} \
      --docker-password=${IMAGE_REPOSITORY_PASSWORD}

    KAS_FLEET_MANAGER_DEPLOYMENT_K8S_SERVICEACCOUNT="kas-fleet-manager"
    ${OC} secrets link ${KAS_FLEET_MANAGER_DEPLOYMENT_K8S_SERVICEACCOUNT} ${KAS_FLEET_MANAGER_IMAGE_PULL_SECRET_NAME} --for=pull
  fi
}

deploy_kasfleetmanager() {
  echo "Deploying KAS Fleet Manager Database..."
  ${OC} process -f ${KAS_FLEET_MANAGER_CODE_DIR}/templates/db-template.yml | ${OC} apply -f - -n ${KAS_FLEET_MANAGER_NAMESPACE}
  echo "Waiting until KAS Fleet Manager Database is ready..."
  time timeout --foreground 3m bash -c "until ${OC} get pods -n ${KAS_FLEET_MANAGER_NAMESPACE}| grep kas-fleet-manager-db | grep -v deploy | grep -q Running; do echo 'database is not ready yet'; sleep 10; done"

  create_kasfleetmanager_service_account
  create_kasfleetmanager_pull_credentials

  echo "Deploying KAS Fleet Manager K8s Secrets..."
  SECRET_PARAMS=${DIR_NAME}/kas-fleet-manager-secrets.env
  > ${SECRET_PARAMS}

  if [ "${SSO_PROVIDER_TYPE}" = "redhat_sso" ] ; then
    echo "REDHAT_SSO_CLIENT_ID='${REDHAT_SSO_CLIENT_ID}'" >> ${SECRET_PARAMS}
    echo "REDHAT_SSO_CLIENT_SECRET='${REDHAT_SSO_CLIENT_SECRET}'" >> ${SECRET_PARAMS}
    echo "OSD_IDP_MAS_SSO_CLIENT_ID='${MAS_SSO_CLIENT_ID}'" >> ${SECRET_PARAMS}
    echo "OSD_IDP_MAS_SSO_CLIENT_SECRET='${MAS_SSO_CLIENT_SECRET}'" >> ${SECRET_PARAMS}
  else
    echo "MAS_SSO_CLIENT_ID='${MAS_SSO_CLIENT_ID}'" >> ${SECRET_PARAMS}
    echo "MAS_SSO_CLIENT_SECRET='${MAS_SSO_CLIENT_SECRET}'" >> ${SECRET_PARAMS}
    echo "OSD_IDP_MAS_SSO_CLIENT_ID='${MAS_SSO_CLIENT_ID}'" >> ${SECRET_PARAMS}
    echo "OSD_IDP_MAS_SSO_CLIENT_SECRET='${MAS_SSO_CLIENT_SECRET}'" >> ${SECRET_PARAMS}
  fi

  ${OC} process -f ${KAS_FLEET_MANAGER_CODE_DIR}/templates/secrets-template.yml \
    --param-file=${SECRET_PARAMS} \
    -p OCM_SERVICE_CLIENT_ID="" \
    -p OCM_SERVICE_CLIENT_SECRET="" \
    -p OCM_SERVICE_TOKEN="${OCM_SERVICE_TOKEN}" \
    -p OBSERVABILITY_CONFIG_ACCESS_TOKEN="${OBSERVABILITY_CONFIG_ACCESS_TOKEN}" \
    -p MAS_SSO_CRT="${SSO_TRUSTED_CA}" \
    -p KAFKA_TLS_CERT="${KAFKA_TLS_CERT}" \
    -p KAFKA_TLS_KEY="${KAFKA_TLS_KEY}" \
    -p KUBE_CONFIG="$(${OC} config view --minify --raw | ${BASE64} -w0)" \
    -p IMAGE_PULL_DOCKER_CONFIG=$(${OC} get secret ${KAS_FLEET_MANAGER_IMAGE_PULL_SECRET_NAME} -n ${KAS_FLEET_MANAGER_NAMESPACE} -o jsonpath="{.data.\.dockerconfigjson}") \
    | ${OC} apply -f - -n ${KAS_FLEET_MANAGER_NAMESPACE}

  echo "Deploying KAS Fleet Manager Envoy ConfigMap..."
  ${OC} apply -f ${KAS_FLEET_MANAGER_CODE_DIR}/templates/envoy-config-configmap.yml -n ${KAS_FLEET_MANAGER_NAMESPACE}

  echo "Deploying KAS Fleet Manager..."
  OCM_ENV="development"

  SERVICE_PARAMS=${DIR_NAME}/kas-fleet-manager-params.env
  > ${SERVICE_PARAMS}

  if [ -n "${OCM_SERVICE_TOKEN}" ] ; then
      PROVIDER_TYPE="ocm"
      ENABLE_OCM_MOCK="false"
      CLUSTER_STATUS="cluster_provisioned"
      echo 'AMS_URL="https://api.stage.openshift.com"' >> ${SERVICE_PARAMS}
      echo 'OCM_URL="https://api.stage.openshift.com"' >> ${SERVICE_PARAMS}
  else
      PROVIDER_TYPE="standalone"
      ENABLE_OCM_MOCK="true"
      CLUSTER_STATUS="ready"
  fi

  if [ -n "${KAS_FLEET_MANAGER_SERVICE_TEMPLATE_PARAMS:-}" ] && [ -x "${KAS_FLEET_MANAGER_SERVICE_TEMPLATE_PARAMS}" ] ; then
      echo "Executing ${KAS_FLEET_MANAGER_SERVICE_TEMPLATE_PARAMS} to generate user-supplied service-template.yml parameters"
      ${KAS_FLEET_MANAGER_SERVICE_TEMPLATE_PARAMS} >> ${SERVICE_PARAMS}
  fi

  if [ -z "${OCM_SERVICE_TOKEN}" ] && [ -z "$(grep 'KAS_FLEETSHARD_OPERATOR_SUBSCRIPTION_CONFIG' ${SERVICE_PARAMS})" ]; then
      # kas-fleetshard sync requires `SSO_ENABLED=true`. Set the value if no user-provided sub config is given
      echo 'KAS_FLEETSHARD_OPERATOR_SUBSCRIPTION_CONFIG={ "env":[{"name":"SSO_ENABLED","value":"true"}, {"name":"MANAGEDKAFKA_KAFKA_PARTITION_LIMIT_ENFORCED","value":"true"}] }' >> ${SERVICE_PARAMS}
  fi
  
  echo "REDHAT_SSO_BASE_URL='${REDHAT_SSO_BASE_URL}'" >> ${SERVICE_PARAMS}

  if [ "${SSO_PROVIDER_TYPE}" = "redhat_sso" ] ; then
     
      echo "ENABLE_KAFKA_OWNER='true'" >> ${SERVICE_PARAMS}
      echo 'KAFKA_OWNERS=[ "'${REDHAT_SSO_CLIENT_ID}'" ]' >> ${SERVICE_PARAMS}
  fi

  ${OC} process -f ${KAS_FLEET_MANAGER_CODE_DIR}/templates/service-template.yml \
    --param-file=${SERVICE_PARAMS} \
    -p ENVIRONMENT="${OCM_ENV}" \
    -p IMAGE_REGISTRY=${IMAGE_REGISTRY} \
    -p IMAGE_REPOSITORY=${IMAGE_REPOSITORY} \
    -p IMAGE_TAG=${IMAGE_TAG} \
    -p IMAGE_PULL_POLICY="Always" \
    -p JWKS_VERIFY_INSECURE=true \
    -p JWKS_URL="${JWKS_URL}" \
    -p SSO_PROVIDER_TYPE="${SSO_PROVIDER_TYPE}" \
    -p MAS_SSO_BASE_URL="${MAS_SSO_BASE_URL}" \
    -p MAS_SSO_INSECURE=true \
    -p MAS_SSO_REALM="${MAS_SSO_REALM}" \
    -p OSD_IDP_MAS_SSO_REALM="${OSD_IDP_MAS_SSO_REALM}" \
    -p ENABLE_KAFKA_SRE_IDENTITY_PROVIDER_CONFIGURATION="false" \
    -p SERVICE_PUBLIC_HOST_URL="https://kas-fleet-manager-${KAS_FLEET_MANAGER_NAMESPACE}.apps.${K8S_CLUSTER_DOMAIN}" \
    -p DATAPLANE_CLUSTER_SCALING_TYPE="manual" \
    -p CLUSTER_LIST='
- "name": "'$(${OC} config view --minify --raw -o json | jq -r '.contexts[0].name')'"
  "provider_type": "'${PROVIDER_TYPE}'"
  "cluster_id": "'${DATA_PLANE_CLUSTER_CLUSTER_ID}'"
  "cloud_provider": "aws"
  "region": "'${DATA_PLANE_CLUSTER_REGION}'"
  "multi_az": true
  "schedulable": true
  "kafka_instance_limit": 5
  "supported_instance_type": "standard,developer"
  "status": "'${CLUSTER_STATUS}'"
  "cluster_dns": "'${DATA_PLANE_CLUSTER_DNS_NAME}'"
' \
    -p SUPPORTED_CLOUD_PROVIDERS='
- "name": "aws"
  "default": true
  "regions":
    - "name": "'${DATA_PLANE_CLUSTER_REGION}'"
      "default": true
      "supported_instance_type":
        "standard": {}
        "developer": {}
' \
    -p REPLICAS=1 \
    -p DEX_URL="http://dex-dex.apps.${K8S_CLUSTER_DOMAIN}" \
    -p TOKEN_ISSUER_URL="${SSO_REALM_URL}" \
    -p ENABLE_OCM_MOCK="${ENABLE_OCM_MOCK}" \
    -p OBSERVABILITY_CONFIG_REPO="${OBSERVABILITY_CONFIG_REPO}" \
    -p OBSERVABILITY_CONFIG_TAG="${OBSERVABILITY_CONFIG_TAG}" \
    -p STRIMZI_OLM_INDEX_IMAGE="${STRIMZI_OLM_INDEX_IMAGE}" \
    -p STRIMZI_OLM_PACKAGE_NAME='kas-strimzi-bundle' \
    -p KAS_FLEETSHARD_OLM_INDEX_IMAGE="${KAS_FLEETSHARD_OLM_INDEX_IMAGE}" \
    -p KAS_FLEETSHARD_OLM_PACKAGE_NAME='kas-fleetshard-operator' \
    | ${OC} apply -f - -n ${KAS_FLEET_MANAGER_NAMESPACE}

  echo "Waiting until KAS Fleet Manager Deployment is available..."
  ${KUBECTL} wait --timeout=90s --for=condition=available deployment/kas-fleet-manager --namespace=${KAS_FLEET_MANAGER_NAMESPACE}

  echo "Deploying KAS Fleet Manager OCP Route..."
  ${OC} process -f ${KAS_FLEET_MANAGER_CODE_DIR}/templates/route-template.yml | ${OC} apply -f - -n ${KAS_FLEET_MANAGER_NAMESPACE}
}

read_kasfleetmanager_env_file() {
  if [ ! -e "${KAS_FLEET_MANAGER_DEPLOY_ENV_FILE}" ]; then
    echo "Required KAS Fleet Manager deployment .env file '${KAS_FLEET_MANAGER_DEPLOY_ENV_FILE}' does not exist"
    exit 1
  fi

  . ${KAS_FLEET_MANAGER_DEPLOY_ENV_FILE}
  PULL_SECRET_REGISTRY=${IMAGE_REGISTRY}
}

wait_for_observability_operator_deployment_availability() {
  echo "Waiting until Observability operator deployment is created..."
  while [ -z "$(${KUBECTL} get deployment ${OBSERVABILITY_OPERATOR_DEPLOYMENT_NAME} --ignore-not-found -o jsonpath=\"{.metadata.name}\" -n ${OBSERVABILITY_OPERATOR_K8S_NAMESPACE})" ]; do
    echo "Deployment ${OBSERVABILITY_OPERATOR_DEPLOYMENT_NAME} still not created. Waiting..."
    sleep 10
  done

  echo "Waiting until Observability operator deployment is available..."
  ${KUBECTL} wait --timeout=120s --for=condition=available deployment/${OBSERVABILITY_OPERATOR_DEPLOYMENT_NAME} --namespace=${OBSERVABILITY_OPERATOR_K8S_NAMESPACE}
}

disable_observability_operator_extras() {
  wait_for_observability_operator_deployment_availability
  echo "Waiting until Observability CR is created..."
  OBSERVABILITY_CR_NAME="observability-stack"
  while [ -z "$(${KUBECTL} get Observability ${OBSERVABILITY_CR_NAME} --ignore-not-found -o jsonpath=\"{.metadata.name}\" -n ${OBSERVABILITY_OPERATOR_K8S_NAMESPACE})" ]; do
    echo "Observability CR ${OBSERVABILITY_CR_NAME} still not created. Waiting..."
    sleep 3
  done

  echo "Patching Observability CR to disable Observatorium, PagerDuty and DeadmanSnitch functionality"
  OBSERVABILITY_MERGE_PATCH_CONTENT=$(cat << EOF
{
  "spec": {
    "selfContained": {
      "disablePagerDuty": true,
      "disableObservatorium": true,
      "disableDeadmansSnitch": true,
      "disableSmtp": true
    }
  }
}
EOF
)
  ${KUBECTL} patch Observability observability-stack --type=merge --patch "${OBSERVABILITY_MERGE_PATCH_CONTENT}" -n ${OBSERVABILITY_OPERATOR_K8S_NAMESPACE}
}

create_namespace() {
    INPUT_NAMESPACE="$1"
    if [ -z "$(${OC} get project/${INPUT_NAMESPACE} -o jsonpath="{.metadata.name}" --ignore-not-found)" ]; then
      echo "K8s namespace ${INPUT_NAMESPACE} does not exist. Creating it..."
      ${OC} new-project ${INPUT_NAMESPACE}
    fi
}

delete_namespace() {
    INPUT_NAMESPACE="$1"
    if [ ! -z "$(${OC} get project/${INPUT_NAMESPACE} -o jsonpath="{.metadata.name}" --ignore-not-found)" ]; then
      echo "Deleting K8s namespace ${INPUT_NAMESPACE} ..."
      ${OC} delete project ${INPUT_NAMESPACE}
    fi
}

create_kas_fleet_manager_namespace() {
  KAS_FLEET_MANAGER_NAMESPACE=${KAS_FLEET_MANAGER_NAMESPACE}
    create_namespace ${KAS_FLEET_MANAGER_NAMESPACE}
}

await_kas_fleetshard_agent() {
  MANAGED_KAFKA_AGENT_NAME="managed-agent"
  echo "Waiting until ManagedKafkaAgents/${MANAGED_KAFKA_AGENT_NAME} CR is created..."

  while [ -z "$(${OC} get ManagedKafkaAgents/${MANAGED_KAFKA_AGENT_NAME} --ignore-not-found -o jsonpath=\"{.metadata.name}\" -n ${KAS_FLEETSHARD_OPERATOR_NAMESPACE})" ]; do
    echo "ManagedKafkaAgents/${MANAGED_KAFKA_AGENT_NAME} CR still not created. Waiting..."
    sleep 10
  done

  ${OC} wait ManagedKafkaAgents/${MANAGED_KAFKA_AGENT_NAME} -n ${KAS_FLEETSHARD_OPERATOR_NAMESPACE} --for=condition=Ready --timeout=180s
  echo "ManagedKafkaAgents/${MANAGED_KAFKA_AGENT_NAME} is ready."
}

## Main body of the script starts here

read_kasfleetmanager_env_file
create_kas_fleet_manager_namespace
clone_kasfleetmanager_code_repository
deploy_kasfleetmanager
disable_observability_operator_extras
await_kas_fleetshard_agent

cd ${ORIGINAL_DIR}

exit 0
