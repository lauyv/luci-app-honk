#!/bin/sh
# shellcheck shell=busybox
# Shared by the rpcd plugin and detached worker. No client-controlled paths/commands.
RUN=/tmp/honk-panel
INIT=/etc/init.d/honk
BIN=/usr/bin/honk-core
MAX_SIZE=65536

prepare() {
	umask 077
	[ "$(id -u)" = 0 ] || { DETAILS='面板后端必须以 root 身份运行'; return 1; }
	[ ! -L "$RUN" ] || { DETAILS="$RUN 是符号链接"; return 1; }
	mkdir -p "$RUN" || { DETAILS="无法创建 $RUN"; return 1; }
	[ -d "$RUN" ] && [ -O "$RUN" ] || {
		DETAILS="$RUN 必须是 root 所有的目录"; return 1;
	}
	chmod 700 "$RUN" || { DETAILS="无法设置 $RUN 的权限"; return 1; }
}

# Check jshn's exit code before evaluating its shell representation. Passing a
# filename also avoids Linux's per-argument size limit for release metadata.
load_json_file() {
	local parsed
	parsed=$(jshn -R "$1" 2>/dev/null) || return 1
	eval "$parsed"
}

read_request() {
	local limit="$1" request result
	request=$(mktemp "$RUN/request.XXXXXX") || return 1
	head -c "$((limit + 1))" > "$request"
	if [ "$(wc -c < "$request")" -gt "$limit" ]; then rm -f "$request"; return 1; fi
	load_json_file "$request"
	result=$?
	rm -f "$request"
	return "$result"
}

load_settings() {
	CONFIG=$(uci -q get honk.main.conffile)
	[ -n "$CONFIG" ] || CONFIG=/etc/honk/config.dae
	SERVICE_USER=root
}

