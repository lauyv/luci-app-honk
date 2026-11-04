#!/bin/sh
# shellcheck shell=busybox
# Official release metadata always comes directly from api.github.com. A proxy
# prefixes asset URLs only; expected archive hashes come from the direct API.
UPSTREAM=daeuniverse/honk

valid_tag() {
	[ "${#1}" -le 64 ] && printf '%s\n' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$'
}

core_target() {
	case "$(uname -m)" in
		aarch64|arm64) echo aarch64-unknown-linux-musl;;
		x86_64) echo x86_64-unknown-linux-musl;;
		*) return 1;;
	esac
}

valid_https_base() {
	# A host plus optional port/path, without credentials, query or fragment.
	[ "${#1}" -le 512 ] && printf '%s\n' "$1" |
		grep -Eq '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
}

valid_preferences() {
	[ -z "$1" ] || valid_https_base "$1"
}

core_proxy_prefix() {
	# An explicitly empty value means direct; only a missing option uses default.
	uci -q get honk.panel.proxy_prefix || printf '%s\n' 'https://gh-proxy.com'
}

asset_url() {
	local prefix
	case "$1" in "https://github.com/$UPSTREAM/releases/download/"*) ;; *) return 1;; esac
	prefix=$(core_proxy_prefix)
	if [ -n "$prefix" ]; then
		valid_https_base "$prefix" || return 1
		printf '%s/%s\n' "${prefix%/}" "$1"
	else
		printf '%s\n' "$1"
	fi
}

# Explicit byte and time limits cover APIs, manifests and compressed archives.
download_file() {
	local url="$1" output="$2" limit="$3"
	curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--connect-timeout 10 --max-time 120 --retry 2 --max-filesize "$limit" \
		--user-agent 'luci-app-honk' --output "$output" "$url" > "$RUN/download.log" 2>&1 || {
		ERROR=download_failed; DETAILS=$(head -c 4096 "$RUN/download.log"); return 1;
	}
	[ "$(wc -c < "$output")" -le "$limit" ] || { ERROR=download_too_large; return 1; }
}

refresh_releases() {
	local target metadata selected names name tag type
	target=$(core_target) || { ERROR=architecture_unsupported; return 1; }
	metadata="$RUN/releases.raw"
	selected="$RUN/releases.selected"
	download_file "https://api.github.com/repos/$UPSTREAM/releases?per_page=10" "$metadata" 16777216 || return 1
	# Filter the large API document in a separate process. Loading release
	# bodies into jshn exports them all into the environment and can exceed
	# Linux's exec limits before even a small helper can run.
	type=$(jsonfilter -i "$metadata" -t '@')
	[ "$type" = array ] || { ERROR=releases_invalid; return 1; }
	names=$(jsonfilter -i "$metadata" -e '@[@.draft=false].assets[*].name' 2>/dev/null)
	: > "$selected"
	printf '%s\n' "$names" | while IFS= read -r name; do
		case "$name" in
			"honk-core-v"*"-$target-full.tar.gz")
				tag=${name#honk-core-}; tag=${tag%-$target-full.tar.gz}
				valid_tag "$tag" && printf '%s\n' "$tag";;
		esac
	done > "$selected"
	json_init
	json_add_array versions
	while IFS= read -r tag; do json_add_string '' "$tag"; done < "$selected"
	json_close_array
	json_dump > "$RUN/releases.new" && mv -f "$RUN/releases.new" "$RUN/releases.json"
	rm -f "$metadata" "$selected"
}

