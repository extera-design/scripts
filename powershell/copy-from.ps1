<#
.SYNOPSIS
    Copy files from a remote SSH server to a local folder

.DESCRIPTION
    Copies files from a remote SSH server to a local folder (the reverse of copy-to.ps1).
    Intended for retrieving files from AWS VMs or any SSH server.
    Supports binary files, wildcard expansion on the remote server, and LF line-ending
    enforcement for text files.

.PARAMETER DnsName
    DNS name of the remote machine to copy from (MANDATORY)

.PARAMETER RemoteUser
    Remote SSH username (default: ec2-user)

.PARAMETER SshKey
    Path to SSH private key for remote access

.PARAMETER TargetFolder
    Local folder where copied files will be saved

.PARAMETER Binary
    Treat the files as binary; uses SCP instead of cat

.PARAMETER NoConnectionReuse
    Disable SSH connection multiplexing

.PARAMETER VerboseSsh
    Enable verbose SSH output

.PARAMETER Files
    Remote file paths to copy. Supports wildcard patterns (e.g., /path/*.sh)
    which are expanded on the remote server.

.PARAMETER Help
    Show help message

.EXAMPLE
    .\copy-from.ps1 -DnsName "ec2-18-116-69-17.us-east-2.compute.amazonaws.com" /home/ec2-user/deployment/app.sh

.EXAMPLE
    .\copy-from.ps1 -DnsName "server.example.com" -TargetFolder ./downloaded /home/ec2-user/deployment/*.sh

.EXAMPLE
    .\copy-from.ps1 -DnsName "server.example.com" -Binary /home/ec2-user/deployment/server

.NOTES
    Environment variables:
      REMOTE_DNS_NAME, SSH_KEY_PATH, TARGET_FOLDER, REMOTE_USER

    Precedence: command line > environment > defaults
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [Alias('d')]
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
    [Alias('M')]
    [switch]$NoConnectionReuse,

    [Parameter(Mandatory=$false)]
    [Alias('v')]
    [switch]$VerboseSsh,

    [Parameter(Position=0, Mandatory=$false, ValueFromRemainingArguments=$true)]
    [Alias('f')]
    [string[]]$Files,

    [Parameter(Mandatory=$false)]
    [Alias('h')]
    [switch]$Help
)

#region Configuration
$Script:DefaultTargetFolder = "."
$Script:DefaultRemoteUser = "ec2-user"
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
    if ($VerboseSsh) {
        Write-Host "[DEBUG] $Message" -ForegroundColor Cyan
    }
}
#endregion

#region Help Function
function Show-Help {
    Write-Host @"
Copies files from a remote SSH server to a local folder (the reverse of copy-to.ps1).
Intended for retrieving files from AWS VMs or any SSH server.

Usage:
  .\copy-from.ps1 -DnsName <dns-name> [options] <remote-file1> [remote-file2 ...]

Options:
  -DnsName, -d <dns-name>           DNS name of the remote machine to copy from
                                    (overrides REMOTE_DNS_NAME)
  -RemoteUser, -u <username>        Remote SSH username (overrides REMOTE_USER)
  -SshKey, -k <path>                Optional path to the SSH private key for remote
                                    access (overrides SSH_KEY_PATH)
  -TargetFolder, -t <path>          Local folder where files will be saved
                                    (overrides TARGET_FOLDER)
  -Binary, -b                       Treat the file(s) as binary; uses SCP instead
                                    of cat (default: false)
  -NoConnectionReuse, -M            Disable SSH connection multiplexing. By default,
                                    the script reuses a single authenticated connection
                                    for all ssh/scp calls to minimize password prompts.
                                    Use this flag to create separate connections
                                    (default: false)
  -VerboseSsh, -v                   Enable verbose output for ssh/scp commands to help
                                    diagnose authentication and key issues
                                    (default: false)
  -Help, -h                         Show this help and exit

Mandatory arguments:
  The following options must be provided either via command line or environment
  variables:
    -DnsName, -d <dns-name>         DNS name of the remote machine (can also be set via
                                    the REMOTE_DNS_NAME env variable)

  At least one remote file path to copy must be provided as a positional argument.
  Remote file paths support wildcard patterns (e.g., /path/*.sh, /path/config*.json)
  which are expanded on the remote server.

Environment variables:
  REMOTE_DNS_NAME, SSH_KEY_PATH, TARGET_FOLDER, REMOTE_USER

Precedence:
  command line > environment > defaults

Defaults:
  TARGET_FOLDER  = $Script:DefaultTargetFolder
  REMOTE_USER    = $Script:DefaultRemoteUser

Note:
  - The script assumes the remote server is Linux-based and has 'cat' available.
  - For text files (default), the script reads the file via 'cat' over SSH and writes
    it locally with LF line endings (any CRLF content from the source is normalized).
  - For binary files (-b), the script uses 'scp' to copy the file directly.
  - Remote file arguments support wildcard patterns (*, ?, []) which are expanded by
    the remote shell. Quote patterns to prevent local shell expansion:
    Examples: '/path/*.sh', '/path/config*.json', '/path/file[123].txt'
"@
}
#endregion

#region SSH Helper Functions
function Get-SshArgs {
    param(
        [string]$SshKeyPath,
        [bool]$DebugMode = $false,
        [bool]$EnableConnectionReuse = $true
    )

    $args = @()

    if ($SshKeyPath) {
        $args += @('-i', $SshKeyPath)
    }

    if ($DebugMode) {
        $args += '-v'
    }

    # Enable SSH connection multiplexing to reuse authenticated connections
    # This reduces password prompts when making multiple SSH calls
    if ($EnableConnectionReuse) {
        # Use Windows TEMP directory for control socket (Unix ~/.ssh doesn't work on Windows)
        $controlPath = Join-Path $env:TEMP "ssh-cm-%r@%h:%p"
        $args += @(
            '-o', 'ControlMaster=auto',
            '-o', "ControlPath=$controlPath",
            '-o', 'ControlPersist=10'
        )
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

#region Wildcard Expansion
function Expand-RemoteWildcards {
    param(
        [string]$Pattern,
        [string]$RemoteUser,
        [string]$RemoteHost,
        [string[]]$SshArgs
    )

    if ($Pattern -match '[\*\?\[]') {
        Write-Debug-Custom "Expanding wildcard pattern on remote: $Pattern"
        # Escape spaces for bash but preserve glob wildcards (*, ?, [, ])
        $escapedPattern = $Pattern -replace ' ', '\ '
        $result = & ssh @SshArgs "$RemoteUser@$RemoteHost" "ls -1 $escapedPattern 2>/dev/null"        
        # Check for SSH connection failures (exit code 255)
        if ($LASTEXITCODE -eq 255) {
            Write-Error-Custom "Failed to connect to remote host: $RemoteHost"
            Write-Error-Custom "Please check the hostname, network connection, and SSH credentials."
            exit 1
        }
        
        # If no error but no results, the pattern didn't match any files
        if ($LASTEXITCODE -ne 0 -or -not $result) {
            Write-Warning-Custom "No remote files matched pattern: $Pattern"
            return @()
        }
        return @($result)
    }
    return @($Pattern)
}
#endregion

#region Copy Functions
function Copy-TextFiles {
    param(
        [string]$RemoteUser,
        [string]$RemoteDns,
        [string]$LocalTargetFolder,
        [string[]]$FilesToCopy,
        [string[]]$SshArgs
    )

    # Resolve the target folder to an absolute path
    $resolvedLocalPath = (Resolve-Path -Path $LocalTargetFolder).Path
    Write-Log "Copying files from $RemoteUser@$RemoteDns to $resolvedLocalPath"

    foreach ($remotePath in $FilesToCopy) {
        $fileName = $remotePath.Split('/')[-1]
        $localPath = Join-Path $resolvedLocalPath $fileName

        Write-Debug-Custom "Remote path: $remotePath"
        Write-Debug-Custom "File name: $fileName"
        Write-Debug-Custom "Local path: $localPath"
        Write-Debug-Custom "SSH Command: ssh $($SshArgs -join ' ') $RemoteUser@$RemoteDns `"cat '$remotePath'`""
        $content = & ssh @SshArgs "$RemoteUser@$RemoteDns" "cat '$remotePath'"

        if ($LASTEXITCODE -ne 0) {
            Write-Error-Custom "Failed to copy: $remotePath (Exit code: $LASTEXITCODE)"
            exit 1
        }

        if (-not $content) {
            Write-Warning-Custom "No content received from remote file: $remotePath"
        }

        # Write with LF line endings; normalize any CRLF content from the source
        $normalizedContent = ($content | ForEach-Object { $_ -replace '\r$', '' }) -join "`n"
        if ($normalizedContent.Length -gt 0) {
            $normalizedContent += "`n"
        }
        
        Write-Debug-Custom "Writing $($normalizedContent.Length) bytes to: $localPath"
        [System.IO.File]::WriteAllText($localPath, $normalizedContent, [System.Text.Encoding]::UTF8)
        
        if (Test-Path -LiteralPath $localPath) {
            $fileInfo = Get-Item -LiteralPath $localPath
            Write-Log "Copied: $remotePath -> $($fileInfo.FullName) ($($fileInfo.Length) bytes)"
        } else {
            Write-Warning-Custom "File not found after write: $localPath"
            Write-Log "Copied: $remotePath"
        }
    }

    Write-Success "All files copied successfully from $RemoteDns"
}

function Copy-BinaryFiles {
    param(
        [string]$RemoteUser,
        [string]$RemoteDns,
        [string]$LocalTargetFolder,
        [string[]]$FilesToCopy,
        [string[]]$SshArgs
    )

    Write-Log "Copying binary files from $RemoteUser@$RemoteDns to $LocalTargetFolder"

    foreach ($remotePath in $FilesToCopy) {
        Write-Debug-Custom "SCP Command: scp $($SshArgs -join ' ') $RemoteUser@$RemoteDns`:$remotePath $LocalTargetFolder/"
        & scp @SshArgs "$RemoteUser@$RemoteDns`:'$remotePath'" "$LocalTargetFolder/"

        if ($LASTEXITCODE -ne 0) {
            Write-Error-Custom "Failed to copy binary file: $remotePath"
            exit 1
        }

        Write-Log "Copied binary: $remotePath"
    }

    Write-Success "All binary files copied successfully from $RemoteDns"
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

    # Resolve local target folder
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
        Write-Error-Custom "No remote files provided to copy."
        Write-Host ""
        Show-Help
        exit 1
    }

    # Build SSH arguments
    # Note: Connection reuse disabled on Windows - OpenSSH for Windows doesn't support ControlMaster
    $sshArgs = Get-SshArgs -SshKeyPath $resolvedSshKeyPath -DebugMode $VerboseSsh -EnableConnectionReuse $false

    Write-Title "Starting file copy from remote machine: $resolvedDnsName"

    # Expand wildcards on the remote server and build the resolved file list
    Write-Debug-Custom "Resolving remote file patterns..."
    $resolvedFiles = @()
    foreach ($pattern in $Files) {
        $expanded = Expand-RemoteWildcards -Pattern $pattern -RemoteUser $resolvedRemoteUser -RemoteHost $resolvedDnsName -SshArgs $sshArgs
        $resolvedFiles += $expanded
    }

    if ($resolvedFiles.Count -eq 0) {
        Write-Error-Custom "No remote files matched the provided patterns."
        exit 1
    }

    Write-Log "Found $($resolvedFiles.Count) file(s) to copy"

    # Create local target directory
    if (-not (Test-Path $resolvedTargetFolder)) {
        New-Item -ItemType Directory -Path $resolvedTargetFolder -Force | Out-Null
    }

    if ($Binary) {
        Copy-BinaryFiles -RemoteUser $resolvedRemoteUser -RemoteDns $resolvedDnsName -LocalTargetFolder $resolvedTargetFolder -FilesToCopy $resolvedFiles -SshArgs $sshArgs
    } else {
        Copy-TextFiles -RemoteUser $resolvedRemoteUser -RemoteDns $resolvedDnsName -LocalTargetFolder $resolvedTargetFolder -FilesToCopy $resolvedFiles -SshArgs $sshArgs
    }
}
#endregion

# Execute main function
Main
