﻿<#
=============================================================================================
Name:         Identify MFA Deployment Sources in Microsoft 365 Using PowerShell
Version:      2.0
website:      o365reports.com

~~~~~~~~~~~~~~~~~~
Script Highlights:
~~~~~~~~~~~~~~~~~~
1. The script identifies and exports MFA enforcement sources for all users.
2. Helps you understand user MFA registration status (registered or not) to plan your MFA rollout campaigns efficiently.
3. It specifically identifies MFA sources for external users as well. 
4. The script checks which Conditional Access policies demand MFA and tells you if users have registered for that MFA method as required by those policies.
5. Automatically install the missing required module Microsoft Graph Beta with your confirmation.
6. The script can be executed with an MFA-enabled account too.  
7. Exports report results as a CSV file. 
8. The script is scheduler-friendly, making it easy to automate.
9. It supports certificate-based authentication (CBA) too. 

Change Log:
~~~~~~~~~~

  V1.0 (Jul 03, 2024) - File created
  V1.1 (Nov 04, 2024) - Scope updation to resolve permission issue
  v2.0 (Jun 27, 2025) - Removed MSOnline PowerShell module to retrieve per-user MFA status and used Graph API.


For detailed Script execution: : https://o365reports.com/2024/06/26/identity-mfa-deployment-source-in-microsoft-365-using-powershell/


============================================================================================
#>
param 
(    
     [string]$TenantId,
     [string]$AppId,
     [string]$CertificateThumbprint
)

$ErrorActionPreference = "Stop"
# Check if Microsoft Graph Beta module is installed
$MsGraphModule =  Get-Module Microsoft.Graph.Beta -ListAvailable
if($MsGraphModule -eq $null)
{ 
    Write-host "Important: Microsoft Graph Beta module is unavailable. It is mandatory to have this module installed in the system to run the script successfully." 
    $confirm = Read-Host Are you sure you want to install Microsoft Graph Beta module? [Y] Yes [N] No  
    if($confirm -match "[yY]") { 
        Write-host "Installing Microsoft Graph Beta module..."
        Install-Module Microsoft.Graph.Beta -Scope CurrentUser -AllowClobber
        Write-host "Microsoft Graph Beta module is installed in the machine successfully" -ForegroundColor Magenta 
    } 
    else { 
        Write-host "Exiting. `nNote: Microsoft Graph Beta module must be available in your system to run the script" -ForegroundColor Red
        Exit 
    } 
}

function Process-ExternalUsers
{
    param(
        [System.Object]$ExternalTenantUser,
        [hashtable]    $UsersinTenant,
        [System.Array] $B2BGuest,
        [System.Array] $B2BMember,
        [System.Array] $LocalGuest,
        [System.Array] $B2BDirectConnect
    )
     $processedUsers = @()
     if ($ExternalTenantUser) 
     {
        $Members = $ExternalTenantUser.ExternalTenants.AdditionalProperties.members
        if ($Members) 
        {
            foreach ($Member in $Members) 
            {
                if ($UsersinTenant.ContainsKey($Member)) 
                {
                    $processedUsers += $ExternalTenantUser.GuestOrExternalUserTypes -split ',' | ForEach-Object {
                        switch -Wildcard ($_) 
                        {
                            'b2bCollaborationGuest' {
                                $B2BGuest | Where-Object { $_ -in $UsersinTenant[$Member] }
                            }
                            'b2bCollaborationMember' {
                                $B2BMember | Where-Object { $_ -in $UsersinTenant[$Member] }
                            }
                            'internalGuest' {
                                $LocalGuest
                            }
                            'b2bDirectConnectUser' {
                                $B2BDirectConnect | Select-Object -Unique | Where-Object { $_.Id -in $UsersinTenant[$Member] }
                            }
                        }
                    }
                }
            }
        } 
        else 
        {
            $processedUsers += $ExternalTenantUser.GuestOrExternalUserTypes -split ',' | ForEach-Object {
                switch -Wildcard ($_) {
                    'b2bCollaborationGuest' {
                        $B2BGuest
                    }
                    'b2bCollaborationMember' {
                        $B2BMember
                    }
                    'internalGuest' {
                        $LocalGuest
                    }
                    'b2bDirectConnectUser' {
                        $B2BDirectConnect | Select-Object -Unique
                    }
                }
            }
        }
    }

    return $processedUsers
}

