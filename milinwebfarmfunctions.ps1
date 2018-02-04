function Configure-Storage {

    param (
        [string]$resourceGroup,
        [string]$location,
        [string]$storageAccount,
        [string]$storageAccountSKU,
        [array]$vhdcontainers,
        [array]$iiscontainers
    )

    # Create a storage account. Create a standard general-purpose storage account with LRS 
    # replication using New-AzureRmStorageAccount, then retrieve the storage account context 
    # that defines the storage account to be used. When acting on a storage account, you 
    # reference the context instead of repeatedly providing the credentials. 

    If ((Get-AzureRmStorageAccount | Where {$_.StorageAccountName -match $storageAccountName}) -ne $null) {
        Write-Host "Storage Account"$storageAccountName" allready configured!"
    }
    Else {
        Write-Host "Configuring Storage Account" $storageAccountName
        New-AzureRmStorageAccount `
            -ResourceGroupName $resourceGroup `
            -Name $storageAccount `
            -Location $location `
            -SkuName $storageAccountSKU `
            -Kind Storage `
            -EnableEncryptionService Blob 
    }

    $ctx = (Get-AzureRmStorageAccount -ResourceGroupName $resourceGroup).Context

    ForEach ($vhdContainer in $vhdContainers) {
        If ((Get-AzureStorageContainer -Context $ctx -Prefix $vhdContainer) -ne $null) {
            Write-Host "Storage Containter" $vhdContainer "allready exist!"
        }
        Else {
            Write-Host "Creating Storage Container $vhdContainer"
            New-AzureStorageContainer `
            -Name $vhdContainer `
            -Context $ctx `
            -Permission blob
        }
    }

    ForEach ($iisContainer in $iisContainers) {
        If ((Get-AzureStorageShare -Context $ctx -Prefix $iisContainer) -ne $null) {
            Write-Host "Storage Containter $iisContainer allready exist!"
        }
        Else {
        Write-Host "Creating Storage Share $iisContainer"
        New-AzureStorageShare `
            -Name $iisContainer `
            -Context $ctx

        }
    }
}

function Configure-Network {
    param (
        [string]$resourceGroup,
        [string]$location,
        [string]$vnetName,
        [array]$vnetPrefixes,
        [array]$subnetConfig,
        [string]$vnetGWName,
        [string]$vnetGWIPName,
        [string]$vnetGWSubnetName,
        [string]$vnetGWCfgName,
        [string]$vnetGWSku,        [string]$vnetGWType,        [string]$vnetGWVpnType,        [string]$localGWName,
        [string]$localGWIPAddress,
        [array]$localPrefixes,
        [string]$vnetGWConnectionName,
        [string]$vnetGWConnectionType,
        [string]$vnetGWConnectionSharedKey
     )

    ### Create and configure milinAzureNetwork
    ###
    ### https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-vnet-vnet-rm-ps
    ### https://github.com/MicrosoftDocs/azure-docs/blob/master/articles/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell.md
    ### https://www.youtube.com/watch?v=Y3qFiKeNgto
    ###

    # Create Network Adresses and Subnet Configurations for milinAzureNetwork.
    #
    # The gateway subnet is using a /27. While it is possible to create a gateway subnet as small as /29, we recommend that you create a larger subnet that 
    # includes more addresses by selecting at least /28 or /27. This will allow for enough addresses to accommodate possible additional configurations 
    # that you may want in the future.

    # Get Actual Virtual Network and Subnet Configurations
    $VNet = Get-AzureRmVirtualNetwork -Name $vnetName -ResourceGroupName $resourceGroup
    $subnetConfiguration = @()
    ForEach ($element in $subnetConfig) {
        $subnetConfigBuild = New-AzureRmVirtualNetworkSubnetConfig -Name $element[0] -AddressPrefix $element[1]
        $subnetConfiguration += $subnetConfigBuild
    }

    # Check Virtual Network Configurations
    Write-Host "Checking Virtual Network Configuration"
    If ($VNet -ne $null) {
        Write-Host "Virtual Network $vnetName allready created"
    }
    Else {
        Write-Host "Creating Virtual Network $vnetName"
        New-AzureRmVirtualNetwork `
        -Name $vnetName `
        -ResourceGroupName $resourceGroup `
        -Location $location `
        -AddressPrefix $vnetPrefixes `
        -Subnet $subnetConfiguration `
        -Force
    }  

    # Check Prefix Configurations
    Write-Host "Checking Address Prefix Configurations"
    $prefixTest = ($VNet.AddressSpace).AddressPrefixes    
    If ((Compare-Object $prefixTest $vnetPrefixes).InputObject -ne $null){
        Write-Host "Configuring Address Prefixes $vnetPrefixes"
        $VNet.AddressSpace.AddressPrefixes = $vnetPrefixes
        Set-AzureRmVirtualNetwork -VirtualNetwork $VNet
    }
    Else {
        Write-Host "Address Prefixes $prefixTest allready created"
    }

    # Check Subnet Configurations
    Write-Host "Checking Subnet Configurations"
    $subnetCompareCheck = Compare-Object $VNet.Subnets $subnetConfiguration
    If ($subnetCompareCheck -ne $null) {
        Write-Host "Reconfiguring Subnets" $subnetConfig
        ForEach($element in $subnetCompareCheck) {
            If ($element.SideIndicator -like "=>") {
            Write-Host "Adding Sunet" $element.InputObject.Name $element.InputObject.AddressPrefix "to Current Configuration"
            Add-AzureRmVirtualNetworkSubnetConfig -Name $element.InputObject.Name -AddressPrefix $element.InputObject.AddressPrefix -VirtualNetwork $VNet
            }
            Else {
            Write-Host "Removing Sunet" $element.InputObject.Name $element.InputObject.AddressPrefix "from Current Configuration"
            Remove-AzureRmVirtualNetworkSubnetConfig -Name $element.InputObject.Name -VirtualNetwork $VNet
            } 
        }
        Set-AzureRmVirtualNetwork -VirtualNetwork $VNet
    }
    Else {
        Write-Host "Subnets" $subnetConfig "allready created"
    }

    # Request a public IP address and allocate to the gateway you will create for your VNet.
    $gwpip = Get-AzureRmPublicIpAddress -Name $vnetGWIPName -ResourceGroupName $resourceGroup
    If ($gwpip -ne $null) {
        Write-Host "Public IP $vnetGWIPName" $gwpip.IpAddress "for your" $VNet.Name "allready requested"
    }
    Else {
        Write-Host "Requesting New Public IP to be Allocated to the Gateway for your" $VNet.Name
        $gwpip = New-AzureRmPublicIpAddress -Name $vnetGWIPName -ResourceGroupName $resourceGroup -Location $location -AllocationMethod Dynamic
    }

    # Create the gateway configuration. The gateway configuration defines the subnet and the public IP address to use.
    $VNet = Get-AzureRmVirtualNetwork -Name $vnetName -ResourceGroupName $resourceGroup
    $vnetGWSubnetCfg = $Vnet.Subnets | Where-Object {$_.Name -eq $vnetGWSubnetName}

    If ($vnetGWSubnetCfg -ne $null) {
        Write-Host "Subnet for $vnetGWIPName allready configured"
    }
    Else {
        Write-Host "Error: Check prior powershell configuration script!"
    }

    # Create the gateway for milinAzureNetwork. VNet-to-VNet configurations require a RouteBased VpnType. 
    # Creating a gateway can often take 45 minutes or more, depending on the selected gateway SKU.
    $vnetGatewayCheck = (Get-AzureRmVirtualNetworkGateway -ResourceGroupName $resourceGroup) | Where-Object {$_.Name -eq $vnetGWName}
    $vnetGWpipCheck = Get-AzureRmPublicIpAddress | Where-Object {$_.Id -eq ($vnetGatewayCheck.IpConfigurations.PublicIpAddress.Id)}

    If (($vnetGatewayCheck.IpConfigurations.PublicIpAddress.Id) -eq ($vnetGWpipCheck.Id)) {
        Write-Host "Public IP $vnetGWIPName" $gwpip.IpAddress "allready bound to the $vnetGWName Gateway"
    }
    Else {
        Write-Host "Creating New Gateway $vnetGWName"
        Write-Host "This can take up to 45 minutes to complete!"    
        $vnetGWipCfg = New-AzureRmVirtualNetworkGatewayIpConfig -Name $vnetGWCfgName -Subnet $vnetGWSubnetCfg -PublicIpAddress $gwpip
        New-AzureRmVirtualNetworkGateway `
            -Name $vnetGWName `
            -ResourceGroupName $resourceGroup `
            -Location $location `
            -IpConfigurations $vnetGWipCfg `
            -GatewayType $vnetGWType `
            -VpnType $vnetGWVpnType `
            -GatewaySku $vnetGWSku
    }

    # Create the local network gateway. The local network gateway typically refers to your on-premises location. You give the site a name by which Azure can refer 
    # to it, then specify the IP address of the on-premises VPN device to which you will create a connection. You also specify the IP address prefixes that 
    # will be routed through the VPN gateway to the VPN device. The address prefixes you specify are the prefixes located on your on-premises network. If your 
    # on-premises network changes, you can easily update the prefixes.
    $localGW = Get-AzureRMLocalNetworkGateway -Name $localGWName -ResourceGroupName $resourceGroup
    If (($localGW | Where-Object {$_.Name -eq $localGWName}) -ne $null)  {
        Write-Host "Local Gateway $localGWName allready created"
        $prefixTest = $localGW.LocalNetworkAddressSpace.AddressPrefixes
        If ((Compare-Object $prefixTest $localPrefixes).InputObject -ne $null){
            Write-Host "Configuring Address Prefixes $localPrefixes"
            $localGW.LocalNetworkAddressSpace.AddressPrefixes = $localPrefixes
            Set-AzureRMLocalNetworkGateway -LocalNetworkGateway $localGW
        }
        Else {
            Write-Host "Local Address Prefixes $prefixTest allready created"
        }
    }
    Else {
        Write-Host "Creating Local Gateway $localGWName with Gateway IP $localGWIPAddress and Address Prefixes $localPrefixes"
        New-AzureRmLocalNetworkGateway `
            -Name $localGWName `
            -ResourceGroupName $resourceGroup `
            -Location $location `
            -GatewayIpAddress $localGWIPAddress `
            -AddressPrefix $localPrefixes
    }

    # Create the VPN connection. Next, configure the Site-to-Site VPN connection between your virtual network gateway and your VPN device. The shared key 
    # must match the value you used for your VPN device configuration. Notice that the '-ConnectionType' for Site-to-Site is IPsec.
    $vnetGW = Get-AzureRmVirtualNetworkGateway -Name $vnetGWName -ResourceGroupName $resourceGroup
    $localGW = Get-AzureRmLocalNetworkGateway -Name $localGWName -ResourceGroupName $resourceGroup
    $vnetGWConnection = Get-AzureRmVirtualNetworkGatewayConnection -ResourceGroupName $resourceGroup
    $vnetGWCheck = Get-AzureRmVirtualNetworkGateway -ResourceGroupName $resourceGroup -Name $vnetGWName
    $localGWCheck = Get-AzureRmLocalNetworkGateway -ResourceGroupName $resourceGroup -Name $localGWName
    If (($vnetGWConnection | Where-Object {$_.Name -eq $vnetGWConnectionName}) -ne $null) {
        If (($vnetGWCheck.Id -ne $vnetGWConnection.VirtualNetworkGateway1.Id) -and ($localGWCheck.Id -ne $vnetGWConnection.LocalNetworkGateway2.id)) {
        Remove-AzureRmVirtualNetworkGatewayConnection -Name $vnetGWConnectionName -ResourceGroupName $resourceGroup -Force
        New-AzureRmVirtualNetworkGatewayConnection `
        -Name $vnetGWConnectionName `
        -ResourceGroupName $resourceGroup `
        -Location $location `
        -VirtualNetworkGateway1 $vnetGW `
        -LocalNetworkGateway2 $localGW `
        -ConnectionType $vnetGWConnectionType[1] `
        -RoutingWeight 10 `
        -SharedKey $vnetGWConnectionSharedKey
        }
        Else { 
            If ((Get-AzureRmVirtualNetworkGatewayConnectionSharedKey -Name $vnetGWConnectionName -ResourceGroupName $resourceGroup) -ne $vnetGWConnectionSharedKey){
            Write-Host "Reconfiguring Shared Key ***"
            Set-AzureRmVirtualNetworkGatewayConnectionSharedKey -Name $vnetGWConnectionName -ResourceGroupName $resourceGroup -Value $vnetGWConnectionSharedKey -Force
            }
        }
        Write-Host "Virtual Network Connection" $vnetGWConnection.Name "configured with Virtual Network Gateway" $vnetGW.Name "and Local Gateway" $localGW.Name
    }
    Else {
        Write-Host "Creating New Virtual Gateway Connection" $vnetGW.Name "to the Local Network Gateway" $localGW.Name
        New-AzureRmVirtualNetworkGatewayConnection `
            -Name $vnetGWConnectionName `
            -ResourceGroupName $resourceGroup `
            -Location $location `
            -VirtualNetworkGateway1 $vnetGW `
            -LocalNetworkGateway2 $localGW `
            -ConnectionType $vnetGWConnectionType[1] `
            -RoutingWeight 10 `
            -SharedKey $vnetGWConnectionSharedKey
    }
}

function Configure-NSG {

        param (
            [string]$resourceGroup,
            [string]$location,
            [string]$nsgName,
            [array]$nsgRules
        )

    ### Create a network security group and a network security group rule.

    $nsgRulesConfig = @()
    ForEach ($element in $nsgRules){
        $nsgRulesConfig += New-AzureRmNetworkSecurityRuleConfig `
        -Name $element[0] `
        -Description $element[1] `
        -Protocol $element[2] `
        -Direction $element[3] `
        -Priority $element[4] `
        -SourceAddressPrefix $element[5] `
        -SourcePortRange $element[6] `
        -DestinationAddressPrefix $element[7] `
        -DestinationPortRange $element[8] `
        -Access $element[9]
    }

    $nsgCheck = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroup -Name $nsgName
    
    If ($nsgCheck -eq $null) {
        Write-Host "Creating Network Security Group $nsgName"
        $nsgCheck.SecurityRules | Format-Table
        New-AzureRmNetworkSecurityGroup `
            -ResourceGroupName $resourceGroup `
            -Location $location `
            -Name $nsgName `
            -SecurityRules $nsgRulesConfig `
            -Force
    }
    Else {
        Write-Host "Reconfiguring Network Security Group $nsgName"
        Remove-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroup -Name $nsgName -Force
        New-AzureRmNetworkSecurityGroup `
            -ResourceGroupName $resourceGroup `
            -Location $location `
            -Name $nsgName `
            -SecurityRules $nsgRulesConfig `
            -Force
    }
}

function Configure-WebFarmServers {

        param (
            [string]$resourceGroup,
            [string]$location,
            [string]$domainName,
            [string]$vmWebFarmServerName,
            [string]$vmWebFarmARRServerName,
            [string]$nsgName,
            [string]$vmSize,
            [string]$localUserName,
            [string]$localUserPassword,
            [string]$domainUserName,
            [string]$domainUserPassword,
            [string]$availabilitySetName
        )
            
    # Create WebFarm Servers
    $webFarmServerCheck = Get-AzureRMVM -ResourceGroupName $resourceGroup
    
    # Check existence WebFarm Servers
    If (($webFarmServerCheck | Where-Object {$_.Name -like $vmWebFarmARRName}) -eq $null) {
        Write-Host "Configuring IIS ARR Server $vmWebFarmARRName"
        $networkConfig = Configure-VMNetwork -resourceGroup $resourceGroup -location $location -domainName $domainName -hostName $vmWebFarmARRServerName -serverGroup "FrontEnd" -nsgName $nsgName -publicIPRequired $false
        New-VM -resourceGroup $resourceGroup -location $location -domainName $domainName -hostName $vmWebFarmARRServerName -vmSize $vmSize -localUserName $localUserName -localUserPassword $localUserPassword -domainUserName $domainUserName -domainUserPassword $domainUserPassword -availabilitySetName $availabilitySetName -nic $networkConfig
        Set-AzureRMVMExtension `
            -VMName $vmWebFarmARRServerName `
            –ResourceGroupName $resourcegroup `
            -Name "JoinAD" `
            -ExtensionType "JsonADDomainExtension" `
            -Publisher "Microsoft.Compute" `
            -TypeHandlerVersion "1.0" `
            -Location $location `
            -Settings @{ "Name" = $domainName; "OUPath" = ""; "User" = $domainJoinAdminName; "Restart" = "true"; "Options" = 3} `
            -ProtectedSettings @{ "Password" = $domainJoinPassword}
        ### Need Code Completion !!!

    }
    
    ForEach ($element in $vmWebFarmServerName) {
        If (($webFarmServerCheck | Where-Object {$element -like $vmWebFarmServerName}) -ne $true) {
            Write-Host "Configuring WebFarmServer $element"
            Configure-VMNetwork -resourceGroup $resourceGroup -location $location -domainName $domainName -hostName $element -serverGroup "BackEnd" -nsgName $nsgName -publicIPRequired $false
            New-vm -resourceGroup $resourceGroup -location $location -domainName $domainName -hostName $element -vmSize $vmSize -localUserName $localUserName -localUserPassword $localUserPassword -domainUserName $domainUserName -domainUserPassword $domainUserPassword -availabilitySetName $availabilitySetName -nic $networkConfig
            Set-AzureRMVMExtension `
                -VMName $element `
                –ResourceGroupName $resourcegroup `
                -Name "JoinAD" `
                -ExtensionType "JsonADDomainExtension" `
                -Publisher "Microsoft.Compute" `
                -TypeHandlerVersion "1.0" `
                -Location $location `
                -Settings @{ "Name" = $domainName; "OUPath" = ""; "User" = $domainJoinAdminName; "Restart" = "true"; "Options" = 3} `
                -ProtectedSettings @{ "Password" = $domainJoinPassword}
             ### Need Code Completion !!!

        }        
    }

}

function New-VM {

        param (
            [string]$resourceGroup,
            [string]$location,
            [string]$domainName,
            [string]$hostName,
            [string]$vmSize,
            [string]$localUserName,
            [string]$localUserPassword,
            [string]$domainUserName,
            [string]$domainUserPassword,
            [string]$availabilitySetName,
            [object]$nic
        )

#Create virtual machine
$acctKey = ConvertTo-SecureString -String $localUserPassword -AsPlainText -Force
$localCredential = New-Object System.Management.Automation.PSCredential -ArgumentList $localUserName, $acctKey
$acctKey = ConvertTo-SecureString -String $domainUserPassword -AsPlainText -Force
$domainCredential = New-Object System.Management.Automation.PSCredential -ArgumentList $domainUserName, $acctKey

# Create a virtual machine configuration
If ((($availabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $resourceGroup -Name $availabilitySetName) -eq $null 2>$null))  {
    Write-Host "Creating Availability Set $availabilitySetName"
    $availabilitySet = New-AzureRmAvailabilitySet -ResourceGroupName $resourceGroup -Location $location -Name $availabilitySetName -Sku "Aligned" -PlatformUpdateDomainCount 5 -PlatformFaultDomainCount 2 -Managed
}
$vmConfig = New-AzureRmVMConfig `
    -VMName $hostName `
    -AvailabilitySetId $availabilitySet.Id `
    -VMSize $vmSize | `
        Set-AzureRmVMOperatingSystem `
            -Windows `
            -ComputerName $hostName `
            -Credential $localCredential | `
        Set-AzureRmVMSourceImage `
            -PublisherName MicrosoftWindowsServer `
            -Offer WindowsServer `
            -Skus 2016-Datacenter `
            -Version latest | 
        Add-AzureRmVMNetworkInterface -Id $nic.Id 

New-AzureRmVM -ResourceGroupName $resourceGroup -Location $location -VM $vmConfig -LicenseType "Windows_Server"
}

function Configure-VMNetwork {

    param (
        [string]$resourceGroup,
        [string]$location,
        [string]$domainName,
        [string]$hostName,
        [string]$serverGroup,
        [string]$nsgName,
        [bool]$publicIPRequired
    )
    
    ### Create networks and network card for the virtual machine.
    ### https://github.com/MicrosoftDocs/azure-docs/blob/master/articles/virtual-network/virtual-network-multiple-ip-addresses-powershell.md

    $fqdn = $hostName + "." + $domainName
    $nsg = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroup -Name $nsgName 
    $dnsServer = ($vmDNSServers | Where-Object {$_ -like "IPv4"}) -ne "IPv4"        
    $IPRebuildSplit = (((($subnetConfig | Where-Object {$_ -like $serverGroup})[1]).split("/"))[0]).split(".")
    $IPRebuildCount = $IPRebuild.Count
    [string] $privateIPv4Address = $null
    $vmWebFarmServerNumber = $hostName.Substring($hostName.Length -2)               
    # $vmWebFarmServerNumber = $vmWebFarmName.IndexOf(($vmWebFarmName | Where-Object {$_ -like $hostName}))
    $vnet = Get-AzureRmVirtualNetwork -ResourceGroupName $resourceGroup -Name $vnetName
    $subnet = Get-AzureRmVirtualNetworkSubnetConfig -Name $serverGroup -VirtualNetwork $vnet

       
    ForEach ($element in $IPRebuildSplit) {
        $IPRebuildCount -= 1
        If ($IPRebuildCount -ne 0) {
            $privateIPv4Address += $element + "."
        }
        Else {
            $privateIPv4Address += $vmWebFarmServerNumber
        }
    }

    # Create a Public IP Address and Specify a DNS Name
    $publicIPv4 = Get-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Name $fqdn 2>$null
    If (($publicIPv4 -eq $null) -and ($publicIPRequired -eq $true)) {
        $publicIPv4 = New-AzureRmPublicIpAddress `
            -ResourceGroupName $resourceGroup `
            -Location $location `
            -Name $fqdn `
            -DomainNameLabel $hostName `
            -AllocationMethod Static `
            -IdleTimeoutInMinutes 4 
        Write-Host "Requesting Public IPv4 Address" $publicIPv4.Name $publicIPv4.IpAddress 
        }
        Else {
            If (($publicIPv4 -ne $null) -and ($publicIPRequired -eq $true)) {
                Write-Host "Public IPv4 Address allready Requested" $publicIPv4.Name $publicIPv4.IpAddress
            }
        }
    If (($publicIPv4 -ne $null) -and ($publicIPRequired -eq $false)) {
        Write-Host "Removing Public IPv4 Address" $publicIPv4.Name $publicIPv4.IpAddress
        Remove-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Name $fqdn -Force
        $publicIPv4 = $null
    }

    # Create a Interface Configuration and Assign a Private and Public IP Address
    $ipConfig = New-AzureRmNetworkInterfaceIpConfig `
        -Name $fqdn `
        -PrivateIpAddressVersion IPv4 `
        -Subnet $Subnet `
        -PrivateIpAddress $privateIPv4Address `
        -PublicIpAddress $publicIPv4 `
        -Primary

    # Create a Virtual Network Card and Associate with Public IP address and NSG
    $nic = Get-AzureRmNetworkInterface -ResourceGroupName $resourceGroup -Name $fqdn 2>$null
    If ($nic -eq $null) {
        Write-Host "Creating Network Interface $fqdn with Security Group" $nsg.Name "with IP Address" $ipConfig.PrivateIpAddress
        $nic = New-AzureRmNetworkInterface `
            -Name $fqdn `
            -ResourceGroupName $resourceGroup `
            -Location $location `
            -NetworkSecurityGroupId $nsg.Id `
            -DnsServer $dnsServer `
            -IpConfiguration $ipConfig         
    }
}

function Configure-WebServer {

        param (
            [string]$hostName,
            [string]$domainUser,
            [string]$domainPassword,
            [bool]$applicationServer ### Code need Construction 
        )

    $acctKey = ConvertTo-SecureString -String $domainUserPassword -AsPlainText -Force
    $domainCredential = New-Object System.Management.Automation.PSCredential -ArgumentList $domainUserName, $acctKey
    Enter-PSSession $vmName -Credential $domainCredential

    # Install Roles and Features

    $windowsFeatures = `
        ('NET-Framework-Features', 1), `
            ('NET-Framework-Core', 1), `
            ('NET-HTTP-Activation', 0), `
            ('NET-Non-HTTP-Activ', 0), `
        ('NET-Framework-45-Features', 1), `
            ('NET-Framework-45-Core', 1), `
            ('NET-Framework-45-ASPNET', 1), `
            ('NET-WCF-Services45', 1), `
                ('NET-WCF-HTTP-Activation45', 0), `
                ('NET-WCF-MSMQ-Activation45', 0), `
                ('NET-WCF-Pipe-Activation45', 0), `
                ('NET-WCF-TCP-Activation45', 0), `
                ('NET-WCF-TCP-PortSharing45', 1), `
        ('Web-Server',1), `            ('Web-WebServer',1), `
                ('Web-Common-Http',1), `
                    ('Web-Default-Doc',1), `
                    ('Web-Dir-Browsing',1), `
                    ('Web-Http-Errors',1), `
                    ('Web-Static-Content',1), `
                    ('Web-Http-Redirect',1), `
                        ('Web-DAV-Publishing',0), `
                ('Web-Health', 1), `
                    ('Web-Http-Logging', 1), `
                    ('Web-Custom-Logging', 0), `
                    ('Web-Log-Libraries', 0), `
                    ('Web-ODBC-Logging', 0), `
                    ('Web-Request-Monitor', 0), `
                    ('Web-Http-Tracing', 0), `
                ('Web-Performance', 1), `
                    ('Web-Stat-Compression', 1), `
                    ('Web-Dyn-Compression', 0), `
                ('Web-Security', 1), `
                    ('Web-Filtering', 1), `
                    ('Web-Basic-Auth', 1), `
                    ('Web-CertProvider', 1), `
                    ('Web-Client-Auth', 0), `
                    ('Web-Digest-Auth', 1), `
                    ('Web-Cert-Auth', 0), `
                    ('Web-IP-Security', 0), `
                    ('Web-Url-Auth', 0), `
                    ('Web-Windows-Auth', 1), `
                ('Web-App-Dev', 1), `
                    ('Web-Net-Ext', 1), `
                    ('Web-Net-Ext45', 1), `
                    ('Web-AppInit', 0), `
                    ('Web-ASP', 1), `
                    ('Web-Asp-Net', 1), `
                    ('Web-Asp-Net45', 1), `
                    ('Web-CGI', 1), `
                    ('Web-ISAPI-Ext', 1), `
                    ('Web-ISAPI-Filter', 1), `
                    ('Web-Includes', 0), `
                    ('Web-WebSockets', 0), `
                ('Web-Ftp-Server', 0), `
                    ('Web-Ftp-Service', 0), `
                    ('Web-Ftp-Ext', 0), `
                ('Web-Mgmt-Tools', 1), `
                    ('Web-Mgmt-Console', 1), `
                    ('Web-Mgmt-Compat', 0), `
                        ('Web-Metabase', 0), `
                        ('Web-Lgcy-Mgmt-Console', 0), `
                        ('Web-Lgcy-Scripting', 0), `
                        ('Web-WMI', 0), `
                    ('Web-Scripting-Tools', 1), `
                    ('Web-Mgmt-Service', 1)

    # $windowsFeatures = $windowsFeatures | Where{$_[1] -eq 1}
    $windowsFeatureSet = New-Object System.Collections.ArrayList       
    foreach ($feature in $windowsFeatures) {
        if ($feature[1] -eq 1) { 
            $windowsFeatureSet.add($feature[0]) 
            } 
        }
    Install-WindowsFeature -name $windowsFeatureSet

    ### Create User Accounts

    # Create milinazurestorage Local User Account

    $localUser = $storageAccountName
    $localUserPassword = ConvertTo-SecureString `
        -String $storageAccountPassword `
        -AsPlainText `
        -Force
    New-LocalUser $localuser -Password $localUserPassword -PasswordNeverExpires

    # Add User to IUSR group

    Add-LocalGroupMember -Group "IIS_IUSRS" -Member $localUser, "IUSR"

    # Open TCP Port 445
    # https://forum.sysinternals.com/psexec-cannot-execute-check-admin-share_topic21738.html

    New-NetFirewallRule -DisplayName "Allow SMB" -Direction Inbound -Action Allow -LocalPort 445 -Protocol TCP

    ###>>> exit <<<### Need to Check !!!

    Start-Sleep s 120

    ### Add key to vault

    $argumentList = '-accepteula -u $domainUser -p $domainPassword -h \\' + $hostName + ' c:\windows\system32\cmd.exe /c cmdkey /add:' + $IISStorageLocation + ' /user:' + $storageAccountName + ' /pass:' + $storageAccountPassword
    Start-Process `
        -Wait `
        -NoNewWindow `
        -PSPath 'c:\tools\PsExec.Exe' `
        -ArgumentList $argumentList `
        -RedirectStandardError c:\tools\error.log `
        -RedirectStandardOutput c:\tools\output.log

    # Install WebPi and ARR

    If ($applicationServer -ne $true) {
    Write-Host "Installing Application Request Routing 3.0 and URL Rewrite 2.0"
    Enter-PSSession $hostName
    New-Item c:/msi -Type Directory
    Invoke-WebRequest 'http://download.microsoft.com/download/C/F/F/CFF3A0B8-99D4-41A2-AE1A-496C08BEB904/WebPlatformInstaller_amd64_en-US.msi' -OutFile c:/msi/WebPlatformInstaller_amd64_en-US.msi
    Start-Process 'c:/msi/WebPlatformInstaller_amd64_en-US.msi' '/qn' -PassThru | Wait-Process
    cd 'C:/Program Files/Microsoft/Web Platform Installer'; .\WebpiCmd.exe /Install /Products:'UrlRewrite2,ARRv3_0' /AcceptEULA /Log:c:/msi/WebpiCmd.log
    C:\Windows\Microsoft.NET\Framework64\v4.0.30319\caspol -m -ag 1. -url 'file://' + $IISStorageLocation + '/*' FullTrust
    }
}
