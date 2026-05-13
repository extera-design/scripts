<#
.SYNOPSIS
    Copy files to a remote SSH server with advanced options

.DESCRIPTION
    Copies files to a remote SSH server (intended for AWS VM but works with any SSH server).
    Supports binary files, executable permissions, service restart, and SSH connection reuse.

.PARAMETER DnsName
    DNS name of the remote machine where files will be copied (MANDATORY)

.PARAMETER RemoteUser
    Remote SSH username (default: ec2-user)

.PARAMETER SshKey
    Path to SSH private key for remote access

.PARAMETER TargetFolder
    Target folder on remote machine

.PARAMETER Binary
    Indicate the files being copied are binary (uses SCP instead of cat)

.PARAMETER Executable
    Set executable permissions on copied files (requires -Binary)

.PARAMETER RestartService
    Restart a service on the remote server after copying

.PARAMETER NoConnectionReuse
    Disable SSH connection multiplexing

.PARAMETER Debug
    Enable verbose SSH output

.PARAMETER Files
    Files to copy to the remote server

.PARAMETER Help
    Show help message

.EXAMPLE
    .\remote-copy.ps1 -DnsName "ec2-18-116-69-17.us-east-2.compute.amazonaws.com" script.sh

.EXAMPLE
    .\remote-copy.ps1 -DnsName "server.example.com" -Binary -Executable -RestartService myapp app.exe

.NOTES
    Environment variables:
      REMOTE_DNS_NAME, SSH_KEY_PATH, TARGET_FOLDER, REMOTE_USER
    
    Precedence: command line > environment > defaults
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [Alias('v')]
    [string]$DnsName,

    [Parameter(Mandatory=$false)]
    [Alias('u')]
    [string]$RemoteUser,

    [Parameter(Mandatory=$false)]
    [Alias('k')]
    [string]$SshKey,

    [Parameter(Mandatory=$false)]
    [Alias('t')]
    [string]$TargetFolder,

    [Parameter(Mandatory=$false)]
    [Alias('b')]
    [switch]$Binary,

    [Parameter(Mandatory=$false)]
    [Alias('x')]
    [switch]$Executable,

    [Parameter(Mandatory=$false)]
    [Alias('r')]
    [string]$RestartService,

    [Parameter(Mandatory=$false)]
    [Alias('M')]
    [switch]$NoConnectionReuse,

    [Parameter(Mandatory=$false)]
    [Alias('d')]
    [switch]$Debug,

    [Parameter(Mandatory=$false, ValueFromRemainingArguments=$true)]
    [string[]]$Files,

    [Parameter(Mandatory=$false)]
    [Alias('h')]
    [switch]$Help
)

#region Configuration
$Script:DefaultTargetFolder = "/home/ec2-user/deployment"
$Script:DefaultRemoteUser = "ec2-user"

# SSH connection multiplexing options (not directly supported in Windows OpenSSH, but we'll handle connection reuse differently)
$Script:SshConnectionArgs = @()
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

function Write-Debug-Custom {
    param([string]$Message)
    if ($Debug) {
        Write-Host "[DEBUG] $Message" -ForegroundColor Cyan
    }
}
#endregion

#region Help Function
function Show-Help {
    Write-Host @"
Copies files to a remote SSH server (intended for copying to AWS VM but can be used
for any SSH server). Can also optionally restart a service on the remote server after
copying.

Usage:
  .\remote-copy.ps1 -DnsName <dns-name> [options] <file1> [file2 ...]

Options:
  -DnsName, -v <dns-name>           DNS name of the remote machine where the files will
                                    be copied (overrides REMOTE_DNS_NAME)
  -RemoteUser, -u <username>        Remote SSH username (overrides REMOTE_USER)
  -SshKey, -k <path>                Optional flag to provide the path to the SSH private key
                                    for access to the remote machine (overrides SSH_KEY_PATH)
  -TargetFolder, -t <path>          Target folder on remote machine (overrides TARGET_FOLDER)
  -Binary, -b                       Optional flag to indicate the file(s) being copied
                                    are binary (default: false)
  -Executable, -x                   Optional flag to set executable permissions on the
                                    copied file(s). Requires the file(s) to be binary
                                    file. It will be ignored if -Binary is not set.
                                    (default: false)
  -RestartService, -r <service>     Optional flag to restart a service on the remote
                                    server after copying
  -NoConnectionReuse, -M            Disable SSH connection multiplexing. By default, the
                                    script reuses a single authenticated connection for
                                    all ssh/scp calls to minimize password prompts.
                                    Use this flag to create separate connections
                                    (default: false)
  -Debug, -d                        Enable verbose output for ssh/scp commands to help
                                    diagnose authentication and key issues
                                    (default: false)
  -Help, -h                         Show this help and exit

Mandatory arguments:
  The following options must be provided either via command line or environment
  variables:
    -DnsName, -v <dns-name>         DNS name of the remote machine (can also be set via
                                    the REMOTE_DNS_NAME env variable)

  At least one file to copy must be provided as a positional argument.

Environment variables:
  REMOTE_DNS_NAME, SSH_KEY_PATH, TARGET_FOLDER, REMOTE_USER

Connection reuse:
  - On Windows, SSH connection multiplexing is limited. The script will batch
    operations where possible to minimize authentication prompts.

Precedence:
  command line > environment > defaults

Defaults:
  TARGET_FOLDER  = $Script:DefaultTargetFolder
  REMOTE_USER    = $Script:DefaultRemoteUser

Note:
  - The script assumes the remote server is Linux-based and has 'cat' and 'chmod'
  commands available.
  - When copying text files, the script uses 'cat' over SSH to create the file on the
  remote server, which can be more efficient for small to medium files and avoids
  issues with scp and text file line endings.
  - For binary files, the script uses 'scp' to copy the file directly.
  - If the -Executable flag is set for binary files, the script will set executable
  permissions on the remote file after copying.
  - If the -Binary flag is not set, the script will identify shell scripts and set
  executable permissions on the remote file after copying.
"@
}
#endregion

