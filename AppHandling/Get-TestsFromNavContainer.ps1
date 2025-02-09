﻿<# 
 .Synopsis
  Get test information from a NAV/BC Container
 .Description
 .Parameter containerName
  Name of the container from which you want to get test information
 .Parameter tenant
  tenant to use if container is multitenant
 .Parameter credential
  Credentials of the SUPER user if using NavUserPassword authentication
 .Parameter accesstoken
  If your container is running AAD authentication, you need to specify an accesstoken for the user specified in credential
 .Parameter testSuite
  Name of test suite to get. Default is DEFAULT.
 .Parameter testCodeunit
  Name or ID of test codeunit to get. Wildcards (? and *) are supported. Default is *.
 .Parameter testPage
  ID of the test page to use. Default for 15.x containers is 130455. Default for 14.x containers and earlier is 130409.
 .Parameter debugMode
  Include this switch to output debug information if getting the tests fails.
 .Parameter ignoreGroups
  Test Groups are not supported in 15.x - include this switch to ignore test groups in 14.x and earlier and have compatible resultsets from this function
 .Parameter usePublicWebBaseUrl
  Connect to the public Url and not to localhost
 .Example
  Get-TestsFromNavContainer -contatinerName test -credential $credential
 .Example
  Get-TestsFromNavContainer -contatinerName $containername -credential $credential -TestSuite "MYTESTS" -TestCodeunit "134001"
