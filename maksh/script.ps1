!/usr/bin/env | curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 |  bash
OR
choco install kubernetes-helm

export MSYS_NO_PATHCONV=1

openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out appgw.crt -keyout appgw.key -subj "/CN=dronedelivery.fabrikam.com/O=Fabrikam Drone Delivery"
openssl pkcs12 -export -out appgw.pfx -in appgw.crt -inkey appgw.key -passout pass:

export APP_GATEWAY_LISTENER_CERTIFICATE=$(cat appgw.pfx | base64 | tr -d '\n')

openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out k8sic.crt -keyout k8sic.key -subj "/CN=*.aks-agic.fabrikam.com/O=Fabrikam Aks Ingress"

export AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64=$(cat k8sic.crt | base64  | tr -d '\n')

az login
az account set --subscription "5dd3998d-b447-44b5-884a-2da7751e365a"
export TENANT_ID=$(az account show --query tenantId --output tsv)

export K8S_RBAC_AAD_PROFILE_TENANTID=$(az account show --query tenantId --output tsv)

export K8S_RBAC_AAD_PROFILE_ADMIN_GROUP_OBJECTID=d6ffaa4e-d30c-4041-8499-4c8ae2c8c9a2

export K8S_RBAC_AAD_PROFILE_TENANT_DOMAIN_NAME=$(az ad signed-in-user show --query 'userPrincipalName' -o tsv | cut -d '@' -f 2 | sed 's/\"//')

export AKS_ADMIN_OBJECTID=d6ffaa4e-d30c-4041-8499-4c8ae2c8c9a2

az group create --name rg-enterprise-networking-hubs-dronedelivery --location uksouth
az group create --name rg-enterprise-networking-spokes-dronedelivery --location uksouth

az deployment group create \
    --resource-group rg-enterprise-networking-hubs-dronedelivery \
    --template-file networking/hub-default.json \
    --parameters location=uksouth

HUB_VNET_ID=$(az deployment group show -g rg-enterprise-networking-hubs-dronedelivery -n hub-default --query properties.outputs.hubVnetId.value -o tsv)

az deployment group create \
    --resource-group rg-enterprise-networking-spokes-dronedelivery \
    --template-file networking/spoke-shipping-dronedelivery.json \
    --parameters location=uksouth hubVnetResourceId="${HUB_VNET_ID}"

NODEPOOL_SUBNET_RESOURCEIDS=$(az deployment group show -g rg-enterprise-networking-spokes-dronedelivery -n spoke-shipping-dronedelivery --query properties.outputs.nodepoolSubnetResourceIds.value -o tsv)

az deployment group create \
    --resource-group rg-enterprise-networking-hubs-dronedelivery \
    --template-file networking/hub-regionA.json \
    --parameters location=uksouth nodepoolSubnetResourceIds="['${NODEPOOL_SUBNET_RESOURCEIDS}']" serviceTagsLocation=UKSouth

az deployment sub create \
    --name cluster-stamp-prereqs \
    --location uksouth \
    --template-file cluster-stamp-prereqs.json \
    --parameters resourceGroupName=rg-shipping-dronedelivery resourceGroupLocation=uksouth

ACR_RESOURCE_GROUP=$(az deployment sub show -n cluster-stamp-prereqs --query properties.outputs.acrResourceGroupName.value -o tsv)

DELIVERY_ID_NAME=$(az deployment group show -g rg-shipping-dronedelivery -n cluster-stamp-prereqs-identities --query properties.outputs.deliveryIdName.value -o tsv) && \
DELIVERY_ID_PRINCIPAL_ID=$(az identity show -g rg-shipping-dronedelivery -n $DELIVERY_ID_NAME --query principalId -o tsv) && \
DRONESCHEDULER_ID_NAME=$(az deployment group show -g rg-shipping-dronedelivery -n cluster-stamp-prereqs-identities --query properties.outputs.droneSchedulerIdName.value -o tsv) && \
DRONESCHEDULER_ID_PRINCIPAL_ID=$(az identity show -g rg-shipping-dronedelivery -n $DRONESCHEDULER_ID_NAME --query principalId -o tsv) && \
WORKFLOW_ID_NAME=$(az deployment group show -g rg-shipping-dronedelivery -n cluster-stamp-prereqs-identities --query properties.outputs.workflowIdName.value -o tsv) && \
WORKFLOW_ID_PRINCIPAL_ID=$(az identity show -g rg-shipping-dronedelivery -n $WORKFLOW_ID_NAME --query principalId -o tsv) && \
INGRESS_CONTROLLER_ID_NAME=$(az deployment group show -g rg-shipping-dronedelivery -n cluster-stamp-prereqs-identities --query properties.outputs.appGatewayControllerIdName.value -o tsv) && \
INGRESS_CONTROLLER_ID_PRINCIPAL_ID=$(az identity show -g rg-shipping-dronedelivery -n $INGRESS_CONTROLLER_ID_NAME --query principalId -o tsv)

