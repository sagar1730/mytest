#-----------------------------------------------#
echo "GENPACT DDE AUTOMATION - WINDOWS HARDENING"
#-----------------------------------------------#

## GET AWS SECRETS AND ENCRYPT PASSWORDS
$DNSIP      = (Get-SSMParameterValue -Name /DDE-BootStrap/Windows/NIC/DNS).Parameters[0].Value
$DomainName = (Get-SSMParameterValue -Name /DDE-BootStrap/Windows/Domain/Name).Parameters[0].Value
$DomainAdmin= (Get-SSMParameterValue -Name /DDE-BootStrap/Windows/Domain/Administrator/Username).Parameters[0].Value
$NessusGroup= (Get-SSMParameterValue -Name /DDE-BootStrap/Windows/Applications/Nessus/Group).Parameters[0].Value
$NessusKey  = (Get-SSMParameterValue -Name /DDE-BootStrap/Windows/Applications/Nessus/Key -WithDecryption $True).Parameters[0].Value
$DomainPass = (Get-SSMParameterValue -Name /DDE-BootStrap/Windows/Domain/Administrator/Password -WithDecryption $True).Parameters[0].Value | ConvertTo-SecureString -asPlainText -Force
$AdminPass = (Get-SSMParameterValue -Name /DDE-BootStrap/Windows/Users/Administrator/Password -WithDecryption $True).Parameters[0].Value
$AdminName = (Get-SSMParameterValue -Name /DDE-BootStrap/Windows/Users/Administrator/Username -WithDecryption $True).Parameters[0].Value

md C:\BootStrap                                                       # Step1  : Create Working Directory
chdir -Path C:\BootStrap -PassThru                                    # Step2  : Set Working Directory
$CurrentDomain = (Get-WmiObject Win32_ComputerSystem).Domain           # Step3  : Get Current Domain
if (($CurrentDomain -ne $DomainName))                                  # Step4  : Continue only if not joined to genpactdde domain
{
  ## Step 5 : NIC CONFIG
  get-netadapter | Disable-NetAdapterBinding -ComponentID ms_tcpip6  -PassThru
  get-netadapter | set-dnsclientserveraddress -ServerAddresses $DNSIP  -PassThru

  ## Step 6 : TENABLE INSTALLATION
  $NessusURL = "https://s3.ap-south-1.amazonaws.com/tenable-bucket/NessusAgent-7.0.3-x64.msi"
  $NessusMsi = "C:\BootStrap\NessusAgent-7.0.3-x64.msi"
  Import-Module BitsTransfer
  Start-BitsTransfer -Source $NessusURL -Destination $NessusMsi
  chdir C:\BootStrap\
  msiexec  /i $NessusMsi NESSUS_GROUPS=$NessusGroup NESSUS_SERVER="cloud.tenable.com:443" NESSUS_KEY=$NessusKey /qn
  Start-Sleep -s 10

  ## Step 7 :  WINCOLLECT INSTALLATION
  $WincollectURL = "https://delivery04.dhe.ibm.com/sar/CMA/OSA/06o5n/0/wincollect-7.2.5-27.x64.exe"
  $WincollectExe = "C:\BootStrap\wincollect-7.2.5-27.x64.exe"
  Start-BitsTransfer -source $WincollectURL -Destination $WincollectExe
  $batchFileContent = @"
wincollect-7.2.5-27.x64.exe /s /v"/qn INSTALLDIR=\"C:\Program Files\IBM\WinCollect\" HEARTBEAT_INTERVAL=6000 LOG_SOURCE_AUTO_CREATION_ENABLED=True LOG_SOURCE_AUTO_CREATION_PARAMETERS=""Component1.AgentDevice=DeviceWindowsLog&Component1.Action=create&Component1.LogSourceName=%COMPUTERNAME%&Component1.LogSourceIdentifier=%COMPUTERNAME%&Component1.Dest.Name=10.79.208.11&Component1.Dest.Hostname=10.79.208.11&Component1.Dest.Port=514&Component1.Dest.Protocol=TCP&Component1.Log.Security=true&Component1.Log.System=true&Component1.Log.Application=true&Component1.Log.DNS+Server=true&Component1.Log.File+Replication+Service=true&Component1.Log.Directory+Service=true&Component1.RemoteMachinePollInterval=3000&Component1.EventRateTuningProfile=High+Event+Rate+Server&Component1.MinLogsToProcessPerPass=1250&Component1.MaxLogsToProcessPerPass=1875"""
"@
  $batchFileContent | Out-File -FilePath:"C:\BootStrap\wincollect.cmd" -Encoding ASCII -Force
  chdir C:\BootStrap\
  Start-Sleep -s 2
  & C:\BootStrap\wincollect.cmd
  Start-Sleep -s 10
  iex C:\BootStrap\wincollect.cmd
  Start-Sleep -s 10
  #Remove-Item -LiteralPath:"C:\BootStrap\wincollect.cmd" -Force

  ## Step 8 :  TREND-MICRO INSTALLATION
  chdir C:\Users\Administrator\
  [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
	$env:LogPath = "$env:appdata\Trend Micro\Deep Security Agent\installer"
	New-Item -path $env:LogPath -type directory
	Start-Transcript -path "$env:LogPath\dsa_deploy.log" -append
	echo "$(Get-Date -format T) - DSA download started"
	(New-Object System.Net.WebClient).DownloadFile("https://dsm.genpact.com:443/software/agent/Windows/x86_64/", "$env:temp\agent.msi")
	echo "$(Get-Date -format T) - Downloaded File Size:" (Get-Item "$env:temp\agent.msi").length
	echo "$(Get-Date -format T) - DSA install started"
	echo "$(Get-Date -format T) - Installer Exit Code:" (Start-Process -FilePath msiexec -ArgumentList "/i $env:temp\agent.msi /qn ADDLOCAL=ALL /l*v `"$env:LogPath\dsa_install.log`"" -Wait -PassThru).ExitCode
	echo "$(Get-Date -format T) - DSA activation started"
	& $Env:ProgramFiles"\Trend Micro\Deep Security Agent\dsa_control" -r
  Start-Sleep -s 5
	& $Env:ProgramFiles"\Trend Micro\Deep Security Agent\dsa_control" -a dsm://hb.genpact.com:443/ "policyid:22"
  Start-Sleep -s 2
	Stop-Transcript
	echo "$(Get-Date -format T) - DSA Deployment Finished"

  ## Step 9 : RESET ADMINISTRATOR
  ([ADSI]"WinNT://$env:computername/Administrator,User").psbase.rename($AdminName)
  Start-Sleep -s 5
  ([ADSI] "WinNT://$env:computername/$AdminName").SetPassword($AdminPass)

  ## Step 10 : DOMAIN ASSOCIATION
  $DomainCredential = New-Object System.Management.Automation.PSCredential($DomainAdmin,$DomainPass)
  Add-Computer -DomainName $DomainName -Credential $DomainCredential
  #-----------------------------------------------#
  echo "BOOTSTRAP COMPLETE. REBOOTING INSTANCE."
  #-----------------------------------------------#
  Start-Sleep -s 15

  ## REBOOT INSTANCE
  restart-computer -force
}
