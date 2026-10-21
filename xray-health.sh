#!/bin/sh
# 由 procd 管理的本机检查；不发送公网探测，不负责修复接管规则。

XRAY_BIN=${XRAY_BIN:-/usr/bin/xray}
GUARD_FILE=${GUARD_FILE:-/usr/share/nftables.d/ruleset-pre/xray-guard.nft}
STATE_DIR=${STATE_DIR:-/var/run/xray-tproxy}
PROC_ROOT=${PROC_ROOT:-/proc}
LAN_IFACE=br-lan
TPROXY_PORT=12345
DNS_PORT=5300
CHECK_INTERVAL=3
LEASE_SECONDS=6
SERVICE_NAME=xray-tproxy

health_log() {
	logger -t xray-tproxy "$*"
}

phase_get() {
	cat "$STATE_DIR/phase" 2>/dev/null || printf '%s\n' stopped
}

phase_set() {
	printf '%s\n' "$1" > "$STATE_DIR/phase.tmp" &&
		mv -f "$STATE_DIR/phase.tmp" "$STATE_DIR/phase"
}

# init 和 monitor 使用同一把锁；绝不删除锁文件或整个状态目录。
health_locked() {
	local result
	umask 077
	mkdir -p "$STATE_DIR" || return 1
	exec 9>"$STATE_DIR/lock" || return 1
	flock -n 9 || { exec 9>&-; return 1; }
	"$@"
	result=$?
	flock -u 9
	exec 9>&-
	return "$result"
}

guard_close() {
	nft flush set inet xray_guard ready
}

guard_open() {
	[ ! -e "$STATE_DIR/stop-request" ] && [ "$(phase_get)" = running ] || return 1
	# 单次 nft 事务替换许可，不依赖重复 add 是否刷新旧元素的 timeout。
	nft -f - <<EOF
flush set inet xray_guard ready
add element inet xray_guard ready { "$LAN_IFACE" timeout ${LEASE_SECONDS}s }
EOF
}

offload_config_disabled() {
	local config defaults
	# 先成功读取整个包，不能把 UCI 故障误当成两个选项都未设置。
	config=$(uci -q show firewall) || return 1
	defaults=$(printf '%s\n' "$config" | awk -F= '$2 == "defaults" { print $1; exit }')
	[ -n "$defaults" ] || return 1
	printf '%s\n' "$config" | awk -v prefix="$defaults." '
		index($0, prefix "flow_offloading=") == 1 || index($0, prefix "flow_offloading_hw=") == 1 {
			value = substr($0, index($0, "=") + 1)
			gsub(/\047/, "", value)
			if (value !~ /^(0|off|false|no)$/) bad = 1
		}
		END { exit bad }
	'
}

offload_disabled() {
	local tables
	# 运行期只检查已生效状态；全局检查也排除自定义 flowtable。
	tables=$(nft -s list flowtables) || return 1
	printf '%s\n' "$tables" | awk '
		/^[ \t]*flowtable[ \t]/ { bad = 1 }
		END { exit bad }
	'
}

health_preflight() {
	offload_config_disabled && offload_disabled &&
		nft list chain inet fw4 input >/dev/null
}

