#!/bin/sh
# 停止 LAN 的 RA / DHCPv6 / NDP；IPv6 公网转发由 xray-guard.nft 阻断。
# 保留路由器自身 IPv6、::1、WAN 配置及 ULA。先部署防火墙保护，再执行本脚本。

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

check_guard() {
	local chain ruleset
	chain=$(nft -s -y list chain inet xray_guard forward 2>/dev/null) || return 1
	printf '%s\n' "$chain" | awk '
		{
			gsub(/^[ \t]+|[ \t]+$/, "")
			gsub(/[ \t]+/, " ")
			sub(/priority filter - 1;/, "priority -1;")
			gsub(/counter packets [0-9]+ bytes [0-9]+/, "counter")
			# nft 可省略由 ip6 daddr 隐含的 IPv6 协议依赖。
			sub(/ meta nfproto ipv6 /, " ")
			if ($0 == "type filter hook forward priority -1; policy accept;") { hook = 1; next }
			if (hook && !rule && $0 != "") {
				# 必须是首条规则，避免前面的 accept / return 绕过保护。
				if ($0 != "iifname \"br-lan\" oifname != \"br-lan\" ip6 daddr != @bypass6 counter drop comment \"Xray guard: block LAN IPv6 internet\"") exit 1
				rule = 1
			}
		}
		END { exit !(hook && rule) }
	' || return 1

	ruleset=$(nft -s -y list set inet xray_guard bypass6 2>/dev/null) || return 1
	printf '%s\n' "$ruleset" | awk '
		{
			text = text " " $0
			if ($0 ~ /^[[:space:]]*type[[:space:]]+ipv6_addr[[:space:]]*;?[[:space:]]*$/) type_ok = 1
			if ($0 ~ /^[[:space:]]*flags[[:space:]]+interval[[:space:]]*;?[[:space:]]*$/) flags_ok = 1
		}
		END {
			if (!type_ok || !flags_ok || text !~ /elements[[:space:]]*=[[:space:]]*\{/) exit 1
			sub(/^.*elements[[:space:]]*=[[:space:]]*\{/, "", text)
			sub(/\}.*/, "", text)
			gsub(/[[:space:]]/, "", text)
			if (split(text, elements, ",") != 3) exit 1
			for (i in elements) seen[elements[i]] = 1
			exit !((seen["::1"] || seen["::1/128"]) && seen["fc00::/7"] && seen["fe80::/10"])
		}
	' || return 1
}

[ "$(id -u)" = 0 ] || fail "请以 root 执行本脚本。"
for command in uci nft awk mktemp cp; do
	command -v "$command" >/dev/null 2>&1 || fail "缺少命令：$command；未修改配置。"
done

[ ! -e /etc/sysctl.d/99-disable-ipv6.conf ] ||
	fail "发现旧版 /etc/sysctl.d/99-disable-ipv6.conf。请先人工检查并处理全局 IPv6 禁用配置；本脚本不会恢复 WAN 或修改 sysctl。"
[ -x /etc/init.d/odhcpd ] || fail "找不到可执行的 /etc/init.d/odhcpd；未修改配置。"
[ "$(uci -q get dhcp.lan)" = dhcp ] || fail "未找到 dhcp.lan 配置段；未修改配置。"

pending=$(uci changes dhcp) || fail "无法检查 dhcp 的未提交更改；未修改配置。"
[ -z "$pending" ] || fail "dhcp 存在未提交的 UCI 更改，请先处理；未修改配置。"
check_guard || fail "LAN IPv6 保护未就绪：请先加载并核对 xray_guard 的 forward 链和 bypass6 集合；未修改配置。"

backup_dir=
if [ "$(uci -q get dhcp.lan.ra)" != disabled ] ||
	[ "$(uci -q get dhcp.lan.dhcpv6)" != disabled ] ||
	[ "$(uci -q get dhcp.lan.ndp)" != disabled ]; then
	umask 077
	backup_dir=$(mktemp -d /root/xray-ipv6-backup.XXXXXX) || fail "无法创建备份目录；未修改配置。"
	cp /etc/config/dhcp "$backup_dir/dhcp" || fail "备份失败：$backup_dir；未修改配置。"

	if ! {
		uci set dhcp.lan.ra='disabled' &&
		uci set dhcp.lan.dhcpv6='disabled' &&
		uci set dhcp.lan.ndp='disabled' &&
		uci commit dhcp
	}; then
		uci -q revert dhcp 2>/dev/null
		fail "修改 dhcp 失败，已尝试撤销未提交更改。原文件备份：$backup_dir/dhcp；请检查当前配置。"
	fi
fi

# 重复执行不重复提交或备份，但仍重载，保证已保存的配置被 odhcpd 采用。
/etc/init.d/odhcpd reload ||
	fail "LAN 配置已保存，但 odhcpd 重载失败。请人工检查；本次备份目录：${backup_dir:-未生成（配置原已关闭）}。"

printf '%s\n' "LAN RA / DHCPv6 / NDP 已关闭，IPv6 公网转发保护已核对。路由器 IPv6 与 ::1 未修改。"
[ -z "$backup_dir" ] || printf '原 DHCP 配置备份：%s/dhcp\n' "$backup_dir"
exit 0