#Function to get the members of the roles
function Get-UserIdsByRole {
    param (
        [array]$Roles,
        [array]$DirectoryRole
    )

    $UserIds = @()

    foreach ($Role in $Roles) {
        $DirRole = $DirectoryRole | Where-Object { $_.RoleTemplateId -eq $Role }
        if ($DirRole) {
            $RoleMembers = Get-MgBetaDirectoryRoleMember -DirectoryRoleId $DirRole.Id
            if ($RoleMembers) {
                $UserIds += $RoleMembers.Id
            }
        }
    }

    return $UserIds
}

#Disconnect from the Microsoft Graph If already connected
if (Get-MgContext) {
    Write-Host Disconnecting from the previous sesssion.... -ForegroundColor Yellow
    Disconnect-MgGraph | Out-Null
}

Write-Host "`nConnecting to Microsoft Graph..."
if(($TenantId -ne "") -and ($ClientId -ne "") -and ($CertificateThumbprint -ne ""))  
{  
    Connect-MgGraph -TenantId $TenantId -AppId $ClientId -CertificateThumbprint $CertificateThumbprint -ErrorAction SilentlyContinue -ErrorVariable ConnectionError | Out-Null
    if($ConnectionError -ne $null) {    
        Write-Host $ConnectionError -Foregroundcolor Red
        Exit
    }
    Write-Host "Connected to Microsoft Graph PowerShell using $((Get-MgContext).AppName) application."
}
else
{
    Connect-MgGraph -Scopes 'User.Read.All','Policy.Read.all','Team.ReadBasic.All','Directory.Read.All','AuditLog.Read.All' -NoWelcome -ErrorAction SilentlyContinue -Errorvariable ConnectionError | Out-Null
    if($ConnectionError -ne $null) {
        Write-Host "$ConnectionError" -Foregroundcolor Red
        Exit
    }
    Write-Host "Connected to Microsoft Graph PowerShell using account: $((Get-MgContext).Account)"
}

Write-Host "`nRetrieving Entra Users..."
$MgUsers  = Get-MgBetaUser -All | Sort-Object DisplayName
#Check Security Default is enabled or not
$SecurityDefault = (Get-MgBetaPolicyIdentitySecurityDefaultEnforcementPolicy).IsEnabled
$DirectoryRole = Get-MgBetaDirectoryRole -All

#Get the User Rgistration Details
$UserAuthenticationDetail = Get-MgBetaReportAuthenticationMethodUserRegistrationDetail -All | Select-Object UserPrincipalName, MethodsRegistered, IsMFARegistered , Id
$ProcessedUserCount =0

