#!/usr/bin/env bash
# 一键卸载本安装脚本部署的 Xray/REALITY 与 Hysteria 2
# 适用：Debian/Ubuntu 等使用 systemd 的 Linux
set -Eeuo pipefail

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2; }

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

echo "即将卸载以下组件（存在时才会删除）："
echo "  - Xray：程序、systemd 服务、配置、GeoIP/GeoSite、日志"
echo "  - Hysteria 2：程序、服务文件、配置、证书、日志"
echo "  - 安装脚本生成的 /root/xray-reality.txt"
echo
echo "不会卸载 curl、openssl 等系统依赖，也不会自动修改防火墙规则。"
echo "继续前会把现有配置和连接信息备份到 /root。"
echo

read -r -p '确认卸载请输入 YES：' answer
if [[ "$answer" != "YES" ]]; then
  echo "已取消，未执行卸载。"
  exit 0
fi

stamp=$(date '+%Y%m%d-%H%M%S')
backup="/root/proxy-uninstall-backup-${stamp}"
mkdir -m 700 -p "$backup"
backup_items=(
  /usr/local/etc/xray
  /usr/local/share/xray
  /etc/hysteria
  /root/xray-reality.txt
)
existing=()
for item in "${backup_items[@]}"; do
  [[ -e "$item" ]] && existing+=("$item")
done

if ((${#existing[@]})); then
  tar -czpf "$backup/configs.tar.gz" --absolute-names "${existing[@]}"
  chmod 600 "$backup/configs.tar.gz"
  log "配置备份已保存：$backup/configs.tar.gz"
else
  rmdir "$backup"
  backup=""
  log "未发现需要备份的配置文件。"
fi

log "停止并禁用相关服务..."
for service in xray hysteria; do
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$service" >/dev/null 2>&1 || true
  fi
done

# 清理可能存在的 OpenRC 注册项（原安装脚本曾创建该文件）。
if command -v rc-update >/dev/null 2>&1; then
  rc-update del hysteria default >/dev/null 2>&1 || true
fi

log "删除服务定义..."
rm -f \
  /etc/systemd/system/xray.service \
  /etc/systemd/system/hysteria.service \
  /etc/init.d/hysteria

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || warn "systemd daemon-reload 执行失败，请稍后手动执行。"
  systemctl reset-failed xray hysteria >/dev/null 2>&1 || true
fi

log "删除程序、配置及日志..."
rm -f /usr/local/bin/xray
# 仅删除指向本安装路径的链接，避免误删用户自己的其他文件。
if [[ -L /usr/local/sbin/xray ]] &&
   [[ "$(readlink -f /usr/local/sbin/xray 2>/dev/null || true)" == "/usr/local/bin/xray" ]]; then
  rm -f /usr/local/sbin/xray
fi
rm -f /usr/local/bin/hysteria

rm -rf \
  /usr/local/etc/xray \
  /usr/local/share/xray \
  /var/log/xray \
  /etc/hysteria \
  /var/log/hysteria.log \
  /var/log/hysteria.err

rm -f /root/xray-reality.txt

echo
log "卸载步骤已完成。"
if [[ -n "$backup" ]]; then
  echo "配置备份：$backup/configs.tar.gz"
fi
echo
echo "注意："
echo "  1. 未卸载 apt 安装的通用依赖包，以免影响其他程序。"
echo "  2. 未修改 UFW/nftables/iptables 规则；请按需检查并清理曾开放的端口。"
echo "  3. 如服务仍显示存在，请检查：systemctl status xray hysteria"
