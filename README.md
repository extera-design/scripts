# Scripts

The scripts in this repository are used to simplify various tasks. The following scripts are available:

- `copy-to-aws.sh`: Copies files to an AWS VM.
- `remote-copy.sh`: Copies files to a remote SSH server.

## Usage

### `copy-to-aws.sh`

Copies files to an AWS VM using SSH.

```bash
./copy-to-aws.sh [options] <file1> [file2 ...]
```

**Options:**

- `-v, --vm-dns-name <dns-name>` - DNS name of the AWS VM where the files will be copied (overrides VM_DNS_NAME)
- `-k, --ssh-key <path>` - Path to SSH private key that provides access to the AWS VM (overrides SSH_KEY_PATH)
- `-t, --target-folder <path>` - Target folder on VM (overrides TARGET_FOLDER)
- `-h, --help` - Show help and exit

**Environment variables:** `VM_DNS_NAME`, `SSH_KEY_PATH`, `TARGET_FOLDER`

### `remote-copy.sh`

Copies files to a remote SSH server (intended for copying to AWS VM but can be used for any SSH server). Can also optionally restart a service on the remote server after copying.

```bash
./remote-copy.sh -v <dns-name> [options] <file1> [file2 ...]
```

**Options:**

- `-v, --dns-name <dns-name>` - **[Required]** DNS name of the remote machine where the files will be copied (overrides REMOTE_DNS_NAME)
- `-u, --remote-user <username>` - Remote SSH username (overrides REMOTE_USER)
- `-k, --ssh-key <path>` - Path to the SSH private key for access to the remote machine (overrides SSH_KEY_PATH)
- `-t, --target-folder <path>` - Target folder on remote machine (overrides TARGET_FOLDER)
- `-b, --binary` - Indicate the file(s) being copied are binary (default: false)
- `-x, --executable` - Set executable permissions on the copied file(s). Requires `--binary` flag (default: false)
- `-r, --restart-service <service>` - Restart a service on the remote server after copying
- `-M, --no-connection-reuse` - Disable SSH connection multiplexing (default: false)
- `-d, --debug` - Enable verbose output for ssh/scp commands (default: false)
- `-h, --help` - Show help and exit

**Environment variables:** `REMOTE_DNS_NAME`, `SSH_KEY_PATH`, `TARGET_FOLDER`, `REMOTE_USER`

**Note:** At least one file to copy must be provided as a positional argument.

## License

This repository private.