#check for Security default if disabled start to process the Conditional access policies
$PolicySetting = 'True'
$TotalUser = $MgUsers.count
if($SecurityDefault)
{
   $PolicySetting = 'False'
}
else
{
    #Initialize the array
    $IncludeId = @()
    $ExcludeId = @()
    $IncludeUsers = @()
    $ExcludeUsers = @()
    $Registered = @()
    $NotRegistered = @()
    $UsersInPolicy = @{}
    # Get conditional access policies that involve MFA and enabled
    $Policies = Get-MgBetaIdentityConditionalAccessPolicy -All | Where-Object { ($_.GrantControls.BuiltInControls -contains 'mfa' -or $_.GrantControls.AuthenticationStrength.RequirementsSatisfied -contains 'mfa') -and $_.State -contains 'enabled' }
    $Policy = $Policies | Where-Object { $_.displayname -eq 'Authentication' } 
    $ProcessedPolicyCount = 0
    #Get the External users if it was specified in the policy
    if($Policies.Conditions.Users.IncludeGuestsOrExternalUsers -ne $null -or $Policies.Conditions.Users.ExcludeGuestsOrExternalUsers -ne $null)
    {
        $ExternalUsers = $MgUsers | where-object {$_.ExternalUserState -ne $null}
                        $UsersinTenant = @{}
                        foreach($GuestUser in $ExternalUsers)
                        {
                            try
                            {
                                if($GuestUser.othermails -ne $null)
                                {
                                    $Parts = $GuestUser.othermails -split "@"
                                    $DomainName = $Parts[1]
                                    $Url = "https://login.microsoftonline.com/$DomainName/.well-known/openid-configuration"
                                    $Response = Invoke-RestMethod -Uri $Url -Method Get
                                    $Issuer = $Response.issuer
                                    $TenantId = [regex]::Match($Issuer, "[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}").Value
                                    if (-not $UsersinTenant.ContainsKey($TenantId))
                                    {
                                        $UsersinTenant[$TenantId] = @($GuestUser.Id)
                                    } 
                                    else
                                    {
                                        $UsersinTenant[$TenantId] += $GuestUser.Id 
                                    }
                                }
                            }
                            catch
                            {
                                Write-Host "External Domain Name $DomainName is Invalid" -ForegroundColor Red
                                continue;
                            }
                        }
        $B2BGuest    = $ExternalUsers | where-object {$_.UserType -eq 'Guest'}
        $B2BMember   = $ExternalUsers | where-object {$_.UserType -ne 'Member'}
        $LocalGuest  = $MgUsers   | where-object { $_.ExternalUserState -eq $null -and $_.UserType -eq 'Guest'}

        #B2B Direct connect
        $Groups = Get-MgBetaTeam -All
        $B2BDirectConnect = @()
        ForEach($ExternalUser in $ExternalUsers)
        {
            $MemberOfs = Get-MgBetaUserMemberof -UserId $ExternalUser.Id | Where-Object {$_.Id -ne $null}
            ForEach($MemberOf in $MemberOfs)
            {
                if($Groups.Id -contains $MemberOf.Id)
                {
                    $B2BDirectConnect += $ExternalUser.Id 
                }
            }
        }
        
    }

    #Hash table ofthe Required Authentication Strength with respect to the Registered method
    $AllowedCombinations = @{
        "mobilephone"                         = @("sms","Password,sms")
        "alternateMobilePhone"                = @("sms","Password,sms")
        "officePhone"                         = @("sms","Password,sms")
        "microsoftAuthenticatorPush"          = @("microsoftAuthenticatorPush", "Password,microsoftAuthenticatorPush")
        "softwareOneTimePasscode"             = @("Password,SoftwareOath")
        "MicrosoftAuthenticatorPzasswordless" = @("MicrosoftAuthenticator(PhoneSignIn)")
        "windowsHelloForBusiness"             = @("windowsHelloForBusiness")
        "hardwareOneTimePasscode"             = @("password,hardwareOath")
        "passKeyDeviceBound"                  = @("fido2")
        "passKeyDeviceBoundAuthenticator"     = @("fido2")
        "passKeyDeviceBoundWindowsHello"      = @("fido2")
        "fido2SecurityKey"                    = @("fido2")
        "temporaryAccessPass"                 = @("TemporaryAccessPassOneTime", "TemporaryAccessPassMultiuse")
    }

    # Loop through each policy
    foreach ( $Policy in $Policies) 
    {
        $ProcessedPolicyCount++
        Write-Progress -Activity "`n    Processed Policy count: $ProcessedPolicyCount `n" -Status "Currently processing Policy: $($Policy.DisplayName)"
            ### Conditions ###
            $IncludeUsers         = $null
            $ExcludeUsers         = $null
            $Check                = $true
            $CurrentPolicy        = $false
            $IncludedExternalUser = $Policy.Conditions.Users.IncludeGuestsOrExternalUsers
            $ExcludedExternalUser = $Policy.Conditions.Users.ExcludeGuestsOrExternalUsers
            $IncludeUsers         = if($Policy.Conditions.Users.IncludeUsers -ne 'All') 
                                    {
                                        $Policy.Conditions.Users.IncludeUsers
                                    }
                                    elseif($Policy.Conditions.Users.IncludeUsers -eq 'All')
                                    {
                                       $MgUsers.Id 
                                       $Check = $false
                                    }
            if($Check)
            {
                $IncludeUsers   += if($Policy.Conditions.Users.IncludeGroups){ $Policy.Conditions.Users.IncludeGroups | ForEach-Object { if ($Members = Get-MgBetaGroupMember -GroupId $_) { $Members.Id}if($Owner = Get-MgBetaGroupOwner -GroupId $_){$Owner.Id} } }
                $IncludeUsers   += Get-UserIdsByRole -Roles $Policy.Conditions.Users.IncludeRoles -DirectoryRole $DirectoryRole
                $IncludeUsers   += Process-ExternalUsers -ExternalTenantUser $IncludedExternalUser -UsersinTenant $UsersinTenant -B2BGuest $B2BGuest.Id -B2BMember $B2BMember.Id -LocalGuest $LocalGuest.Id -B2BDirectConnect $B2BDirectConnect
            }
            $ExcludeUsers        = if($Policy.Conditions.Users.ExcludeUsers){$Policy.Conditions.Users.ExcludeUsers}
            $ExcludeUsers       += if($Policy.Conditions.Users.ExcludeGroups){$Policy.Conditions.Users.ExcludeGroups | ForEach-Object { if ($Members = Get-MgBetaGroupMember -GroupId $_) { $Members.Id} if($Owner = Get-MgBetaGroupOwner -GroupId $_){$Owner.Id}}}
            $ExcludeUsers       += Get-UserIdsByRole -Roles $Policy.Conditions.Users.ExcludeRoles -DirectoryRole $DirectoryRole
            $ExcludeUsers       += Process-ExternalUsers -ExternalTenantUser $ExcludedExternalUser -UsersinTenant $UsersinTenant -B2BGuest $B2BGuest.Id -B2BMember $B2BMember.Id -LocalGuest $LocalGuest.Id -B2BDirectConnect $B2BDirectConnect
            $ExcludeId          += $ExcludeUsers
            $IncludeId          += $IncludeUsers | Where-Object { $_ -notin $ExcludeUsers }
            $UsersInPolicy[$Policy.DisplayName] += $IncludeUsers | Where-Object { $_ -notin $ExcludeUsers }             
            if ($Policy.GrantControls.AuthenticationStrength.RequirementsSatisfied -contains 'mfa') 
            {
                $NotRegistered  += $IncludeUsers| Where-Object { $_ -notin $ExcludeUsers }
                $CurrentPolicy   = $true 
                $Strength        = $Policy.GrantControls.AuthenticationStrength.AllowedCombinations
                foreach ($IncludeUser in $IncludeUsers) 
                {
                    $UserAuthDetails   = $UserAuthenticationDetail | Where-Object { $_.Id -eq $IncludeUser }
                    $MethodsRegistered = if ($UserAuthDetails.MethodsRegistered -ne $null) { $UserAuthDetails.MethodsRegistered -split ',' } else {'None'}
                    foreach ($Method in $MethodsRegistered) 
                    {
                        if ($AllowedCombinations.ContainsKey($Method)) 
                        {
                            foreach($MFA in $AllowedCombinations[$Method])
                            {
                                if($Strength -contains $MFA)
                                {
                                # Check if the user is included in any other policies with MFA strength                      
                                    $Registered += $IncludeUser -join','                       
                                }
                            }
                         }
                    }
                 }
              }
              $Registered = $Registered | Select-Object -Unique 
              if(!$CurrentPolicy)
              {
                $NotRegistered = $NotRegistered.GUID |  Where-Object { $_ -notin $IncludeUsers.GUID }
              } 
        $IncludedUsers = $IncludeId | Select-Object -Unique
    }
}

