#!/bin/bash

export location=$LOCATION
export resourceGroup=$RESOURCEGROUP
export clusterName=$CLUSTERNAME
export arcClusterName="${clusterName}-arcCluster"
export workspaceName=$WORKSPACENAME
export groupName=$resourceGroup
export customLocationName=$CUSTOMLOCATIONNAME
export extensionName=$EXTENSIONNAME # Name of the App Service extension
export namespace=$NAMESPACE # Namespace in your cluster to install the extension and provision resources
export kubeEnvironmentName=$KUBEENVIRONMENTNAME # Name of the App Service Kubernetes environment resource --needs to be unique for every deployment

# Getting AKS credentials
echo "Getting AKS credentials (kubeconfig)"
az aks get-credentials --name $clusterName --resource-group $resourceGroup --admin --overwrite-existing

az config set extension.use_dynamic_install=yes_without_prompt
# az config set extension.use_dynamic_install=yes_prompt
az extension add --yes --source "https://aka.ms/appsvc/appservice_kube-latest-py2.py3-none-any.whl"

# Installing Azure Arc k8s CLI extensions
echo "Checking if you have up-to-date Azure Arc AZ CLI 'connectedk8s' extension..."
az extension show --name "connectedk8s" &> extension_output
if cat extension_output | grep -q "not installed"; then
az extension add --name "connectedk8s"
rm extension_output
else
az extension update --name "connectedk8s"
rm extension_output
fi
echo ""

echo "Checking if you have up-to-date Azure Arc AZ CLI 'k8s-configuration' extension..."
az extension show --name "k8s-configuration" &> extension_output
if cat extension_output | grep -q "not installed"; then
az extension add --name "k8s-configuration"
rm extension_output
else
az extension update --name "k8s-configuration"
rm extension_output
fi
echo ""

echo "Checking if you have up-to-date Azure Arc AZ CLI 'customlocation' extension..."
az extension show --name "customlocation" &> extension_output
if cat extension_output | grep -q "not installed"; then
az extension add --name "customlocation"
rm extension_output
else
az extension update --name "customlocation"
rm extension_output
fi
echo ""

echo "Creating Azure Arc Resource Group"
if [ $(az group exists --name $resourceGroup) = false ]; then
    az group create --name $resourceGroup --location $location
fi
echo "Connecting the cluster to Azure Arc"
az connectedk8s connect --name $arcClusterName --resource-group $resourceGroup --custom-locations-oid "b7e7a93e-8ac8-40e5-a246-34ebd7ed40c9" --distribution "aks" --infrastructure "azure"

echo "Creating an Public IP"
infra_rg=$(az aks show --resource-group $groupName --name $clusterName --output tsv --query nodeResourceGroup)
az network public-ip create --resource-group $infra_rg --name MyPublicIP --sku STANDARD
staticIp=$(az network public-ip show --resource-group $infra_rg --name MyPublicIP --output tsv --query ipAddress)

logAnalyticsWorkspaceId=$(az monitor log-analytics workspace show \
    --resource-group $groupName \
    --workspace-name $workspaceName \
    --query customerId \
    --output tsv)
logAnalyticsWorkspaceIdEnc=$(printf %s $logAnalyticsWorkspaceId | base64) # Needed for the next step
logAnalyticsKey=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group $groupName \
    --workspace-name $workspaceName \
    --query primarySharedKey \
    --output tsv)
logAnalyticsKeyEncWithSpace=$(printf %s $logAnalyticsKey | base64)
logAnalyticsKeyEnc=$(echo -n "${logAnalyticsKeyEncWithSpace//[[:space:]]/}") # Needed for the next step

# extensionname="appservice-ext" # name of the app service extension
# namespace="appservice-ns" # namespace in your cluster to install the extension and provision resources
# kubeenvironmentname="appservicekubeenvironmentrashmi" # name of the app service kubernetes environment resource
# # staticip=$(az network public-ip show --resource-group $resourceGroupName --name "${clusterName}-IP" --output tsv --query ipAddress)

echo "Creating App service kubernetes extension"
az k8s-extension create \
    --resource-group $groupName \
    --name $extensionName \
    --cluster-type connectedClusters \
    --cluster-name $arcClusterName \
    --extension-type 'Microsoft.Web.Appservice' \
    --release-train stable \
    --auto-upgrade-minor-version true \
    --scope cluster \
    --release-namespace $namespace \
    --configuration-settings "Microsoft.CustomLocation.ServiceAccount=default" \
    --configuration-settings "appsNamespace=${namespace}" \
    --configuration-settings "clusterName=${kubeEnvironmentName}" \
    --configuration-settings "loadBalancerIp=${staticIp}" \
    --configuration-settings "keda.enabled=true" \
    --configuration-settings "buildService.storageClassName=default" \
    --configuration-settings "buildService.storageAccessMode=ReadWriteOnce" \
    --configuration-settings "customConfigMap=${namespace}/kube-environment-config" \
    --configuration-settings "envoy.annotations.service.beta.kubernetes.io/azure-load-balancer-resource-group=${groupName}" \
    --configuration-settings "logProcessor.appLogs.destination=log-analytics" \
    --configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.customerId=${logAnalyticsWorkspaceIdEnc}" \
    --configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.sharedKey=${logAnalyticsKeyEnc}"

extensionId=$(az k8s-extension show --cluster-type connectedClusters --cluster-name $arcClusterName --resource-group $groupName --name $extensionName --query id --output tsv)
echo extensionId: $extensionId

az resource wait --ids ${extensionId} --custom "properties.installState!='Pending'" --api-version "2020-07-01-preview"


echo "Creating custom location"
connectedClusterId=$(az connectedk8s show --resource-group $groupName --name $arcClusterName --query id --output tsv)
az customlocation create \
    --resource-group $groupName \
    --name $customLocationName \
    --host-resource-id ${connectedClusterId} \
    --namespace $namespace \
    --cluster-extension-ids $extensionId

customLocationId=$(az customlocation show \
    --resource-group $groupName \
    --name $customLocationName \
    --query id \
    --output tsv)

echo "App Service Kubernetes environment"
az appservice kube create \
    --resource-group $groupName \
    --name $kubeEnvironmentName \
    --custom-location $customLocationId \
    --static-ip $staticIp
