#!/bin/bash

# === Portainer CE Updater Script ===
# Updates to latest LTS version, backs up existing container, sends email with version info
# Usage: ./update-portainer.sh [--force]

set -euo pipefail

# --- Dependency Check ---
required_bins=(jq curl docker)

missing_bins=()
for bin in "${required_bins[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    missing_bins+=("$bin")
  fi
done

if (( ${#missing_bins[@]} > 0 )); then
  echo "🛠 Installing missing dependencies: ${missing_bins[*]}"

  # Determine if sudo is needed
  SUDO=""
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
      SUDO="sudo"
    else
      echo "❌ Cannot install dependencies — not root and sudo not found."
      exit 1
    fi
  fi

  if command -v apt-get &>/dev/null; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y "${missing_bins[@]}"
  elif command -v dnf &>/dev/null; then
    $SUDO dnf install -y "${missing_bins[@]}"
  elif command -v yum &>/dev/null; then
    $SUDO yum install -y "${missing_bins[@]}"
  elif command -v pacman &>/dev/null; then
    $SUDO pacman -Sy --noconfirm "${missing_bins[@]}"
  else
    echo "❌ Could not detect supported package manager. Please install manually: ${missing_bins[*]}"
    exit 1
  fi
fi

# --- Load or Create Config ---
CONFIG_PATH="${CONFIG_PATH:-./portainer-upd.conf}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "📝 No config file found. Creating default config at $CONFIG_PATH..."

  cat <<EOF > "$CONFIG_PATH"
# === Portainer Updater Configuration ===

# Email notifications
EMAIL_ENABLED=false
EMAIL_TO="your@email.com"
EMAIL_FROM="\$(hostname)@yourdomain.com"
EMAIL_SUBJECT="Portainer Updated on \$(hostname)"
EMAIL_BODY="/tmp/portainer_update_email.txt"

# Docker settings
CONTAINER_NAME="portainer"
IMAGE_NAME="portainer/portainer-ce:lts"
VOLUME_NAME="portainer_data"
EOF

  echo "✅ Default config created. Email disabled until you update: $CONFIG_PATH"
fi

# Load the config
source "$CONFIG_PATH"

# --- Handle --force flag ---
FORCE_UPDATE=false
if [[ "${1:-}" == "--force" ]]; then
  echo "⚠️  Force update enabled — proceeding even if up to date."
  FORCE_UPDATE=true
fi

# --- Docker Hub Digest Helpers ---
get_auth_token() {
  curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:portainer/portainer-ce:pull" | jq -r '.token'
}

get_lts_image_digest() {
  local token manifest_list amd64_digest
  token=$(get_auth_token)
  manifest_list=$(curl -s -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://registry-1.docker.io/v2/portainer/portainer-ce/manifests/lts")
  amd64_digest=$(echo "$manifest_list" | jq -r '.manifests[] | select(.platform.architecture == "amd64" and .platform.os == "linux") | .digest')
  curl -s -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/portainer/portainer-ce/manifests/${amd64_digest}" \
    | jq -r '.config.digest // empty'
}

get_current_image_digest() {
  docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo ""
}

get_running_version() {
  docker exec "$CONTAINER_NAME" /portainer --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "unknown"
}

# --- Determine if update is needed ---
echo "Checking remote LTS image digest from Docker Hub..."
latest_digest=$(get_lts_image_digest)
echo "Latest LTS image digest: $latest_digest"

current_digest=$(get_current_image_digest)
echo "Currently running container image digest: $current_digest"

if [[ "$latest_digest" == "$current_digest" ]]; then
  if [[ "$FORCE_UPDATE" = true ]]; then
    echo "⚠️  Force update requested — proceeding despite identical digests."
  else
    echo "✅ Portainer is already up to date (based on image digest)."
    exit 0
  fi
fi

# --- Stop other conflicting containers (but NOT Portainer) ---
conflicting_containers=$(docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0:(8000|9000|9443)->' | grep -v " ${CONTAINER_NAME} " || true)
if [[ -n "$conflicting_containers" ]]; then
  echo "⚠️  The following containers are using required ports:"
  echo "$conflicting_containers"
  echo "Stopping them to free ports..."
  while read -r container_id _; do
    docker stop "$container_id"
  done <<< "$conflicting_containers"
fi

# --- Pull latest image ---
echo "Pulling latest LTS image..."
docker pull "$IMAGE_NAME" > /dev/null

# --- Backup and stop current Portainer container ---
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  backup_name="${CONTAINER_NAME}_backup_$(date +%Y%m%d_%H%M%S)"
  echo "Backing up and stopping container: $backup_name"

  echo "Stopping container: $CONTAINER_NAME"
  docker stop "$CONTAINER_NAME"

  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Renaming to backup: $backup_name"
    docker rename "$CONTAINER_NAME" "$backup_name"
  else
    echo "⚠️  Skipped rename — container $CONTAINER_NAME no longer exists."
  fi
fi

# Clean up any leftover stopped container with target name
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# --- Start new Portainer container ---
echo "Starting new Portainer container..."
docker run -d \
  -p 8000:8000 \
  -p 9443:9443 \
  -p 9000:9000 \
  --name="$CONTAINER_NAME" \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$VOLUME_NAME":/data \
  "$IMAGE_NAME"

echo "✅ Portainer update complete."

# --- Report running version ---
current_version=$(get_running_version)
echo "Running Portainer version: $current_version"

# --- Cleanup old backups (keep most recent) ---
echo "Cleaning up old Portainer backups..."
docker ps -a --format '{{.Names}}' | grep "^${CONTAINER_NAME}_backup_" | sort -r | tail -n +3 | while read -r old_backup; do
  echo "Removing old backup: $old_backup"
  docker rm "$old_backup" > /dev/null || true
done

# --- Email notification ---
if [ "$EMAIL_ENABLED" = true ]; then
  echo "Sending email notification to $EMAIL_TO..."
  {
    echo "✅ Portainer CE has been updated on host: $(hostname)"
    echo ""
    echo "Updated to       : $current_version"
    echo "Time             : $(date)"
    echo "Container name   : $CONTAINER_NAME"
  } > "$EMAIL_BODY"

  if command -v s-nail &> /dev/null; then
    s-nail -s "$EMAIL_SUBJECT" -r "$EMAIL_FROM" -S from="$EMAIL_FROM" "$EMAIL_TO" < "$EMAIL_BODY"
  elif command -v mail &> /dev/null; then
    mail -s "$EMAIL_SUBJECT" -r "$EMAIL_FROM" "$EMAIL_TO" < "$EMAIL_BODY"
  else
    echo "⚠️  Email not sent: s-nail/mail not found."
  fi

  rm -f "$EMAIL_BODY"
fi
