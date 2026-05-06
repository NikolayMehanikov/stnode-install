#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly INSTALL_ROOT="/opt/fragmenter-node"
readonly DATA_ROOT="/opt/fragmenter-node/data"
readonly BRANCH_NAME="fragmenter-agent"
readonly FRAGMENTER_USER="fragmenter"

color_red()   { printf '\033[31m%s\033[0m' "$*"; }
color_green() { printf '\033[32m%s\033[0m' "$*"; }
color_blue()  { printf '\033[34m%s\033[0m' "$*"; }
color_dim()   { printf '\033[2m%s\033[0m' "$*"; }

step() { echo; echo "$(color_blue "==>") $*"; }
ok()   { echo "  $(color_green ✓) $*"; }
warn() { echo "  $(color_red ⚠) $*"; }
die()  { echo; echo "$(color_red ERROR:) $*" >&2; exit 1; }

require_root() {
	if [[ "$(id -u)" -ne 0 ]]; then
		die "this script must be run as root (use sudo)"
	fi
}

sanitize_input() {
	local raw="$1"
	raw="${raw//$'\r'/}"
	raw="${raw#"${raw%%[![:space:]]*}"}"
	raw="${raw%"${raw##*[![:space:]]}"}"
	printf '%s' "$raw"
}

prompt_value() {
	local label="$1"
	local default_value="${2:-}"
	local result
	if [[ -n "$default_value" ]]; then
		read -r -p "  $label [$default_value]: " result
		result=$(sanitize_input "$result")
		printf '%s' "${result:-$default_value}"
	else
		read -r -p "  $label: " result
		printf '%s' "$(sanitize_input "$result")"
	fi
}

prompt_secret() {
	local label="$1"
	local result
	read -r -s -p "  $label: " result </dev/tty
	echo >/dev/tty
	result=$(printf '%s' "$result" | tr -d '[:space:]')
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
	for package in curl ca-certificates git rsync openssl jq ufw; do
		if ! dpkg -s "$package" >/dev/null 2>&1; then
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

ensure_nvidia_driver() {
	step "Checking NVIDIA driver"
	if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
		local driver_version
		driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1)
		ok "NVIDIA driver already installed (version $driver_version)"
		return
	fi
	echo "  NVIDIA driver not found — installing via ubuntu-drivers"
	apt-get install -y -qq ubuntu-drivers-common
	ubuntu-drivers autoinstall
	echo
	warn "NVIDIA driver installed — A REBOOT IS REQUIRED before NVENC will work."
	warn "Re-run this script after reboot to continue."
	echo
	die "reboot required (run: reboot)"
}

ensure_nvidia_container_toolkit() {
	step "Checking NVIDIA Container Toolkit"
	if command -v nvidia-ctk >/dev/null 2>&1; then
		ok "nvidia-container-toolkit already installed"
	else
		echo "  installing nvidia-container-toolkit..."
		curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
			| gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
		curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
			| sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
			| tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
		apt-get update -qq
		apt-get install -y -qq nvidia-container-toolkit
		nvidia-ctk runtime configure --runtime=docker >/dev/null
		systemctl restart docker
		ok "nvidia-container-toolkit installed and docker reconfigured"
	fi

	echo "  testing GPU access from docker..."
	if docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi -L >/dev/null 2>&1; then
		ok "docker can access GPU"
	else
		warn "docker GPU smoke test failed — re-check driver/toolkit installation"
	fi
}

prompt_node_config() {
	step "Node configuration"
	NODE_ID=$(prompt_required "Node ID (e.g. FRU01)")
	NODE_ID="${NODE_ID^^}"

	local node_ip
	node_ip=$(prompt_required "Public IP of this node (e.g. 87.228.57.52)")
	NODE_PUBLIC_URL="http://${node_ip}:8080"
	INCOMING_SSH_HOST="$node_ip"

	local parser_raw
	parser_raw=$(prompt_required "Parser API URL (e.g. https://parser.nfdev.cc)")
	parser_raw=$(normalize_domain "$parser_raw")
	PARSER_BASE_URL="https://${parser_raw}"
	PARSER_PUBLIC_URL="$PARSER_BASE_URL"

	PARSER_REGISTER_SECRET=$(prompt_secret "Parser register secret (FRAGMENTER_REGISTER_SECRET from parser .env)")
	if [[ -z "$PARSER_REGISTER_SECRET" ]]; then
		die "register secret is required"
	fi

	INCOMING_SSH_PORT=$(prompt_value "Incoming SSH port" "22")
	PRIORITY=$(prompt_value "Priority (higher = preferred)" "100")
	PARALLEL_JOBS=$(prompt_value "Parallel jobs (RTX A2000: keep 1)" "1")
	CLEANUP_DELAY_SECONDS=$(prompt_value "Cleanup delay after upload (seconds)" "60")

	PARSER_SERVER_IP=$(prompt_required "Parser server IP for UFW whitelist (port 8080)")

	echo
	echo "  Summary:"
	echo "    NODE_ID:           $NODE_ID"
	echo "    NODE_PUBLIC_URL:   $NODE_PUBLIC_URL"
	echo "    PARSER_BASE_URL:   $PARSER_BASE_URL"
	echo "    INCOMING_SSH:      ${FRAGMENTER_USER}@${INCOMING_SSH_HOST}:${INCOMING_SSH_PORT}"
	echo "    INSTALL_ROOT:      $INSTALL_ROOT"
	echo "    DATA_ROOT:         $DATA_ROOT"
	echo "    PARSER_SERVER_IP:  $PARSER_SERVER_IP (UFW whitelist)"
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
		local clone_error_log
		clone_error_log=$(mktemp)
		if ! git clone --quiet --depth 1 -b "$BRANCH_NAME" "$credential_url" "$INSTALL_ROOT" 2>"$clone_error_log"; then
			local clone_error
			clone_error=$(cat "$clone_error_log")
			rm -f "$clone_error_log"
			die "git clone failed: $clone_error"
		fi
		rm -f "$clone_error_log"
		(cd "$INSTALL_ROOT" && git remote set-url origin "$GIT_REPO_URL")
	fi
	chmod 700 "$INSTALL_ROOT"
	ok "code at $INSTALL_ROOT"
}

setup_data_dirs() {
	step "Setting up data directories"
	mkdir -p "$DATA_ROOT/processing" "$DATA_ROOT/ready" "$DATA_ROOT/ssh"
	chmod 755 "$DATA_ROOT" "$DATA_ROOT/ready"
	chmod 700 "$DATA_ROOT/ssh"
	ok "data dirs at $DATA_ROOT"
}

create_fragmenter_user() {
	step "Creating user '$FRAGMENTER_USER' for incoming rsync"
	if id -u "$FRAGMENTER_USER" >/dev/null 2>&1; then
		ok "user '$FRAGMENTER_USER' already exists"
	else
		useradd -m -d "/home/$FRAGMENTER_USER" -s /bin/bash "$FRAGMENTER_USER"
		ok "user '$FRAGMENTER_USER' created"
	fi
	mkdir -p "/home/$FRAGMENTER_USER/.ssh"
	chmod 700 "/home/$FRAGMENTER_USER/.ssh"
	touch "/home/$FRAGMENTER_USER/.ssh/authorized_keys"
	chmod 600 "/home/$FRAGMENTER_USER/.ssh/authorized_keys"
	chown -R "$FRAGMENTER_USER:$FRAGMENTER_USER" "/home/$FRAGMENTER_USER/.ssh"

	chown -R "$FRAGMENTER_USER:$FRAGMENTER_USER" "$DATA_ROOT/processing"
	chmod 755 "$DATA_ROOT/processing"
}

prompt_incoming_ssh_key() {
	step "Parser pubkey for incoming rsync"
	echo "  $(color_dim "Paste the public key from parser server: /opt/noctafilm/ssh-fragmenter/id_rsa.pub")"
	echo "  $(color_dim "(starts with 'ssh-ed25519' or 'ssh-rsa', single line)")"
	read -r -p "  pubkey: " PARSER_PUBKEY
	PARSER_PUBKEY=$(sanitize_input "$PARSER_PUBKEY")
	if [[ -z "$PARSER_PUBKEY" ]]; then
		warn "skipped — parser will not be able to push files"
		return
	fi
	local auth_file="/home/$FRAGMENTER_USER/.ssh/authorized_keys"
	if grep -qF "$PARSER_PUBKEY" "$auth_file" 2>/dev/null; then
		ok "key already present in $auth_file"
	else
		echo "$PARSER_PUBKEY" >> "$auth_file"
		ok "key added to $auth_file"
	fi
}

generate_outgoing_ssh_key() {
	step "Outgoing SSH key (for rsync to storage-nodes)"
	local key_path="$DATA_ROOT/ssh/id_rsa"
	if [[ -f "$key_path" ]]; then
		ok "outgoing key already exists at $key_path"
	else
		ssh-keygen -t ed25519 -f "$key_path" -N "" -C "fragmenter-node-$NODE_ID" -q
		chmod 600 "$key_path"
		ok "generated $key_path"
	fi
}

show_outgoing_pubkey() {
	step "ВАЖНО: добавьте этот ключ на каждую storage-ноду"
	echo
	echo "  $(color_blue "Public key:")"
	echo
	echo "  $(cat "$DATA_ROOT/ssh/id_rsa.pub")"
	echo
	echo "  $(color_dim "На storage-ноде (например FR01) выполнить:")"
	echo "  $(color_dim "    echo '<ключ-выше>' >> /root/.ssh/authorized_keys")"
	echo "  $(color_dim "Без этого фрагментер-нода не сможет отправлять контент на storage.")"
	echo
	read -r -p "  Press ENTER когда добавите ключ на все storage-ноды... "
}

setup_ufw_whitelist() {
	step "UFW: opening port 8080 only for parser server"
	if ! command -v ufw >/dev/null 2>&1; then
		apt-get install -y -qq ufw
	fi
	ufw allow ssh >/dev/null
	ufw allow from "$PARSER_SERVER_IP" to any port 8080 proto tcp >/dev/null
	ufw --force enable >/dev/null
	ok "UFW: port 8080 open only for $PARSER_SERVER_IP, ssh allowed"
}

write_env_file() {
	step "Writing .env"
	local timezone
	timezone=$(cat /etc/timezone 2>/dev/null || echo UTC)
	cat >"$INSTALL_ROOT/.env" <<EOF
NODE_ID=$NODE_ID
PARSER_BASE_URL=$PARSER_BASE_URL
PARSER_REGISTER_SECRET=$PARSER_REGISTER_SECRET
PARSER_PUBLIC_URL=$PARSER_PUBLIC_URL
NODE_PUBLIC_URL=$NODE_PUBLIC_URL
INCOMING_SSH_USER=$FRAGMENTER_USER
INCOMING_SSH_HOST=$INCOMING_SSH_HOST
INCOMING_SSH_PORT=$INCOMING_SSH_PORT
INCOMING_SSH_TARGET_PATH=$DATA_ROOT/processing
PRIORITY=$PRIORITY
CLEANUP_DELAY_SECONDS=$CLEANUP_DELAY_SECONDS
PARALLEL_JOBS=$PARALLEL_JOBS
DATA_ROOT_HOST=$DATA_ROOT
TZ=$timezone
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
	if curl -fsS -m 5 "$NODE_PUBLIC_URL/health" >/dev/null 2>&1; then
		ok "$NODE_PUBLIC_URL/health → 200"
	else
		warn "health check failed — check: docker logs fragmenter-node"
	fi
	if docker logs fragmenter-node 2>&1 | grep -q "registered with parser"; then
		ok "registered with parser successfully"
	else
		warn "registration log not found yet — check: docker logs fragmenter-node"
	fi
}

main() {
	require_root
	echo
	echo "  $(color_blue "fragmenter-node installer v$SCRIPT_VERSION")"
	echo

	ensure_packages
	ensure_docker
	ensure_nvidia_driver
	ensure_nvidia_container_toolkit
	prompt_node_config
	prompt_git_credentials
	clone_source
	setup_data_dirs
	create_fragmenter_user
	prompt_incoming_ssh_key
	generate_outgoing_ssh_key
	show_outgoing_pubkey
	setup_ufw_whitelist
	write_env_file
	start_stack
	self_test

	echo
	echo "  $(color_green "Done.")"
	echo "  Logs:    docker logs -f fragmenter-node"
	echo "  Restart: cd $INSTALL_ROOT && docker compose restart"
	echo "  Update:  rerun this installer to pull latest code"
	echo
}

main "$@"
