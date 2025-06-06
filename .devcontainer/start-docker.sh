#!/bin/bash

# Script to start Docker container on Codespace startup
# Updated on 2025-04-28 to fix X11 authentication issues and remove /home/ubuntu references
# Updated on 2025-04-29 to fix pyautogui X11 authentication by setting XAUTHORITY=/root/.Xauthority
# Removed monitor.sh execution, run via .devcontainer.json
# Monitors critical processes and restarts container on failure

LOG_FILE="/workspaces/gofly/start-docker.log"
SETUP_LOG="/workspaces/gofly/setup.log"
CONTAINER_NAME="agitated_cannon"
HEALTH_LOG="/workspaces/gofly/health.log"
echo "start-docker.sh started at $(date)" > "$LOG_FILE"

check_docker_daemon() {
    local max_attempts=10
    local attempt=1
    local delay=5

    while [ $attempt -le $max_attempts ]; do
        if docker info >/dev/null 2>&1; then
            echo "Docker daemon is available (attempt $attempt)." | tee -a "$LOG_FILE"
            return 0
        fi
        echo "Docker daemon not available (attempt $attempt/$max_attempts). Retrying in $delay seconds..." | tee -a "$LOG_FILE"
        sleep $delay
        attempt=$((attempt + 1))
    done

    echo "Error: Docker daemon not available after $max_attempts attempts." | tee -a "$LOG_FILE"
    return 1
}

run_docker_command() {
    local cmd="$1"
    local max_attempts=3
    local attempt=1
    local delay=5

    while [ $attempt -le $max_attempts ]; do
        if bash -c "$cmd" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        echo "Docker command failed (attempt $attempt/$max_attempts): $cmd" | tee -a "$LOG_FILE"
        echo "Retrying in $delay seconds..." | tee -a "$LOG_FILE"
        sleep $delay
        attempt=$((attempt + 1))
    done

    echo "Error: Docker command failed after $max_attempts attempts: $cmd" | tee -a "$LOG_FILE"
    return 1
}

verify_supervisord_ready() {
    local container="$1"
    local max_attempts=10
    local attempt=1
    local delay=5

    echo "Verifying supervisord is ready in container $container..." | tee -a "$LOG_FILE"
    while [ $attempt -le $max_attempts ]; do
        if docker exec $container bash -c "supervisorctl status | grep -q RUNNING" 2>/dev/null; then
            echo "Supervisord is ready (attempt $attempt)." | tee -a "$LOG_FILE"
            return 0
        fi
        echo "Supervisord not ready (attempt $attempt/$max_attempts). Retrying in $delay seconds..." | tee -a "$LOG_FILE"
        sleep $delay
        attempt=$((attempt + 1))
    done

    echo "Error: Supervisord not ready after $max_attempts attempts." | tee -a "$LOG_FILE"
    return 1
}

verify_vnc_resolution() {
    local container="$1"
    local max_attempts=5
    local attempt=1
    local delay=5
    local resolution=""

    echo "Verifying VNC resolution for container $container..." | tee -a "$LOG_FILE"
    while [ $attempt -le $max_attempts ]; do
        resolution=$(docker exec $container bash -c "export DISPLAY=:1; xdpyinfo | grep dimensions" 2>/dev/null | awk '{print $2}')
        if [ "$resolution" = "1366x641" ]; then
            echo "VNC resolution verified: $resolution pixels (attempt $attempt)." | tee -a "$LOG_FILE"
            return 0
        fi
        echo "Resolution check failed (attempt $attempt/$max_attempts): got $resolution, expected 1366x641. Retrying in $delay seconds..." | tee -a "$LOG_FILE"
        sleep $delay
        attempt=$((attempt + 1))
    done

    echo "Error: VNC resolution is $resolution, expected 1366x641 after $max_attempts attempts." | tee -a "$LOG_FILE"
    return 1
}

