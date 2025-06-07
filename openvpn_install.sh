#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m\033[01m"
YELLOW="\033[33m\033[01m"
BLUE="\033[34m"
PLAIN="\033[0m"
red(){ echo -e "\033[31m\033[01m$1\033[0m" >&2; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

# 错误处理函数
error_exit() {
    red "错误：$1"
    exit 1
}

# 默认配置
DEFAULT_PORT=7005
DEFAULT_PROTOCOL="udp"
SERVER_IP=$(curl -s ifconfig.me)
CONFIG_DIR="/etc/openvpn"
SERVER_CONFIG="$CONFIG_DIR/server.conf"
CLIENT_CONFIG="$CONFIG_DIR/client.ovpn"
SILENT_MODE=false

# FRP配置
FRP_VERSION="v0.44.0"
FRPS_PORT="7000"
FRPS_UDP_PORT="7001"
FRPS_KCP_PORT="7002"
FRPS_TOKEN="DFRN2vbG123"

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    red "请使用 root 权限运行此脚本"
    exit 1
fi

# 静默输出函数 (已弃用，直接使用颜色函数或 echo)
# log() {
#     if [ "$SILENT_MODE" = false ]; then
#         echo -e "$1"
#     fi
# }

# 安装依赖
install_dependencies() {
    yellow "正在安装依赖..."
    apt-get update > /dev/null 2>&1 || error_exit "apt-get update 失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn easy-rsa openssl curl wget python3 > /dev/null 2>&1 || error_exit "依赖安装失败"
}

# 生成证书
generate_certificates() {
    yellow "正在生成证书..."
    mkdir -p /etc/openvpn/easy-rsa/ > /dev/null 2>&1 || error_exit "无法创建 easy-rsa 目录"
    cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/ > /dev/null 2>&1 || error_exit "复制 easy-rsa 文件失败"
    cd /etc/openvpn/easy-rsa/ || error_exit "无法进入 easy-rsa 目录"
    
    ./easyrsa --batch init-pki > /dev/null 2>&1 || error_exit "初始化 PKI 失败"
    yes "" | ./easyrsa --batch build-ca nopass > /dev/null 2>&1 || error_exit "生成 CA 证书失败"
    yes "" | ./easyrsa --batch build-server-full server nopass > /dev/null 2>&1 || error_exit "生成服务器证书失败"
    yes "" | ./easyrsa --batch build-client-full client nopass > /dev/null 2>&1 || error_exit "生成客户端证书失败"
    ./easyrsa --batch gen-dh > /dev/null 2>&1 || error_exit "生成 Diffie-Hellman 参数失败"
    openvpn --genkey secret /etc/openvpn/ta.key > /dev/null 2>&1 || error_exit "生成 ta.key 失败"
    cp /etc/openvpn/easy-rsa/pki/ca.crt /etc/openvpn/ > /dev/null 2>&1 || error_exit "复制 ca.crt 失败"
    cp /etc/openvpn/easy-rsa/pki/issued/server.crt /etc/openvpn/ > /dev/null 2>&1 || error_exit "复制 server.crt 失败"
    cp /etc/openvpn/easy-rsa/pki/private/server.key /etc/openvpn/ > /dev/null 2>&1 || error_exit "复制 server.key 失败"
    cp /etc/openvpn/easy-rsa/pki/dh.pem /etc/openvpn/ > /dev/null 2>&1 || error_exit "复制 dh.pem 失败"
}

# 创建服务器配置
create_server_config() {
    yellow "正在创建服务器配置..."
    cat > $SERVER_CONFIG << EOF || error_exit "创建服务器配置文件失败"
port $DEFAULT_PORT
proto $DEFAULT_PROTOCOL
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC
data-ciphers-fallback AES-256-CBC
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
tls-auth ta.key 0
remote-cert-tls client
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
log-append openvpn.log
verb 1
EOF
}

# 创建客户端配置
create_client_config() {
    yellow "正在创建客户端配置..."
    cat > $CLIENT_CONFIG << EOF || error_exit "创建客户端配置文件失败"
client
dev tun
proto $DEFAULT_PROTOCOL
remote $SERVER_IP $DEFAULT_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC
data-ciphers-fallback AES-256-CBC
remote-cert-tls server
verb 1

<ca>
$(cat $CONFIG_DIR/easy-rsa/pki/ca.crt)
</ca>
<cert>
$(cat $CONFIG_DIR/easy-rsa/pki/issued/client.crt)
</cert>
<key>
$(cat $CONFIG_DIR/easy-rsa/pki/private/client.key)
</key>
<tls-auth>
$(cat $CONFIG_DIR/ta.key)
</tls-auth>
key-direction 1
EOF
}

# 设置端口转发
setup_port_forwarding() {
    yellow "正在设置端口转发..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf > /dev/null 2>&1
    fi
    sysctl -p > /dev/null 2>&1
    
    PUB_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    
    cat > /etc/iptables.rules << EOF || error_exit "创建iptables规则文件失败"
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD -i tun0 -o ${PUB_IF} -j ACCEPT
-A FORWARD -i ${PUB_IF} -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.8.0.0/24 -o ${PUB_IF} -j MASQUERADE
COMMIT
EOF

    iptables-restore < /etc/iptables.rules || error_exit "应用iptables规则失败"
    
    cat > /etc/systemd/system/iptables.service << EOF || error_exit "创建iptables服务文件失败"
[Unit]
Description=Restore iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable iptables > /dev/null 2>&1 || error_exit "启用iptables服务失败"
}

# 启动服务
start_service() {
    yellow "正在启动 OpenVPN 服务..."
    systemctl enable openvpn@server > /dev/null 2>&1 || error_exit "启用 OpenVPN 服务失败"
    systemctl start openvpn@server > /dev/null 2>&1 || error_exit "启动 OpenVPN 服务失败"
    
    # 创建OpenVPN自启动服务
    if [[ ! -f /etc/systemd/system/openvpn-autostart.service ]]; then
        cat > /etc/systemd/system/openvpn-autostart.service << EOF || error_exit "创建 OpenVPN 自启动服务文件失败"
[Unit]
Description=OpenVPN Auto Start Service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "systemctl start openvpn@server"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable openvpn-autostart >/dev/null 2>&1 || error_exit "启用 OpenVPN 自启动服务失败"
    fi
}

# 卸载功能
uninstall() {
    yellow "正在卸载 OpenVPN..."
    systemctl stop openvpn@server > /dev/null 2>&1
    systemctl disable openvpn@server > /dev/null 2>&1
    systemctl disable openvpn-autostart > /dev/null 2>&1
    rm -f /etc/systemd/system/openvpn-autostart.service > /dev/null 2>&1
    systemctl stop iptables > /dev/null 2>&1
    systemctl disable iptables > /dev/null 2>&1
    rm -f /etc/systemd/system/iptables.service > /dev/null 2>&1
    rm -f /etc/iptables.rules > /dev/null 2>&1
    apt-get remove -y openvpn > /dev/null 2>&1
    rm -rf /etc/openvpn > /dev/null 2>&1
    systemctl daemon-reload > /dev/null 2>&1
    
    # 终止可能仍在运行的占用80端口的python3进程
    PID=$(lsof -i :80 | grep python3 | awk '{print $2}') > /dev/null 2>&1
    if [ -n "$PID" ]; then
        kill $PID > /dev/null 2>&1
        sleep 1
        if ps -p $PID > /dev/null 2>&1; then
            kill -9 $PID > /dev/null 2>&1
        fi
    fi
    
    green "OpenVPN 已成功卸载"
}

# 修改端口
change_port() {
    local new_port=$1
    yellow "正在修改端口为 $new_port..."
    sed -i "s/port [0-9]*/port $new_port/" $SERVER_CONFIG > /dev/null 2>&1 || error_exit "修改服务器端口失败"
    sed -i "s/remote $SERVER_IP [0-9]*/remote $SERVER_IP $new_port/" $CLIENT_CONFIG > /dev/null 2>&1 || error_exit "修改客户端端口失败"
    systemctl restart openvpn@server > /dev/null 2>&1 || error_exit "重启OpenVPN服务失败"
    green "端口已成功修改为 $new_port"
}

# 生成下载链接
generate_download_link() {
    yellow "正在生成客户端下载链接..."
    local config_path="$CONFIG_DIR/client.ovpn"
    if [ -f "$config_path" ]; then
        if lsof -i :80 > /dev/null 2>&1; then
            red "错误：80 端口已被占用，请先关闭占用该端口的服务"
            exit 1
        fi
        green "客户端配置文件下载链接："
        red "http://$SERVER_IP/client.ovpn"
        echo ""
        # 确保下载目录存在
        mkdir -p $CONFIG_DIR || error_exit "无法创建下载目录 $CONFIG_DIR"
        
        # 切换到配置目录启动HTTP服务器
        (cd $CONFIG_DIR && python3 -m http.server 80 > /dev/null 2>&1 & 
         pid=$!
         sleep 600
         kill $pid 2>/dev/null) &
        
        exit 0
    else
        red "客户端配置文件不存在"
    fi
}

# 卸载旧版FRPS
uninstall_frps() {
    yellow "卸载旧版FRPS服务..."
    systemctl stop frps >/dev/null 2>&1
    systemctl disable frps >/dev/null 2>&1
    rm -f /etc/systemd/system/frps.service > /dev/null 2>&1
    rm -rf /usr/local/frp /etc/frp > /dev/null 2>&1
    systemctl daemon-reload >/dev/null 2>&1
    green "旧版FRPS服务已成功卸载"
}

# 安装FRPS
install_frps() {
    yellow "安装FRPS服务..."
    uninstall_frps
    local FRP_NAME="frp_${FRP_VERSION#v}_linux_amd64"
    local FRP_FILE="${FRP_NAME}.tar.gz"
    cd /usr/local/ || error_exit "无法进入 /usr/local 目录"
    if ! wget "https://github.com/fatedier/frp/releases/download/${FRP_VERSION}/${FRP_FILE}" -O "${FRP_FILE}" >/dev/null 2>&1; then
        error_exit "FRPS下载失败"
    fi
    if ! tar -zxf "${FRP_FILE}" >/dev/null 2>&1; then
        rm -f "${FRP_FILE}" >/dev/null 2>&1
        error_exit "FRPS解压失败"
    fi
    cd "${FRP_NAME}" || error_exit "无法进入解压目录"
    mkdir -p /usr/local/frp >/dev/null 2>&1 || error_exit "无法创建FRP目录"
    if ! cp frps /usr/local/frp/ >/dev/null 2>&1; then
        error_exit "FRPS复制失败"
    fi
    chmod +x /usr/local/frp/frps
    mkdir -p /etc/frp >/dev/null 2>&1 || error_exit "无法创建FRP配置目录"
    {
        echo "[common]"
        echo "bind_addr = 0.0.0.0"
        echo "bind_port = ${FRPS_PORT}"
        echo "bind_udp_port = ${FRPS_UDP_PORT}"
        echo "kcp_bind_port = ${FRPS_KCP_PORT}"
        echo "token = $FRPS_TOKEN"
        echo "log_level = silent"
        echo "disable_log_color = true"
    } > /etc/frp/frps.toml || error_exit "无法创建FRP配置文件"
    {
        echo "[Unit]"
        echo "Description=FRP Server"
        echo "After=network.target"
        echo "[Service]"
        echo "Type=simple"
        echo "ExecStart=/usr/local/frp/frps -c /etc/frp/frps.toml"
        echo "Restart=on-failure"
        echo "LimitNOFILE=1048576"
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > /etc/systemd/system/frps.service || error_exit "无法创建FRP服务文件"
    if ! systemctl daemon-reload >/dev/null 2>&1; then
        error_exit "FRPS服务重载失败"
    fi
    if ! systemctl enable --now frps >/dev/null 2>&1; then
        systemctl status frps
        error_exit "FRPS服务启动失败"
    fi
    green "FRPS安装成功"
    rm -rf /usr/local/frp_* /usr/local/frp_*_linux_amd64 > /dev/null 2>&1
    show_frps_info
}

# 显示FRPS信息
show_frps_info() {
    yellow ">>> FRPS服务状态："
    systemctl is-active frps
    yellow ">>> FRPS信息："
    echo "服务器地址: $(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
    red "FRPS 密码: $FRPS_TOKEN"
    red "TCP端口: $FRPS_PORT"
    red "UDP端口: $FRPS_UDP_PORT"
    red "KCP端口: $FRPS_KCP_PORT\n"
}

# 主菜单
main_menu() {
    while true; do
        green "\n请选择操作："
        echo "1) 安装 OpenVPN + FRP"
        echo "2) 卸载 OpenVPN"
        echo "3) 修改端口"
        echo "4) 生成客户端下载链接"
        echo "5) 卸载 FRP"
        echo "6) 显示 FRP 信息"
        echo "7) 退出"
        read -t 30 -p "请输入数字 [1-7]: " choice
        if [ -z "$choice" ]; then
            yellow "未输入选项，请重新输入"
            continue
        fi
        case $choice in
            1)
                install_dependencies
                generate_certificates
                create_server_config
                create_client_config
                setup_port_forwarding
                start_service
                install_frps
                green "======================================================================================"
                green "OpenVPN + FRP 安装完成！"
                yellow "OpenVPN 端口: $DEFAULT_PORT"
                yellow "OpenVPN 协议: $DEFAULT_PROTOCOL"
                echo ""
                green "====================================================================================="
                echo ""
                generate_download_link
                exit 0
                ;;
            2)
                uninstall
                ;;
            3)
                # 自动输入端口，无需回车
                new_port=7005
                change_port $new_port
                ;;
            4)
                generate_download_link
                ;;
            5)
                uninstall_frps
                ;;
            6)
                show_frps_info
                ;;
            7)
                yellow "已退出"
                exit 0
                ;;
            *)
                red "无效选择，请重新输入"
                ;;
        esac
    done
}

# 执行主菜单
main_menu 