#!/bin/sh
# shellcheck shell=busybox
# Geo files live directly in global.data_dir; the init script sets no asset env.
GEOROOT=/etc/honk
GEO_MAX_SIZE=67108864
GEO_DEFAULT_SITE=https://gh-proxy.com/https://github.com/lauyv/rdat/raw/rel/geosite.dat
GEO_DEFAULT_IP=https://gh-proxy.com/https://github.com/lauyv/cnip/raw/rel/chnroutes.dat

geo_config_url() {
	case "$1" in
		geosite) uci -q get honk.panel.geosite_url || printf '%s\n' "$GEO_DEFAULT_SITE";;
		geoip) uci -q get honk.panel.geoip_url || printf '%s\n' "$GEO_DEFAULT_IP";;
		*) return 1;;
	esac
}

valid_geo_url() {
	[ "${#1}" -le 2048 ] && printf '%s\n' "$1" |
		grep -Eq '^https://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?(/[^[:space:]#]*)?$'
}

geo_check_file() {
	local file="$1" size magic
	[ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || { ERROR=geo_invalid; return 1; }
	size=$(wc -c < "$file")
	[ "$size" -gt 1 ] && [ "$size" -le "$GEO_MAX_SIZE" ] || { ERROR=geo_invalid; return 1; }
	# Basic protobuf field check, not full semantic validation by the engine.
	magic=$(od -An -tx1 -N1 "$file" | tr -d ' \n')
	[ "$magic" = 0a ] || { ERROR=geo_invalid; return 1; }
}

geo_write_settings() {
	local delta result=0
	delta=$(mktemp -d "$RUN/geo-uci.XXXXXX") || return 1
	# Private deltas prevent a failed transaction from changing shared saved state.
	if uci -t "$delta" set honk.panel=panel &&
		uci -t "$delta" set honk.panel.geosite_url="$1" &&
		uci -t "$delta" set honk.panel.geoip_url="$2" &&
		uci -t "$delta" set honk.panel.geo_updated="$3"; then
		uci -t "$delta" commit honk || result=1
	else
		result=1
	fi
	rm -rf "$delta"
	return "$result"
}

geo_settings_revision() {
	uci -q export honk | sha256sum | cut -d ' ' -f 1
}

geo_prepare_root() {
	[ ! -L "$GEOROOT" ] || { ERROR=geo_path_invalid; return 1; }
	mkdir -p "$GEOROOT" || { ERROR=geo_write_failed; return 1; }
	[ "$(readlink -f "$GEOROOT")" = "$GEOROOT" ] && [ -O "$GEOROOT" ] || { ERROR=geo_path_invalid; return 1; }
}

geo_check_destinations() {
	local name file
	for name in geosite.dat geoip.dat; do
		file="$GEOROOT/$name"
		[ ! -L "$file" ] && { [ ! -e "$file" ] || { [ -f "$file" ] && [ -O "$file" ]; }; } || {
			ERROR=geo_path_invalid; return 1;
		}
	done
}

geo_data_revision() {
	local name
	for name in geosite.dat geoip.dat; do
		if [ -f "$GEOROOT/$name" ]; then sha256sum "$GEOROOT/$name"; else printf 'missing %s\n' "$name"; fi
	done | sha256sum | cut -d ' ' -f 1
}

geo_restore_files() {
	local name result=0
	for name in geosite.dat geoip.dat; do
		[ -f "$GEO_STAGE/changed/$name" ] || continue
		# Refuse an externally replaced symlink or special file during recovery.
		if ! geo_check_destinations; then result=1; continue; fi
		if [ -f "$GEO_STAGE/backup/$name" ]; then
			# Keep the backup for another recovery attempt if only one restore succeeds.
			cp -p "$GEO_STAGE/backup/$name" "$GEO_STAGE/restore" &&
				mv -f "$GEO_STAGE/restore" "$GEOROOT/$name" || result=1
		else
			rm -f "$GEOROOT/$name" || result=1
		fi
	done
	return "$result"
}

geo_replace_files() {
	local name
	# Back up every file to be replaced before publishing either download.
	for name in geosite.dat geoip.dat; do
		[ -f "$GEO_STAGE/new/$name" ] || continue
		if [ -f "$GEOROOT/$name" ]; then
			cp -p "$GEOROOT/$name" "$GEO_STAGE/backup/$name" || return 1
		fi
	done
	GEO_KEEP=1
	for name in geosite.dat geoip.dat; do
		[ -f "$GEO_STAGE/new/$name" ] || continue
		: > "$GEO_STAGE/changed/$name" || return 1
		mv -f "$GEO_STAGE/new/$name" "$GEOROOT/$name" || return 1
	done
}

apply_geo() {
	local site_url ip_url old_site old_ip old_updated signature data_signature config_signature
	local name source_url was_running=0 failure original_error settings_changed=0
	load_json_file "$RUN/geo-request.json" || { ERROR=request_invalid; return 1; }
	json_get_var site_url geosite_url
	json_get_var ip_url geoip_url
	[ -n "$site_url$ip_url" ] || { ERROR=geo_empty; return 1; }
	geo_prepare_root && geo_check_destinations || return 1
	old_site=$(geo_config_url geosite)
	old_ip=$(geo_config_url geoip)
	old_updated=$(uci -q get honk.panel.geo_updated || true)
	signature=$(geo_settings_revision)
	data_signature=$(geo_data_revision)
	GEO_STAGE=$(mktemp -d "$GEOROOT/.geo-update.XXXXXX") || { ERROR=geo_write_failed; return 1; }
	GEO_KEEP=0
	mkdir "$GEO_STAGE/new" "$GEO_STAGE/backup" "$GEO_STAGE/changed" || { ERROR=geo_write_failed; return 1; }
	for name in geosite.dat geoip.dat; do
		case "$name" in geosite.dat) source_url="$site_url";; geoip.dat) source_url="$ip_url";; esac
		[ -n "$source_url" ] || continue
		valid_geo_url "$source_url" || { ERROR=geo_url_invalid; return 1; }
		job running operation_running "下载 $name" geo
		download_file "$source_url" "$GEO_STAGE/new/$name" "$GEO_MAX_SIZE" || return 1
		geo_check_file "$GEO_STAGE/new/$name" || return 1
		chmod 600 "$GEO_STAGE/new/$name" || { ERROR=geo_write_failed; return 1; }
	done
	geo_check_destinations || return 1
	[ "$signature" = "$(geo_settings_revision)" ] && [ "$data_signature" = "$(geo_data_revision)" ] || {
		ERROR=geo_settings_changed; return 1;
	}
	service_snapshot || return 1
	if [ -n "$SERVICE_PID" ] && kill -0 "$SERVICE_PID" 2>/dev/null; then was_running=1; fi
	if [ "$was_running" = 1 ]; then
		settings || return 1
		config_signature=$(config_revision)
		check_config "$CONFIG" || return 1
		[ "$config_signature" = "$(config_revision)" ] || { ERROR=geo_settings_changed; return 1; }
		stop_service || return 1
	fi
	# Settings or data may also change while the service is stopping.
	if ! geo_check_destinations || [ "$signature" != "$(geo_settings_revision)" ] || [ "$data_signature" != "$(geo_data_revision)" ]; then
		if [ "$was_running" = 1 ]; then run_service start geo_recovery_failed || return 1; fi
		ERROR=geo_settings_changed; return 1
	fi
	original_error=''
	if ! geo_replace_files; then
		original_error=geo_write_failed
	else
		settings_changed=1
		if ! geo_write_settings "$site_url" "$ip_url" "$(date +%s)"; then
			original_error=geo_write_failed
		elif [ "$was_running" = 1 ] && ! run_service start geo_restart_failed; then
			original_error=geo_restored
		fi
	fi
	if [ -n "$original_error" ]; then
		failure="${DETAILS:-}"
		if [ "$was_running" = 1 ]; then
			stop_service || { ERROR=geo_recovery_failed; DETAILS="$GEO_STAGE"; return 1; }
		fi
		if ! geo_restore_files || { [ "$settings_changed" = 1 ] && ! geo_write_settings "$old_site" "$old_ip" "$old_updated"; }; then
			GEO_KEEP=1; ERROR=geo_recovery_failed; DETAILS="备份目录：$GEO_STAGE"; return 1
		fi
		GEO_KEEP=0
		if [ "$was_running" = 1 ]; then run_service start geo_recovery_failed || return 1; fi
		ERROR="$original_error"; DETAILS="$failure"; return 1
	fi
	GEO_KEEP=0
	DETAILS="数据目录：$GEOROOT"
}