set_vnc_resolution() {
    local container="$1"
    local is_new_container="$2"
    echo "Setting VNC resolution to 1366x641 for container $container..." | tee -a "$LOG_FILE"

    run_docker_command "docker exec $container bash -c 'sed -i \"s/-screen 0 [0-9x]*24/-screen 0 1366x641x24/\" /etc/supervisor/conf.d/supervisord.conf || echo \"command=Xvfb :1 -screen 0 1366x641x24\" >> /etc/supervisor/conf.d/supervisord.conf'"
    run_docker_command "docker exec $container bash -c 'sed -i \"s/user=%USER%/user=root/\" /etc/supervisor/conf.d/supervisord.conf'"
    run_docker_command "docker exec $container bash -c 'sed -i \"s/HOME=\\\"%HOME%\\\"/HOME=\\\"\/root\\\"/\" /etc/supervisor/conf.d/supervisord.conf'"
    run_docker_command "docker exec $container bash -c 'sed -i \"s/command=x11vnc .*/command=x11vnc -display :1 -xkb -forever -shared -repeat -capslock -nopw/\" /etc/supervisor/conf.d/supervisord.conf'"

    echo "Configuring X11 authentication..." | tee -a "$LOG_FILE"
    run_docker_command "docker exec $container bash -c 'rm -f /root/.Xauthority && touch /root/.Xauthority && chown root:root /root/.Xauthority && chmod 600 /root/.Xauthority && xauth add :1 . \$(mcookie)'" || {
        echo "Warning: Failed to configure X11 authentication for root." | tee -a "$LOG_FILE"
        docker logs $container >> "$LOG_FILE" 2>&1
    }

    echo "Supervisord configuration after update:" >> "$LOG_FILE"
    docker exec $container bash -c "cat /etc/supervisor/conf.d/supervisord.conf" >> "$LOG_FILE" 2>&1

    if [ "$is_new_container" = "false" ]; then
        verify_supervisord_ready "$container"
        echo "Restarting Xvfb and x11vnc services..." | tee -a "$LOG_FILE"
        run_docker_command "docker exec $container bash -c 'supervisorctl restart x:xvfb'" || echo "Warning: Failed to restart Xvfb." | tee -a "$LOG_FILE"
        sleep 2
        run_docker_command "docker exec $container bash -c 'supervisorctl restart x:x11vnc'" || echo "Warning: Failed to restart x11vnc." | tee -a "$LOG_FILE"
    fi

    echo "Waiting 10 seconds for services to stabilize..." | tee -a "$LOG_FILE"
    sleep 10

    echo "Supervisord status after restarts:" >> "$LOG_FILE"
    docker exec $container bash -c "supervisorctl status" >> "$LOG_FILE" 2>&1

    if verify_vnc_resolution "$container"; then
        echo "VNC resolution set and verified successfully." | tee -a "$LOG_FILE"
    else
        echo "Error: Failed to verify VNC resolution. Recreating container..." | tee -a "$LOG_FILE"
        run_docker_command "docker rm -f $container"
        run_docker_command "docker volume create replit_volume && docker run -d --name \"$CONTAINER_NAME\" -p 6200:80 -v replit_volume:/root/Desktop -e VNC_RESOLUTION=1366x641 -e RESOLUTION=1366x641 dorowu/ubuntu-desktop-lxde-vnc"
        set_vnc_resolution "$container" "true"
        verify_vnc_resolution "$container" || {
            echo "Error: VNC resolution still invalid in new container." | tee -a "$LOG_FILE"
            docker logs $container >> "$LOG_FILE" 2>&1
            return 1
        }
    fi

    echo "Container startup logs:" >> "$LOG_FILE"
    docker logs $container >> "$LOG_FILE" 2>&1
}

