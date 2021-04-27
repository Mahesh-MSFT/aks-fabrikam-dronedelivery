curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

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

KEYVAULT_NAME=$(az deployment group show --resource-group rg-shipping-dronedelivery -n cluster-stamp-prereqs-identities --query properties.outputs.keyVaultName.value -o tsv)

#####

az deployment group create \
    --resource-group rg-shipping-dronedelivery \
    --template-file cluster-stamp.json \
    -parameters "@azuredeploy.parameters.prod.json"