#>
function Get-TestsFromNavContainer {
    Param (
        [string] $containerName = "navserver",
        [Parameter(Mandatory=$false)]
        [string] $tenant = "default",
        [Parameter(Mandatory=$false)]
        [PSCredential] $credential = $null,
        [Parameter(Mandatory=$false)]
        [string] $accessToken = "",
        [Parameter(Mandatory=$false)]
        [string] $testSuite = "DEFAULT",
        [Parameter(Mandatory=$false)]
        [string] $testCodeunit = "*",
        [Parameter(Mandatory=$false)]
        [int] $testPage,
        [switch] $debugMode,
        [switch] $ignoreGroups,
        [switch] $usePublicWebBaseUrl
    )
    
    $navversion = Get-NavContainerNavversion -containerOrImageName $containerName
    $version = [System.Version]($navversion.split('-')[0])

    $PsTestToolFolder = "C:\ProgramData\NavContainerHelper\Extensions\$containerName\PsTestTool-3"
    $PsTestFunctionsPath = Join-Path $PsTestToolFolder "PsTestFunctions.ps1"
    $ClientContextPath = Join-Path $PsTestToolFolder "ClientContext.ps1"
    $fobfile = Join-Path $PsTestToolFolder "PSTestToolPage.fob"
    $serverConfiguration = Get-NavContainerServerConfiguration -ContainerName $containerName
    $clientServicesCredentialType = $serverConfiguration.ClientServicesCredentialType

    if ($serverConfiguration.PublicWebBaseUrl -eq "") {
        throw "Container $containerName needs to include the WebClient in order to get tests (PublicWebBaseUrl is blank)"
    }

    if (!$testPage) {
        if ($version.Major -ge 15) {
            $testPage = 130455
        }
        else {
            $testPage = 130409
        }
    }

    If (!(Test-Path -Path $PsTestToolFolder -PathType Container)) {
        try {
            New-Item -Path $PsTestToolFolder -ItemType Directory | Out-Null
    
            Copy-Item -Path (Join-Path $PSScriptRoot "PsTestFunctions.ps1") -Destination $PsTestFunctionsPath -Force
            Copy-Item -Path (Join-Path $PSScriptRoot "ClientContext.ps1") -Destination $ClientContextPath -Force
        
            if ($version.Major -ge 15) {
                if ($testPage -eq 130409) {
                    Publish-BcContainerApp -containerName $containerName -appFile (Join-Path $PSScriptRoot "Microsoft_PSTestToolPage_15.0.0.0.app") -skipVerification -sync -install
                }
            }
            else {
                if ($version.Major -lt 11) {
                    Copy-Item -Path (Join-Path $PSScriptRoot "PSTestToolPage$($version.Major).fob") -Destination $fobfile -Force
                }
                else {
                    Copy-Item -Path (Join-Path $PSScriptRoot "PSTestToolPage.fob") -Destination $fobfile -Force
                }

                if ($clientServicesCredentialType -eq "Windows") {
                    Import-ObjectsToNavContainer -containerName $containerName -objectsFile $fobfile
                } else {
                    Import-ObjectsToNavContainer -containerName $containerName -objectsFile $fobfile -sqlCredential $credential
                }
            }
        } catch {
            Remove-Item -Path $PsTestToolFolder -Recurse -Force
            throw
        }
    }

    Invoke-ScriptInNavContainer -containerName $containerName { Param([string] $tenant, [pscredential] $credential, [string] $accessToken, [string] $testSuite, [string] $testCodeunit, [string] $PsTestFunctionsPath, [string] $ClientContextPath, $testPage, $version, $debugMode, $ignoreGroups, $usePublicWebBaseUrl)
    
        $newtonSoftDllPath = (Get-Item "C:\Program Files\Microsoft Dynamics NAV\*\Service\NewtonSoft.json.dll").FullName
        $clientDllPath = "C:\Test Assemblies\Microsoft.Dynamics.Framework.UI.Client.dll"
        $customConfigFile = Join-Path (Get-Item "C:\Program Files\Microsoft Dynamics NAV\*\Service").FullName "CustomSettings.config"
        [xml]$customConfig = [System.IO.File]::ReadAllText($customConfigFile)
        $publicWebBaseUrl = $customConfig.SelectSingleNode("//appSettings/add[@key='PublicWebBaseUrl']").Value.TrimEnd('/')
        $clientServicesCredentialType = $customConfig.SelectSingleNode("//appSettings/add[@key='ClientServicesCredentialType']").Value
        
        $uri = [Uri]::new($publicWebBaseUrl)
        if ($usePublicWebBaseUrl) {
            $disableSslVerification = $false
            $serviceUrl = "$publicWebBaseUrl/cs?tenant=$tenant"
        } 
        else {
            $disableSslVerification = ($Uri.Scheme -eq "https")
            $serviceUrl = "$($Uri.Scheme)://localhost:$($Uri.Port)/$($Uri.PathAndQuery)/cs?tenant=$tenant"
        }

        if ($clientServicesCredentialType -eq "Windows") {
            $windowsUserName = whoami
            if (!(Get-NAVServerUser -ServerInstance $ServerInstance -tenant $tenant -ErrorAction Ignore | Where-Object { $_.UserName -eq $windowsusername })) {
                Write-Host "Creating $windowsusername as user"
                New-NavServerUser -ServerInstance $ServerInstance -tenant $tenant -WindowsAccount $windowsusername
                New-NavServerUserPermissionSet -ServerInstance $ServerInstance -tenant $tenant -WindowsAccount $windowsusername -PermissionSetId SUPER
            }
        }
        elseif ($accessToken) {
            $clientServicesCredentialType = "AAD"
            $credential = New-Object pscredential $credential.UserName, (ConvertTo-SecureString -String $accessToken -AsPlainText -Force)
        }

        . $PsTestFunctionsPath -newtonSoftDllPath $newtonSoftDllPath -clientDllPath $clientDllPath -clientContextScriptPath $ClientContextPath

        try {
            if ($disableSslVerification) {
                Disable-SslVerification
            }
            
            $clientContext = New-ClientContext -serviceUrl $serviceUrl -auth $clientServicesCredentialType -credential $credential -debugMode:$debugMode

            Get-Tests -clientContext $clientContext -TestSuite $testSuite -TestCodeunit $testCodeunit -testPage $testPage -ignoreGroups:$ignoreGroups

        }
        catch {
            if ($debugMode) {
                Dump-ClientContext -clientcontext $clientContext 
            }
            throw
        }
        finally {
            if ($disableSslVerification) {
                Enable-SslVerification
            }
            Remove-ClientContext -clientContext $clientContext
        }

    } -argumentList $tenant, $credential, $accessToken, $testSuite, $testCodeunit, $PsTestFunctionsPath, $ClientContextPath, $testPage, $version, $debugMode, $ignoreGroups, $usePublicWebBaseUrl | ConvertFrom-Json
}
Set-Alias -Name Get-TestsFromBCContainer -Value Get-TestsFromNavContainer
Export-ModuleMember -Function Get-TestsFromNavContainer -Alias Get-TestsFromBCContainer