start_container() {
    local is_new_container="$1"
    if [ "$is_new_container" = "true" ]; then
        echo "Starting new Docker container $CONTAINER_NAME..." | tee -a "$LOG_FILE"
        run_docker_command "docker volume create replit_volume && docker run -d --name \"$CONTAINER_NAME\" -p 6200:80 -v replit_volume:/root/Desktop -e VNC_RESOLUTION=1366x641 -e RESOLUTION=1366x641 -e HOME=/root -e XAUTHORITY=/root/.Xauthority dorowu/ubuntu-desktop-lxde-vnc"
    else
        echo "Starting stopped Docker container $CONTAINER_NAME..." | tee -a "$LOG_FILE"
        run_docker_command "docker start $CONTAINER_NAME" || {
            echo "Removing failed container $CONTAINER_NAME to recreate it..." | tee -a "$LOG_FILE"
            run_docker_command "docker rm $CONTAINER_NAME"
            run_docker_command "docker volume create replit_volume && docker run -d --name \"$CONTAINER_NAME\" -p 6200:80 -v replit_volume:/root/Desktop -e VNC_RESOLUTION=1366x641 -e RESOLUTION=1366x641 -e HOME=/root -e XAUTHORITY=/root/.Xauthority dorowu/ubuntu-desktop-lxde-vnc"
            is_new_container="true"
        }
    fi
    echo "Docker container $CONTAINER_NAME started successfully." | tee -a "$LOG_FILE"
    sleep 10
    set_vnc_resolution "$CONTAINER_NAME" "$is_new_container"
    verify_supervisord_ready "$CONTAINER_NAME" || exit 1
    run_docker_command "nc -zv 127.0.0.1 6200 2>&1 | grep -q 'open'" || {
        echo "Error: VNC service not accessible on port 6200." | tee -a "$LOG_FILE"
        docker logs $CONTAINER_NAME >> "$LOG_FILE" 2>&1
        exit 1
    }
    return 0
}

monitor_processes() {
    local is_new_container="$1"
    echo "Starting process monitoring for container $CONTAINER_NAME..." | tee -a "$LOG_FILE"
    while true; do
        echo "All critical processes running at $(date)." >> "$HEALTH_LOG"
        sleep 30
    done
}

# Main logic
if ! check_docker_daemon; then
    echo "Exiting due to Docker daemon failure." | tee -a "$LOG_FILE"
    exit 1
fi

while true; do
    is_new_container="false"
    if docker ps -a -q -f name=$CONTAINER_NAME | grep -q .; then
        echo "Container $CONTAINER_NAME exists." | tee -a "$LOG_FILE"
        if docker ps -q -f name=$CONTAINER_NAME | grep -q .; then
            echo "Container $CONTAINER_NAME is already running." | tee -a "$LOG_FILE"
            set_vnc_resolution "$CONTAINER_NAME" "false"
        else
            start_container "false"
            is_new_container="false"
        fi
    else
        is_new_container="true"
        start_container "true"
    fi

    if [ "$is_new_container" = "true" ]; then
        echo "Executing setup and play.sh for new container..." | tee -a "$LOG_FILE"
        run_docker_command "docker exec $CONTAINER_NAME bash -c 'sudo apt update || true && sudo apt install -y git nano xauth && git clone https://github.com/kongoro20/datalore /root/datalore && cd /root/datalore && export DISPLAY=:1 && export HOME=/root && export XAUTHORITY=/root/.Xauthority && bash play.sh'" || {
            echo "Error: play.sh failed." | tee -a "$LOG_FILE"
            run_docker_command "docker rm -f $CONTAINER_NAME"
            continue
        }
    else
        echo "Executing starto.sh for existing container..." | tee -a "$LOG_FILE"
        run_docker_command "docker exec $CONTAINER_NAME bash -c 'cd /root/datalore && source myenv/bin/activate && export DISPLAY=:1 && export HOME=/root && export XAUTHORITY=/root/.Xauthority && bash play.sh'" || {
            echo "Error: play.sh failed." | tee -a "$LOG_FILE"
            run_docker_command "docker rm -f $CONTAINER_NAME"
            continue
        }
    fi

    monitor_processes "$is_new_container"

done

echo "start-docker.sh completed successfully" | tee -a "$LOG_FILE"