# Select one exact official full/musl asset and SHA256SUMS from a fresh release.
select_release() {
	local tag="$1" target metadata count sums_count actual_tag draft
	valid_tag "$tag" || { ERROR=version_invalid; return 1; }
	target=$(core_target) || { ERROR=architecture_unsupported; return 1; }
	ASSET_NAME="honk-core-$tag-$target-full.tar.gz"
	metadata="$CORE_STAGE/release.json"
	download_file "https://api.github.com/repos/$UPSTREAM/releases/tags/$tag" "$metadata" 2097152 || return 1
	actual_tag=$(jsonfilter -i "$metadata" -e '@.tag_name')
	draft=$(jsonfilter -i "$metadata" -e '@.draft')
	[ "$actual_tag" = "$tag" ] && [ "$draft" = false ] || { ERROR=releases_invalid; return 1; }
	count=$(jsonfilter -i "$metadata" -e "@.assets[@.name=\"$ASSET_NAME\"].name" | wc -l)
	sums_count=$(jsonfilter -i "$metadata" -e '@.assets[@.name="SHA256SUMS"].name' | wc -l)
	[ "$count" -eq 1 ] && [ "$sums_count" -eq 1 ] || { ERROR=asset_missing; return 1; }
	ASSET_SOURCE=$(jsonfilter -i "$metadata" -e "@.assets[@.name=\"$ASSET_NAME\"].browser_download_url")
	ASSET_DIGEST=$(jsonfilter -i "$metadata" -e "@.assets[@.name=\"$ASSET_NAME\"].digest")
	SUMS_SOURCE=$(jsonfilter -i "$metadata" -e '@.assets[@.name="SHA256SUMS"].browser_download_url')
	[ "$ASSET_SOURCE" = "https://github.com/$UPSTREAM/releases/download/$tag/$ASSET_NAME" ] &&
		[ "$SUMS_SOURCE" = "https://github.com/$UPSTREAM/releases/download/$tag/SHA256SUMS" ] || {
		ERROR=asset_missing; return 1;
	}
	printf '%s\n' "$ASSET_DIGEST" | grep -Eq '^sha256:[a-f0-9]{64}$' || { ERROR=digest_missing; return 1; }
}

verify_archive() {
	local archive="$1" sums="$2" digest expected
	digest=$(sha256sum "$archive" | cut -d ' ' -f 1)
	[ "sha256:$digest" = "$ASSET_DIGEST" ] || { ERROR=digest_mismatch; return 1; }
	expected=$(awk -v name="$ASSET_NAME" '$2 == name || $2 == "*" name {print $1}' "$sums")
	[ "$expected" = "$digest" ] || { ERROR=digest_mismatch; return 1; }
}

extract_binary() {
	local archive="$1" output="$2" member listing type magic machine
	member="${ASSET_NAME%.tar.gz}/honk-core"
	listing=$(run_timeout 20 tar -tzf "$archive") || { ERROR=archive_invalid; return 1; }
	[ "$(printf '%s\n' "$listing" | grep -cxF "$member")" = 1 ] || { ERROR=archive_invalid; return 1; }
	type=$(run_timeout 10 tar -tvzf "$archive" "$member" | head -c 1)
	[ "$type" = '-' ] || { ERROR=archive_invalid; return 1; }
	# Extract exactly one regular member to stdout; archive paths are never
	# applied to the filesystem. Bound the uncompressed output too.
	(ulimit -f 131072; run_timeout 30 tar -xOzf "$archive" "$member" > "$output") 2> "$RUN/download.log" || {
		ERROR=archive_invalid; return 1;
	}
	[ "$(wc -c < "$output")" -le 134217728 ] || { ERROR=download_too_large; return 1; }
	magic=$(od -An -tx1 -N6 "$output" | tr -d ' \n')
	machine=$(od -An -tx1 -j18 -N2 "$output" | tr -d ' \n')
	[ "$magic" = 7f454c460201 ] || { ERROR=binary_invalid; return 1; }
	case "$(core_target):$machine" in
		aarch64-unknown-linux-musl:b700|x86_64-unknown-linux-musl:3e00) ;;
		*) ERROR=binary_invalid; return 1;;
	esac
	chmod 700 "$output"
}

prepare_core_dir() {
	[ ! -L "$COREDIR" ] || { ERROR=core_path_unsafe; return 1; }
	mkdir -p "$COREDIR" || { ERROR=core_write_failed; return 1; }
	[ "$(readlink -f "$COREDIR")" = "$COREDIR" ] && [ -O "$COREDIR" ] || { ERROR=core_path_unsafe; return 1; }
	[ ! -L "$BIN" ] && [ ! -L "$BACKUP" ] || { ERROR=core_path_unsafe; return 1; }
	[ ! -e "$BIN" ] || [ -f "$BIN" ] || { ERROR=core_path_unsafe; return 1; }
	[ ! -e "$BACKUP" ] || [ -f "$BACKUP" ] || { ERROR=core_path_unsafe; return 1; }
	chmod 755 "$COREDIR"
}