#region SSH Helper Functions
function Get-SshArgs {
    param(
        [string]$SshKeyPath,
        [bool]$DebugMode = $false
    )
    
    $args = @()
    
    if ($SshKeyPath) {
        $args += @('-i', $SshKeyPath)
    }
    
    if ($DebugMode) {
        $args += '-v'
    }
    
    return $args
}

function Invoke-SshCommand {
    param(
        [string]$User,
        [string]$RemoteHost,
        [string]$Command,
        [string[]]$SshArgs
    )
    
    Write-Debug-Custom "SSH Command: ssh $($SshArgs -join ' ') $User@$RemoteHost `"$Command`""
    & ssh @SshArgs "$User@$RemoteHost" $Command
    return $LASTEXITCODE
}
#endregion

#region Copy Functions
function Copy-TextFiles {
    param(
        [string]$RemoteUser,
        [string]$RemoteDns,
        [string]$TargetFolder,
        [string[]]$FilesToCopy,
        [string[]]$SshArgs
    )
    
    Write-Log "Copying files to $RemoteUser@$RemoteDns`:$TargetFolder"
    
    foreach ($file in $FilesToCopy) {
        if (-not (Test-Path $file)) {
            Write-Warning-Custom "File not found: $file (skipping)"
            continue
        }
        
        $fileName = Split-Path $file -Leaf
        $remotePath = "$TargetFolder/$fileName"
        
        # Copy file using cat over SSH
        Get-Content $file -Raw | & ssh @SshArgs "$RemoteUser@$RemoteDns" "cat > $remotePath"
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error-Custom "Failed to copy file: $file"
            continue
        }
        
        # Check if it's a shell script and make it executable
        if ($file -match '\.(sh|bash)$') {
            $exitCode = Invoke-SshCommand -User $RemoteUser -RemoteHost $RemoteDns -Command "chmod +x $remotePath" -SshArgs $SshArgs
            if ($exitCode -ne 0) {
                Write-Warning-Custom "Failed to set executable permissions on: $file"
            }
        }
        
        Write-Log "Copied file: $file"
    }
    
    Write-Success "All files copied successfully to $RemoteDns"
}

function Copy-BinaryFiles {
    param(
        [string]$RemoteUser,
        [string]$RemoteDns,
        [string]$TargetFolder,
        [string[]]$FilesToCopy,
        [string[]]$SshArgs,
        [bool]$MakeExecutable = $false
    )
    
    Write-Log "Copying binary files to $RemoteUser@$RemoteDns`:$TargetFolder"
    
    foreach ($file in $FilesToCopy) {
        if (-not (Test-Path $file)) {
            Write-Warning-Custom "File not found: $file (skipping)"
            continue
        }
        
        $fileName = Split-Path $file -Leaf
        
        # Copy file using SCP
        Write-Debug-Custom "SCP Command: scp $($SshArgs -join ' ') $file $RemoteUser@$RemoteDns`:$TargetFolder/"
        & scp @SshArgs $file "$RemoteUser@$RemoteDns`:$TargetFolder/"
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error-Custom "Failed to copy binary file: $file"
            continue
        }
        
        # Set executable permissions if requested
        if ($MakeExecutable) {
            $remotePath = "$TargetFolder/$fileName"
            $exitCode = Invoke-SshCommand -User $RemoteUser -RemoteHost $RemoteDns -Command "chmod +x $remotePath" -SshArgs $SshArgs
            if ($exitCode -ne 0) {
                Write-Warning-Custom "Failed to set executable permissions on: $file"
            }
        }
        
        Write-Log "Copied binary file: $file"
    }
    
    Write-Success "All binary files copied successfully to $RemoteDns"
}