$ProcessedUserCount = 0
$FilePath = ".\MFA_Deployment_Sources_Report_$((Get-Date -format 'yyyy-MMM-dd-ddd hh-mm tt').ToString()).csv"

#Now starts the Process of Checking various conditions for the users
foreach ($User in $MgUsers) 
{
    $name  = @()
    $ProcessedUserCount++
    $percent = ($ProcessedUserCount/$TotalUser)*100
    Write-Progress -Activity "`n    Processed user count: $ProcessedUserCount `n" -Status "Currently processing User: $($User.DisplayName)" -PercentComplete $percent
    $UserId = $User.Id
    $Peruser = (Invoke-MgGraphRequest -Method GET -Uri "/beta/users/$UserId/authentication/requirements").perUserMfaState 
    # Get user authentication details
    $UserAuthDetails   = $UserAuthenticationDetail | Where-Object { $_.UserPrincipalName -eq $User.UserPrincipalName }
    $MethodsRegistered = if ($UserAuthDetails.MethodsRegistered -ne "") { $UserAuthDetails.MethodsRegistered -join ',' } else { 'None' }
    $Name   += foreach($Pol in $Policies.DisplayName){if($UsersInPolicy[$pol] -contains $user.Id){$Pol}}
    $PolicyName = $Name -join','
    $MFAEnforce = @{
        'User Display Name'         = $User.DisplayName
        'User Principal Name'       = $User.UserPrincipalName
        'MFA Enforced Via'          =  if($PerUser -eq 'Enforced' -and $PolicySetting -eq 'True' -and $IncludedUsers -contains $User.Id){'Per User MFA , Conditional Access Policy'} 
                                        elseif ( $PerUser -eq 'Enforced' -and $SecurityDefault -eq $true) { 'Per User MFA , Security Default' } 
                                        elseif ($PerUser -eq 'Enforced') { 'Per User MFA' } 
                                        elseif ($SecurityDefault -eq $true) { 'Security Default' } 
                                        elseif ($PolicySetting -eq 'True' -and $IncludedUsers -contains $User.Id){'Conditional Access Policy'}
                                        elseif ($User.AccountEnabled -eq $false) {'SignIn Blocked'}
                                        else {'Disabled'}
        'Is Registered MFA Supported in CA' = if($IncludedUsers -contains $User.Id){if($UserAuthDetails.IsMFARegistered -contains 'True'){if($PolicySetting -eq 'True' -and  $NotRegistered -notcontains $User.Id) {'True'}elseif($Registered -contains $User.Id){'True'}else{'False'}}else{'False'}}else{''}
        'CA MFA Status'              = if($IncludedUsers -contains $User.Id){'Enabled'}else{'Disabled'}
        'Assigned CA Policy'         = if($IncludedUsers -contains $User.Id){$PolicyName}else{''}
        'Per User MFA Status'        =  if ($PerUser) { $PerUser } else { 'Disabled' }
        'Security Default Status'    = if ($SecurityDefault -eq $false){'Disabled'} else{'Enabled'}
        'MFA Registered'             = $UserAuthDetails.IsMFARegistered -contains 'True'
        'Methods Registered'         = if($MethodsRegistered){$MethodsRegistered}else{'None'} 
    }

    $MFAEnforced = New-Object PSObject -Property $MFAEnforce
    try
    {
        $MFAEnforced | Select-Object 'User Display Name','User Principal Name','MFA Registered','Methods Registered','MFA Enforced Via','Per User MFA Status','Security Default Status','CA MFA Status','Assigned CA Policy','Is Registered MFA Supported in CA' | Export-Csv -Path $FilePath -NoTypeInformation -Append
    }
    catch
    {       
        Write-Host "Error occurred While Exporting: $_" -ForegroundColor Red
    }
}

#Disconnect from the Microsoft Graph
Disconnect-MgGraph | Out-Null

#Open output file after execution
if((Test-Path -Path $FilePath) -eq "True")
{
    Write-Host `n~~ Script prepared by AdminDroid Community ~~`n -ForegroundColor Green
    Write-Host "~~ Check out " -NoNewline -ForegroundColor Green; Write-Host "admindroid.com" -ForegroundColor Yellow -NoNewline; Write-Host " to get access to 1800+ Microsoft 365 reports. ~~" -ForegroundColor Green `n
    Write-Host "Exported report has $ProcessedUserCount user(s)" 
    $Prompt = New-Object -ComObject wscript.shell
    $UserInput = $Prompt.popup("Do you want to open output file?",` 0,"Open Output File",4)
    if ($UserInput -eq 6)
    {
        Invoke-Item "$FilePath"
    }
    Write-Host `n"Detailed report available in: " -NoNewline -ForegroundColor Yellow
    Write-Host $FilePath 
}
else
{
    Write-Host "No user(s) found" -ForegroundColor Red
}