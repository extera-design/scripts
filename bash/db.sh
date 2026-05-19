#!/bin/bash

set -e

# === CONFIGURATION ===
MONGO_CONTAINER_DEFAULT="mongodb"
DATABASE_NAME_DEFAULT="solver-api"
MAX_RETRIES=5
DEFAULT_PAGE_SIZE=20

# Global variables
ARG_CONTAINER=""
ARG_DATABASE=""
STRICT_MODE=false
USE_ONE_MODE=false
COMMAND=""
COLLECTION=""
FILTER_ARGS=()
REPLACEMENT_ARGS=()
VALIDATION_ERRORS=()
IS_TERMINAL=false

# === UTILITY FUNCTIONS ===

# Check if output is going to a terminal
check_terminal() {
    if [[ -t 1 ]]; then
        IS_TERMINAL=true
    else
        IS_TERMINAL=false
    fi
}

# Get terminal height or use default
get_page_size() {
    if [[ "$IS_TERMINAL" == true ]]; then
        local height=$(tput lines 2>/dev/null || echo "24")
        echo $((height - 4))  # Leave some space for prompts
    else
        echo $DEFAULT_PAGE_SIZE
    fi
}

# Show progress indicator
show_progress() {
    local message="$1"
    if [[ "$IS_TERMINAL" == true ]]; then
        echo -ne "\r\033[K$message..."
    fi
}

# Clear progress indicator
clear_progress() {
    if [[ "$IS_TERMINAL" == true ]]; then
        echo -ne "\r\033[K"
    fi
}

# === VALIDATION FUNCTIONS ===