offload_cleanup_plan() {
	local tables rules
	tables=$(nft -s list flowtables) || return 1
	rules=$(nft -s -a list table inet fw4) || return 1
	# 只接受官方 fw4/ft 与 forward 中纯加速语句；不删除带其他动作的自定义规则。
	printf '%s\n# XRAY_FW4_RULES\n%s\n' "$tables" "$rules" | awk '
		/^# XRAY_FW4_RULES$/ { rules = 1; next }
		!rules && $1 == "table" { family = $2; table = $3 }
		!rules && $1 == "flowtable" {
			if (family != "inet" || table != "fw4" || $2 != "ft") bad = 1
			tables++
		}
		rules && $1 == "flowtable" { if ($2 != "ft") bad = 1; found++ }
		rules && $1 == "chain" { chain = $2 }
		rules {
			line = $0
			sub(/ comment .*/, "", line)
			if (line !~ /(^|[ \t])flow[ \t]+(add|offload)[ \t]+@/) next
			if (chain != "forward" || $0 !~ /^[ \t]*meta l4proto \{ tcp, udp \} flow (add|offload) @ft;?[ \t]+# handle [0-9]+[ \t]*$/) bad = 1
			commands[++count] = "delete rule inet fw4 forward handle " $NF
		}
		END {
			if (bad || tables > 1 || tables != found || (count && found != 1)) exit 1
			for (i = 1; i <= count; i++) print commands[i]
			if (found) print "delete flowtable inet fw4 ft"
		}
	'
}

guard_restore_closed() (
	local source cleanup
	# 与 fw4 使用同一把锁，避免读取 handle 后与 reload/stop 竞争；子进程退出释放 FD 8。
	exec 8>"${FW4_LOCK:-/var/run/fw4.lock}" || return 1
	flock -n 8 || return 1
	# 读取失败时不能把仅含前提检查的半份事务当成恢复成功。
	source=$(cat "$GUARD_FILE") || return 1
	[ -n "$source" ] || return 1
	cleanup=$(offload_cleanup_plan) || {
		health_log "无法读取加速状态或发现自定义 flow offload，拒绝自动清理；无法确认公网阻断"
		return 1
	}
	# 先去掉标准 flow add 引用再删 ft，清理双向缓存；绝不重建加速表或改 UCI。
	# add chain 保留父表存在这一事务前提，避免主动 firewall stop 后创建保护表。
	printf 'add chain inet fw4 syn_flood\n%s\n%s\n' "$cleanup" "$source" | nft -f -
)

maintain_failed() {
	[ -e "$STATE_DIR/needs-close" ] || return 0
	# 只恢复默认关闭的保护表，不修复接管表/策略路由，也不重新开放。
	# 防火墙被主动停止/清空时不重建，以免干预用户的维护操作。
	guard_restore_closed || return 1
	delete_xray_instance 2>/dev/null || return 1
	rm -f "$STATE_DIR/needs-close" || return 1
	health_log "${1:-闭合保护已恢复；仍需人工排查后 restart}"
}

delete_xray_instance() {
	# delete 同时取消待执行的 respawn；单独 kill PID 会再次触发重启。
	ubus -t 3 call service delete '{"name":"xray-tproxy","instance":"xray"}' >/dev/null
}

health_fail() {
	phase_set failed || return 1
	: > "$STATE_DIR/needs-close" || return 1
	guard_close 2>/dev/null || :
	maintain_failed "$*；LAN 公网保持阻断，需人工排查后 restart" ||
		health_log "$*；闭合保护或取消重启未完成，将继续重试，请人工检查"
	return 1
}

service_pid() {
	local reply pid
	reply=$(ubus -t 2 call service list '{"name":"xray-tproxy"}') || return 1
	pid=$(jsonfilter -s "$reply" -e "@[\"xray-tproxy\"].instances.$1.pid") || return 1
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	[ "$pid" -gt 1 ] || return 1
	printf '%s\n' "$pid"
}

process_identity() {
	local pid started executable
	pid=$(service_pid xray) || return 1
	executable=$(readlink "$PROC_ROOT/$pid/exe") || return 1
	[ "$executable" = "$XRAY_BIN" ] || return 1
	started=$(awk '{
		sub(/^.*\) /, "")
		if ($1 == "Z" || $1 == "X" || $1 == "T" || $1 == "t" || NF < 20) exit 1
		print $20
	}' "$PROC_ROOT/$pid/stat") || return 1
	case "$started" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s %s\n' "$pid" "$started"
}

socket_records() {
	local loopback
	set -- "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/udp"
	[ ! -r "$PROC_ROOT/net/tcp6" ] || set -- "$@" "$PROC_ROOT/net/tcp6"
	[ ! -r "$PROC_ROOT/net/udp6" ] || set -- "$@" "$PROC_ROOT/net/udp6"
	# /proc/net 使用本机字节序表示 IPv4 地址。
	loopback=$(printf '\177\000\000\001' | od -An -tx4 | tr -d ' \n' | tr 'a-f' 'A-F')
	[ -n "$loopback" ] || return 1
	awk -v tp="$TPROXY_PORT" -v dns="$DNS_PORT" -v loop="$loopback" '
		FNR == 1 { next }
		{
			proto = (FILENAME ~ /\/tcp6?$/) ? "tcp" : "udp"
			if ((proto == "tcp" && $4 != "0A") || (proto == "udp" && $4 != "07")) next
			key = ""
			if ($2 == sprintf("00000000:%04X", tp)) key = proto "-tproxy"
			# 冻结配置 listen=0.0.0.0、v6only未启用；Go可创建显式V6ONLY=0的双栈socket。
			if ($2 == sprintf("00000000000000000000000000000000:%04X", tp)) key = proto "-tproxy"
			if ($2 == sprintf("%s:%04X", loop, dns)) key = proto "-dns"
			if (key != "") { count[key]++; inode[key] = $10 }
		}
		END {
			n = split("tcp-tproxy tcp-dns udp-tproxy udp-dns", keys, " ")
			for (i = 1; i <= n; i++) if (count[keys[i]] != 1 || inode[keys[i]] !~ /^[0-9]+$/) exit 1
			for (i = 1; i <= n; i++) print keys[i], inode[keys[i]]
		}
	' "$@"
}

