#!/usr/bin/env bash

# ================= Configuration Variables =================
# Update these paths/values to suit your environment
LOG_FILE=""           # path where update history is stored
DOCKER_COMPOSE_CMD="docker compose"                      # docker compose command
DOCKER_RUN_OPTS="-d"                  # default docker run options
# ==========================================================

# Fallback if LOG_FILE is not set
if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="/tmp/docker-update.log"
  echo -e "${YELLOW}LOG_FILE not set. Using fallback: $LOG_FILE.${RESET}"
  echo -e "Please edit the script and set LOG_FILE to your preferred path.${RESET}"
fi

# Start timer
 t1=$(date +%s)

set -euo pipefail
IFS=$'\n\t'

# Track current context for error logging
CURRENT_CONTAINER=""
CURRENT_IMAGE=""

# Improved error trap showing line, command, and logging failures
trap 'echo -e "\e[31mError at line ${BASH_LINENO[0]}: '\''${BASH_COMMAND}'\''\e[0m" >&2; \
      if [[ -n "$CURRENT_CONTAINER" && -n "$CURRENT_IMAGE" ]]; then \
        log_entry "$CURRENT_CONTAINER" "$CURRENT_IMAGE" "FAIL"; fi; \
      exit 1' ERR

# LOG_FILE configured above

# ANSI color codes
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RED="\e[31m"
RESET="\e[0m"

show_usage() {
  cat <<EOF
Usage:
  $0 -f|--file <docker-compose.yml> [-s|--service <service_name>]
  $0 -c|--containers <container1> [<container2> ...] [-t|--tag <image_tag>]
  $0 -r|--rollback <container_name>

Options:
  -f, --file         Path to docker-compose.yml to update.
  -s, --service      (Compose) Specific service name to update.
  -c, --containers   One or more standalone container names to update.
  -t, --tag          (Containers only) Specific image tag or version.
  -r, --rollback     Roll back a container to a previous image from the log.

Notes:
  --tag may be used only with a single container.

Examples:
  # Update all services in a compose file
  $0 --file docker-compose.yml

  # Update a single compose service
  $0 --file docker-compose.yml --service web

  # Update two standalone containers to their latest images
  $0 --containers webapi redis

  # Update a single container to a specific version
  $0 --containers my_app --tag v2.1.0

  # Rollback a container
  $0 --rollback my_app
EOF
  exit 1
}

# --- Parse arguments ---
MODE="update"
COMPOSE_FILE=""
SERVICE=""
CONTAINERS=()
OVERRIDE_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      COMPOSE_FILE="$2"; shift 2;;
    -s|--service)
      SERVICE="$2"; shift 2;;
    -c|--containers)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        CONTAINERS+=("$1"); shift
      done;;
    -t|--tag)
      OVERRIDE_TAG="$2"; shift 2;;
    -r|--rollback)
      MODE="rollback"; ROLLBACK_CONTAINER="$2"; shift 2;;
    *) show_usage;;
  esac
done

# --- Validate mode ---
if [[ "$MODE" == "rollback" ]]; then
  [[ -n "${ROLLBACK_CONTAINER:-}" ]] || show_usage
elif [[ -n "$COMPOSE_FILE" ]]; then
  [[ -z "$OVERRIDE_TAG" ]] || { echo -e "${RED}--tag cannot be used with --file.${RESET}" >&2; exit 1; }
