#!/bin/bash

export location=$LOCATION
export resourceGroup=$RESOURCEGROUP
export clusterName=$CLUSTERNAME
export arcClusterName="${resourceGroup}-arcCluster"
export workspaceName=$WORKSPACENAME
export groupName=$resourceGroup
export customLocationName=$CUSTOMLOCATIONNAME
export appresourceGroup="${resourceGroup}-AppService"
export webAppName=$WEBAPPNAME
export myPlanName=$MYPLANNAME


az config set extension.use_dynamic_install=yes_without_prompt
az extension add --upgrade --yes --name customlocation
az extension remove --name appservice-kube
az extension add --yes --source "https://aka.ms/appsvc/appservice_kube-latest-py2.py3-none-any.whl"

customLocationId=$(az customlocation show \
    --resource-group $groupName \
    --name $customLocationName \
    --query id \
    --output tsv)

echo "Creating Azure App Resource Group"
if [ $(az group exists --name $appresourceGroup) = false ]; then
    az group create --name $appresourceGroup --location $location
fi
echo "Creating App Plan"
az appservice plan create -g $appresourceGroup -n $myPlanName \
    --custom-location $customLocationId \
    --per-site-scaling --is-linux --sku K1

# az webapp create \
#    --plan $myPlanName \
#    --resource-group $appresourceGroup \
 #   --name $webAppName \
#    --custom-location $customLocationId \
#    --runtime 'DOTNET|5.0'

# az webapp deployment source config-zip --resource-group $appresourceGroup --name $webAppName --src package.zip
