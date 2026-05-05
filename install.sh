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
	for package in curl ca-certificates git rsync openssl jq parted e2fsprogs util-linux; do
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

disk_has_mounted_partition() {
	local device="$1"
	local mountpoint
	while read -r mountpoint; do
		[[ -n "$mountpoint" ]] && return 0
	done < <(lsblk -nl -o MOUNTPOINTS "$device" 2>/dev/null | tail -n +2)
	return 1
}

disk_filesystem_type() {
	local device="$1"
	local fstype
	fstype=$(blkid -s TYPE -o value "$device" 2>/dev/null || true)
	if [[ -n "$fstype" ]]; then
		printf '%s' "$fstype"
		return
	fi
	while read -r child_fs; do
		if [[ -n "$child_fs" ]]; then
			printf '%s' "$child_fs"
			return
		fi
	done < <(lsblk -nl -o FSTYPE "$device" 2>/dev/null | tail -n +2)
}

disk_first_partition_with_fs() {
	local device="$1"
	while IFS= read -r line; do
		local part_name part_fs
		part_name=$(awk '{print $1}' <<<"$line")
		part_fs=$(awk '{print $2}' <<<"$line")
		if [[ -n "$part_fs" && "$part_name" != "$device" ]]; then
			printf '%s' "$part_name"
			return
		fi
	done < <(lsblk -nlp -o NAME,FSTYPE "$device" 2>/dev/null)
}

partition_for_disk() {
	local device="$1"
	if [[ -e "${device}1" ]]; then
		printf '%s' "${device}1"
	elif [[ -e "${device}p1" ]]; then
		printf '%s' "${device}p1"
	fi
}

setup_storage() {
	step "Detecting storage disk"
	local candidates_file
	candidates_file=$(mktemp)
	local biggest_device=""
	local biggest_size=0
	local biggest_fs=""

	while IFS= read -r line; do
		local name size type
		name=$(awk '{print $1}' <<<"$line")
		size=$(awk '{print $2}' <<<"$line")
		type=$(awk '{print $3}' <<<"$line")
		[[ "$type" != "disk" ]] && continue
		[[ "$name" == /dev/sr* ]] && continue
		[[ "$size" -lt 50000000000 ]] && continue
		if disk_has_mounted_partition "$name"; then
			continue
		fi
		local fstype
		fstype=$(disk_filesystem_type "$name")
		echo "$name|$size|$fstype" >> "$candidates_file"
	done < <(lsblk -bnlp -o NAME,SIZE,TYPE 2>/dev/null)

	if [[ ! -s "$candidates_file" ]]; then
		rm -f "$candidates_file"
		die "no unmounted disk found (need a separate data disk attached to this VPS)"
	fi

	while IFS='|' read -r device size fstype; do
		if (( size > biggest_size )); then
			biggest_device="$device"
			biggest_size="$size"
			biggest_fs="$fstype"
		fi
	done < "$candidates_file"
	rm -f "$candidates_file"

	local size_h
	size_h=$(numfmt --to=iec --suffix=B "$biggest_size" 2>/dev/null || echo "$biggest_size")
	echo "  Selected disk: $biggest_device ($size_h)"

	STORAGE_HOST_PATH="/mnt/storage"
	mkdir -p "$STORAGE_HOST_PATH"

	local target_partition=""
	local target_fs=""

	if [[ -n "$biggest_fs" ]]; then
		case "$biggest_fs" in
			ext4|ext3|xfs|btrfs)
				target_partition=$(disk_first_partition_with_fs "$biggest_device")
				if [[ -z "$target_partition" ]]; then
					target_partition="$biggest_device"
				fi
				target_fs=$(blkid -s TYPE -o value "$target_partition" 2>/dev/null)
				echo "  Disk has existing $target_fs filesystem on $target_partition — mounting as-is"
				;;
			*)
				die "disk $biggest_device has unsupported filesystem '$biggest_fs' — please wipe it manually first or use a clean disk"
				;;
		esac
	else
		echo "  Disk is empty — creating GPT partition + ext4"
		parted -s "$biggest_device" mklabel gpt
		parted -s "$biggest_device" mkpart primary ext4 0% 100%
		sleep 2
		partprobe "$biggest_device" 2>/dev/null || true
		udevadm settle 2>/dev/null || true
		sleep 1
		target_partition=$(partition_for_disk "$biggest_device")
		if [[ -z "$target_partition" ]]; then
			die "partition not found after parted on $biggest_device"
		fi
		mkfs.ext4 -L noctafilm-storage -F "$target_partition" >/dev/null
		target_fs="ext4"
	fi

	if ! mountpoint -q "$STORAGE_HOST_PATH"; then
		mount "$target_partition" "$STORAGE_HOST_PATH"
	fi
	chmod 755 "$STORAGE_HOST_PATH"

	local uuid
	uuid=$(blkid -s UUID -o value "$target_partition" 2>/dev/null)
	if [[ -z "$uuid" ]]; then
		die "could not read UUID for $target_partition"
	fi
	if ! grep -q "$uuid" /etc/fstab; then
		echo "UUID=$uuid  $STORAGE_HOST_PATH  $target_fs  defaults,noatime  0 2" >> /etc/fstab
	fi

	local free_h
	free_h=$(df -B1 --output=avail "$STORAGE_HOST_PATH" | tail -n 1 | xargs numfmt --to=iec --suffix=B 2>/dev/null || echo "?")
	ok "mounted $target_partition at $STORAGE_HOST_PATH ($target_fs, $free_h free)"
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
	setup_storage
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
