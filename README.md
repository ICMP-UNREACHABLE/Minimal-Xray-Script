# Minimal Xray Script

一键安装和配置 **Xray-core** 的 Shell 脚本，支持 **Alpine Linux** 和 **Debian 13 x86_64**。

支持快速配置 **VLESS + REALITY**，也提供 **Hysteria 2** 安装选项。

## 功能

* 自动下载最新版本 Xray-core
* 自动生成 UUID、REALITY 密钥和 Short ID
* 自动配置 VLESS + REALITY
* 支持按地区选择 REALITY Target / SNI
* 自动生成客户端 VLESS URI
* 安装后自动检查 Xray 配置
* 自动设置开机启动
* 支持 SHA-256 校验 Xray 压缩包
* 可选安装 Hysteria 2

## 安装

### Alpine Linux

```sh
wget -qO- https://raw.githubusercontent.com/ICMP-UNREACHABLE/Minimal-Xray-Script/main/alpine-install.sh | sh
```

### Debian 13 x86_64

```sh
wget -qO- https://raw.githubusercontent.com/ICMP-UNREACHABLE/Minimal-Xray-Script/main/debian-install.sh | bash
```

## 配置 Xray

运行脚本后选择：

```text
1) Install Xray + Reality
2) Install Hysteria 2
```

选择 Xray 后：

```text
1) Auto Config
2) Regional Config
3) Exit
```

### 自动配置

默认使用：

```text
Target: www.amazon.com:443
SNI:    www.amazon.com
```

脚本会自动生成：

* UUID
* REALITY Private Key
* REALITY Public Key
* Short ID
* VLESS 客户端 URI

生成的客户端信息保存在：

```text
/root/xray-reality.txt
```

### 区域配置

可以根据地区选择 REALITY Target / SNI：

```text
1) US
2) UK
3) JP
4) HK
5) TW
6) SG
7) FR
8) DE
9) IN
10) Others
```

## Xray 文件位置

| 文件         | 路径                                 |
| ---------- | ---------------------------------- |
| Xray 程序    | `/usr/local/bin/xray/xray`         |
| 命令         | `/usr/local/sbin/xray`             |
| 配置文件       | `/usr/local/etc/xray/config.json`  |
| 数据目录       | `/usr/local/share/xray/`           |
| 日志目录       | `/var/log/xray/`                   |
| systemd 服务 | `/etc/systemd/system/xray.service` |

## Xray 管理

### Debian

```sh
systemctl start xray
systemctl stop xray
systemctl restart xray
systemctl status xray
systemctl enable xray
systemctl disable xray
```

查看日志：

```sh
journalctl -u xray -n 100 --no-pager
```

实时查看：

```sh
journalctl -u xray -f
```

### Alpine

```sh
service xray start
service xray stop
service xray restart
service xray status
```

## 检查 Xray 配置

```sh
/usr/local/bin/xray/xray run -test \
  -format json \
  -c /usr/local/etc/xray/config.json
```

如果检查通过，说明配置文件没有语法错误。

如果 Xray 无法启动，可以查看日志：

```sh
journalctl -u xray -n 100 --no-pager
```

## Hysteria 2

选择：

```text
2) Install Hysteria 2
```

主要文件：

```text
程序：/usr/local/bin/hysteria
配置：/etc/hysteria/config.yaml
服务：/etc/systemd/system/hysteria.service
```

管理服务：

```sh
systemctl start hysteria
systemctl stop hysteria
systemctl restart hysteria
systemctl status hysteria
```

查看日志：

```sh
journalctl -u hysteria -n 100 --no-pager
```

## 参考

项目原地址：
[XrayOnAlpine](https://github.com/miku111/XrayOnAlpine)  
感谢miku111大大开发

## License

MIT