settings() {
	load_settings
	# Only the dedicated configuration tree is writable through this RPC.
	case "$CONFIG" in /etc/honk/*.dae) ;; *) ERROR=config_path_invalid; return 1;; esac
	[ "$(readlink -f "$CONFIG")" = "$CONFIG" ] && [ ! -L "$CONFIG" ] || {
		ERROR=config_symlink; return 1;
	}
	[ ! -e "$CONFIG" ] || [ -f "$CONFIG" ] || { ERROR=config_not_regular; return 1; }
}

action_settings() {
	# Stopping a running service must work even if its configuration is broken.
	if [ "$1" = stop ]; then
		[ -x "$INIT" ] || { ERROR=service_missing; return 1; }
	else
		settings
	fi
}

lock() {
	# The worker inherits this descriptor; the kernel releases it on process exit.
	# Never unlink the lock file: concurrent callers must lock the same inode.
	exec 9> "$RUN/operation.lock"
	flock -n 9 && return 0
	exec 9>&-
	return 1
}

unlock() {
	exec 9>&-
}

recover_job() {
	local state=''
	# Called with the lock held, so no worker can still own these temporary files.
	if json_load "$(cat "$RUN/job.json" 2>/dev/null)" 2>/dev/null; then
		json_get_var state state
		json_get_var JOB_ID id
		case "$state" in queued|running) job error operation_interrupted;; esac
	fi
	rm -f "$RUN/service.log" "$RUN/save.conf"
}

job() {
	json_init
	json_add_string id "${JOB_ID:-}"
	json_add_string revision "${SAVE_REVISION:-}"
	json_add_string state "$1"
	json_add_string code "$2"
	json_add_string argument "${4:-${ERROR_ARG:-}}"
	json_add_string details "${3:-}"
	json_add_int updated "$(date +%s)"
	json_dump > "$RUN/job.new" && mv -f "$RUN/job.new" "$RUN/job.json"
}

running_pid() {
	ubus call service list '{"name":"honk"}' 2>/dev/null |
		jsonfilter -e '@["honk"].instances.*.pid' 2>/dev/null | head -n 1
}

service_snapshot() {
	local state pids flags pid
	SERVICE_PID=''
	state=$(ubus call service list '{"name":"honk"}') || { ERROR=service_status_failed; return 1; }
	json_load "$state" || { ERROR=service_status_failed; return 1; }
	pids=$(jsonfilter -s "$state" -e '@.honk.instances.*.pid')
	flags=$(jsonfilter -s "$state" -e '@.honk.instances.*.running')
	case "$pids:$flags" in :*true*) ERROR=service_status_failed; return 1;; esac
	for pid in $pids; do
		case "$pid" in ''|*[!0-9]*) ERROR=service_status_failed; return 1;; esac
		if kill -0 "$pid" 2>/dev/null; then SERVICE_PID="$pid"; break; fi
	done
}

healthy() {
	# Require a stable live PID across three observations; a respawn is a failure.
	local first current _attempt
	sleep 1
	first=$(running_pid)
	[ -n "$first" ] && kill -0 "$first" 2>/dev/null || return 1
	for _attempt in 1 2; do
		sleep 1
		current=$(running_pid)
		[ "$current" = "$first" ] && kill -0 "$current" 2>/dev/null || return 1
	done
}

# Run a command with a bounded lifetime without requiring coreutils-timeout.
run_timeout() (
	# Service scripts may spawn long-lived processes; do not pass our lock to them.
	exec 9>&-
	trap - EXIT HUP INT TERM
	limit="$1"
	shift
	command_pid=''
	watchdog_pid=''
	# Called by the EXIT trap below, including timeout and signal exits.
	# shellcheck disable=SC2329
	cleanup_timeout() {
		[ -z "$watchdog_pid" ] || kill "$watchdog_pid" 2>/dev/null
		[ -z "$command_pid" ] || kill -KILL "$command_pid" 2>/dev/null
		[ -z "$watchdog_pid" ] || wait "$watchdog_pid" 2>/dev/null
	}
	trap cleanup_timeout EXIT
	trap 'exit 143' HUP INT TERM
	"$@" &
	command_pid=$!
	(
		trap - EXIT HUP INT TERM
		elapsed=0
		while kill -0 "$command_pid" 2>/dev/null; do
			sleep 1
			elapsed=$((elapsed + 1))
			if [ "$elapsed" -eq "$limit" ]; then
				kill -TERM "$command_pid" 2>/dev/null || exit 0
			elif [ "$elapsed" -ge "$((limit + 2))" ]; then
				kill -KILL "$command_pid" 2>/dev/null
				exit 0
			fi
		done
	) &
	watchdog_pid=$!
	wait "$command_pid"
	result=$?
	command_pid=''
	exit "$result"
)

service_do() {
	run_timeout 45 "$INIT" "$1" > "$RUN/service.log" 2>&1
}

stop_service() {
	local state pids pid attempt alive running
	service_do stop || { ERROR=stop_failed; DETAILS=$(head -c 8192 "$RUN/service.log"); return 1; }
	for attempt in $(seq 0 35); do
		# Fail closed if procd cannot confirm the state; check every instance.
		state=$(ubus call service list '{"name":"honk"}') || { ERROR=service_status_failed; return 1; }
		json_load "$state" || { ERROR=service_status_failed; return 1; }
		command -v jsonfilter >/dev/null || { ERROR=service_status_failed; return 1; }
		pids=$(jsonfilter -s "$state" -e '@["honk"].instances.*.pid')
		running=$(jsonfilter -s "$state" -e '@["honk"].instances.*.running')
		case "$pids:$running" in :*true*) ERROR=service_status_failed; return 1;; esac
		alive=0
		for pid in $pids; do
			case "$pid" in ''|*[!0-9]*) ERROR=service_status_failed; return 1;; esac
			if kill -0 "$pid" 2>/dev/null; then alive=1; fi
		done
		[ "$alive" = 0 ] && return 0
		[ "$attempt" -lt 35 ] || { ERROR=stop_failed; DETAILS='等待服务进程退出超时'; return 1; }
		sleep 1
	done
}

config_revision() {
	# Includes are read by honk relative to the entry directory. Track all dae
	# files here too so external edits during staging invalidate the save.
	{ printf '%s\n' "$CONFIG"; if [ -f "$CONFIG" ]; then sha256sum "$CONFIG"; else printf 'missing\n'; fi
	  find /etc/honk -type f -name '*.dae' -exec sha256sum '{}' \; | sort; } |
		sha256sum | cut -d ' ' -f 1
}

stage_config() {
	local tmp
	[ ! -L "$CONFIG" ] && { [ ! -e "$CONFIG" ] || [ -f "$CONFIG" ]; } || return 1
	tmp=$(mktemp "${CONFIG}.panel.XXXXXX") || return 1
	if [ -f "$CONFIG" ]; then
		cp -p "$CONFIG" "$tmp" || { rm -f "$tmp"; return 1; }
	else
		if ! chown "$SERVICE_USER" "$tmp" || ! chmod 600 "$tmp"; then
			rm -f "$tmp"
			return 1
		fi
	fi
	printf '%s' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
	printf '%s' "$tmp"
}

save_config() {
	local content="$1" expected="$2" original_config="$CONFIG" original_user="$SERVICE_USER" pid
	SAVE_REVISION=''
	[ -n "$expected" ] && [ "$expected" = "$(config_revision)" ] || {
		ERROR=config_changed; return 1;
	}
	# Keep the candidate beside the destination for an atomic rename. The worker
	# owns this path until commit and removes it on failure or interruption.
	SAVE_CANDIDATE=$(stage_config "$content") || { ERROR=config_save_failed; return 1; }
	# SSH and UCI edits do not take the panel lock. Recheck after staging.
	if ! settings || [ "$CONFIG" != "$original_config" ] ||
		[ "$SERVICE_USER" != "$original_user" ] ||
		[ "$expected" != "$(config_revision)" ]; then
		rm -f "$SAVE_CANDIDATE"; SAVE_CANDIDATE=''
		ERROR=config_changed; return 1
	fi
	if [ -f "$CONFIG" ] && cmp -s "$SAVE_CANDIDATE" "$CONFIG"; then
		rm -f "$SAVE_CANDIDATE"; SAVE_CANDIDATE=''
		SAVE_REVISION="$expected"
		SAVE_CODE=config_unchanged
		return 0
	fi
	service_snapshot || return 1
	pid="$SERVICE_PID"
	mv -f "$SAVE_CANDIDATE" "$CONFIG" || { ERROR=config_save_failed; return 1; }
	SAVE_CANDIDATE=''
	SAVE_REVISION=$(config_revision)
	SAVE_CODE=config_saved
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		run_service reload apply_failed || return 1;
		SAVE_CODE=config_applied
	fi
}

start_service() {
	run_service "$1" "$2"
}

run_service() {
	if service_do "$1" && healthy; then
		return 0
	fi
	DETAILS=$(head -c 8192 "$RUN/service.log" 2>/dev/null)
	ERROR="$2"
	return 1
}

set_autostart() {
	local init_action=disable
	[ "$1" != 1 ] || init_action=enable
	service_do "$init_action" || { ERROR=autostart_failed; return 1; }
}

worker() {
	local action="$1" expected="${2:-}" content
	JOB_ID="${3:-}"
	SAVE_REVISION=''
	SAVE_CANDIDATE=''
	# Refuse direct invocation without the descriptor inherited from rpcd.
	flock -n 9 || return 1
	trap 'worker_exit' EXIT
	trap 'job error operation_interrupted; exit 1' HUP INT TERM
	job running operation_running '' "$action"
	action_settings "$action" || { job error "$ERROR"; return 1; }
	case "$action" in
		save)
			content=$(cat "$RUN/save.conf"; printf '.')
			content=${content%.}
			save_config "$content" "$expected" || { job error "$ERROR" "$DETAILS"; return 1; }
			job success "$SAVE_CODE";;
		start)
			start_service "$action" start_failed || { job error "$ERROR" "$DETAILS"; return 1; }
			job success 'service_running';;
		stop)
			stop_service || { job error "$ERROR" "$DETAILS"; return 1; }
			job success 'service_stopped';;
		*) job error 'action_unknown'; return 1;;
	esac
}

worker_exit() {
	[ -z "${SAVE_CANDIDATE:-}" ] || rm -f "$SAVE_CANDIDATE"
	rm -f "$RUN/service.log" "$RUN/save.conf"
	unlock
}

environment_report() {
	local kernel major minor notes=''
	kernel=$(uname -r)
	major=${kernel%%.*}; minor=${kernel#*.}; minor=${minor%%.*}
	if [ "$major" -lt 6 ] || { [ "$major" = 6 ] && [ "$minor" -lt 12 ]; }; then notes='需要 Linux 6.12+；'; fi
	[ -r /sys/kernel/btf/vmlinux ] || [ -r /usr/lib/debug/boot/vmlinux ] || notes="${notes}缺少内核 BTF；"
	[ -r /sys/fs/cgroup/cgroup.controllers ] || notes="${notes}需要 cgroup v2；"
	printf '%s\n' "${notes:-Linux $kernel · BTF / cgroup v2 可用}"
}
