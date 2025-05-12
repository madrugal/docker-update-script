#!/usr/bin/env bash

# ================= Configuration Variables =================
LOG_FILE="" # Path for update history
DOCKER_COMPOSE_CMD=(docker compose)                 # Docker compose command
DOCKER_RUN_OPTS=(--detach)                          # Default docker run options
# ==========================================================

# ANSI colors
GREEN="\e[32m" YELLOW="\e[33m" BLUE="\e[34m" RED="\e[31m" RESET="\e[0m"

# Fallback LOG_FILE
if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="/tmp/docker-update.log"
  echo -e "${YELLOW}LOG_FILE not set; using: $LOG_FILE${RESET}"
  echo -e "Please set LOG_FILE at top of the script."
fi

t1=$(date +%s) # Start timer

set -euo pipefail
IFS=$' \n\t'

CURRENT_CONTAINER_CONTEXT="" # For trap logging
CURRENT_IMAGE_CONTEXT=""     # For trap logging

# Error trap
trap 'echo -e "${RED}Error on line ${BASH_LINENO[0]}: '\''${BASH_COMMAND}'\''${RESET}" >&2;
      [[ -n "$CURRENT_CONTAINER_CONTEXT" && -n "$CURRENT_IMAGE_CONTEXT" ]] && log_entry "$CURRENT_CONTAINER_CONTEXT" "$CURRENT_IMAGE_CONTEXT" "FAIL_SCRIPT_ERROR";
      exit 1' ERR

# Display usage information
show_usage() {
  cat <<EOF
Usage:
  $0 -f|--file <compose.yml> [-s|--service <svc>] [-t <tag>] [-n]
  $0 -c|--containers <ctr1> [<ctr2> ...] [-t <tag>] [-n]
  $0 -r|--rollback <name>

Options:
  -f, --file         Docker Compose file
  -s, --service      Service name (use with -f; -t can override its image tag)
  -c, --containers   Container names for manual update (can detect compose-managed)
  -t, --tag          Specific image tag (with -c for single container, or with -f -s)
  -n, --no-prune     Skip image pruning
  -r, --rollback     Roll back a container or compose service (by container or service name)
EOF
  exit 1
}

# Parse arguments
MODE="update"; COMPOSE_FILE=""; SERVICE_NAME=""
CONTAINERS_TO_UPDATE=(); OVERRIDE_TAG=""; NO_PRUNE=false
ROLLBACK_TARGET_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then echo -e "${RED}Error: $1 requires a file path argument.${RESET}"; show_usage; fi
      COMPOSE_FILE="$2"; shift 2;;
    -s|--service)
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then echo -e "${RED}Error: $1 requires a service name argument.${RESET}"; show_usage; fi
      SERVICE_NAME="$2"; shift 2;;
    -c|--containers)
      shift; 
      if [[ $# -eq 0 || "$1" == -* ]]; then echo -e "${RED}Error: -c requires at least one container name.${RESET}"; show_usage; fi
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do CONTAINERS_TO_UPDATE+=("$1"); shift; done;;
    -t|--tag)
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then echo -e "${RED}Error: $1 requires a tag argument.${RESET}"; show_usage; fi
      OVERRIDE_TAG="$2"; shift 2;;
    -r|--rollback)
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then echo -e "${RED}Error: $1 requires a container or service name argument.${RESET}"; show_usage; fi
      MODE="rollback"; ROLLBACK_TARGET_NAME="$2"; shift 2;;
    -n|--no-prune)
      NO_PRUNE=true; shift;;
    *) show_usage;;
  esac
done

# Validate arguments
if [[ "$MODE" == "rollback" ]]; then
  [[ -n "$ROLLBACK_TARGET_NAME" ]] || { echo -e "${RED}Error: --rollback requires name (validation).${RESET}"; show_usage; }
