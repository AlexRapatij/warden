#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

## global service containers to be connected with the project docker network
## Only non-disablable services should be listed here. Optioanl services should be handled in getPeeredServices
DOCKER_PEERED_SERVICES=("traefik" "tunnel" "mailhog")
DOCKER_OPTIONAL_PEERED_SERVICES=("phpmyadmin" "grafana")

## messaging functions
function warning {
  >&2 printf "\033[33mWARNING\033[0m: $@\n"
}

function error {
  >&2 printf "\033[31mERROR\033[0m: $@\n"
}

function fatal {
  error "$@"
  exit -1
}

function version {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }';
}

## determines if value is present in an array; returns 0 if element is present
## in array, otherwise returns 1
##
## usage: containsElement <needle> <haystack>
##
function containsElement {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

## verify docker is running
function assertDockerRunning {
  if ! docker system info >/dev/null 2>&1; then
    fatal "Docker does not appear to be running. Please start Docker."
  fi
}

## use this to add services that can be opted in/out of
function getPeeredServices {
  local services=("${DOCKER_PEERED_SERVICES[@]}")

  if [[ "${WARDEN_PHPMYADMIN_ENABLE}" == 1 ]]; then
    services+=("phpmyadmin")
  fi

  if [[ "${WARDEN_GRAFANA_ENABLED}" == 1 ]]; then
    services+=("grafana")
  fi

  echo "${services[@]}"
}

function getAllKnownPeeredServices {
  echo "${DOCKER_PEERED_SERVICES[@]}" "${DOCKER_OPTIONAL_PEERED_SERVICES[@]}"
}

## methods to peer global services requiring network connectivity with project networks
function connectPeeredServices {
  enabledServices=($(getPeeredServices))
  for svc in ${enabledServices[@]}; do
    echo "Connecting ${svc} to $1 network"
    (docker network connect "$1" ${svc} 2>&1| grep -v 'already exists in network') || true
  done
}

function disconnectPeeredServices {
  knownServices=($(getAllKnownPeeredServices))
  for svc in ${knownServices[@]}; do
    echo "Disconnecting ${svc} from $1 network"
    (docker network disconnect "$1" ${svc} 2>&1| grep -v 'is not connected') || true
  done
}

function trimWhitespace() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

function sanitizeAlloyName() {
  printf '%s' "$1" | tr '/: .' '____'
}

function getAlloyStateDir() {
  printf '%s' "${WARDEN_HOME_DIR}/etc/alloy"
}

function getAlloyTargetsDir() {
  printf '%s' "$(getAlloyStateDir)/targets"
}

function regenerateAlloyTargets() {
  mkdir -p "$(getAlloyTargetsDir)"
}

function regenerateAlloyComposeOverride() {
  local alloy_state_dir
  local alloy_targets_dir
  local alloy_compose_file
  local mounts_found=0
  local current_section=""
  local line
  local mount_entry
  local volume_entry
  local container_name
  local volume_name
  local volume_source
  local volumes_from_entries=()
  local volume_entries=()
  local declared_named_volumes=()

  alloy_state_dir="$(getAlloyStateDir)"
  alloy_targets_dir="$(getAlloyTargetsDir)"
  alloy_compose_file="${alloy_state_dir}/docker-compose.yml"

  mkdir -p "${alloy_targets_dir}"

  for mounts_file in "${alloy_targets_dir}"/*.mounts.yml; do
    if [[ -f "${mounts_file}" ]]; then
      mounts_found=1
      break
    fi
  done

  if [[ ${mounts_found} -eq 0 ]]; then
    rm -f "${alloy_compose_file}"
    return
  fi

  for mounts_file in "${alloy_targets_dir}"/*.mounts.yml; do
    [[ -f "${mounts_file}" ]] || continue

    current_section=""
    while IFS= read -r line; do
      case "${line}" in
        "    volumes_from:")
          current_section="volumes_from"
          ;;
        "    volumes:")
          current_section="volumes"
          ;;
        "      - "*)
          if [[ "${current_section}" == "volumes_from" ]]; then
            mount_entry="${line#      - }"
            container_name="${mount_entry#container:}"
            container_name="${container_name%:ro}"
            if ! docker container inspect "${container_name}" >/dev/null 2>&1; then
              continue
            fi
            if ! containsElement "${mount_entry}" "${volumes_from_entries[@]}"; then
              volumes_from_entries+=("${mount_entry}")
            fi
          elif [[ "${current_section}" == "volumes" ]]; then
            volume_entry="${line#      - }"
            if ! containsElement "${volume_entry}" "${volume_entries[@]}"; then
              volume_entries+=("${volume_entry}")
              volume_source="${volume_entry%%:*}"
              if [[ "${volume_source}" != /* ]] && [[ "${volume_source}" != .* ]] \
                && ! containsElement "${volume_source}" "${declared_named_volumes[@]}"; then
                declared_named_volumes+=("${volume_source}")
              fi
            fi
          fi
          ;;
      esac
    done < "${mounts_file}"
  done

  {
    echo "services:"
    echo "  alloy:"
    if [[ ${#volumes_from_entries[@]} -gt 0 ]]; then
      echo "    volumes_from:"
      for mount_entry in "${volumes_from_entries[@]}"; do
        echo "      - ${mount_entry}"
      done
    fi
    if [[ ${#volume_entries[@]} -gt 0 ]]; then
      echo "    volumes:"
      for volume_entry in "${volume_entries[@]}"; do
        echo "      - ${volume_entry}"
      done
    fi
    if [[ ${#declared_named_volumes[@]} -gt 0 ]]; then
      echo "volumes:"
      for volume_name in "${declared_named_volumes[@]}"; do
        echo "  ${volume_name}:"
        echo "    external: true"
      done
    fi
  } > "${alloy_compose_file}"
}

function removeAlloyProjectConfig() {
  local alloy_targets_dir
  alloy_targets_dir="$(getAlloyTargetsDir)"
  mkdir -p "${alloy_targets_dir}"
  rm -f "${alloy_targets_dir}/${WARDEN_ENV_NAME}.targets.yml"
  rm -f "${alloy_targets_dir}/${WARDEN_ENV_NAME}.mounts.yml"
}

function writeAlloyProjectConfig() {
  local alloy_targets_dir
  local targets_file
  local mounts_file
  local project_log_mount
  local project_log_source="host"
  local project_appdata_mount
  local include_project_logs=0
  local raw_include_logs
  local include_logs
  local token
  local default_include_logs
  local mounted_path
  local source_path
  local job_name
  local abs_index=0
  local parent_path
  local mount_name
  local mounted_parent
  local parent_paths=()
  local parent_mount_names=()
  local parent_index

  alloy_targets_dir="$(getAlloyTargetsDir)"
  mkdir -p "${alloy_targets_dir}"
  targets_file="${alloy_targets_dir}/${WARDEN_ENV_NAME}.targets.yml"
  mounts_file="${alloy_targets_dir}/${WARDEN_ENV_NAME}.mounts.yml"
  project_log_mount="/srv/warden-logs/${WARDEN_ENV_NAME}/project-var-log"

  : > "${targets_file}"
  : > "${mounts_file}"

  if [[ ${WARDEN_MUTAGEN_ENABLE:-0} -eq 1 ]]; then
    project_log_source="volume"
    project_appdata_mount="/srv/warden-logs/${WARDEN_ENV_NAME}/appdata"
    project_log_mount="${project_appdata_mount}/var/log"
  fi

  default_include_logs="${WARDEN_GRAFANA_INCLUDE_LOGS:-}"
  if [[ -z "${default_include_logs}" && "${WARDEN_ENV_TYPE}" == "magento2" ]]; then
    default_include_logs="default"
  fi

  IFS=',' read -r -a include_logs <<< "${default_include_logs}"
  for token in "${include_logs[@]}"; do
    token="$(trimWhitespace "${token}")"
    [[ -n "${token}" ]] || continue

    if [[ "${token}" == "default" ]]; then
      include_project_logs=1
      for job_name in debug system exception correlated-access; do
        cat >> "${targets_file}" <<EOF
- targets:
    - ${WARDEN_ENV_NAME}-${job_name}
  labels:
    job: ${WARDEN_ENV_NAME}-${job_name}
    warden_environment: ${WARDEN_ENV_NAME}
    __path__: ${project_log_mount}/${job_name}.log
EOF
      done
      continue
    fi

    if [[ "${token}" == /* ]]; then
      source_path="${token}"
      if [[ "${source_path}" == /var/www/html/* ]]; then
        source_path="${WARDEN_ENV_PATH}/${source_path#/var/www/html/}"
      fi
      parent_path="$(dirname "${source_path}")"
      parent_index=-1
      for i in "${!parent_paths[@]}"; do
        if [[ "${parent_paths[$i]}" == "${parent_path}" ]]; then
          parent_index=$i
          break
        fi
      done
      if [[ ${parent_index} -eq -1 ]]; then
        parent_paths+=("${parent_path}")
        abs_index=$((abs_index + 1))
        mount_name="abs_${abs_index}"
        parent_mount_names+=("${mount_name}")
      else
        mount_name="${parent_mount_names[$parent_index]}"
      fi
      mounted_parent="/srv/warden-logs/${WARDEN_ENV_NAME}/${mount_name}"
      mounted_path="${mounted_parent}/$(basename "${source_path}")"
      job_name="$(basename "${source_path}")"
      job_name="${job_name%.log}"
    else
      include_project_logs=1
      job_name="${token%.log}"
      mounted_path="${project_log_mount}/${token}"
      if [[ "${token}" != *.log ]]; then
        mounted_path="${mounted_path}.log"
      fi
    fi

    cat >> "${targets_file}" <<EOF
- targets:
    - ${WARDEN_ENV_NAME}-${job_name}
  labels:
    job: ${WARDEN_ENV_NAME}-${job_name}
    warden_environment: ${WARDEN_ENV_NAME}
    __path__: ${mounted_path}
EOF
  done

  if [[ ${include_project_logs} -eq 1 ]]; then
    if [[ "${project_log_source}" == "volume" ]]; then
      cat >> "${mounts_file}" <<EOF
    volumes:
      - ${WARDEN_ENV_NAME}_appdata:${project_appdata_mount}:ro
EOF
    else
      cat >> "${mounts_file}" <<EOF
    volumes:
      - ${WARDEN_ENV_PATH}/var/log:${project_log_mount}:ro
EOF
    fi
  fi

  for i in "${!parent_paths[@]}"; do
    parent_path="${parent_paths[$i]}"
    mount_name="${parent_mount_names[$i]}"
    mounted_parent="/srv/warden-logs/${WARDEN_ENV_NAME}/${mount_name}"
    if ! grep -q '^    volumes:$' "${mounts_file}" 2>/dev/null; then
      cat >> "${mounts_file}" <<EOF
    volumes:
EOF
    fi
    cat >> "${mounts_file}" <<EOF
      - ${parent_path}:${mounted_parent}:ro
EOF
  done
}

function syncAlloyProjectConfig() {
  local action="${1}"

  if [[ "${action}" == "remove" ]]; then
    removeAlloyProjectConfig
  elif [[ "${WARDEN_GRAFANA_ENABLED:-0}" == 1 ]]; then
    writeAlloyProjectConfig
  else
    removeAlloyProjectConfig
  fi

  regenerateAlloyTargets
  regenerateAlloyComposeOverride
}

function restartAlloyServiceIfRunning() {
  if docker container inspect alloy >/dev/null 2>&1; then
    "${WARDEN_BIN}" svc up -d alloy >/dev/null 2>&1
  fi
}

function regeneratePMAConfig() {
  if [[ -f "${WARDEN_HOME_DIR}/.env" ]]; then
    # Recheck PMA since old versions of .env may not have WARDEN_PHPMYADMIN_ENABLE setting
    eval "$(grep "^WARDEN_PHPMYADMIN_ENABLE" "${WARDEN_HOME_DIR}/.env")"
    WARDEN_PHPMYADMIN_ENABLE="${WARDEN_PHPMYADMIN_ENABLE:-1}"
  fi
  if [[ "${WARDEN_PHPMYADMIN_ENABLE}" == 1 ]]; then
    >&2 echo "Regenerating phpMyAdmin configuration..."
    pma_config_file="${WARDEN_HOME_DIR}/etc/phpmyadmin/config.user.inc.php"
    mkdir -p "$(dirname "$pma_config_file")"
    {
      echo "<?php"
      echo "\$i = 1;"
      for container_id in $(docker ps -q --filter "name=mysql" --filter "name=mariadb" --filter "name=db"); do
        container_name=$(docker inspect --format '{{.Name}}' "${container_id}" | sed 's#^/##')
        container_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_id}")
        MYSQL_ROOT_PASSWORD=$(docker exec "${container_id}" printenv | grep MYSQL_ROOT_PASSWORD | awk -F '=' '{print $2}')
        echo "\$cfg['Servers'][\$i]['host'] = '${container_ip}';"
        echo "\$cfg['Servers'][\$i]['auth_type'] = 'config';"
        echo "\$cfg['Servers'][\$i]['user'] = 'root';"
        echo "\$cfg['Servers'][\$i]['password'] = '${MYSQL_ROOT_PASSWORD}';"
        echo "\$cfg['Servers'][\$i]['AllowNoPassword'] = true;"
        echo "\$cfg['Servers'][\$i]['hide_db'] = '(information_schema|performance_schema|mysql|sys)';"
        echo "\$cfg['Servers'][\$i]['verbose'] = '${container_name}';"
        echo "\$i++;"
      done
    } > "${pma_config_file}"
    >&2 echo "phpMyAdmin configuration regenerated."
  fi
}
