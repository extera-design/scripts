<#
.SYNOPSIS
    Copy files to AWS VM via SSH

.DESCRIPTION
    Copies files to an AWS EC2 instance using SSH/SCP with support for
    automatic shell script executable permissions.

.PARAMETER VmDnsName
    DNS name of the AWS VM where the files will be copied

.PARAMETER SshKey
    Path to SSH private key for AWS VM access

.PARAMETER TargetFolder
    Target folder on VM

.PARAMETER Files
    Files to copy to the VM

.PARAMETER Help
    Show help message

.EXAMPLE
    .\copy-to-aws.ps1 -VmDnsName "ec2-18-116-69-17.us-east-2.compute.amazonaws.com" script1.sh script2.sh

.EXAMPLE
    .\copy-to-aws.ps1 -SshKey "~/.ssh/mykey.pem" -TargetFolder "/home/ec2-user/app" file.txt

.NOTES
    Environment variables:
      VM_DNS_NAME, SSH_KEY_PATH, TARGET_FOLDER
    
    Precedence: command line > environment > defaults
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [Alias('v')]
    [string]$VmDnsName,

    [Parameter(Mandatory=$false)]
    [Alias('k')]
    [string]$SshKey,

    [Parameter(Mandatory=$false)]
    [Alias('t')]
    [string]$TargetFolder,

    [Parameter(Mandatory=$false, ValueFromRemainingArguments=$true)]
    [string[]]$Files,

    [Parameter(Mandatory=$false)]
    [Alias('h')]
    [switch]$Help
)

#region Configuration
$Script:DefaultVmDnsName = "ec2-18-116-69-17.us-east-2.compute.amazonaws.com"
$Script:DefaultSshKeyPath = "~/.ssh/Neumann_v1.0_API.pem"
$Script:DefaultTargetFolder = "/home/ec2-user/deployment"
$Script:VmUser = "ec2-user"
#endregion

#region Logging Functions
function Write-Log {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Blue
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Warning-Custom {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Title {
    param([string]$Message)
    Write-Host ""
    Write-Log "=== $Message ==="
    Write-Host ""
}
#endregion

#region Help Function
function Show-Help {
    Write-Host @"
Usage:
  .\copy-to-aws.ps1 [options] <file1> [file2 ...]

Options:
  -VmDnsName, -v <dns-name>      DNS name of the AWS VM where the files will
                                 be copied (overrides VM_DNS_NAME)
  -SshKey, -k <path>             Path to SSH private key that provides
                                 access to the AWS VM (overrides SSH_KEY_PATH)
  -TargetFolder, -t <path>       Target folder on VM (overrides TARGET_FOLDER)
  -Help, -h                      Show this help and exit

Environment variables:
  VM_DNS_NAME, SSH_KEY_PATH, TARGET_FOLDER

Precedence:
  command line > environment > defaults

Defaults:
  VM_DNS_NAME    = $Script:DefaultVmDnsName
  SSH_KEY_PATH   = $Script:DefaultSshKeyPath
  TARGET_FOLDER  = $Script:DefaultTargetFolder
"@
}
#endregion

#region Main Function
function Main {
    # Show help if requested
    if ($Help) {
        Show-Help
        exit 0
    }

    # Resolve parameters with precedence: CLI > Environment > Default
    $resolvedVmDnsName = if ($VmDnsName) { 
        $VmDnsName 
    } elseif ($env:VM_DNS_NAME) { 
        $env:VM_DNS_NAME 
    } else { 
        $Script:DefaultVmDnsName 
    }

    $resolvedSshKeyPath = if ($SshKey) { 
        $SshKey 
    } elseif ($env:SSH_KEY_PATH) { 
        $env:SSH_KEY_PATH 
    } else { 
        $Script:DefaultSshKeyPath 
    }

    $resolvedTargetFolder = if ($TargetFolder) { 
        $TargetFolder 
    } elseif ($env:TARGET_FOLDER) { 
        $env:TARGET_FOLDER 
    } else { 
        $Script:DefaultTargetFolder 
    }

    # Expand path if it contains ~
    if ($resolvedSshKeyPath -match '^~') {
        $resolvedSshKeyPath = $resolvedSshKeyPath -replace '^~', $env:USERPROFILE
    }

    Write-Title "Starting file copy to AWS VM: $resolvedVmDnsName"

    # Check if at least one file is provided
    if (-not $Files -or $Files.Count -eq 0) {
        Write-Error-Custom "No files provided to copy."
        Write-Host ""
        Show-Help
        exit 1
    }

    # Create target directory on remote server
    $sshCommand = "mkdir -p $resolvedTargetFolder"
    & ssh -i $resolvedSshKeyPath "$Script:VmUser@$resolvedVmDnsName" $sshCommand

    if ($LASTEXITCODE -ne 0) {
        Write-Error-Custom "Failed to create target directory on remote server"
        exit 1
    }

    Write-Log "Copying files to $Script:VmUser@$resolvedVmDnsName`:$resolvedTargetFolder"

    # Copy each file
    foreach ($file in $Files) {
        if (-not (Test-Path $file)) {
            Write-Warning-Custom "File not found: $file (skipping)"
            continue
        }

        # Copy file using cat over SSH for text files
        $remotePath = "$resolvedTargetFolder/$(Split-Path $file -Leaf)"
        Get-Content $file -Raw | & ssh -i $resolvedSshKeyPath "$Script:VmUser@$resolvedVmDnsName" "cat > $remotePath"

        if ($LASTEXITCODE -ne 0) {
            Write-Error-Custom "Failed to copy file: $file"
            continue
        }

        # Check if it's a shell script and make it executable
        if ($file -match '\.(sh|bash)$') {
            & ssh -i $resolvedSshKeyPath "$Script:VmUser@$resolvedVmDnsName" "chmod +x $remotePath"
        }

        Write-Log "Copied file: $file"
    }

    Write-Success "All files copied successfully to $resolvedVmDnsName"
}
#endregion

# Execute main function
Main
