# 自用 OpenWrt Xray 透明代理

目标版本：OpenWrt **25.12.6**、Xray **26.10.17**。仅接管 `br-lan` 的 IPv4 TCP/UDP；路由器普通出站不接管。本次保持 `config.json` 的分流规则、顺序、DNS 分类和日志设置不变。

Xray 不可用时，LAN 公网流量默认阻断，内网和路由器管理按既有豁免与防火墙规则保留。LAN IPv6 公网转发始终禁止；路由器自身 IPv6、`::1` 和 LAN 本地 IPv6 保留。以下命令是部署说明，须由操作者在指定环境执行。

## 部署

1. **连接、检查未提交配置并备份。** 本地 PowerShell 连接：

   ```powershell
   ssh -p 40022 root@192.168.8.1
   ```

   以下在路由器执行。先查看 `uci changes dhcp` 和 `uci changes firewall`；如有未提交更改，先确认并处理，不要让后续 `commit` 混入其他修改。

   ```sh
   uci changes dhcp
   uci changes firewall
   umask 077
   backup_dir=$(mktemp -d /root/xray-backup.XXXXXX) || exit 1
   for path in /etc/config/dhcp /etc/config/firewall /etc/passwd /etc/bash.bashrc \
       /etc/xray /etc/init.d/xray-tproxy /usr/bin/xray /usr/share/xray \
       /usr/share/nftables.d/chain-pre/input/xray-fw4.nft \
       /usr/share/nftables.d/ruleset-pre/xray-guard.nft \
       /usr/share/nftables.d/ruleset-post/xray-fw4.nft; do
       [ -e "$path" ] || continue
       mkdir -p "$backup_dir$(dirname "$path")" || exit 1
       cp -a "$path" "$backup_dir$(dirname "$path")/" || exit 1
   done
   printf '备份目录：%s\n' "$backup_dir"
   ```

   记下备份目录，后续覆盖文件前确认备份成功。备份可能包含节点凭据，应保留其仅 root 可访问的权限。