function Stop-ServiceIfRunning {
    param(
        [string]$RemoteUser,
        [string]$RemoteDns,
        [string]$ServiceName,
        [string[]]$SshArgs
    )
    
    # Check if service is active
    $exitCode = Invoke-SshCommand -User $RemoteUser -RemoteHost $RemoteDns -Command "systemctl is-active --quiet $ServiceName" -SshArgs $SshArgs
    
    if ($exitCode -eq 0) {
        Write-Log "Stopping service $ServiceName on remote server..."
        $exitCode = Invoke-SshCommand -User $RemoteUser -RemoteHost $RemoteDns -Command "sudo systemctl stop $ServiceName" -SshArgs $SshArgs
        if ($exitCode -eq 0) {
            Write-Log "Service $ServiceName stopped"
        } else {
            Write-Error-Custom "Failed to stop service $ServiceName"
        }
    } else {
        Write-Log "Service $ServiceName is not running, no need to stop"
    }
}

function Start-ServiceRemote {
    param(
        [string]$RemoteUser,
        [string]$RemoteDns,
        [string]$ServiceName,
        [string[]]$SshArgs
    )
    
    Write-Log "Starting service $ServiceName on remote server..."
    $exitCode = Invoke-SshCommand -User $RemoteUser -RemoteHost $RemoteDns -Command "sudo systemctl start $ServiceName" -SshArgs $SshArgs
    if ($exitCode -eq 0) {
        Write-Log "Service $ServiceName started"
    } else {
        Write-Error-Custom "Failed to start service $ServiceName"
    }
}
#endregion

#region Main Function
function Main {
    # Show help if requested
    if ($Help) {
        Show-Help
        exit 0
    }

    # Resolve DNS name (mandatory)
    $resolvedDnsName = if ($DnsName) { 
        $DnsName 
    } elseif ($env:REMOTE_DNS_NAME) { 
        $env:REMOTE_DNS_NAME 
    } else { 
        Write-Error-Custom "DNS name is required. Use -DnsName parameter or set REMOTE_DNS_NAME environment variable."
        Write-Host ""
        Show-Help
        exit 1
    }

    # Resolve SSH key path (optional)
    $resolvedSshKeyPath = if ($SshKey) { 
        $SshKey 
    } elseif ($env:SSH_KEY_PATH) { 
        $env:SSH_KEY_PATH 
    } else { 
        $null
    }

    # Expand path if it contains ~
    if ($resolvedSshKeyPath -and $resolvedSshKeyPath -match '^~') {
        $resolvedSshKeyPath = $resolvedSshKeyPath -replace '^~', $env:USERPROFILE
    }

    # Resolve target folder
    $resolvedTargetFolder = if ($TargetFolder) { 
        $TargetFolder 
    } elseif ($env:TARGET_FOLDER) { 
        $env:TARGET_FOLDER 
    } else { 
        $Script:DefaultTargetFolder 
    }

    # Resolve remote user
    $resolvedRemoteUser = if ($RemoteUser) { 
        $RemoteUser 
    } elseif ($env:REMOTE_USER) { 
        $env:REMOTE_USER 
    } else { 
        $Script:DefaultRemoteUser 
    }

    # Check if at least one file is provided
    if (-not $Files -or $Files.Count -eq 0) {
        Write-Error-Custom "No files provided to copy."
        Write-Host ""
        Show-Help
        exit 1
    }

    # Build SSH arguments
    $sshArgs = Get-SshArgs -SshKeyPath $resolvedSshKeyPath -DebugMode $Debug

    Write-Title "Starting file copy to remote machine: $resolvedDnsName"

    # Create target directory on remote server
    $exitCode = Invoke-SshCommand -User $resolvedRemoteUser -RemoteHost $resolvedDnsName -Command "mkdir -p $resolvedTargetFolder" -SshArgs $sshArgs
    if ($exitCode -ne 0) {
        Write-Error-Custom "Failed to create target directory on remote server"
        exit 1
    }

    # Handle service restart and file copying
    if ($Binary) {
        if ($RestartService) {
            Stop-ServiceIfRunning -RemoteUser $resolvedRemoteUser -RemoteDns $resolvedDnsName -ServiceName $RestartService -SshArgs $sshArgs
        }
        
        Copy-BinaryFiles -RemoteUser $resolvedRemoteUser -RemoteDns $resolvedDnsName -TargetFolder $resolvedTargetFolder -FilesToCopy $Files -SshArgs $sshArgs -MakeExecutable $Executable
        
        if ($RestartService) {
            Start-ServiceRemote -RemoteUser $resolvedRemoteUser -RemoteDns $resolvedDnsName -ServiceName $RestartService -SshArgs $sshArgs
        }
    } else {
        Copy-TextFiles -RemoteUser $resolvedRemoteUser -RemoteDns $resolvedDnsName -TargetFolder $resolvedTargetFolder -FilesToCopy $Files -SshArgs $sshArgs
    }
}
#endregion

# Execute main function
Main
