#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly INSTALL_ROOT="/opt/node-agent"
readonly BRANCH_NAME="storage-agent"

color_red()   { printf '\033[31m%s\033[0m' "$*"; }
color_green() { printf '\033[32m%s\033[0m' "$*"; }
color_blue()  { printf '\033[34m%s\033[0m' "$*"; }
color_dim()   { printf '\033[2m%s\033[0m' "$*"; }

step()    { echo; echo "$(color_blue "==>") $*"; }
ok()      { echo "  $(color_green ✓) $*"; }
warn()    { echo "  $(color_red ⚠) $*"; }
die()     { echo; echo "$(color_red ERROR:) $*" >&2; exit 1; }

require_root() {
	if [[ "$(id -u)" -ne 0 ]]; then
		die "this script must be run as root (use sudo)"
	fi
}

prompt_value() {
	local label="$1"
	local default_value="${2:-}"
	local result
	if [[ -n "$default_value" ]]; then
		read -r -p "  $label [$default_value]: " result
		printf '%s' "${result:-$default_value}"
	else
		read -r -p "  $label: " result
		printf '%s' "$result"
	fi
}

prompt_secret() {
	local label="$1"
	local result
	read -r -s -p "  $label: " result
	echo
	printf '%s' "$result"
}

prompt_required() {
	local label="$1"
	local result=""
	while [[ -z "$result" ]]; do
		result=$(prompt_value "$label")
		if [[ -z "$result" ]]; then
			warn "value cannot be empty"
		fi
	done
	printf '%s' "$result"
}

normalize_domain() {
	local raw="$1"
	raw="${raw#https://}"
	raw="${raw#http://}"
	raw="${raw%/}"
	printf '%s' "$raw"
}

