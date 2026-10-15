#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "[-] 请使用 root 权限运行此脚本 (e.g. sudo bash setup.sh)"
    exit 1
fi

echo "=========================================="
echo "    NarwhalCloud 系统初始化与优化脚本"
echo "=========================================="

# 1. 交互式获取用户输入
read -p "[?] 请输入数据盘镜像大小 (例如 10G, 20G): " DISK_SIZE
if [ -z "$DISK_SIZE" ]; then
    DISK_SIZE="10G"
    echo "[*] 未输入大小，默认使用: $DISK_SIZE"
fi

read -p "[?] 请输入防火墙绑定的外网网卡名称 (例如 eth0, ens33): " NETWORK_IFACE
if [ -z "$NETWORK_IFACE" ]; then
    echo "[-] 错误：网卡名称不能为空！"
    exit 1
fi

echo "[+] 配置参数确认: 数据盘大小=$DISK_SIZE, 网卡=$NETWORK_IFACE"
echo ""

# 2. 安装软件包
echo "[*] 正在更新软件源并安装基础软件包..."
apt update
apt install -y curl wget python3 uuid-runtime systemd-zram-generator jq chrony iptables iproute2 fdisk bc dnsutils podman aardvark-dns lxcfs xfsprogs

# 3. 配置内核参数
echo "[*] 正在配置系统内核调优参数..."
cat > /etc/sysctl.d/99-narwhalcloud.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.inotify.max_user_instances=524288
fs.inotify.max_user_watches=1048576
fs.inotify.max_queued_events=65536
kernel.pid_max=4194304
fs.file-max=2097152
fs.nr_open=2097152
vm.swappiness=100
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
net.ipv6.conf.all.use_tempaddr=0
net.ipv6.conf.default.use_tempaddr=0
EOF
sysctl -p /etc/sysctl.d/99-narwhalcloud.conf

# 4. 配置 systemd-journald 日志限制
echo "[*] 正在配置 systemd-journald 日志限制..."
cat > /etc/systemd/journald.conf <<EOF
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
SystemMaxFileSize=50M
RateLimitIntervalSec=10s
RateLimitBurst=1000
ForwardToSyslog=no
EOF
systemctl restart systemd-journald

# 5. 创建并挂载 XFS 数据盘 (启用 Direct I/O)
echo "[*] 正在创建并挂载大小为 $DISK_SIZE 的 XFS 数据盘..."
fallocate -l "$DISK_SIZE" /xfs_disk.img
mkfs.xfs -f /xfs_disk.img
mkdir -p /data
losetup --direct-io=on /dev/loop0 /xfs_disk.img
mountpoint -q /data || mount -o defaults,pquota,loop,noatime /xfs_disk.img /data

echo "[*] 验证 loop0 的 dio 状态:"
cat /sys/block/loop0/loop/dio

grep -q "/xfs_disk.img" /etc/fstab || echo "/xfs_disk.img /data xfs defaults,pquota,loop,noatime 0 0" >> /etc/fstab
findmnt -T /data -o TARGET,SOURCE,FSTYPE,OPTIONS
xfs_quota -x -c 'state -p' /data

# 6. 配置 Podman 存储
echo "[*] 正在配置 Podman 存储目录..."
cat > /etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/data/containers/storage"
EOF
mkdir -p /data/containers/storage
podman info --format '{{.Store.GraphRoot}}'
podman info --format '{{.Store.GraphDriverName}}'

# 7. 启动 LXCFS
echo "[*] 正在配置并启动 lxcfs..."
systemctl start lxcfs
systemctl enable lxcfs


# 8. 设置虚拟内存管理
echo "[*] 正在配置zram..."
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
compression-algorithm=lz4
zram-size=ram/2
fs-type=swap
swap-priority=100
EOF
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service


# 9. 安装并配置 rfw 防火墙
echo "[*] 正在安装 rfw 防火墙..."
mkdir -p /opt/narwhal-agent
curl -fsSL -o /opt/narwhal-agent/rfw.new https://github.com/narwhal-cloud/runman-agent/releases/download/v0.3.2/rfw-amd64
chmod +x /opt/narwhal-agent/rfw.new
systemctl is-active --quiet rfw && systemctl stop rfw
mv /opt/narwhal-agent/rfw.new /opt/narwhal-agent/rfw

cat > /etc/systemd/system/rfw.service <<EOF
[Unit]
Description=RFW eBPF Firewall
After=network.target

[Service]
Type=simple
User=root
Environment=RUST_LOG=info
WorkingDirectory=/opt/narwhal-agent
ExecStart=/opt/narwhal-agent/rfw --iface $NETWORK_IFACE --api-addr 127.0.0.1:7131
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now rfw

# 等待 API 服务就绪
echo "[*] 等待 rfw API 服务启动..."
sleep 2

# 10. 批量初始化防火墙规则
echo "[*] 正在添加默认安全规则..."

# 高风险地区入站协议拦截
for proto in http socks fet; do
    curl -s -X POST "http://127.0.0.1:7131/api/rules" \
        -H "Content-Type: application/json" \
        -d "{\"priority\":100,\"direction\":\"in\",\"protocol\":\"$proto\",\"action\":\"block\",\"port_start\":0,\"enabled\":true,\"ip_type\":\"geoip\",\"countries\":[\"CN\"]}"
    echo
done

# 出站 SMTP 端口封锁（防垃圾邮件）
for _port in 25 465 587; do
                curl -s -X POST "http://127.0.0.1:7131/api/rules" \
                    -H "Content-Type: application/json" \
                    -d "{\"priority\":100,\"direction\":\"out\",\"protocol\":\"tcp\",\"action\":\"block\",\"port_start\":$_port,\"enabled\":true,\"ip_type\":\"any\"}" 
                echo
done

# 11. podman启动守护
echo "[*] 正在添加启动守护服务..."
cat > /usr/lib/systemd/system/podman-restart.service <<'EOF'
[Unit]
Description=Podman Start All Containers With Restart Policy
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/bin/podman start --all --filter restart-policy=always --filter restart-policy=unless-stopped
ExecStop=/usr/bin/podman stop --all --filter restart-policy=always --filter restart-policy=unless-stopped

[Install]
WantedBy=default.target
EOF

systemctl daemon-reload
systemctl start podman-restart
systemctl enable podman-restart

systemctl start podman.socket
systemctl enable podman.socket



echo "[+] NarwhalCloud 初始化及规则配置全部完成！"