elif [[ ${#CONTAINERS[@]} -gt 0 ]]; then
  [[ -z "$OVERRIDE_TAG" || ${#CONTAINERS[@]} -eq 1 ]] || { echo -e "${RED}--tag may only be used with a single container.${RESET}" >&2; exit 1; }
else
  show_usage
fi

# --- Logging ---
log_entry() {
  local container="$1" image_ref="$2" type="$3" digest ts
  if [[ "$image_ref" == *"@"* ]]; then
    digest="${image_ref#*@}"
    image_ref="${image_ref%@*}"
  else
    # fetch digest for image:tag
    digest=$(docker inspect "$image_ref" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "")
    digest="${digest#*@}"
  fi
  ts=$(date +"%Y-%m-%dT%H:%M:%S%z")
  echo "${ts}|${container}|${image_ref}|${digest}|${type}" >> "$LOG_FILE"
}

# --- Compose update ---
do_compose(){
  local file="$1" svc="$2"
  [[ -f "$file" ]] || { echo -e "${RED}Compose file '$file' not found.${RESET}" >&2; exit 1; }
  if [[ -n "$svc" ]]; then
    echo -e "${BLUE}Pulling image for service '$svc' from '$file'...${RESET}"
    docker compose -f "$file" pull "$svc"
    echo -e "${BLUE}Recreating service '$svc'...${RESET}"
    docker compose -f "$file" up -d --force-recreate "$svc"
    # get container ID and image info
    local cid img digest
    cid=$(docker compose -f "$file" ps -q "$svc")
    img=$(docker inspect "$cid" --format='{{.Config.Image}}')
    digest=$(docker inspect "$cid" --format='{{index .Image}}')
    log_entry "$svc" "$img@$digest" "UPDATE"
    echo -e "${GREEN}Compose service '$svc' update complete.${RESET}"
  else
    echo -e "${BLUE}Pulling images from '$file'...${RESET}"
    docker compose -f "$file" pull
    echo -e "${BLUE}Recreating containers...${RESET}"
    docker compose -f "$file" up -d --force-recreate
    # Log each service updated
    local cid img digest service
    while read -r service; do
      cid=$(docker compose -f "$file" ps -q "$service")
      img=$(docker inspect "$cid" --format='{{.Config.Image}}')
      digest=$(docker inspect "$cid" --format='{{index .Image}}')
      log_entry "$service" "$img@$digest" "UPDATE"
    done < <(docker compose -f "$file" config --services)
    echo -e "${GREEN}Compose update complete.${RESET}"
  fi
}

# --- Manual container update, with compose detection ---
do_container_manual(){
  local name="$1" override="$2"
  CURRENT_CONTAINER="$name"
  echo -e "${BLUE}Inspecting container '$name'...${RESET}"

  # Detect compose-managed container
  local labels raw_cf cf workdir svc
  labels=$(docker inspect "$name" --format='{{json .Config.Labels}}' 2>/dev/null || echo '{}')
  raw_cf=$(jq -r '."com.docker.compose.project.config_files" // empty' <<< "$labels")
  raw_cf="${raw_cf#[}"
  raw_cf="${raw_cf%]}"
  IFS="," read -r cf _ <<< "$raw_cf"
  cf="${cf//\"/}"
  workdir=$(jq -r '."com.docker.compose.project.working_dir" // empty' <<< "$labels")
  svc=$(jq -r '."com.docker.compose.service" // empty' <<< "$labels")

  if [[ -n "$cf" && -n "$workdir" && -n "$svc" ]]; then
    local compose_path="$cf"
    [[ "$cf" != /* ]] && compose_path="$workdir/$cf"
    echo -e "${BLUE}Detected compose-managed service '$svc' in '$compose_path'.${RESET}"
    do_compose "$compose_path" "$svc"
    return
  fi

  # Manual update
  local flags base_image target_image current_id remote_digest
  flags=$(docker inspect "$name" --format='{{range .Config.Env}}-e {{printf "%q" .}} {{end}}{{range $p,$bs := .HostConfig.PortBindings}}{{range $b := $bs}}-p {{$b.HostIp}}:{{$b.HostPort}}:{{$p}} {{end}}{{end}}{{range .Mounts}}{{if eq .Type "bind"}}-v {{printf "%q" .Source}}:{{printf "%q" .Destination}}{{if not .RW}}:ro{{end}} {{end}}{{if eq .Type "volume"}}-v {{printf "%q" .Name}}:{{printf "%q" .Destination}}{{if not .RW}}:ro{{end}} {{end}}{{end}}{{with .HostConfig.RestartPolicy}}{{if .Name}}--restart={{.Name}}{{if .MaximumRetryCount}}:{{.MaximumRetryCount}}{{end}}{{end}}{{end}}{{range .Config.Entrypoint}}--entrypoint {{printf "%q" .}} {{end}}{{with .HostConfig.NetworkMode}}{{if ne . "default"}}--network={{.}}{{end}}{{end}}')
  base_image=$(docker inspect "$name" --format='{{.Config.Image}}'); base_image="${base_image%%:*}"
  target_image="$base_image:${override:-latest}"
  CURRENT_IMAGE="$target_image"
  current_id=$(docker inspect "$name" --format='{{.Image}}')

  echo -e "${BLUE}Pulling image '$target_image'...${RESET}"
  docker pull "$target_image"
  remote_digest=$(docker inspect "$target_image" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "")

  if [[ "$remote_digest" == *"$current_id"* ]]; then
    echo -e "${YELLOW}Container '$name' already uses '$target_image'. Skipping.${RESET}"
    log_entry "$name" "$target_image" "SKIP"
    return
  fi

  echo -e "${BLUE}Stopping & removing '$name'...${RESET}"
  docker stop "$name"
  docker rm   "$name"

  echo -e "${BLUE}Recreating '$name' with image '$target_image'...${RESET}"
  eval "docker run --name $(printf '%q' "$name") -d $flags $(printf '%q' "$target_image")"

  echo -e "${GREEN}Container '$name' updated to '$target_image'.${RESET}"
  log_entry "$name" "$target_image" "UPDATE"
}

# --- Rollback logic ---
do_rollback(){
  local name="$1"
  [[ -f "$LOG_FILE" ]] || { echo -e "${RED}No log file at $LOG_FILE${RESET}" >&2; exit 1; }
  mapfile -t entries < <(grep "|${name}|" "$LOG_FILE" | tail -n 5)
  [[ ${#entries[@]} -gt 0 ]] || { echo -e "${RED}No history for '$name'.${RESET}" >&2; exit 1; }

  echo -e "${BLUE}Select rollback target for '$name':${RESET}"
  local i=1
  for e in "${entries[@]}"; do
    IFS='|' read -r ts c img dig type <<< "$e"
    printf "  [%d] %s => %s@%s (%s)\n" "$i" "$ts" "$img" "$dig" "$type"
    ((i++))
  done
  read -p "Enter choice [1-$((i-1))]: " choice
  [[ $choice -ge 1 && $choice -lt i ]] || { echo -e "${RED}Invalid choice.${RESET}" >&2; exit 1; }
  IFS='|' read -r sel_ts sel_c sel_img sel_dig sel_type <<< "${entries[$((choice-1))]}"

  echo -e "${BLUE}Rolling back '$name' to $sel_img@$sel_dig...${RESET}"
  do_container_manual "$name" "$sel_img"
  log_entry "$name" "$sel_img" "ROLLBACK"
  echo -e "${GREEN}Rollback of '$name' complete.${RESET}"
}

# --- Main dispatch ---
if [[ "$MODE" == "rollback" ]]; then
  do_rollback "$ROLLBACK_CONTAINER"
elif [[ -n "$COMPOSE_FILE" ]]; then
  do_compose "$COMPOSE_FILE" "$SERVICE"
elif [[ ${#CONTAINERS[@]} -gt 0 ]]; then
  for ctr in "${CONTAINERS[@]}"; do
    do_container_manual "$ctr" "$OVERRIDE_TAG"
  done
else
  show_usage
fi

if [[ "$MODE" == "update" ]]; then
  echo -e "${BLUE}Pruning unused images...${RESET}"
  docker image prune -a -f
  echo -e "${GREEN}All operations complete.${RESET}"
  # show duration
t2=$(date +%s)
duration=$((t2 - t1))
printf "Script execution time: %02d:%02d:%02d\n" $((duration/3600)) $(((duration%3600)/60)) $((duration%60))
fi