# Check if string is a valid ObjectID
is_object_id() {
    local value="$1"
    local length=${#value}
    
    if [[ "$STRICT_MODE" == true ]]; then
        # Strict mode: exactly 24 hex characters
        if [[ $length -eq 24 && "$value" =~ ^[0-9a-fA-F]{24}$ ]]; then
            return 0
        fi
    else
        # Lenient mode: 22-26 characters
        if [[ $length -ge 22 && $length -le 26 ]]; then
            if [[ "$value" =~ ^[0-9a-fA-F]+$ ]]; then
                if [[ $length -ne 24 ]]; then
                    VALIDATION_ERRORS+=("Warning: ObjectID '$value' has length $length (expected 24)")
                fi
                return 0
            fi
        fi
    fi
    return 1
}

# Check if string is a number (including scientific notation)
is_number() {
    local value="$1"
    
    # Match integers, decimals, and scientific notation (positive/negative)
    if [[ "$value" =~ ^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$ ]]; then
        # Check for potential precision loss with very large numbers
        local abs_value=$(echo "$value" | sed 's/^[-+]//' | sed 's/[eE][-+]/e/')
        if [[ ${#abs_value} -gt 15 ]]; then
            echo "Warning: Number '$value' may lose precision in MongoDB" >&2
        fi
        return 0
    fi
    return 1
}

# Check if string is a boolean
is_boolean() {
    local value="$1"
    local lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    [[ "$lower" == "true" || "$lower" == "false" ]]
}

# Convert value to appropriate MongoDB type
convert_value() {
    local value="$1"
    
    if is_object_id "$value"; then
        echo "ObjectId(\"$value\")"
    elif is_boolean "$value"; then
        local lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')
        echo "$lower"
    elif is_number "$value"; then
        echo "$value"
    else
        # Escape quotes and wrap in quotes for string
        local escaped=$(echo "$value" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
        echo "\"$escaped\""
    fi
}

# === MONGODB CONNECTION FUNCTIONS ===

# Test MongoDB connection with retry logic
test_mongo_connection() {
    local attempt=1
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        show_progress "Testing MongoDB connection (attempt $attempt/$MAX_RETRIES)"
        
        if sudo docker exec "$MONGO_CONTAINER" mongosh --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            clear_progress
            return 0
        fi
        
        if [[ $attempt -eq $MAX_RETRIES ]]; then
            clear_progress
            echo "Error: Failed to connect to MongoDB after $MAX_RETRIES attempts" >&2
            return 1
        fi
        
        sleep 2
        ((attempt++))
    done
}

# Check if collection exists
check_collection_exists() {
    local collection="$1"
    
    show_progress "Checking if collection '$collection' exists"
    
    local collections=$(sudo docker exec "$MONGO_CONTAINER" mongosh "$DATABASE_NAME" --quiet --eval "
        JSON.stringify(db.getCollectionNames())
    " 2>/dev/null)
    
    clear_progress
    
    if echo "$collections" | grep -q "\"$collection\""; then
        return 0
    else
        echo "Error: Collection '$collection' does not exist" >&2
        echo "Available collections: $(echo "$collections" | sed 's/\[//' | sed 's/\]//' | sed 's/"//g')" >&2
        return 1
    fi
}

# Check if the MongoDB Docker container exists and is running
check_container_exists() {
    show_progress "Checking if container '$MONGO_CONTAINER' exists"

    local status=$(sudo docker inspect --format '{{.State.Status}}' "$MONGO_CONTAINER" 2>/dev/null)

    clear_progress

    if [[ -z "$status" ]]; then
        echo "Error: Container '$MONGO_CONTAINER' does not exist" >&2
        return 1
    fi

    if [[ "$status" != "running" ]]; then
        echo "Error: Container '$MONGO_CONTAINER' exists but is not running (status: $status)" >&2
        return 1
    fi

    return 0
}

# Check if the target database exists in MongoDB
check_database_exists() {
    show_progress "Checking if database '$DATABASE_NAME' exists"

    local databases=$(sudo docker exec "$MONGO_CONTAINER" mongosh --quiet --eval "
        JSON.stringify(db.adminCommand({ listDatabases: 1 }).databases.map(function(d) { return d.name; }))
    " 2>/dev/null)

    clear_progress

    if echo "$databases" | grep -q "\"$DATABASE_NAME\""; then
        return 0
    else
        echo "Error: Database '$DATABASE_NAME' does not exist" >&2
        echo "Available databases: $(echo "$databases" | sed 's/\[//' | sed 's/\]//' | sed 's/"//g')" >&2
        return 1
    fi
}

# === ARGUMENT PARSING FUNCTIONS ===

# Parse field:value arguments into MongoDB query
parse_filter_args() {
    local args=("$@")
    local filter_json="{"
    local first=true
    
    # Group values by field name
    declare -A field_values
    
    for arg in "${args[@]}"; do
        if [[ "$arg" == *":"* ]]; then
            local field="${arg%%:*}"
            local values="${arg#*:}"
            
            # Split comma-separated values
            IFS=',' read -ra value_array <<< "$values"
            
            # Add to field_values array (maintaining uniqueness)
            for value in "${value_array[@]}"; do
                value=$(echo "$value" | xargs)  # Trim whitespace
                if [[ -n "$value" ]]; then
                    if [[ -z "${field_values[$field]}" ]]; then
                        field_values[$field]="$value"
                    else
                        # Check if value already exists
                        if [[ ! "${field_values[$field]}" =~ (^|,)"$value"(,|$) ]]; then
                            field_values[$field]="${field_values[$field]},$value"
                        fi
                    fi
                fi
            done
        else
            VALIDATION_ERRORS+=("Error: Invalid filter argument format '$arg' (expected field:value)")
        fi
    done
    
    # Build JSON query
    for field in "${!field_values[@]}"; do
        if [[ "$first" != true ]]; then
            filter_json+=","
        fi
        first=false
        
        IFS=',' read -ra values <<< "${field_values[$field]}"
        
        if [[ ${#values[@]} -eq 1 ]]; then
            # Single value
            filter_json+="\"$field\":$(convert_value "${values[0]}")"
        else
            # Multiple values - use $in operator
            filter_json+="\"$field\":{\"\$in\":["
            local value_first=true
            for value in "${values[@]}"; do
                if [[ "$value_first" != true ]]; then
                    filter_json+=","
                fi
                value_first=false
                filter_json+="$(convert_value "$value")"
            done
            filter_json+="]}"
        fi
    done
    
    filter_json+="}"
    echo "$filter_json"
}

# Parse replacement arguments and detect conflicts
parse_replacement_args() {
    local args=("$@")
    local set_ops="{}"
    local addtoset_ops="{}"
    local pull_ops="{}"
    
    declare -A set_fields
    declare -A array_fields
    declare -A last_set_values
    
    # First pass: collect all operations and detect conflicts
    for arg in "${args[@]}"; do
        if [[ "$arg" == *":"* ]]; then
            local field_part="${arg%%:*}"
            local values="${arg#*:}"
            local prefix=""
            local field=""
            
            # Parse prefix if present
            if [[ "$field_part" == *":"* ]]; then
                prefix="${field_part%%:*}"
                field="${field_part#*:}"
            else
                field="$field_part"
            fi
            
            # Validate prefix
            if [[ -n "$prefix" && "$prefix" != "add" && "$prefix" != "del" && "$prefix" != "rem" ]]; then
                VALIDATION_ERRORS+=("Error: Invalid prefix '$prefix' for field '$field' (valid prefixes: add, del, rem)")
                continue
            fi
            
            # Track field usage
            if [[ -z "$prefix" ]]; then
                set_fields["$field"]=1
                # Keep only the last occurrence for set operations
                last_set_values["$field"]="$values"
            else
                array_fields["$field"]=1
            fi
        else
            VALIDATION_ERRORS+=("Error: Invalid replacement argument format '$arg' (expected [prefix:]field:value)")
        fi
    done
    
    # Check for conflicts between set and array operations
    for field in "${!set_fields[@]}"; do
        if [[ -n "${array_fields[$field]}" ]]; then
            VALIDATION_ERRORS+=("Error: Field '$field' cannot have both replacement and array operations")
        fi
    done
    
    # Stop if there are conflicts
    if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
        return 1
    fi
    
    # Second pass: build operations
    local set_first=true
    local addtoset_first=true
    local pull_first=true
    
    # Process set operations (use last occurrence only)
    set_ops="{"
    for field in "${!last_set_values[@]}"; do
        if [[ "$set_first" != true ]]; then
            set_ops+=","
        fi
        set_first=false
        
        local values="${last_set_values[$field]}"
        IFS=',' read -ra value_array <<< "$values"
        
        if [[ ${#value_array[@]} -eq 1 ]]; then
            set_ops+="\"$field\":$(convert_value "${value_array[0]}")"
        else
            # Multiple values become an array
            set_ops+="\"$field\":["
            local value_first=true
            for value in "${value_array[@]}"; do
                value=$(echo "$value" | xargs)
                if [[ "$value_first" != true ]]; then
                    set_ops+=","
                fi
                value_first=false
                set_ops+="$(convert_value "$value")"
            done
            set_ops+="]"
        fi
    done
    set_ops+="}"
    
    # Process array operations
    addtoset_ops="{"
    pull_ops="{"
    
    for arg in "${args[@]}"; do
        if [[ "$arg" == *":"* ]]; then
            local field_part="${arg%%:*}"
            local values="${arg#*:}"
            local prefix=""
            local field=""
            
            if [[ "$field_part" == *":"* ]]; then
                prefix="${field_part%%:*}"
                field="${field_part#*:}"
            else
                continue  # Skip set operations, already handled
            fi
            
            # Skip if field has conflict (already reported)
            if [[ -n "${set_fields[$field]}" ]]; then
                continue
            fi
            
            IFS=',' read -ra value_array <<< "$values"
            
            if [[ "$prefix" == "add" ]]; then
                if [[ "$addtoset_first" != true ]]; then
                    addtoset_ops+=","
                fi
                addtoset_first=false
                
                if [[ ${#value_array[@]} -eq 1 ]]; then
                    addtoset_ops+="\"$field\":$(convert_value "${value_array[0]}")"
                else
                    addtoset_ops+="\"$field\":{\"\$each\":["
                    local value_first=true
                    for value in "${value_array[@]}"; do
                        value=$(echo "$value" | xargs)
                        if [[ "$value_first" != true ]]; then
                            addtoset_ops+=","
                        fi
                        value_first=false
                        addtoset_ops+="$(convert_value "$value")"
                    done
                    addtoset_ops+="]}"
                fi
            elif [[ "$prefix" == "del" || "$prefix" == "rem" ]]; then
                if [[ "$pull_first" != true ]]; then
                    pull_ops+=","
                fi
                pull_first=false
                
                if [[ ${#value_array[@]} -eq 1 ]]; then
                    pull_ops+="\"$field\":$(convert_value "${value_array[0]}")"
                else
                    pull_ops+="\"$field\":{\"\$in\":["
                    local value_first=true
                    for value in "${value_array[@]}"; do
                        value=$(echo "$value" | xargs)
                        if [[ "$value_first" != true ]]; then
                            pull_ops+=","
                        fi
                        value_first=false
                        pull_ops+="$(convert_value "$value")"
                    done
                    pull_ops+="]}"
                fi
            fi
        fi
    done
    
    addtoset_ops+="}"
    pull_ops+="}"
    
    # Combine operations into final update document
    local update_doc="{"
    local first=true
    
    if [[ "$set_ops" != "{}" ]]; then
        update_doc+="\"\$set\":$set_ops"
        first=false
    fi
    
    if [[ "$addtoset_ops" != "{}" ]]; then
        if [[ "$first" != true ]]; then
            update_doc+=","
        fi
        update_doc+="\"\$addToSet\":$addtoset_ops"
        first=false
    fi
    
    if [[ "$pull_ops" != "{}" ]]; then
        if [[ "$first" != true ]]; then
            update_doc+=","
        fi
        update_doc+="\"\$pull\":$pull_ops"
        first=false
    fi
    
    update_doc+="}"
    echo "$update_doc"
}

# === OUTPUT FUNCTIONS ===

# Display paginated JSON output with interactive controls
display_paginated_output() {
    local json_output="$1"
    
    if [[ "$IS_TERMINAL" != true ]]; then
        # Non-terminal output: just print everything
        echo "$json_output"
        return 0
    fi
    
    # Pretty-print JSON with 2-space indentation
    local formatted_json=$(echo "$json_output" | python3 -m json.tool --indent 2 2>/dev/null || echo "$json_output")
    
    local page_size=$(get_page_size)
    local total_lines=$(echo "$formatted_json" | wc -l)
    local current_line=1
    
    if [[ $total_lines -le $page_size ]]; then
        # Content fits on one screen
        echo "$formatted_json"
        return 0
    fi
    
    while [[ $current_line -le $total_lines ]]; do
        local end_line=$((current_line + page_size - 1))
        if [[ $end_line -gt $total_lines ]]; then
            end_line=$total_lines
        fi
        
        # Display current page
        echo "$formatted_json" | sed -n "${current_line},${end_line}p"
        
        if [[ $end_line -ge $total_lines ]]; then
            break
        fi
        
        # Show prompt
        echo -n "-- More -- (Press SPACE for next page, 'b' for back, 'q' to quit): "
        read -n 1 -s key
        echo  # New line
        
        case "$key" in
            ' '|$'\n')  # Space or Enter
                current_line=$((end_line + 1))
                ;;
            'b'|'B')    # Back
                current_line=$((current_line - page_size))
                if [[ $current_line -lt 1 ]]; then
                    current_line=1
                fi
                ;;
            'q'|'Q')    # Quit
                break
                ;;
            *)          # Any other key - treat as next page
                current_line=$((end_line + 1))
                ;;
        esac
    done
}

# === MONGODB OPERATION FUNCTIONS ===

# Execute find operation
execute_find() {
    local collection="$1"
    local filter_json="$2"
    local method="find"
    
    if [[ "$USE_ONE_MODE" == true ]]; then
        method="findOne"
    fi
    
    show_progress "Executing $method operation on collection '$collection'"
    
    local mongo_script="
        db = db.getSiblingDB('$DATABASE_NAME');
        var result = db.$collection.$method($filter_json);
        if (result.toArray) {
            var docs = result.toArray();
            print('Found ' + docs.length + ' document(s)');
            print(JSON.stringify(docs));
        } else if (result) {
            print('Found 1 document');
            print(JSON.stringify([result]));
        } else {
            print('Found 0 documents');
            print('[]');
        }
    "
    
    local output=$(sudo docker exec "$MONGO_CONTAINER" mongosh "$DATABASE_NAME" --quiet --eval "$mongo_script" 2>&1)
    local exit_code=$?
    
    clear_progress
    
    if [[ $exit_code -ne 0 ]]; then
        echo "Error executing find operation:" >&2
        echo "$output" >&2
        return 1
    fi
    
    # Parse output - first line is count, rest is JSON
    local count_line=$(echo "$output" | head -n 1)
    local json_output=$(echo "$output" | tail -n +2)
    
    echo "$count_line"
    display_paginated_output "$json_output"
}

# Validate array operations against existing document
validate_array_operations() {
    local collection="$1"
    local filter_json="$2"
    local replacement_args=("${@:3}")
    
    # Get first matching document to check field types
    show_progress "Validating array operations against existing document"
    
    local mongo_script="
        db = db.getSiblingDB('$DATABASE_NAME');
        var doc = db.$collection.findOne($filter_json);
        if (doc) {
            print(JSON.stringify(doc));
        } else {
            print('null');
        }
    "
    
    local sample_doc=$(sudo docker exec "$MONGO_CONTAINER" mongosh "$DATABASE_NAME" --quiet --eval "$mongo_script" 2>/dev/null)
    
    clear_progress
    
    if [[ "$sample_doc" == "null" ]]; then
        # No documents found - array operations will create new fields as needed
        return 0
    fi
    
    # Check each array operation
    for arg in "${replacement_args[@]}"; do
        if [[ "$arg" == *":"* ]]; then
            local field_part="${arg%%:*}"
            local prefix=""
            local field=""
            
            if [[ "$field_part" == *":"* ]]; then
                prefix="${field_part%%:*}"
                field="${field_part#*:}"
                
                if [[ "$prefix" == "add" || "$prefix" == "del" || "$prefix" == "rem" ]]; then
                    # Check if field exists and is not an array
                    local field_type=$(echo "$sample_doc" | python3 -c "
import json, sys
try:
    doc = json.load(sys.stdin)
    if '$field' in doc:
        value = doc['$field']
        if isinstance(value, list):
            print('array')
        elif value is None:
            print('null')
        else:
            print('non-array')
    else:
        print('missing')
except:
    print('error')
" 2>/dev/null)
                    
                    if [[ "$field_type" == "non-array" ]]; then
                        VALIDATION_ERRORS+=("Error: Cannot apply array operation '$prefix' to non-array field '$field'")
                    fi
                fi
            fi
        fi
    done
}

# Execute update operation
execute_update() {
    local collection="$1"
    local filter_json="$2"
    local update_json="$3"
    local method="updateMany"
    
    if [[ "$USE_ONE_MODE" == true ]]; then
        method="updateOne"
    fi
    
    # First check if any documents match the filter
    show_progress "Checking for documents matching filter"
    
    local count_script="
        db = db.getSiblingDB('$DATABASE_NAME');
        var count = db.$collection.countDocuments($filter_json);
        print(count);
    "
    
    local match_count=$(sudo docker exec "$MONGO_CONTAINER" mongosh "$DATABASE_NAME" --quiet --eval "$count_script" 2>/dev/null)
    
    clear_progress
    
    if [[ "$match_count" == "0" ]]; then
        echo "No documents found to update"
        return 0
    fi
    
    echo "Found $match_count document(s) matching filter"
    
    # Validate array operations if needed
    validate_array_operations "$collection" "$filter_json" "${REPLACEMENT_ARGS[@]}"
    
    if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
        return 1
    fi
    
    show_progress "Executing $method operation on collection '$collection'"
    
    local mongo_script="
        db = db.getSiblingDB('$DATABASE_NAME');
        var result = db.$collection.$method($filter_json, $update_json);
        print('Updated ' + result.modifiedCount + ' document(s)');
        
        // Get updated documents
        var updated = db.$collection.find($filter_json).toArray();
        print(JSON.stringify(updated));
    "
    
    local output=$(sudo docker exec "$MONGO_CONTAINER" mongosh "$DATABASE_NAME" --quiet --eval "$mongo_script" 2>&1)
    local exit_code=$?
    
    clear_progress
    
    if [[ $exit_code -ne 0 ]]; then
        echo "Error executing update operation:" >&2
        echo "$output" >&2
        return 1
    fi
    
    # Parse output - first line is count, rest is JSON
    local count_line=$(echo "$output" | head -n 1)
    local json_output=$(echo "$output" | tail -n +2)
    
    echo "$count_line"
    display_paginated_output "$json_output"
}

# === HELP FUNCTION ===

show_help() {
    cat << 'EOF'
USAGE:
    db.sh <command> [OPTIONS] <collection> [filter_args...] [with replacement_args...]

COMMANDS:
    find    - Find documents in the database
    update  - Update documents in the database

OPTIONS:
    -1, -o, --one                Use findOne/updateOne instead of find/updateMany
    -s, --strict                 Strict ObjectID validation (24 hex chars only)
    -c, --container-name NAME    MongoDB container name (overrides env MONGO_CONTAINER)
    -d, --database-name NAME     Database name (overrides env DATABASE_NAME)
    -h, --help                   Show this help message

ARGUMENTS:
    collection       Name of the MongoDB collection to operate on
    filter_args      Filter criteria in format: fieldName:value[,value2,...]
    replacement_args Update operations in format: [prefix:]fieldName:value[,value2,...]

FILTER FORMAT:
    fieldName:value                    Match documents where fieldName equals value
    fieldName:value1,value2,value3     Match documents where fieldName equals any of the values
    field1:value1 field2:value2        Match documents where both conditions are met
    
    If the same fieldName appears multiple times, all values are combined with OR logic.

UPDATE FORMAT:
    fieldName:value                    Set field to value (replaces current value)
    fieldName:value1,value2            Set field to array [value1, value2]
    add:fieldName:value               Add value to array field (creates array if missing)
    del:fieldName:value               Remove value from array field
    rem:fieldName:value               Remove value from array field (same as del)
    
    Note: Cannot mix replacement and array operations on the same field.

VALUE TYPES:
    Strings:     "text", "hello world"
    Numbers:     123, -45.67, 1.5e-3, -2E+5
    Booleans:    true, false, TRUE, FALSE
    ObjectIDs:   507f1f77bcf86cd799439011 (auto-detected and wrapped)
    
    Numbers in scientific notation and large numbers are supported.
    Boolean values are case-insensitive.

OBJECTID VALIDATION:
    --strict:    Exactly 24 hexadecimal characters
    default:     22-26 characters (warns if not exactly 24)

EXAMPLES:
    # Find all users
    db.sh find users
    
    # Find user by email
    db.sh find users email:john@example.com
    
    # Find users by multiple criteria
    db.sh find projects __t:Case "name:case 1"
    
    # Find one document by ObjectID
    db.sh find --one users _id:507f1f77bcf86cd799439011
    
    # Find case by ID and change its name
    db.sh update projects _id:507f1f77bcf86cd799439011 with "name:case 2"
    
    # Add case parameter to jsonParams field
    db.sh update projects _id:507f1f77bcf86cd799439011 with jsonParams.nnn:5
    
    # Update a case's parameter
    db.sh update projects _id:695aea5a58f6c79138b81c5e "params.id:EDP\$Alpha" with "params.\$.value:5"
    
    # Update multiple fields atomically (case name and parameter value)
    db.sh update projects _id:695aea5a58f6c79138b81c5e "params.id:EDP\$Alpha" with "name:case-1" params.\$.value:5

OUTPUT:
    When run in a terminal: Interactive paginated output with navigation controls
    When redirected: Plain JSON output without pagination
    
    Navigation: SPACE=next page, b=back, q=quit

ERROR HANDLING:
    All validation occurs before any database operations.
    Specific error messages indicate which arguments are invalid.
    Array operations are validated against existing document field types.

EOF
}

# === MAIN SCRIPT ===

# Initialize
check_terminal

# Parse command line arguments
if [[ $# -eq 0 ]]; then
    echo "Error: No command provided."
    echo ""
    show_help
    exit 1
fi

# Parse options and command
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--strict)
            STRICT_MODE=true
            shift
            ;;
        -c|--container-name)
            ARG_CONTAINER="$2"
            shift 2
            ;;
        -d|--database-name)
            ARG_DATABASE="$2"
            shift 2
            ;;
        -1|-o|--one)
            USE_ONE_MODE=true
            shift
            ;;
        find|update)
            COMMAND="$1"
            shift
            break
            ;;
        *)
            echo "Error: Invalid option or command '$1'."
            echo ""
            show_help
            exit 1
            ;;
    esac
done

# Resolve MONGO_CONTAINER and DATABASE_NAME using priority: arg > env > default
MONGO_CONTAINER="${ARG_CONTAINER:-${MONGO_CONTAINER:-$MONGO_CONTAINER_DEFAULT}}"
DATABASE_NAME="${ARG_DATABASE:-${DATABASE_NAME:-$DATABASE_NAME_DEFAULT}}"

# Validate command
if [[ -z "$COMMAND" ]]; then
    echo "Error: No command specified."
    echo ""
    show_help
    exit 1
fi

# Get collection name
if [[ $# -eq 0 ]]; then
    echo "Error: No collection specified."
    echo ""
    show_help
    exit 1
fi

COLLECTION="$1"
shift

# Parse remaining arguments
with_found=false
if [[ "$COMMAND" == "update" ]]; then
    # Look for 'with' keyword
    while [[ $# -gt 0 && "$1" != "with" ]]; do
        FILTER_ARGS+=("$1")
        shift
    done
    
    if [[ $# -gt 0 && "$1" == "with" ]]; then
        with_found=true
        shift
        REPLACEMENT_ARGS=("$@")
    fi
    
    if [[ "$with_found" != true ]]; then
        echo "Error: Update command requires 'with' keyword before replacement arguments."
        echo ""
        show_help
        exit 1
    fi
else
    # Find command - all remaining args are filter args
    FILTER_ARGS=("$@")
fi

# Check container and database exist before any operations
if ! check_container_exists; then
    exit 1
fi

if ! check_database_exists; then
    exit 1
fi

# Validate arguments before any database operations
echo "Validating arguments..."

# Validate filter arguments
if [[ ${#FILTER_ARGS[@]} -eq 0 ]]; then
    # No filter means match all documents
    filter_json="{}"
else
    # Pre-validate filter arguments
    for arg in "${FILTER_ARGS[@]}"; do
        if [[ ! "$arg" == *":"* ]]; then
            VALIDATION_ERRORS+=("Error: Invalid filter argument format '$arg' (expected field:value)")
        fi
    done
fi

# Validate replacement arguments for update command
if [[ "$COMMAND" == "update" ]]; then
    if [[ ${#REPLACEMENT_ARGS[@]} -eq 0 ]]; then
        VALIDATION_ERRORS+=("Error: Update command requires replacement arguments after 'with'")
    fi
fi

# Report all validation errors
if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
    echo "Validation failed:"
    for error in "${VALIDATION_ERRORS[@]}"; do
        echo "  $error"
    done
    exit 1
fi

# Test MongoDB connection
if ! test_mongo_connection; then
    exit 1
fi

# Check collection exists
if ! check_collection_exists "$COLLECTION"; then
    exit 1
fi

# Parse filter arguments
if [[ ${#FILTER_ARGS[@]} -gt 0 ]]; then
    filter_json=$(parse_filter_args "${FILTER_ARGS[@]}")
else
    filter_json="{}"
fi

# Check for any parsing errors
if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
    echo "Validation failed:"
    for error in "${VALIDATION_ERRORS[@]}"; do
        echo "  $error"
    done
    exit 1
fi

# Execute command
case "$COMMAND" in
    find)
        execute_find "$COLLECTION" "$filter_json"
        ;;
    update)
        # Parse replacement arguments
        update_json=$(parse_replacement_args "${REPLACEMENT_ARGS[@]}")
        
        # Check for any parsing errors
        if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
            echo "Validation failed:"
            for error in "${VALIDATION_ERRORS[@]}"; do
                echo "  $error"
            done
            exit 1
        fi
        
        execute_update "$COLLECTION" "$filter_json" "$update_json"
        ;;
esac

echo "Operation completed successfully."