until az ad sp show --id ${DELIVERY_ID_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
until az ad sp show --id ${DRONESCHEDULER_ID_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
until az ad sp show --id ${WORKFLOW_ID_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
until az ad sp show --id ${INGRESS_CONTROLLER_ID_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done

TARGET_VNET_RESOURCE_ID=$(az deployment group show -g rg-enterprise-networking-spokes-dronedelivery -n spoke-shipping-dronedelivery --query properties.outputs.clusterVnetResourceId.value -o tsv)

az ad sp create-for-rbac --name "github-workflow-aks-microservices-dronedelivery" --sdk-auth --skip-assignment > sp.json

export APP_ID=$(grep -oP '(?<="clientId": ").*?[^\\](?=",)' sp.json)

until az ad sp show --id ${APP_ID} &> /dev/null ; do echo "Waiting for Azure AD propagation" && sleep 5; done

az role assignment create --assignee $APP_ID --role 'Contributor'
az role assignment create --assignee $APP_ID --role 'User Access Administrator'

cat sp.json
echo $APP_GATEWAY_LISTENER_CERTIFICATE
echo $AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64

mkdir -p .github/workflows

cat github-workflow/aks-deploy.yaml | \
    sed "s#<resource-group-location>#eastus2#g" | \
    sed "s#<resource-group-name>#rg-shipping-dronedelivery#g" | \
    sed "s#<geo-redundancy-location>#centralus#g" | \
    sed "s#<cluster-spoke-vnet-resource-id>#$TARGET_VNET_RESOURCE_ID#g" | \
    sed "s#<tenant-id-with-user-admin-permissions>#$K8S_RBAC_AAD_PROFILE_TENANTID#g" | \
    sed "s#<azure-ad-aks-admin-group-object-id>#$K8S_RBAC_AAD_PROFILE_ADMIN_GROUP_OBJECTID#g" | \
    sed "s#<delivery-id-name>#$DELIVERY_ID_NAME#g" | \
    sed "s#<delivery-principal-id>#$DELIVERY_ID_PRINCIPAL_ID#g" | \
    sed "s#<dronescheduler-id-name>#$DRONESCHEDULER_ID_NAME#g" | \
    sed "s#<dronescheduler-principal-id>#$DRONESCHEDULER_ID_PRINCIPAL_ID#g" | \
    sed "s#<workflow-id-name>#$WORKFLOW_ID_NAME#g" | \
    sed "s#<workflow-principal-id>#$WORKFLOW_ID_PRINCIPAL_ID#g" | \
    sed "s#<ingress-controller-id-name>#$INGRESS_CONTROLLER_ID_NAME#g" | \
    sed "s#<ingress-controller-principalid>#$INGRESS_CONTROLLER_ID_PRINCIPAL_ID #g" | \
    sed "s#<acr-resource-group-name>#$ACR_RESOURCE_GROUP#g" | \
    sed "s#<acr-resource-group-location>#eastus2#g" \
    > .github/workflows/aks-deploy.yaml

    KEYVAULT_NAME=$(az deployment group show --resource-group rg-shipping-dronedelivery -n cluster-stamp --query properties.outputs.keyVaultName.value -o tsv)

    az keyvault set-policy --certificate-permissions import list get --upn $(az account show --query user.name -o tsv) -n $KEYVAULT_NAME

    cat k8sic.crt k8sic.key > k8sic.pem

    az keyvault certificate import -f k8sic.pem -n aks-internal-ingress-controller-tls --vault-name $KEYVAULT_NAME

    az keyvault delete-policy --upn $(az account show --query user.name -o tsv) -n $KEYVAULT_NAME

    export AKS_CLUSTER_NAME=$(az deployment group show --resource-group rg-shipping-dronedelivery -n cluster-stamp --query properties.outputs.aksClusterName.value -o tsv)
    az aks get-credentials -g rg-shipping-dronedelivery -n $AKS_CLUSTER_NAME
    kubectl get constrainttemplate

    kubectl get ns backend-dev -w

    kubectl get resourcequota -n backend-dev

    cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: aks-internal-ingress-controller-tls-secret-csi-akv
  namespace: backend-dev
spec:
  provider: azure
  parameters:
    usePodIdentity: "true"
    keyvaultName: "${KEYVAULT_NAME}"
    objects:  |
      array:
        - |
          objectName: aks-internal-ingress-controller-tls
          objectAlias: tls.crt
          objectType: cert
        - |
          objectName: aks-internal-ingress-controller-tls
          objectAlias: tls.key
          objectType: secret
    tenantId: "${TENANT_ID}"
EOF

INGRESS_CONTROLLER_PRINCIPAL_RESOURCE_ID=$(az deployment group show -g rg-shipping-dronedelivery -n cluster-stamp-prereqs-identities --query properties.outputs.appGatewayControllerPrincipalResourceId.value -o tsv)
INGRESS_CONTROLLER_PRINCIPAL_CLIENT_ID=$(az identity show --ids $INGRESS_CONTROLLER_PRINCIPAL_RESOURCE_ID --query clientId -o tsv)

APPGW_NAME=$(az deployment group show --resource-group rg-shipping-dronedelivery -n cluster-stamp --query properties.outputs.agwName.value -o tsv)

helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
helm repo update

helm install ingress-azure-dev application-gateway-kubernetes-ingress/ingress-azure \
  --namespace kube-system \
  --set appgw.name=$APPGW_NAME \
  --set appgw.resourceGroup=rg-shipping-dronedelivery \
  --set appgw.subscriptionId=$(az account show --query id --output tsv) \
  --set appgw.shared=false \
  --set kubernetes.watchNamespace=backend-dev \
  --set armAuth.type=aadPodIdentity \
  --set armAuth.identityResourceID=$INGRESS_CONTROLLER_PRINCIPAL_RESOURCE_ID \
  --set armAuth.identityClientID=$INGRESS_CONTROLLER_PRINCIPAL_CLIENT_ID \
  --set rbac.enabled=true \
  --set verbosityLevel=3 \
  --set aksClusterConfiguration.apiServerAddress=$(az aks show -n $AKS_CLUSTER_NAME -g rg-shipping-dronedelivery --query fqdn -o tsv) \
  --set appgw.usePrivateIP=false \
  --version 1.3.0

  kubectl wait --namespace kube-system --for=condition=ready pod --selector=release=ingress-azure-dev --timeout=90s

  ACR_NAME=$(az deployment group show --resource-group rg-shipping-dronedelivery -n cluster-stamp --query properties.outputs.acrName.value -o tsv)
  ACR_SERVER=$(az acr show -n $ACR_NAME --query loginServer -o tsv)

  export CLUSTER_SUBNET_PREFIX=$(az deployment group show -g rg-enterprise-networking-spokes-dronedelivery -n spoke-shipping-dronedelivery --query properties.outputs.clusterSubnetPrefix.value -o tsv)
  export GATEWAY_SUBNET_PREFIX=$(az deployment group show -g rg-enterprise-networking-spokes-dronedelivery -n spoke-shipping-dronedelivery --query properties.outputs.gatewaySubnetPrefix.value -o tsv)

  export AI_NAME=$(az deployment group show -g rg-shipping-dronedelivery -n cluster-stamp --query properties.outputs.appInsightsName.value -o tsv)
  export AI_IKEY=$(az resource show -g rg-shipping-dronedelivery -n $AI_NAME --resource-type "Microsoft.Insights/components" --query properties.InstrumentationKey -o tsv)

  az acr update --name $ACR_NAME --public-network-enabled true
  az acr update --name $ACR_NAME --set networkRuleSet.defaultAction="Allow"

  az acr build -r $ACR_NAME -t $ACR_SERVER/delivery:0.1.0 ./src/shipping/delivery/.