cache_valid() {
	local key inode fd count=0
	[ "$(cat "$STATE_DIR/socket.identity" 2>/dev/null)" = "$IDENTITY" ] || return 1
	[ -r "$STATE_DIR/socket.cache" ] || return 1
	while read -r key inode fd; do
		case "$fd" in ''|*[!0-9]*) return 1 ;; esac
		[ "$(readlink "$PROC_ROOT/$PID/fd/$fd")" = "socket:[$inode]" ] || return 1
		printf '%s\n' "$RECORDS" | grep -qx "$key $inode" || return 1
		count=$((count + 1))
	done < "$STATE_DIR/socket.cache"
	[ "$count" -eq 4 ]
}

cache_build() {
	local key inode path found
	printf '%s\n' "$RECORDS" | while read -r key inode; do
		found=
		for path in "$PROC_ROOT/$PID/fd/"*; do
			if [ "$(readlink "$path" 2>/dev/null)" = "socket:[$inode]" ]; then
				printf '%s %s %s\n' "$key" "$inode" "${path##*/}"
				found=1
				break
			fi
		done
		[ -n "$found" ] || exit 1
	done > "$STATE_DIR/socket.cache.tmp" || return 1
	mv -f "$STATE_DIR/socket.cache.tmp" "$STATE_DIR/socket.cache" || return 1
	printf '%s\n' "$IDENTITY" > "$STATE_DIR/socket.identity"
}

application_ready() {
	local IDENTITY PID RECORDS
	IDENTITY=$(process_identity) || return 1
	PID=${IDENTITY%% *}
	RECORDS=$(socket_records) || return 1
	cache_valid || cache_build || return 1
	# 检查过程中发生退出/重启时，不把旧 PID 的端口作为新实例的证据。
	[ "$(process_identity)" = "$IDENTITY" ]
}

normalize_guard() {
	# 只忽略 ready 的动态元素，bypass 等静态集合仍完整参与比较。
	awk '
		/^[ \t]*set ready \{/ { ready = 1 }
		ready && /^[ \t]*elements = \{/ {
			if ($0 !~ /}/) elements = 1
			next
		}
		elements { if ($0 ~ /}/) elements = 0; next }
		ready && /^[ \t]*}/ { ready = 0 }
		{ print }
	'
}

syn_exemption() {
	local rules first
	rules=$(nft -s list chain inet fw4 syn_flood) || return 1
	first=$(printf '%s\n' "$rules" | awk '
		/^[ \t]*chain syn_flood \{/ { chain = 1; next }
		chain && /^[ \t]*[^ \t}]/ { sub(/^[ \t]+/, ""); print; exit }
	')
	case "$first" in
		*'return comment "Xray TPROXY SYN exemption"') ;;
		*) return 1 ;;
	esac
	# 核对豁免范围，不只信任 comment；接受 nft 对 mark 的补零输出。
	printf '%s\n' "$first" | grep -Eq 'meta nfproto ipv4 iifname "br-lan" meta mark 0x0*1 ' || return 1
	printf '%s\n' "$first" | grep -q 'tcp flags' || return 1
	printf '%s\n' "$first"
}