# Install and rollback use the same locked transaction. The old core is kept
# intact until the candidate has validated the existing configuration.
activate_core() {
	local candidate="$1" pid was_running=0 prior=0 failed_details
	settings || return 1
	service_snapshot || return 1
	pid="$SERVICE_PID"
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then was_running=1; fi
	# First installation stays stopped and must allow fixing an invalid config
	# afterwards. Existing cores are replaced only after config validation.
	if [ -x "$BIN" ] || [ "$was_running" = 1 ]; then
		check_config "$CONFIG" "$candidate" || return 1
	fi
	[ ! -f "$BIN" ] || { cp -p "$BIN" "$CORE_STAGE/prior" || { ERROR=core_write_failed; return 1; }; prior=1; }
	if [ "$was_running" = 1 ]; then stop_service || return 1; fi
	# Make the backup durable before publishing the new executable.
	if [ "$prior" = 1 ]; then
		cp -p "$CORE_STAGE/prior" "$CORE_STAGE/backup" && mv -f "$CORE_STAGE/backup" "$BACKUP" || {
			if [ "$was_running" = 1 ]; then run_service start core_recovery_failed || return 1; fi
			ERROR=core_write_failed; return 1;
		}
	fi
	if ! mv -f "$candidate" "$BIN"; then
		if [ "$was_running" = 1 ]; then run_service start core_recovery_failed || return 1; fi
		ERROR=core_write_failed; return 1
	fi
	if [ "$was_running" = 1 ] && ! run_service start start_failed; then
		failed_details="$DETAILS"
		# Never replace a second time until procd confirms the new process quit.
		if ! stop_service; then ERROR=core_recovery_failed; return 1; fi
		if [ "$prior" = 1 ]; then
			mv -f "$CORE_STAGE/prior" "$BIN" || { ERROR=core_recovery_failed; return 1; }
			if ! run_service start start_failed; then ERROR=core_recovery_failed; return 1; fi
			ERROR=core_restored
		else ERROR=start_failed; fi
		DETAILS="$failed_details"
		return 1
	fi
	DETAILS=$(run_timeout 3 "$BIN" --version 2>/dev/null)
	return 0
}

install_core() {
	local tag="$1" url sums_url version version_tag
	prepare_core_dir || return 1
	CORE_STAGE=$(mktemp -d "$COREDIR/.update.XXXXXX") || { ERROR=core_write_failed; return 1; }
	select_release "$tag" || return 1
	url=$(asset_url "$ASSET_SOURCE") && sums_url=$(asset_url "$SUMS_SOURCE") || { ERROR=preferences_invalid; return 1; }
	job running operation_running '下载官方 musl full 核心并校验' install
	download_file "$url" "$CORE_STAGE/core.tar.gz" 134217728 &&
		download_file "$sums_url" "$CORE_STAGE/SHA256SUMS" 1048576 || return 1
	verify_archive "$CORE_STAGE/core.tar.gz" "$CORE_STAGE/SHA256SUMS" || return 1
	extract_binary "$CORE_STAGE/core.tar.gz" "$CORE_STAGE/candidate" || return 1
	version=$(run_timeout 3 "$CORE_STAGE/candidate" --version 2>/dev/null) || { ERROR=binary_invalid; return 1; }
	version_tag=$(printf '%s\n' "$version" | awk '{print $NF}')
	[ "$version_tag" = "$tag" ] || {
		ERROR=version_mismatch; return 1;
	}
	job running operation_running '校验现有配置并安装；运行中的服务会短暂中断' install
	activate_core "$CORE_STAGE/candidate"
}

rollback_core() {
	prepare_core_dir || return 1
	[ -x "$BACKUP" ] || { ERROR=rollback_missing; return 1; }
	CORE_STAGE=$(mktemp -d "$COREDIR/.update.XXXXXX") || { ERROR=core_write_failed; return 1; }
	cp -p "$BACKUP" "$CORE_STAGE/candidate" || { ERROR=core_write_failed; return 1; }
	activate_core "$CORE_STAGE/candidate"
}

environment_report() {
	local kernel major minor notes=''
	kernel=$(uname -r)
	major=${kernel%%.*}; minor=${kernel#*.}; minor=${minor%%.*}
	if [ "$major" -lt 6 ] || { [ "$major" = 6 ] && [ "$minor" -lt 12 ]; }; then notes='需要 Linux 6.12+；'; fi
	[ -r /sys/kernel/btf/vmlinux ] || [ -r /usr/lib/debug/boot/vmlinux ] || notes="${notes}缺少内核 BTF；"
	[ -r /sys/fs/cgroup/cgroup.controllers ] || notes="${notes}需要 cgroup v2；"
	core_target >/dev/null || notes="${notes}不支持此架构；"
	printf '%s\n' "${notes:-Linux $kernel · BTF / cgroup v2 可用}"
}
