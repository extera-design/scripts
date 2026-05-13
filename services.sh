#!/bin/bash

set -e

# === CONFIGURATION ===
API_SERVICE_NAME="extera-api-solverd.service"
SOLVER_SERVICE_NAME="extera-linux-service-solver.service"
MONGO_CONTAINER="mongodb"
MONGO_SERVICE="mongo-solver-api.service"
NGROK_SERVICE="ngrok.service"

# === HELPER FUNCTIONS ===

# Check if a systemctl service is active
is_service_active() {
    local service_name=$1
    sudo systemctl is-active --quiet "$service_name" 2>/dev/null
}

# Check if a docker container is running
is_container_running() {
    local container_name=$1
    sudo docker container inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true
}

# Stop a service with status notification
stop_service() {
    local service_name=$1
    local service_display_name=$2
    
    if is_service_active "$service_name"; then
        echo "Stopping $service_display_name..."
        sudo systemctl stop "$service_name"
        echo "$service_display_name stopped successfully."
    else
        echo "$service_display_name is already stopped."
    fi
}

# Stop a container with status notification
stop_container() {
    local container_name=$1
    local container_display_name=$2
    
    if is_container_running "$container_name"; then
        echo "Stopping $container_display_name container..."
        sudo docker stop "$container_name"
        echo "$container_display_name container stopped successfully."
    else
        echo "$container_display_name container is already stopped."
    fi
}

# Start a service with status notification
start_service() {
    local service_name=$1
    local service_display_name=$2
    
    if is_service_active "$service_name"; then
        echo "$service_display_name is already running."
    else
        echo "Starting $service_display_name..."
        sudo systemctl start "$service_name"
        echo "$service_display_name started successfully."
    fi
}

# Start a container with status notification
start_container() {
    local container_name=$1
    local container_display_name=$2
    
    if is_container_running "$container_name"; then
        echo "$container_display_name container is already running."
    else
        echo "Starting $container_display_name container..."
        if sudo docker container inspect "$container_name" >/dev/null 2>&1; then
            # Container exists, just start it
            sudo docker start "$container_name"
        else
            echo "Error: $container_display_name container does not exist. Please run the deployment script first."
            return 1
        fi
        echo "$container_display_name container started successfully."
    fi
}

# === MAIN FUNCTIONS ===

stop_services() {
    echo "=== STOPPING SERVICES ==="
    stop_service "$NGROK_SERVICE" "ngrok service"
    stop_service "$SOLVER_SERVICE_NAME" "Solver service"
    stop_service "$API_SERVICE_NAME" "API service"
    echo "Services stopped."
}

stop_all_services() {
    echo "=== STOPPING ALL SERVICES AND DATABASE ==="
    stop_service "$SOLVER_SERVICE_NAME" "Solver service"
    stop_service "$NGROK_SERVICE" "ngrok service"
    stop_service "$API_SERVICE_NAME" "API service"
    stop_service "$MONGO_SERVICE" "MongoDB service"
    stop_container "$MONGO_CONTAINER" "MongoDB container"
    echo "All services and database stopped."
}

start_services() {
    echo "=== STARTING SERVICES ==="
    
    # Start MongoDB container first
    if ! start_container "$MONGO_CONTAINER" "MongoDB container"; then
        echo "Error: Failed to start MongoDB container. Aborting startup sequence."
        exit 1
    fi
    
    # Wait for MongoDB to be ready
    echo "Waiting for MongoDB to be ready..."
    local max_wait=30
    local wait_count=0
    while ! sudo docker container inspect -f '{{.State.Running}}' "$MONGO_CONTAINER" | grep -q true; do
        if [ $wait_count -ge $max_wait ]; then
            echo "Error: MongoDB container failed to start within ${max_wait} seconds."
            exit 1
        fi
        sleep 1
        ((wait_count++))
    done
    
    # Start MongoDB service
    start_service "$MONGO_SERVICE" "MongoDB service"

    # Start API service
    start_service "$API_SERVICE_NAME" "API service"
    
    # Start Solver service
    start_service "$SOLVER_SERVICE_NAME" "Solver service"

    # Start ngrok service
    start_service "$NGROK_SERVICE" "ngrok service"
    
    echo "All services started successfully."
}

# === USAGE FUNCTION ===
show_usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  stop     - Stop ngrok, solver and API services (in that order)"
    echo "  stopAll  - Stop solver, API, MongoDB, and ngrok services, and MongoDB container"
    echo "  start    - Start MongoDB container, then MongoDB, API, solver, and ngrok services"
    echo ""
    echo "Examples:"
    echo "  $0 stop"
    echo "  $0 stopAll"
    echo "  $0 start"
}

# === MAIN SCRIPT ===

# Check if parameter is provided
if [ $# -eq 0 ]; then
    echo "Error: No command provided."
    echo ""
    show_usage
    exit 1
fi

# Parse command line parameter
case $1 in
    stop)
        stop_services
        ;;
    stopAll)
        stop_all_services
        ;;
    start)
        start_services
        ;;
    -h|--help)
        show_usage
        exit 0
        ;;
    *)
        echo "Error: Invalid command '$1'."
        echo ""
        show_usage
        exit 1
        ;;
esac

echo "Operation completed successfully."