policy_snapshot() {
	local rules
	# 数字表名避免 /etc/iproute2/rt_tables 别名影响 table 100 的筛选。
	rules=$(ip -N -4 rule show) || return 1
	printf '%s\n' "$rules" | awk '
		NF {
			if ($1 !~ /^[0-9]+:$/) { bad = 1; next }
			lines[++count] = $0
			early = ($1 + 0 <= 100)
			keep[count] = early
			for (i = 2; i <= NF; i++) {
				if ($i == "lookup" && $(i + 1) == "100") keep[count] = 1
				# 早期 goto 可跳过接管规则；保守比较完整列表，不解析跳转图。
				if (early && $i == "goto") full = 1
			}
		}
		END {
			if (bad || !count) exit 1
			for (i = 1; i <= count; i++) if (full || keep[i]) print lines[i]
		}
	' || return 1
	ip -4 route show table 100
}

rules_snapshot() {
	local rules
	offload_disabled || return 1
	rules=$(nft -s list table ip xray) || return 1
	printf '%s\n' "$rules"
	rules=$(nft -s list table inet xray_guard) || return 1
	printf '%s\n' "$rules" | normalize_guard || return 1
	syn_exemption || return 1
	# 排除旧部署的 INPUT 提前 accept，避免两份规则同时生效。
	rules=$(nft -s list chain inet fw4 input) || return 1
	case "$rules" in *'comment "Xray TPROXY"'*) return 1 ;; esac
	policy_snapshot
}

rules_unchanged() {
	rules_snapshot > "$STATE_DIR/rules.current" || return 1
	cmp -s "$STATE_DIR/rules.baseline" "$STATE_DIR/rules.current"
}

health_prepare() {
	phase_set starting || return 1
	guard_close || return 1
	rm -f "$STATE_DIR/rules.baseline" "$STATE_DIR/socket.identity" "$STATE_DIR/socket.cache" \
		"$STATE_DIR/stop-request" "$STATE_DIR/needs-close"
}

health_activate() {
	local deadline="${1:-0}" uptime rest
	[ "$(phase_get)" = starting ] || return 1
	application_ready || return 1
	service_pid health >/dev/null || return 1
	rules_snapshot > "$STATE_DIR/rules.baseline.tmp" || return 1
	mv -f "$STATE_DIR/rules.baseline.tmp" "$STATE_DIR/rules.baseline" || return 1
	read -r uptime rest < "$PROC_ROOT/uptime" || return 1
	[ "${uptime%%.*}" -lt "$deadline" ] || return 1
	phase_set running || return 1
	guard_open || { health_fail "无法发放健康许可"; return 1; }
}

health_stop() {
	: > "$STATE_DIR/stop-request" || return 1
	phase_set stopped || return 1
	guard_close
}

health_tick() {
	local phase
	phase=$(phase_get)
	[ ! -e "$STATE_DIR/stop-request" ] || return 0
	case "$phase" in
		running|recovering) ;;
		failed) maintain_failed; return $? ;;
		*) return 0 ;;
	esac
	if ! rules_unchanged; then
		health_fail "接管规则或策略路由发生异常"
		return 1
	fi
	if ! application_ready; then
		guard_close || return 1
		if [ "$phase" != recovering ]; then
			phase_set recovering || return 1
			health_log "Xray 本机入口未就绪，阻断公网并等待 procd 有限重试"
		fi
		return 0
	fi
	if [ "$phase" = recovering ]; then
		phase_set running || return 1
		health_log "Xray 本机入口恢复，恢复原有分流"
	fi
	guard_open || health_fail "刷新健康许可失败"
}

health_monitor() {
	# 退出后由内核许可到期兜底；不能让退出 trap 在新一轮 start 后误关新许可。
	trap 'exit 0' TERM INT
	while :; do
		health_locked health_tick
		sleep "$CHECK_INTERVAL"
	done
}

if [ "${XRAY_HEALTH_LIBRARY:-0}" != 1 ]; then
	case "${1:-}" in
		monitor) health_monitor ;;
		preflight) health_locked health_preflight ;;
		protect) health_locked guard_restore_closed ;;
		prepare) health_locked health_prepare ;;
		activate) health_locked health_activate "${2:-0}" ;;
		stop) health_locked health_stop ;;
		check) health_locked application_ready ;;
		fail) shift; health_locked health_fail "$*" ;;
		*) printf '%s\n' 'usage: xray-health.sh {monitor|preflight|protect|prepare|activate|stop|check|fail}' >&2; exit 1 ;;
	esac
fi
