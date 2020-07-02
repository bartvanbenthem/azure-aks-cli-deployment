#!/bin/bash
#####################################################################################
# START AKS ENV DEPLOYMENT SCRIPT
#####################################################################################

# Use Azure Priveliged Identity Managment to activate tenant admin role 

# set AKS Cluster name from environment variable
aksname=$AKSNAMEAZD
tenantId=$TENNANTIDAZD

# Set subscription from environment variable
subscription=$SUBSCRIPTIONAZD
az account set --subscription $subscription
az account show

#####################################################################################
# CREATE AZURE AD SERVER COMPONENT
#####################################################################################

# Create the Azure AD application
serverApplicationId=$(az ad app create \
    --display-name "${aksname}Server" \
    --identifier-uris "https://${aksname}Server" \
    --query appId -o tsv)

# Update the application group memebership claims
az ad app update --id $serverApplicationId --set groupMembershipClaims=All

# Create a service principal for the Azure AD application
az ad sp create --id $serverApplicationId

# Get the service principal secret
serverApplicationSecret=$(az ad sp credential reset \
    --name $serverApplicationId \
    --credential-description "AKSPassword" \
    --query password -o tsv)

# Add app permissions
az ad app permission add \
    --id $serverApplicationId \
    --api 00000003-0000-0000-c000-000000000000 \
    --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope 06da0dbc-49e2-44d2-8312-53f166ab848a=Scope 7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role

az ad app permission grant --id $serverApplicationId --api 00000003-0000-0000-c000-000000000000
az ad app permission admin-consent --id  $serverApplicationId
echo "When admin consent failes, contact the tenant administrator to give the admin consent before creating the AD client component"

#####################################################################################
# CREATE AZURE AD CLIENT COMPONENT
#####################################################################################

clientApplicationId=$(az ad app create \
    --display-name "${aksname}Client" \
    --native-app \
    --reply-urls "https://${aksname}Client" \
    --query appId -o tsv)

az ad sp create --id $clientApplicationId

# Get the oAuth2 ID for the server app to allow the authentication flow between the two app components
oAuthPermissionId=$(az ad app show --id $serverApplicationId --query "oauth2Permissions[0].id" -o tsv)

# Add the permissions for the client application and server application components to use the oAuth2 communication flow 
az ad app permission add --id $clientApplicationId --api $serverApplicationId --api-permissions $oAuthPermissionId=Scope
az ad app permission grant --id $clientApplicationId --api $serverApplicationId

#####################################################################################
# DEPLOY THE CLUSTER
#####################################################################################

# declare variables from environment values
vnet=$VNETAZD
subnet=$SUBNETAZD
resourcegroup=$RESOURCEGROUPAZD
location=$LOCATIONAZD
kubeversion=$KUBEVERSIONAZD
admin=$ADMINAZD
dnsprefix=$DNSPREFIXAZD
# get tenant id dynamic
tenantId=$(az account show --query tenantId -o tsv)

# Assign contributor role to SP for vNet
az role assignment create --assignee $serverApplicationId --resource-group $(az network vnet show --ids $vnet --query resourceGroup -o tsv) --role Contributor
az role assignment create --assignee $serverApplicationId --scope $vnet --role Owner

# Create Resource group
az group create --name $resourcegroup --location $location
# Assign contributor role to SP for the new Resource group
az role assignment create --assignee $serverApplicationId --resource-group $resourcegroup --role Owner

# Create the AKS cluster and specify the virtual network and service principal information
# Enable network policy by using the `--network-policy` parameter
echo 'Creating AKS Cluster'

az aks create \
    --kubernetes-version $kubeversion \
    --resource-group $resourcegroup \
    --subscription $subscription \
    --service-principal $serverApplicationId \
    --client-secret $serverApplicationSecret \
    --name $aksname \
    --node-count 1 \
    --generate-ssh-keys \
    --aad-server-app-id $serverApplicationId \
    --aad-server-app-secret $serverApplicationSecret \
    --aad-client-app-id $clientApplicationId \
    --aad-tenant-id $tenantId \
    --admin-username $admin \
    --dns-name-prefix $dnsprefix \
    --node-vm-size Standard_E4s_v3 \
    --max-pods 42 \
    --network-plugin azure \
    --service-cidr 10.0.0.0/16 \
    --dns-service-ip 10.0.0.10 \
    --docker-bridge-address 172.17.0.1/16 \
    --network-policy azure \
    --vnet-subnet-id $subnet \
    --location $location \
    --enable-rbac \
    --enable-addons monitoring

az aks get-credentials --resource-group $resourcegroup --name $aksname --admin

aksNodeResourceGroup=$(az aks show --resource-group $resourcegroup --name $aksname --query nodeResourceGroup -o tsv)
az role assignment create --assignee $serverApplicationId --resource-group $aksNodeResourceGroup --role 'Contributor'

#####################################################################################
# DEPLOY AND CONFIGURE AZURE MONITOR
#####################################################################################

oms=$aksname
az group deployment create --resource-group $resourcegroup --template-uri https://raw.githubusercontent.com/neumanndaniel/armtemplates/master/operationsmanagement/aksMonitoringSolution.json --parameters workspaceName=$oms --verbose
workspace=$(az resource show --resource-group $resourcegroup --name $oms --resource-type 'Microsoft.OperationalInsights/workspaces' --query id)
az aks enable-addons --addons monitoring --resource-group $resourcegroup --name $aksname --workspace-resource-id $workspace --output table

#####################################################################################