ensure_packages() {
	step "Checking system packages"
	apt-get update -qq
	local need_install=()
	for package in curl ca-certificates git rsync openssl jq; do
		if ! command -v "$package" >/dev/null 2>&1; then
			need_install+=("$package")
		fi
	done
	if [[ ${#need_install[@]} -gt 0 ]]; then
		echo "  installing: ${need_install[*]}"
		apt-get install -y -qq "${need_install[@]}"
	fi
	ok "system packages ready"
}

ensure_docker() {
	step "Checking Docker"
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		ok "docker + compose plugin already installed"
		return
	fi
	echo "  installing Docker..."
	curl -fsSL https://get.docker.com | sh >/dev/null
	systemctl enable --now docker
	ok "docker installed"
}

list_storage_candidates() {
	step "Available storage locations"
	local lines=()
	while IFS= read -r line; do
		lines+=("$line")
	done < <(df -B1 --output=target,size,avail,fstype -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2 | sort -u)
	if [[ ${#lines[@]} -eq 0 ]]; then
		die "no usable mount points found via df"
	fi
	local index=1
	declare -ga STORAGE_OPTIONS=()
	echo "  #   Mount                  Total       Free        FS"
	echo "  --- ---------------------- ----------- ----------- ----"
	for line in "${lines[@]}"; do
		local mount size avail fs
		mount=$(awk '{print $1}' <<<"$line")
		size=$(awk '{print $2}' <<<"$line")
		avail=$(awk '{print $3}' <<<"$line")
		fs=$(awk '{print $4}' <<<"$line")
		local size_h avail_h
		size_h=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")
		avail_h=$(numfmt --to=iec --suffix=B "$avail" 2>/dev/null || echo "$avail")
		printf "  %-3s %-22s %-11s %-11s %s\n" "$index)" "$mount" "$size_h" "$avail_h" "$fs"
		STORAGE_OPTIONS+=("$mount")
		((index++))
	done
}

choose_storage_location() {
	list_storage_candidates
	local choice=""
	while true; do
		choice=$(prompt_value "Select storage location" "1")
		if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#STORAGE_OPTIONS[@]} )); then
			STORAGE_BASE="${STORAGE_OPTIONS[$((choice - 1))]}"
			break
		fi
		warn "invalid selection, enter a number from 1 to ${#STORAGE_OPTIONS[@]}"
	done
	if [[ "$STORAGE_BASE" == "/" ]]; then
		STORAGE_HOST_PATH="/storage"
	else
		STORAGE_HOST_PATH="${STORAGE_BASE%/}/storage"
	fi
	mkdir -p "$STORAGE_HOST_PATH"
	chmod 755 "$STORAGE_HOST_PATH"
	ok "storage path: $STORAGE_HOST_PATH"
}

prompt_node_config() {
	step "Node configuration"
	NODE_ID=$(prompt_required "Node ID (e.g. DE01)")
	local domain_raw
	domain_raw=$(prompt_required "Public domain (без https://)")
	PUBLIC_DOMAIN=$(normalize_domain "$domain_raw")
	PUBLIC_URL="https://${PUBLIC_DOMAIN}"

	local parser_raw
	parser_raw=$(prompt_value "Parser API URL" "https://parser.nfgate.net")
	parser_raw=$(normalize_domain "$parser_raw")
	PARSER_BASE_URL="https://${parser_raw}"

	PARSER_REGISTER_SECRET=$(prompt_secret "Parser register secret (одноразовый, выдаёт админ парсера)")
	if [[ -z "$PARSER_REGISTER_SECRET" ]]; then
		die "register secret is required"
	fi

	RSYNC_TARGET_USER=$(prompt_value "SSH user for rsync uploads" "root")
	RSYNC_TARGET_HOST=$(prompt_value "SSH host (public IP/domain of this node)" "$PUBLIC_DOMAIN")
	RSYNC_TARGET_PORT=$(prompt_value "SSH port" "22")
	RSYNC_TARGET_PATH="$STORAGE_HOST_PATH"

	echo
	echo "  Summary:"
	echo "    NODE_ID:           $NODE_ID"
	echo "    PUBLIC_URL:        $PUBLIC_URL"
	echo "    PARSER_BASE_URL:   $PARSER_BASE_URL"
	echo "    STORAGE_HOST_PATH: $STORAGE_HOST_PATH"
	echo "    RSYNC target:      $RSYNC_TARGET_USER@$RSYNC_TARGET_HOST:$RSYNC_TARGET_PORT$RSYNC_TARGET_PATH"
	echo
	local confirm
	confirm=$(prompt_value "Continue? [y/N]" "y")
	if [[ "${confirm,,}" != "y" ]]; then
		die "aborted by user"
	fi
}

prompt_git_credentials() {
	step "Git credentials for source code"
	echo "  $(color_dim "Provide credentials with read access to the private repo.")"
	GIT_USERNAME=$(prompt_required "GitHub username")
	GIT_TOKEN=$(prompt_secret "Personal Access Token (with repo:read scope)")
	if [[ -z "$GIT_TOKEN" ]]; then
		die "token is required"
	fi
	GIT_REPO_URL=$(prompt_required "Git repo URL (https://github.com/<user>/<repo>.git)")
}

clone_source() {
	step "Fetching source from branch '$BRANCH_NAME'"
	local credential_url
	credential_url="${GIT_REPO_URL/https:\/\//https:\/\/${GIT_USERNAME}:${GIT_TOKEN}@}"

	if [[ -d "$INSTALL_ROOT/.git" ]]; then
		echo "  existing install detected, pulling latest"
		(
			cd "$INSTALL_ROOT"
			git remote set-url origin "$credential_url"
			git fetch --quiet origin "$BRANCH_NAME" || die "git fetch failed (check credentials, repo URL, branch name)"
			git checkout --quiet "$BRANCH_NAME"
			git reset --quiet --hard "origin/$BRANCH_NAME"
			git remote set-url origin "$GIT_REPO_URL"
		)
	else
		mkdir -p "$INSTALL_ROOT"
		if ! git clone --quiet --depth 1 -b "$BRANCH_NAME" "$credential_url" "$INSTALL_ROOT" 2>/dev/null; then
			die "git clone failed (check credentials, repo URL, branch name)"
		fi
		(cd "$INSTALL_ROOT" && git remote set-url origin "$GIT_REPO_URL")
	fi
	chmod 700 "$INSTALL_ROOT"
	ok "code at $INSTALL_ROOT"
}

prompt_ssh_key_install() {
	step "SSH authorized_keys for fragmenter rsync push"
	echo "  $(color_dim "Paste the public key generated on the parser/fragmenter side.")"
	echo "  $(color_dim "(starts with 'ssh-ed25519' or 'ssh-rsa', single line)")"
	echo "  $(color_dim "Press ENTER on empty line to skip if already configured.")"
	read -r -p "  pubkey: " PUBKEY
	if [[ -z "$PUBKEY" ]]; then
		warn "skipped — make sure rsync user can SSH in already"
		return
	fi
	local target_user="$RSYNC_TARGET_USER"
	local home_dir
	if [[ "$target_user" == "root" ]]; then
		home_dir="/root"
	else
		home_dir=$(eval echo "~$target_user")
	fi
	mkdir -p "$home_dir/.ssh"
	chmod 700 "$home_dir/.ssh"
	touch "$home_dir/.ssh/authorized_keys"
	if grep -qF "$PUBKEY" "$home_dir/.ssh/authorized_keys" 2>/dev/null; then
		ok "key already present in $home_dir/.ssh/authorized_keys"
	else
		echo "$PUBKEY" >> "$home_dir/.ssh/authorized_keys"
		chmod 600 "$home_dir/.ssh/authorized_keys"
		ok "key added to $home_dir/.ssh/authorized_keys"
	fi
}

write_env_file() {
	step "Writing .env"
	cat >"$INSTALL_ROOT/.env" <<EOF
NODE_ID=$NODE_ID
PUBLIC_DOMAIN=$PUBLIC_DOMAIN
PUBLIC_URL=$PUBLIC_URL
PARSER_BASE_URL=$PARSER_BASE_URL
PARSER_REGISTER_SECRET=$PARSER_REGISTER_SECRET
RSYNC_TARGET_USER=$RSYNC_TARGET_USER
RSYNC_TARGET_HOST=$RSYNC_TARGET_HOST
RSYNC_TARGET_PORT=$RSYNC_TARGET_PORT
RSYNC_TARGET_PATH=$RSYNC_TARGET_PATH
STORAGE_HOST_PATH=$STORAGE_HOST_PATH
TIMEZONE=$(cat /etc/timezone 2>/dev/null || echo UTC)
EOF
	chmod 600 "$INSTALL_ROOT/.env"
	ok ".env written"
}

start_stack() {
	step "Building and starting docker compose stack"
	cd "$INSTALL_ROOT"
	docker compose pull --quiet 2>/dev/null || true
	docker compose build --quiet
	docker compose up -d
	ok "containers up"
}

self_test() {
	step "Self-test"
	sleep 4
	if curl -fsS -m 5 "https://${PUBLIC_DOMAIN}/health" >/dev/null 2>&1; then
		ok "https://${PUBLIC_DOMAIN}/health → 200"
	else
		warn "TLS health check failed (Caddy may still be issuing the cert; retry in 30s with: curl https://${PUBLIC_DOMAIN}/health)"
	fi
	if docker logs node-agent 2>&1 | grep -q "registered with parser"; then
		ok "registered with parser successfully"
	else
		warn "registration log not found yet — check: docker logs node-agent"
	fi
}

main() {
	require_root
	echo
	echo "  $(color_blue "node-agent installer v$SCRIPT_VERSION")"
	echo

	ensure_packages
	ensure_docker
	choose_storage_location
	prompt_node_config
	prompt_git_credentials
	clone_source
	prompt_ssh_key_install
	write_env_file
	start_stack
	self_test

	echo
	echo "  $(color_green "Done.")"
	echo "  Logs:    docker logs -f node-agent"
	echo "  Restart: cd $INSTALL_ROOT && docker compose restart"
	echo "  Update:  rerun this installer to pull latest code"
	echo
}

main "$@"
