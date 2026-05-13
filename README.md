# Scripts

The scripts in this repository are used to simplify various tasks. The following scripts are available:

- `copy-to-aws.sh`: Copies files to an AWS VM.
- `remote-copy.sh`: Copies files to a remote SSH server.
- `db.sh`: Finds and updates documents in a MongoDB container.
- `services.sh`: Starts and stops application services (API, solver, MongoDB, ngrok).

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

### `db.sh`

Finds and updates documents in a MongoDB database running inside a Docker container.

```bash
./db.sh [options] <command> <collection> [filter_args...] [with replacement_args...]
```

**Commands:**

- `find` - Find documents in the database
- `update` - Update documents in the database

**Options:**

- `-1, -o, --one` - Use `findOne`/`updateOne` instead of `find`/`updateMany`
- `-s, --strict` - Strict ObjectID validation (exactly 24 hex characters)
- `-c, --container-name <name>` - MongoDB container name (overrides `MONGO_CONTAINER`)
- `-d, --database-name <name>` - Database name (overrides `DATABASE_NAME`)
- `-h, --help` - Show help and exit

**Environment variables:** `MONGO_CONTAINER` (default: `mongodb`), `DATABASE_NAME` (default: `solver-api`)

**Filter format:** `fieldName:value` or `fieldName:value1,value2` for multiple values. Multiple filter args are combined with AND logic; multiple values for the same field use OR logic.

**Update format:** `fieldName:value` to set a field; `add:fieldName:value` to append to an array; `del:`/`rem:fieldName:value` to remove from an array. Use the `with` keyword to separate filter args from replacement args.

**Value types:** Strings, numbers (including scientific notation), booleans (`true`/`false`), and MongoDB ObjectIDs (auto-detected).

**Output:** Interactive paginated output when run in a terminal (`SPACE`=next page, `b`=back, `q`=quit); plain JSON when redirected.

**Examples:**

```bash
# Find all documents in a collection
./db.sh find users

# Find by field value
./db.sh find users email:john@example.com

# Find one document by ObjectID
./db.sh find --one users _id:507f1f77bcf86cd799439011

# Update a field
./db.sh update projects _id:507f1f77bcf86cd799439011 with "name:case 2"

# Update with array filter
./db.sh update projects _id:695aea5a58f6c79138b81c5e "params.id:EDP\$Alpha" with "params.\$.value:5"
```

### `services.sh`

Starts and stops the application's systemd services and MongoDB Docker container.

```bash
./services.sh <command>
```

**Commands:**

- `stop` - Stop ngrok, solver, and API services (in that order)
- `stopAll` - Stop solver, ngrok, API, and MongoDB services, and the MongoDB container
- `start` - Start the MongoDB container, then MongoDB, API, solver, and ngrok services (in that order)

**Examples:**

```bash
./services.sh start
./services.sh stop
./services.sh stopAll
```

## License

This repository private.
