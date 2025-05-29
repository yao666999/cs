#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要root权限运行" 
   exit 1
fi

# 更新系统
apt update && apt upgrade -y

# 安装必要的依赖
apt install -y curl wget unzip

# 下载并安装xray-ui
wget -N https://raw.githubusercontent.com/vaxilu/xray-ui/master/install.sh
bash install.sh

# 修改面板端口为7006
sed -i 's/54321/7006/g' /etc/xray-ui/xray-ui.db

# 重启xray-ui服务
systemctl restart xray-ui

# 设置开机自启
systemctl enable xray-ui

echo "xray-ui 安装完成！"
echo "面板地址: http://服务器IP:7006"
echo "默认用户名: admin"
echo "默认密码: admin"
