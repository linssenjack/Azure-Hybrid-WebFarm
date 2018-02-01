### Azure Web-Farm Project

. .\milinwebfarmfunctions.ps1

### 1. Load Variables

# Resource Group Variables
$subscription = ""
$resourceGroup = ""
$location = ""

# Storage Group Variables
$storageAccountName = ""
$storageAccountPassword = "" # Automaticaly generated password on creation of Storage Account
$storageAccountKind = ("Storage","BlobStorage")
$storageAccountSKU = ("Standard_LRS","Standard_RAGS","Standard_ZRS","Premium_LRS","Premium_ZRS")
$storageAccountAccessTier = ("Cool","Hot")
$vhdContainers = ("vhdblobs")
$iisContainers = ("iisshare")
$IISStorageLocation = "" # Location for your Shared IIS Configuration and Public Files

# Network Group Variables
$vnetName = ""
$vnetPrefixes = ("10.240.0.0/16","10.241.0.0/16")
$subnetConfig = (("FrontEnd","/24"),("BackEnd","/24"),("GatewaySubnet","/27")) # Subnets may vary according to your Configuration
$vnetGWName = ""
$vnetGWIPName = ""
$vnetGWSubnetName = ""
$vnetGWCfgName = ""
$vnetGWSku = ("Basic", "VpnGw1", "VpnGw2", "VpnGw3")$vnetGWType = ("Vpn","ExpressRoute")$vnetGWVpnType = ("RouteBased","PolicyBased")$localGWName = ""
$localGWIPAddress = ""
$localPrefixes = ("","")
$vnetGWConnectionName = ""
$vnetGWConnectionType = ("ExpressRoute","IPsec","Vnet2Vnet","VPNClient")
$vnetGWConnectionSharedKey = ""

# Security/Firewall Rules
$nsgName = "milinAzureIISNsg"
$nsgRules = (("rdp-rule","Allow RDP","Tcp","Inbound","100","*","*","*","3389","Allow"), `
            ("http-rule","Allow HTTP","Tcp","Inbound","110","*","*","*","80","Allow"), `
            ("https-rule","Allow HTTPS","Tcp","Inbound","120","*","*","*","443","Allow"), `
            ("smb-rule","Allow SMB","Tcp","Inbound","130","10.0.0.0/8","*","*","445","Allow"), `
            ("wmi-rule","Allow WMI","Tcp","Inbound","140","10.0.0.0/8","*","*","135","Allow"), `
            ("snmp-rule","Allow SNMP","Udp","Inbound","150","10.0.0.0/8","*","*","161","Allow"))

# WebFarm Server Variables
$vmWebFarmARRServerName = "" # Last 2 digits are used as last octet of IP Address
$vmWebFarmServerName = ("","") # Last 2 digits are used as last octet of IP Address
$vmSize = 'Standard_DS1_v2'
$domainName = "milin.cc"
$vmDNSServers = (("IPv4","",""),("IPv6","",""))
$localUserName = ""
$localUserPassword = ""
$domainUserName = ""
$domainUserPassword = ""
$availabilitySetName = ""

### 2. Connect to your account.

Login-AzureRmAccount

# Check subscriptions for the account.

Get-AzureRmSubscription

# Specify the subscription you want to use.

Select-AzureRmSubscription -SubscriptionName $subscription

### 3. Configure WebFarm

Configure-Storage $resourceGroup $location $storageAccountName $storageAccountSKU.Item(0) $vhdContainers $iisContainers
Configure-Network $resourceGroup $location $vnetName $vnetPrefixes $subnetConfig $vnetGWName $vnetGWIPName $vnetGWSubnetName $vnetGWCfgName $vnetGWSku.Item(0) $vnetGWType.Item(0) $vnetGWVpnType.Item(0) $localGWName $localGWIPAddress $localPrefixes $vnetGWConnectionName $vnetGWConnectionType.Item(1) $vnetGWConnectionSharedKey
Configure-NSG $resourceGroup $location $nsgName $nsgRules
Configure-WebFarmServers $resourceGroup, $location, $domainName, $vmWebFarmServerName, $vmWebFarmARRServerName, $nsgName, $vmSize, $localUserName, $localUserPassword, $domainUserName, $domainUserPassword, $availabilitySetName

### Check variables passing on Configure-WebFarmServers