2. **安装依赖与 Xray。** OpenWrt 25.12 使用 `apk`；较旧的 `opkg` 系统不属于本次验证目标。`ca-bundle` 为节点 TLS 与 Ali DoH 提供 CA 证书；已有该包时复用，不关闭证书校验。Bash 保留为原有交互环境选项，不是透明代理服务的依赖。

   ```sh
   apk add kmod-nft-tproxy kmod-nft-socket ip-full ca-bundle bash coreutils-od
   ```

   国内镜像可参考 [MirrorZ 的 OpenWrt 说明](https://help.mirrorz.org/openwrt/)，不要混用不同固件版本的软件源。脚本还依赖系统已有的 `nft`、`uci`、`ubus`、`jsonfilter`、`flock`、`awk`、`od`、`readlink`、`cmp` 等命令。

   从 [Xray 发布页](https://github.com/XTLS/Xray-core/releases/tag/v26.10.17) 下载与路由器实际 CPU/ABI 匹配的 **Linux** 二进制，按发布页校验后在本地解压，不要上传 Windows 版本。可先在路由器用 `ubus call system board` 与 `uname -m` 核对设备信息。将解压所得的 `xray` 上传：

   ```powershell
   scp -P 40022 -O .\xray root@192.168.8.1:/usr/bin/xray
   scp -P 40022 -O .\bash.bashrc root@192.168.8.1:/etc/bash.bashrc
   ```

   路由器上执行 `chmod 755 /usr/bin/xray` 并检查 `/usr/bin/xray version`。如需将 root 登录 shell 改为 Bash，编辑 `/etc/passwd` 中 root 行的**最后一个字段**为 `/bin/bash`，保留用户名、密码字段、UID、GID、说明和主目录；不要用一整行示例覆盖原记录。服务脚本仍使用 `/bin/sh`。

3. **准备 DAT 和配置，先通过配置检查。** 在本地项目目录用 PowerShell 下载；来源保留 Loyalsoldier 原始地址，保存名必须匹配 `config.json` 中的 `ext:` 引用：

   ```powershell
   Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip-only-cn-private.dat' -OutFile '.\loyalsoldier_geoip-only-cn-private.dat'
   Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat' -OutFile '.\loyalsoldier_geosite.dat'
   ssh -p 40022 root@192.168.8.1 'mkdir -p /etc/xray /usr/share/xray'
   scp -P 40022 -O .\config.json root@192.168.8.1:/etc/xray/
   scp -P 40022 -O .\loyalsoldier_geosite.dat .\loyalsoldier_geoip-only-cn-private.dat root@192.168.8.1:/usr/share/xray/
   ```

   上传前确认配置中的节点参数正确；若以后更换节点域名，还须核对 `dns-ali-1` 的对应域名规则。本次部署不重写现有分流或日志。路由器上检查：

   ```sh
   chmod 600 /etc/xray/config.json
   XRAY_LOCATION_ASSET=/usr/share/xray /usr/bin/xray run -test -config /etc/xray/config.json
   ```

   配置检查失败时先修正，不继续安装接管规则。它能检查配置加载，不能证明节点连通。

4. **安装脚本和保护规则，关闭流量卸载。** 本地 PowerShell：

   ```powershell
   ssh -p 40022 root@192.168.8.1 'mkdir -p /usr/share/nftables.d/ruleset-pre /usr/share/nftables.d/ruleset-post'
   scp -P 40022 -O .\xray.nft .\xray-health.sh .\disable-ipv6.sh root@192.168.8.1:/etc/xray/
   scp -P 40022 -O .\xray-tproxy root@192.168.8.1:/etc/init.d/
   scp -P 40022 -O .\xray-guard.nft root@192.168.8.1:/usr/share/nftables.d/ruleset-pre/
   scp -P 40022 -O .\xray-fw4.nft root@192.168.8.1:/usr/share/nftables.d/ruleset-post/
   ```

   路由器上确认第 1 步已备份旧文件，然后移除旧版 INPUT 提前放行片段。软件、硬件 flow offload 都必须关闭：卸载路径可能绕过本项目的检查，关闭后可能降低转发吞吐。

   ```sh
   chmod 755 /etc/init.d/xray-tproxy /etc/xray/xray-health.sh /etc/xray/disable-ipv6.sh
   rm -f /usr/share/nftables.d/chain-pre/input/xray-fw4.nft
   uci changes firewall
   ```

   若存在未提交的 firewall 更改，先处理，再执行：

   ```sh
   uci set firewall.@defaults[0].flow_offloading='0'
   uci set firewall.@defaults[0].flow_offloading_hw='0'
   uci commit firewall
   fw4 check && /etc/init.d/firewall reload
   ```

   必须确认 `fw4 check` 和重载成功。重载用于应用关闭设置并清除旧卸载缓存；**此时保护表许可为空，LAN 公网将封闭**。有线 SSH 和内网管理按既有防火墙规则保留。不得把新文件继续放在 `chain-pre/input`，也不要把 `xray-fw4.nft` 当作旧版链内片段使用。

   保护规则加载后，再在路由器执行：

   ```sh
   nft list table inet xray_guard
   /bin/sh /etc/xray/disable-ipv6.sh
   ```

   该脚本仅关闭 LAN 的 RA、DHCPv6、NDP，并重载 odhcpd，**不需要重启路由器**。它保留 WAN、路由器 IPv6 和 `::1`，并检查保护规则与未提交的 DHCP 更改。若发现旧版全局 IPv6 禁用文件，会拒绝继续，须先人工核对旧配置。

5. **启动并接入 dnsmasq。** 路由器上执行：

   ```sh
   /etc/init.d/xray-tproxy enable
   /etc/init.d/xray-tproxy restart
   /etc/init.d/xray-tproxy status
   logread -e xray
   ```

   确认状态为 `running`、日志出现“TPROXY 规则已加载，本机检查通过”，再查看 `uci changes dhcp`。处理完未提交更改后，沿用 dnsmasq 的唯一外部上游：

   ```sh
   uci set dhcp.@dnsmasq[0].noresolv='1'
   uci -q delete dhcp.@dnsmasq[0].server
   uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5300'
   uci commit dhcp && /etc/init.d/dnsmasq restart
   ```

   本方案保留 dnsmasq 的 DHCP、缓存和局域网设备名服务。路由器当前系统解析器指向本机 dnsmasq，因此**路由器与 LAN 的外部 DNS 都依赖 Xray**；此处没有配置独立系统 DNS 或节点故障时的直连 DNS 备用上游。

6. **核验。** 以下只读取路由器状态：

   ```sh
   /etc/init.d/xray-tproxy status
   nft list set inet xray_guard ready
   nft list table ip xray
   nft list chain inet fw4 syn_flood
   nft list flowtables
   ip -4 rule show
   ip -4 route show table 100
   logread -e xray
   ```

   `ready` 应有持续续租的 `br-lan` 元素，系统不应有启用的 flowtable。SYN 豁免必须是 `syn_flood` 的首条规则，以 `return` 跳过该链的限速后继续 INPUT 检查；它不是提前 `accept`，WAN SYN 防护保留。再由 LAN 终端验证原直连与代理分流、DNS、IPv6 公网阻断及内网管理。

## 运行与故障边界

- **初启与重试：** 初启最多等待 30 秒完成本机入口及规则核验，窗口内允许 procd 重试。超时会删除实例，取消尚未执行的重试，保持封闭，须人工排查后 `restart`。运行中的 `respawn 3600 5 5` 表示间隔 5 秒、最多 5 次连续短时运行后的重启；单次稳定运行满 1 小时才重置计数，不是整次开机仅能重启 5 次。
- **检查内容：** 每轮完成后间隔 3 秒检查，许可有效期 6 秒。验证 procd 实例、PID 与启动时间、TCP/UDP 的 TPROXY 和 DNS 四个监听及其 socket 归属，并比较规则基线。缓存只减少 FD 扫描，仍逐轮检查绑定；冻结配置下也识别 Go 为 `0.0.0.0` 建立的双栈监听。没有公网探测，也不能证明端口仍开着的进程不存在内部挂死。检测和许可到期包含调度窗口，不是硬实时承诺。
- **进程与节点故障不同：** Xray 入口不可用时收回许可，等待 procd 有限重试；入口恢复且规则未变化后恢复原分流。仅远端节点不可用而 Xray 正常时，不自动把代理流量改成直连；原直连出口继续存在，但依赖代理侧 DNS 的查询仍可能失败。
- **规则异常锁定：** 状态进入 `failed`，只尝试恢复默认关闭的保护表，不自动修复 TPROXY 或策略路由，不重新开放。闭合保护或取消重启未完成时会重试。策略规则比较覆盖优先级不大于 `100` 的规则、所有查询表 `100` 的规则，以及表 `100` 的全部路由；保留规则顺序与重复项。无关的后置 VPN 规则变化不再触发锁定；若前述早期规则存在 `goto`，则保守比较整张规则列表。不比较 `main` 表的普通默认路由变化。修复原因后使用 `/etc/init.d/xray-tproxy restart`。
- **流量卸载：** 启动检查 UCI 与实际 nft 状态，运行中只检查已生效的 flowtable，未应用的 UCI 改动不再触发锁定。对标准 fw4 的 `ft` 及 `forward` 链中仅负责加入该表的规则，异常处理会移除对应引用和 flowtable、清理双向缓存并锁定 `failed`，不会更改 UCI 或自动恢复加速。自定义 flow offload、厂商加速等不受支持，不能承诺阻断；须先人工关闭并核验。若 UCI 仍启用卸载，之后的 fw4 重载可能重新建立它，应先修正配置。
- **停止不是恢复直连：** `xray-tproxy stop` 停止实例并清理接管规则，但保留关闭的 guard，LAN 公网仍阻断，包括非 TCP/UDP 流量。公网范围沿用 `xray.nft` 与 guard 的 `bypass4`，其中私网、CGNAT 等地址仍豁免，不能把这理解为所有经 WAN 的目的地址均阻断。仅取消 `xray.nft` 中某设备绕过代理的注释会被 guard 拦截，设备直连豁免需要另行设计。
- **主动停止防火墙：** `/etc/init.d/firewall stop` 或清空规则集会移除保护，本项目不保证此期间阻断，也不会在防火墙不存在时强行重建。恢复防火墙后须人工 `restart` Xray 服务并核验。
- **DNS 行为：** A 查询沿用原国内外分类；内置 DNS 的 `UseIPv4` 不返回 IPv6 地址，不能宣称 AAAA 完整沿用相同上游查询流程。HTTPS 类型 65 返回 `REFUSED`；其余查询经代理转发到 `8.8.8.8:53`。本地设备名由 dnsmasq 回答的行为保留。
- **文件格式：** Shell、nft 文件使用 LF；通过旧 Windows 工作区部署时，确认未被编辑器另存为 CRLF。接口 `br-lan`、TPROXY 端口 `12345`、DNS 端口 `5300`、mark `1` 和策略表 `100` 须在相关文件中保持一致。

## 人工回退

回退会改变联网方式，应保持有线管理连接，并逐项核对第 1 步的备份；不要执行一键清空防火墙或路由表。

1. 先 `/etc/init.d/xray-tproxy stop`、`/etc/init.d/xray-tproxy disable`，此时 guard 仍封闭公网。
2. 对照备份恢复原 DHCP/DNS 与 firewall 配置，只撤销本次改动；期间有其他配置更改时须合并，不能直接覆盖。恢复 dnsmasq 和 odhcpd，避免系统 DNS 仍指向已经停止的 Xray。
3. 移除本次新增的 `ruleset-pre/xray-guard.nft`、`ruleset-post/xray-fw4.nft`，并按原部署情况恢复被覆盖的项目文件、旧 include、Bash 配置和 root 原 shell。先核验 `fw4 check`，再重载防火墙。
4. 若目标是恢复没有本项目保护的原直连行为，确认原 DNS、防火墙配置正确后，**显式**执行 `nft delete table inet xray_guard`。仅删除 include 文件或停 Xray 不等于删除已加载的保护表。最后确认 `ip xray` 接管表、mark 1/table 100 的项目规则与路由已清理；如有残留，只删除本项目对应项，不清空共享规则表。