elif [[ -n "$COMPOSE_FILE" ]]; then 
  [[ ! -f "$COMPOSE_FILE" ]] && { echo -e "${RED}Error: Compose file not found: $COMPOSE_FILE${RESET}"; exit 1; }
  if [[ -n "$OVERRIDE_TAG" && -z "$SERVICE_NAME" ]]; then echo -e "${RED}Error: --tag with --file also requires --service.${RESET}"; exit 1; fi
  [[ ${#CONTAINERS_TO_UPDATE[@]} -gt 0 ]] && { echo -e "${RED}Error: --containers cannot be used with --file.${RESET}"; exit 1; }
elif [[ ${#CONTAINERS_TO_UPDATE[@]} -gt 0 ]]; then 
  [[ -n "$SERVICE_NAME" ]] && { echo -e "${RED}Error: --service cannot be used with --containers.${RESET}"; exit 1; }
  if [[ -n "$OVERRIDE_TAG" && ${#CONTAINERS_TO_UPDATE[@]} -ne 1 ]]; then echo -e "${RED}Error: --tag for single container only when using -c.${RESET}"; exit 1; fi
else
  show_usage
fi

log_entry() {
  local name_in_log="$1" image_ref_with_id="$2" status_type="$3"; local image_name_tag image_digest_or_id timestamp
  timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
  if [[ "$image_ref_with_id" == *"@"* ]]; then image_digest_or_id="${image_ref_with_id#*@}"; image_name_tag="${image_ref_with_id%@*}"; else image_name_tag="$image_ref_with_id"; image_digest_or_id=$(docker inspect "$image_name_tag" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo ""); if [[ -n "$image_digest_or_id" ]]; then image_digest_or_id="${image_digest_or_id#*@}"; else image_digest_or_id=$(docker inspect "$image_name_tag" --format='{{.Id}}' 2>/dev/null || echo "UNKNOWN_ID"); fi; fi
  echo "${timestamp};${name_in_log};${image_name_tag};${image_digest_or_id};${status_type}" >> "$LOG_FILE"
}

temp_override_file_for_cleanup="" # Used by trap
_cleanup_temp_compose_override() {
    if [[ -n "$temp_override_file_for_cleanup" && -f "$temp_override_file_for_cleanup" ]]; then
        echo -e "${BLUE}Cleaning up temporary override file: $temp_override_file_for_cleanup${RESET}"
        rm -f "$temp_override_file_for_cleanup"
        temp_override_file_for_cleanup="" 
    fi
    trap - EXIT RETURN SIGINT SIGTERM 
}

do_compose_update() {
  local compose_file="$1" specific_service="$2" cli_override_tag="$3"
  CURRENT_CONTAINER_CONTEXT="compose_$(basename "$compose_file" .yml)"

  if [[ -n "$specific_service" ]]; then 
    echo -e "${BLUE}Inspecting service '$specific_service'...${RESET}"; local image_spec_in_compose image_to_target
    image_spec_in_compose=$("${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" config --format json | jq -r ".services.\"$specific_service\".image // \"\"")
    if [[ -z "$image_spec_in_compose" ]]; then echo -e "${RED}Error: Cannot get original image for '$specific_service' from $compose_file.${RESET}"; log_entry "$specific_service" "unknown_config" "FAIL_NO_IMAGE_CONFIG"; return 1; fi

    if [[ -n "$cli_override_tag" ]]; then local base_name_part="${image_spec_in_compose%%:*}"; if [[ "$cli_override_tag" == *":"* ]]; then image_to_target="$cli_override_tag"; else image_to_target="$base_name_part:$cli_override_tag"; fi; echo -e "${BLUE}CLI override: Targeting image '$image_to_target' for service '$specific_service'.${RESET}";
    else image_to_target="$image_spec_in_compose"; fi
    CURRENT_IMAGE_CONTEXT="$image_to_target"

    local old_container_id current_image_id="NOT_RUNNING" current_config_image_tag="none"
    old_container_id=$("${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" ps -q "$specific_service")
    if [[ -n "$old_container_id" ]] && docker inspect "$old_container_id" &>/dev/null; then current_image_id=$(docker inspect "$old_container_id" --format='{{.Image}}'); current_config_image_tag=$(docker inspect "$old_container_id" --format='{{.Config.Image}}'); else echo -e "${YELLOW}Service '$specific_service' not running.${RESET}"; fi

    echo -e "${BLUE}Pulling target image '$image_to_target' for '$specific_service'...${RESET}"
    if ! docker pull "$image_to_target"; then echo -e "${RED}Error: Pull failed for '$image_to_target'.${RESET}"; log_entry "$specific_service" "$image_to_target" "PULL_FAIL"; return 1; fi
    local pulled_target_image_id=$(docker inspect "$image_to_target" --format='{{.Id}}' 2>/dev/null || echo "ID_NOT_FOUND")
    if [[ "$pulled_target_image_id" == "ID_NOT_FOUND" ]]; then echo -e "${RED}Error: Image ID for '$image_to_target' not found post-pull.${RESET}"; log_entry "$specific_service" "$image_to_target" "FAIL_NO_IMAGE_ID"; return 1; fi

    if [[ "$current_image_id" == "$pulled_target_image_id" ]]; then
        if [[ -n "$cli_override_tag" ]]; then echo -e "${GREEN}Service '$specific_service' already running target image '$image_to_target' (ID: $current_image_id).${RESET}"; else echo -e "${GREEN}Service '$specific_service' ($image_spec_in_compose) matches version in $compose_file.${RESET}"; echo -e "${YELLOW}Note: To update '$specific_service' to a different tag, use the -t/--tag flag.${RESET}"; fi
        log_entry "$specific_service" "$image_to_target@$current_image_id" "SKIP_PINNED"; return 0
    fi
    if [[ -z "$cli_override_tag" && "$current_image_id" != "NOT_RUNNING" && "$current_config_image_tag" != "$image_spec_in_compose" ]]; then
        echo -e "${YELLOW}Warning: Service '$specific_service' currently running '$current_config_image_tag' (ID: $current_image_id).${RESET}"; echo -e "${YELLOW}Compose file specifies '$image_spec_in_compose' (target ID after pull: $pulled_target_image_id).${RESET}"; echo -e "${YELLOW}Skipping to avoid unintended downgrade/change. Use -t to target '$image_spec_in_compose' (or other) explicitly, or update $compose_file.${RESET}"; log_entry "$specific_service" "$current_config_image_tag@$current_image_id" "SKIP_MISMATCH_NO_T"; return 0
    fi
    
    echo -e "${BLUE}Updating '$specific_service': from '$current_config_image_tag' (ID: $current_image_id) to '$image_to_target' (ID: $pulled_target_image_id)...${RESET}"
    local compose_args_array=(-f "$compose_file")
    temp_override_file_for_cleanup="" 
    if [[ -n "$cli_override_tag" ]]; then
        temp_override_file_for_cleanup=$(mktemp) || { echo -e "${RED}Error creating temp file${RESET}"; return 1; }
        trap _cleanup_temp_compose_override EXIT RETURN SIGINT SIGTERM
        printf 'services:\n  "%s":\n    image: "%s"\n' "$specific_service" "$image_to_target" > "$temp_override_file_for_cleanup"
        compose_args_array+=(-f "$temp_override_file_for_cleanup"); echo -e "${BLUE}Using temporary override for image: $image_to_target (file: $temp_override_file_for_cleanup)${RESET}"
    fi

    echo -e "${BLUE}Executing: ${DOCKER_COMPOSE_CMD[*]} ${compose_args_array[*]} up -d --force-recreate $specific_service${RESET}"
    if ! "${DOCKER_COMPOSE_CMD[@]}" "${compose_args_array[@]}" up -d --force-recreate "$specific_service"; then echo -e "${RED}Error: Update failed for '$specific_service'.${RESET}"; log_entry "$specific_service" "$image_to_target@$pulled_target_image_id" "FAIL_RECREATE"; _cleanup_temp_compose_override; return 1; fi
    _cleanup_temp_compose_override 

    local new_cid=$("${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" ps -q "$specific_service"); local final_img_id="unknown"; if [[ -n "$new_cid" ]]; then final_img_id=$(docker inspect "$new_cid" --format='{{.Image}}'); fi
    log_entry "$specific_service" "$image_to_target@$final_img_id" "UPDATE"; echo -e "${GREEN}Service '$specific_service' updated.${RESET}"

  else # Update all services
    echo -e "${BLUE}Checking all services in $compose_file...${RESET}"; local services_to_recreate=() recreate_any_service=false all_defined_services
    mapfile -t all_defined_services < <("${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" config --services); if [[ ${#all_defined_services[@]} -eq 0 ]]; then echo -e "${YELLOW}No services defined in $compose_file.${RESET}"; return; fi
    declare -A cs_ids sc_names cs_cfg_tags; echo -e "${BLUE}Inspecting current states...${RESET}"
    for s_name in "${all_defined_services[@]}"; do CURRENT_IMAGE_CONTEXT="$s_name"; local s_cid img_from_compose s_cfg_tag="none"; s_cid=$("${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" ps -q "$s_name"); img_from_compose=$("${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" config --format json | jq -r ".services.\"$s_name\".image // \"\"")
        if [[ -z "$img_from_compose" ]]; then echo -e "${YELLOW}Warn: No image for '$s_name' in compose. Using running if avail.${RESET}"; if [[ -n "$s_cid" ]] && docker inspect "$s_cid" &>/dev/null; then img_from_compose=$(docker inspect "$s_cid" --format='{{.Config.Image}}'); else img_from_compose="UNKNOWN_CONFIG_FOR_$s_name"; fi; fi
        sc_names["$s_name"]="$img_from_compose"; if [[ -n "$s_cid" ]] && docker inspect "$s_cid" &>/dev/null; then cs_ids["$s_name"]=$(docker inspect "$s_cid" --format='{{.Image}}'); s_cfg_tag=$(docker inspect "$s_cid" --format='{{.Config.Image}}'); else cs_ids["$s_name"]="NOT_RUNNING"; fi; cs_cfg_tags["$s_name"]="$s_cfg_tag"; done
    echo -e "${BLUE}Pulling images for all services (based on $compose_file)...${RESET}"; if ! "${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" pull; then echo -e "${YELLOW}Warn: Pull command failed for one or more images.${RESET}"; fi
    echo -e "${BLUE}Comparing images post-pull...${RESET}"
    for s_name in "${all_defined_services[@]}"; do CURRENT_IMAGE_CONTEXT="${sc_names[$s_name]}"; local cfg_img_for_svc="${sc_names[$s_name]}"; if [[ "$cfg_img_for_svc" == "UNKNOWN_CONFIG_FOR_"* ]]; then echo -e "${YELLOW}Svc '$s_name': Skipping (unknown image config).${RESET}"; log_entry "$s_name" "$cfg_img_for_svc" "SKIP_UNKNOWN_CONFIG"; continue; fi
        local pulled_s_img_id=$(docker inspect "$cfg_img_for_svc" --format='{{.Id}}' 2>/dev/null || echo "ID_NOT_FOUND_POST_PULL"); if [[ "$pulled_s_img_id" == "ID_NOT_FOUND_POST_PULL" ]]; then echo -e "${RED}Error: Image '$cfg_img_for_svc' for '$s_name' not found post-pull. Skipping.${RESET}"; log_entry "$s_name" "$cfg_img_for_svc" "PULL_FAIL_OR_NO_ID"; continue; fi
        local current_s_id="${cs_ids[$s_name]}"; local current_s_cfg_tag="${cs_cfg_tags[$s_name]}"
        if [[ "$current_s_id" == "$pulled_s_img_id" ]]; then echo -e "${GREEN}Svc '$s_name' ($cfg_img_for_svc) matches version in $compose_file.${RESET}"; echo -e "${YELLOW}Note: To update '$s_name' to a different tag, use: $0 -f $compose_file -s $s_name -t <tag>${RESET}"; log_entry "$s_name" "$cfg_img_for_svc@$pulled_s_img_id" "SKIP_PINNED";
        elif [[ "$current_s_id" != "NOT_RUNNING" && "$current_s_cfg_tag" != "$cfg_img_for_svc" ]]; then echo -e "${YELLOW}Warn: Svc '$s_name' running '$current_s_cfg_tag' (ID: $current_s_id).${RESET}"; echo -e "${YELLOW}Compose file specifies '$cfg_img_for_svc' (ID: $pulled_s_img_id).${RESET}"; echo -e "${YELLOW}Skipping. Use -s $s_name -t <tag> or update $compose_file.${RESET}"; log_entry "$s_name" "$current_s_cfg_tag@$current_s_id" "SKIP_MISMATCH_NO_T";
        else if [[ "$current_s_id" == "NOT_RUNNING" ]]; then echo -e "${BLUE}Svc '$s_name' not running. Will start with $cfg_img_for_svc (ID: $pulled_s_img_id).${RESET}"; else echo -e "${BLUE}Svc '$s_name' ($cfg_img_for_svc) needs update. From ($current_s_cfg_tag ID: $current_s_id) to (ID: $pulled_s_img_id).${RESET}"; fi; services_to_recreate+=("$s_name"); recreate_any_service=true; log_entry "$s_name" "$cfg_img_for_svc@$pulled_s_img_id" "PENDING_UPDATE"; fi; done
    if [[ "$recreate_any_service" == true && ${#services_to_recreate[@]} -gt 0 ]]; then echo -e "${BLUE}Recreating services: ${services_to_recreate[*]}${RESET}"; if ! "${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" up -d --force-recreate --no-deps "${services_to_recreate[@]}"; then echo -e "${RED}Error during 'compose up' for: ${services_to_recreate[*]}. Check logs.${RESET}"; for s_failed_name in "${services_to_recreate[@]}"; do if [[ -z "$("${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" ps -q "$s_failed_name")" ]]; then log_entry "$s_failed_name" "${sc_names[$s_failed_name]}" "FAIL_RECREATE_NO_START"; fi; done; fi
        echo -e "${BLUE}Verifying (re)started services...${RESET}"; for s_updated_name in "${services_to_recreate[@]}"; do CURRENT_IMAGE_CONTEXT="${sc_names[$s_updated_name]}"; local final_cid running_img_name running_img_id; final_cid=$("${DOCKER_COMPOSE_CMD[@]}" -f "$compose_file" ps -q "$s_updated_name"); if [[ -n "$final_cid" ]] && docker inspect "$final_cid" &>/dev/null; then running_img_name=$(docker inspect "$final_cid" --format='{{.Config.Image}}'); running_img_id=$(docker inspect "$final_cid" --format='{{.Image}}'); log_entry "$s_updated_name" "$running_img_name@$running_img_id" "UPDATE"; echo -e "${GREEN}Svc '$s_updated_name' processed.${RESET}"; else echo -e "${RED}Svc '$s_updated_name' may not have started.${RESET}"; if ! grep -q ";$s_updated_name;.*;FAIL_RECREATE_NO_START" <(tail -n5 "$LOG_FILE"); then log_entry "$s_updated_name" "${sc_names[$s_updated_name]}" "FAIL_POST_RECREATE_CHECK"; fi; fi; done
    elif [[ "$recreate_any_service" == false && ${#all_defined_services[@]} -gt 0 ]]; then echo -e "${GREEN}All services in $compose_file already up-to-date or intentionally skipped.${RESET}"; elif [[ ${#all_defined_services[@]} -gt 0 ]]; then echo -e "${GREEN}No services required an update in $compose_file.${RESET}"; fi
  fi; echo -e "${GREEN}Compose processing complete for $compose_file.${RESET}"
}

do_manual_container_update() {
  local container_name_arg="$1" image_override_tag="$2"; CURRENT_CONTAINER_CONTEXT="$container_name_arg"; local actual_container_name="$container_name_arg"
  
  # Resolve service name to actual container name if in rollback mode and arg is not a direct container name
  if ! docker inspect "$actual_container_name" &>/dev/null && [[ "$MODE" == "rollback" ]]; then 
    local found_cid_for_service=$(docker ps -q --filter "label=com.docker.compose.service=${container_name_arg}" --filter status=running | head -n 1)
    if [[ -n "$found_cid_for_service" ]]; then actual_container_name=$(docker inspect "$found_cid_for_service" -f '{{.Name}}' | sed 's|^/||'); echo -e "${BLUE}Info: Rollback target '$container_name_arg' resolved to running container '$actual_container_name'.${RESET}";
    else echo -e "${RED}Error: For rollback, cannot find running container for service '$container_name_arg'. And '$container_name_arg' is not a direct container name.${RESET}"; log_entry "$container_name_arg" "unknown_image" "NOT_FOUND_ROLLBACK_OP"; return 1; fi
  fi
  if ! docker inspect "$actual_container_name" &>/dev/null; then echo -e "${RED}Error: Container '$actual_container_name' not found.${RESET}"; log_entry "$actual_container_name" "unknown_image" "NOT_FOUND"; return 1; fi # Check final actual_container_name

  echo -e "${BLUE}Inspecting '$actual_container_name'...${RESET}"; local labels raw_compose_files compose_file_path project_work_dir service_name
  labels=$(docker inspect "$actual_container_name" --format='{{json .Config.Labels}}'); raw_compose_files=$(jq -r '.["com.docker.compose.project.config_files"] // ""' <<<"$labels")
  if [[ "$raw_compose_files" == \[*\] ]]; then compose_file_path=$(printf '%s' "$raw_compose_files" | sed -e 's/^\[\(.*\)\]$/\1/' -e 's/"//g' | cut -d',' -f1); else compose_file_path="$raw_compose_files"; fi
  project_work_dir=$(jq -r '.["com.docker.compose.project.working_dir"] // ""' <<<"$labels"); service_name=$(jq -r '.["com.docker.compose.service"] // ""' <<<"$labels")

  if [[ -n "$compose_file_path" && -n "$project_work_dir" && -n "$service_name" ]]; then # Is compose-managed
    if [[ "$compose_file_path" != /* ]]; then compose_file_path="$project_work_dir/$compose_file_path"; fi
    echo -e "${BLUE}'$actual_container_name' is compose-managed (svc: '$service_name'). Using compose update. CLI tag: '${image_override_tag:-none}'.${RESET}"
    if [[ ! -f "$compose_file_path" ]]; then echo -e "${RED}Error: Compose file '$compose_file_path' not found.${RESET}"; log_entry "$service_name" "compose_file_missing" "COMPOSE_FILE_MISSING"; return 1; fi
    do_compose_update "$compose_file_path" "$service_name" "$image_override_tag"; return $?
  fi

  local current_image_config_ref target_image_ref image_base_name current_container_image_id pulled_image_id
  current_image_config_ref=$(docker inspect "$actual_container_name" --format='{{.Config.Image}}'); image_base_name="${current_image_config_ref%%:*}"
  if [[ -n "$image_override_tag" ]]; then if [[ "$image_override_tag" == *":"* ]]; then target_image_ref="$image_override_tag"; else target_image_ref="$image_base_name:$image_override_tag"; fi; else target_image_ref="$image_base_name:latest"; fi
  CURRENT_IMAGE_CONTEXT="$target_image_ref"; current_container_image_id=$(docker inspect "$actual_container_name" --format='{{.Image}}')

  echo -e "${BLUE}Pulling '$target_image_ref' for '$actual_container_name'...${RESET}"
  if ! docker pull "$target_image_ref"; then echo -e "${RED}Error: Failed to pull '$target_image_ref'.${RESET}"; log_entry "$actual_container_name" "$target_image_ref" "PULL_FAIL"; return 1; fi
  pulled_image_id=$(docker inspect "$target_image_ref" --format='{{.Id}}')

  if [[ "$current_container_image_id" == "$pulled_image_id" ]]; then echo -e "${GREEN}'$actual_container_name' already running target '$target_image_ref' (ID: $current_container_image_id). Skipping.${RESET}"; log_entry "$actual_container_name" "$target_image_ref@$current_container_image_id" "SKIP"; return 0; fi

  echo -e "${BLUE}Recreating '$actual_container_name': from '$current_image_config_ref' (ID: $current_container_image_id) to '$target_image_ref' (ID: $pulled_image_id)...${RESET}"
  declare -a DOCKER_EXISTING_OPTS=()
  while IFS= read -r env_var_line; do if [[ -n "$env_var_line" ]]; then DOCKER_EXISTING_OPTS+=("-e" "$env_var_line"); else echo -e "${YELLOW}Warn: Skipped empty env var line from inspect for $actual_container_name.${RESET}"; fi; done < <(docker inspect "$actual_container_name" --format='{{range .Config.Env}}{{.}}{{println}}{{end}}')
  mapfile -t port_mappings < <(docker inspect "$actual_container_name" --format='{{range $p, $b := .HostConfig.PortBindings}}{{range $x := $b}}{{printf "%s:%s:%s\n" $x.HostIp $x.HostPort $p}}{{end}}{{end}}')
  for mapping in "${port_mappings[@]}"; do local final_mapping="$mapping"; if [[ "$final_mapping" == "0.0.0.0:"* ]]; then final_mapping="${final_mapping#0.0.0.0:}"; fi; if [[ "$final_mapping" == ":"* ]]; then final_mapping="${final_mapping#:}"; fi; if [[ -n "$final_mapping" ]]; then DOCKER_EXISTING_OPTS+=("-p" "$final_mapping"); else echo -e "${YELLOW}Warn: Skipped invalid port mapping '$mapping' for $actual_container_name.${RESET}";fi; done
  mapfile -t mounts < <(docker inspect "$actual_container_name" --format='{{range .Mounts}}{{printf "%s:%s:%s:%s\n" .Type .Source .Destination .RW}}{{end}}')
  for mount_info in "${mounts[@]}"; do IFS=':' read -r type source destination rw_flag <<<"$mount_info"; local mount_option_str=""; if [[ "$type" == "bind" ]]; then mount_option_str="$source:$destination"; elif [[ "$type" == "volume" ]]; then mount_option_str="$source:$destination"; elif [[ "$type" == "tmpfs" ]]; then if [[ -n "$destination" ]]; then DOCKER_EXISTING_OPTS+=("--mount" "type=tmpfs,destination=$destination"); fi; continue; else continue; fi; if [[ -n "$mount_option_str" && "$mount_option_str" != ":" ]]; then [[ "$rw_flag" == "false" ]] && mount_option_str+=":ro"; DOCKER_EXISTING_OPTS+=("-v" "$mount_option_str"); else echo -e "${YELLOW}Warn: Skipped invalid mount '$mount_info' for $actual_container_name.${RESET}"; fi; done
  local restart_policy_name restart_retries; restart_policy_name=$(docker inspect "$actual_container_name" --format='{{.HostConfig.RestartPolicy.Name}}'); restart_retries=$(docker inspect "$actual_container_name" --format='{{.HostConfig.RestartPolicy.MaximumRetryCount}}')
  if [[ -n "$restart_policy_name" && "$restart_policy_name" != "no" ]]; then if [[ "$restart_retries" -gt 0 ]]; then DOCKER_EXISTING_OPTS+=("--restart=${restart_policy_name}:${restart_retries}"); else DOCKER_EXISTING_OPTS+=("--restart=${restart_policy_name}"); fi; fi
  local network_mode=$(docker inspect "$actual_container_name" --format='{{.HostConfig.NetworkMode}}'); if [[ "$network_mode" != "default" && "$network_mode" != "bridge" ]]; then DOCKER_EXISTING_OPTS+=("--network=$network_mode"); fi
  local hostname_val=$(docker inspect "$actual_container_name" --format='{{.Config.Hostname}}'); [[ -n "$hostname_val" ]] && DOCKER_EXISTING_OPTS+=("--hostname=$hostname_val")

  echo -e "${BLUE}Stopping '$actual_container_name'...${RESET}"; docker stop "$actual_container_name" >/dev/null
  echo -e "${BLUE}Removing '$actual_container_name'...${RESET}"; docker rm "$actual_container_name" >/dev/null
  echo -e "${BLUE}Starting new container '$actual_container_name' with '$target_image_ref'...${RESET}"
  if ! docker run --name "$actual_container_name" "${DOCKER_RUN_OPTS[@]}" "${DOCKER_EXISTING_OPTS[@]}" "$target_image_ref"; then echo -e "${RED}Error: Failed to start new '$actual_container_name' with '$target_image_ref'.${RESET}"; log_entry "$actual_container_name" "$target_image_ref@$pulled_image_id" "FAIL_RECREATE"; echo -e "${YELLOW}Old '$actual_container_name' removed. Recreate or use rollback with ID: $current_container_image_id.${RESET}"; return 1; fi
  echo -e "${GREEN}'$actual_container_name' updated to '$target_image_ref'.${RESET}"; log_entry "$actual_container_name" "$target_image_ref@$pulled_image_id" "UPDATE"; return 0
}

do_rollback() {
  local name_arg="$1"; CURRENT_CONTAINER_CONTEXT="$name_arg"; CURRENT_IMAGE_CONTEXT="rollback_operation"
  if [[ ! -f "$LOG_FILE" ]]; then echo -e "${RED}Error: Log file '$LOG_FILE' not found.${RESET}"; exit 1; fi

  local primary_search_key="$name_arg" secondary_search_key="" service_name_from_label operational_target_name="$name_arg"
  if docker inspect "$name_arg" &>/dev/null; then local labels=$(docker inspect "$name_arg" --format='{{json .Config.Labels}}' 2>/dev/null || echo ""); if [[ -n "$labels" ]]; then service_name_from_label=$(jq -r '.["com.docker.compose.service"] // ""' <<<"$labels"); if [[ -n "$service_name_from_label" && "$service_name_from_label" != "$name_arg" ]]; then secondary_search_key="$service_name_from_label"; echo -e "${BLUE}Info: '$name_arg' is container for service '$service_name_from_label'. Searching logs for both names.${RESET}"; fi; fi
  else echo -e "${YELLOW}Warn: '$name_arg' not found as a container. Assuming it's a service name for log search.${RESET}"; fi
  
  local log_grep_pattern=";(${primary_search_key}"; if [[ -n "$secondary_search_key" ]]; then log_grep_pattern+="|${secondary_search_key}"; fi; log_grep_pattern+=");"
  mapfile -t rollback_entries < <(grep -E "$log_grep_pattern" "$LOG_FILE" | grep -E ";(UPDATE|ROLLBACK_SUCCESS|FAIL_RECREATE)$" | tail -n 10)
  if [[ ${#rollback_entries[@]} -eq 0 ]]; then echo -e "${RED}No suitable rollback history for '$name_arg' (or potential service '$secondary_search_key').${RESET}"; exit 1; fi

  echo -e "${BLUE}Select version to roll back target related to '$name_arg' to:${RESET}"
  local i=1; declare -a choice_image_refs=() choice_logged_names=()
  for entry_line in "${rollback_entries[@]}"; do IFS=';' read -r ts logged_name img_tag img_digest status <<<"$entry_line"; if [[ -n "$img_tag" && "$img_tag" != "unknown_image"* && -n "$img_digest" && "$img_digest" != "UNKNOWN_ID"* ]]; then choice_image_refs+=("$img_tag"); choice_logged_names+=("$logged_name"); printf "  [%d] Logged: %s, Image: %s -> %s (Status: %s, Date: %s)\n" "$i" "$logged_name" "$img_tag" "$img_digest" "$status" "$ts"; ((i++)); fi; done
  if [[ ${#choice_image_refs[@]} -eq 0 ]]; then echo -e "${RED}No valid image references in recent logs for '$name_arg'.${RESET}"; exit 1; fi

  local choice_num; read -rp "Choice [1-$((i-1))]: " choice_num
  if ! [[ "$choice_num" =~ ^[0-9]+$ && "$choice_num" -ge 1 && "$choice_num" -lt "$i" ]]; then echo -e "${RED}Invalid choice.${RESET}"; exit 1; fi

  local selected_image_tag_for_rollback="${choice_image_refs[$((choice_num-1))]}"
  local logged_name_for_selected_entry="${choice_logged_names[$((choice_num-1))]}"
  
  # Determine operational_target_name for do_manual_container_update
  # operational_target_name should be the name that do_manual_container_update can work with (actual container name, or service name if it needs to resolve it)
  if docker inspect "$name_arg" &>/dev/null; then # If user provided an existing container name
      operational_target_name="$name_arg"
      echo -e "${BLUE}Rolling back container '$operational_target_name' (related to logged entry for '$logged_name_for_selected_entry') to '$selected_image_tag_for_rollback'...${RESET}"
  else # User likely provided a service name (which is not a running container by that exact name)
      operational_target_name="$logged_name_for_selected_entry" # Use the name from the log (service name)
      echo -e "${BLUE}Rolling back service '$operational_target_name' to '$selected_image_tag_for_rollback'...${RESET}"
  fi
  
  if do_manual_container_update "$operational_target_name" "$selected_image_tag_for_rollback"; then log_entry "$logged_name_for_selected_entry" "$selected_image_tag_for_rollback" "ROLLBACK_SUCCESS"; echo -e "${GREEN}Rollback of '$logged_name_for_selected_entry' to '$selected_image_tag_for_rollback' complete.${RESET}";
  else echo -e "${RED}Rollback of '$logged_name_for_selected_entry' to '$selected_image_tag_for_rollback' failed.${RESET}"; log_entry "$logged_name_for_selected_entry" "$selected_image_tag_for_rollback" "ROLLBACK_FAIL"; fi
}

# ======================= Main Dispatch Logic =======================
if [[ "$MODE" == "rollback" ]]; then do_rollback "$ROLLBACK_TARGET_NAME";
elif [[ -n "$COMPOSE_FILE" ]]; then if [[ -n "$SERVICE_NAME" ]]; then do_compose_update "$COMPOSE_FILE" "$SERVICE_NAME" "$OVERRIDE_TAG"; else if [[ -n "$OVERRIDE_TAG" ]]; then echo -e "${YELLOW}Warning: --tag is ignored when updating all services (no --service specified).${RESET}"; fi; do_compose_update "$COMPOSE_FILE" "" ""; fi
elif [[ ${#CONTAINERS_TO_UPDATE[@]} -gt 0 ]]; then for ctr_name in "${CONTAINERS_TO_UPDATE[@]}"; do do_manual_container_update "$ctr_name" "$OVERRIDE_TAG"; CURRENT_CONTAINER_CONTEXT=""; CURRENT_IMAGE_CONTEXT=""; done
else show_usage; fi

if [[ "$MODE" == "update" || "$MODE" == "rollback" ]]; then # Prune after successful updates or rollbacks
  if ! $NO_PRUNE; then echo -e "${BLUE}Pruning unused Docker images...${RESET}"; if docker image prune -a -f; then echo -e "${GREEN}Image pruning complete.${RESET}"; else echo -e "${YELLOW}Image pruning finished.${RESET}"; fi
  else echo -e "${YELLOW}Skipping image pruning (--no-prune).${RESET}"; fi
fi
echo -e "${GREEN}All operations complete.${RESET}"; t2=$(date +%s); duration=$((t2-t1)); printf "Total time: %02d:%02d:%02d\n" $((duration/3600)) $(((duration%3600)/60)) $((duration%60));
