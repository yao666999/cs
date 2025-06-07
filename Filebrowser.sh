#!/bin/bash

# FileBrowser一键安装脚本
# 支持Linux系统，包括Ubuntu, Debian, CentOS等

# 处理命令行参数
if [ "$1" = "--auto" ] || [ "$1" = "-a" ]; then
    # 自动安装模式
    auto_install=true
    
    # 读取参数
    for i in "$@"; do
        case $i in
            --path=*|--root=*)
            file_path="${i#*=}"
            ;;
            --port=*)
            port="${i#*=}"
            ;;
            --user=*)
            admin_user="${i#*=}"
            ;;
            --password=*)
            admin_password="${i#*=}"
            ;;
            --help|-h)
            echo "FileBrowser自动安装模式用法:"
            echo "  $0 --auto [选项]"
            echo ""
            echo "选项:"
            echo "  --path=PATH      指定文件存储路径 (默认: /home/files)"
            echo "  --port=PORT      指定端口 (默认: 8080)"
            echo "  --user=USER      指定管理员用户名 (默认: admin)"
            echo "  --password=PASS  指定管理员密码 (默认: admin)"
            echo "  --help, -h       显示此帮助信息"
            echo ""
            echo "示例:"
            echo "  $0 --auto --path=/data/files --port=8888 --user=admin --password=secure123"
            exit 0
            ;;
        esac
    done
    
    # 设置默认值
    file_path=${file_path:-/home/files}
    port=${port:-8080}
    admin_user=${admin_user:-admin}
    admin_password=${admin_password:-admin}
    
    # 调用静默安装函数
    install_filebrowser_silent
    exit 0
fi

# 显示菜单
show_menu() {
    clear
    echo "===== FileBrowser 管理脚本 ====="
    echo "1. 安装 FileBrowser"
    echo "2. 卸载 FileBrowser"
    echo "3. 重置管理员密码"
    echo "4. 静默安装(自动)"
    echo "5. 退出"
    echo "================================="
    echo -n "请输入选项 [1-5]: "
    read -r choice
    case $choice in
        1) install_filebrowser ;;
        2) uninstall_filebrowser ;;
        3) reset_admin_password ;;
        4) 
            echo "请输入文件存储路径 (默认: /home/files):"
            read -r file_path
            file_path=${file_path:-/home/files}
            
            echo "请输入端口 (默认: 8080):"
            read -r port
            port=${port:-8080}
            
            echo "请输入管理员用户名 (默认: admin):"
            read -r admin_user
            admin_user=${admin_user:-admin}
            
            echo "请输入管理员密码 (默认: admin):"
            read -r admin_password
            admin_password=${admin_password:-admin}
            
            install_filebrowser_silent
            ;;
        5) exit 0 ;;
        *) echo "无效选项，请重新选择"; sleep 2; show_menu ;;
    esac
}

# 获取配置文件路径
get_db_path() {
    # 首先检查服务文件中的路径
    if [ -f "/etc/systemd/system/filebrowser.service" ]; then
        DB_PATH=$(grep -o "\-\-database [^ ]*" /etc/systemd/system/filebrowser.service | cut -d' ' -f2 | tr -d '"')
        
        # 如果找不到，尝试检查 -d 参数
        if [ -z "$DB_PATH" ]; then
            DB_PATH=$(grep -o "\-d [^ ]*" /etc/systemd/system/filebrowser.service | cut -d' ' -f2 | tr -d '"')
        fi
        
        # 如果还是找不到，使用默认路径
        if [ -z "$DB_PATH" ]; then
            DB_PATH="$HOME/.config/filebrowser/filebrowser.db"
        fi
    else
        # 默认路径
        DB_PATH="$HOME/.config/filebrowser/filebrowser.db"
    fi
    
    echo "$DB_PATH"
}

# 静默安装FileBrowser函数
install_filebrowser_silent() {
    echo "开始静默安装FileBrowser..."

    # 检查系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        echo "检测到系统: $OS"
    else
        echo "无法检测系统类型，将尝试使用通用安装方法"
        OS="Unknown"
    fi

    # 检查是否已安装curl
    if ! command -v curl &> /dev/null; then
        echo "安装curl..."
        if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
            sudo apt-get update -qq
            sudo apt-get install -y curl -qq
        elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Red Hat"* ]] || [[ "$OS" == *"Fedora"* ]]; then
            sudo yum install -y curl -q
        else
            echo "请手动安装curl后再运行此脚本"
            exit 1
        fi
    fi

    # 安装FileBrowser
    echo "下载并安装FileBrowser..."
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

    # 创建配置目录
    echo "创建配置目录..."
    mkdir -p ~/.config/filebrowser

    # 确保存储路径存在
    mkdir -p "$file_path"
    
    # 设置数据库路径
    DB_PATH="$HOME/.config/filebrowser/filebrowser.db"
    
    # 初始化配置
    echo "初始化FileBrowser配置..."
    filebrowser config init --address 0.0.0.0 --port "$port" --root "$file_path" --database "$DB_PATH"

    # 创建管理员用户
    echo "创建管理员用户..."
    filebrowser users add "$admin_user" "$admin_password" --perm.admin --database "$DB_PATH" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo "创建用户失败，尝试删除已存在的用户后重新创建..."
        filebrowser users rm "$admin_user" --database "$DB_PATH" 2>/dev/null
        filebrowser users add "$admin_user" "$admin_password" --perm.admin --database "$DB_PATH"
    fi

    # 创建systemd服务
    echo "创建systemd服务..."
    cat > filebrowser.service << EOL
[Unit]
Description=FileBrowser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser --address 0.0.0.0 --port $port --root "$file_path" --database "$DB_PATH"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

    # 安装服务
    echo "安装systemd服务..."
    sudo mv filebrowser.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable filebrowser
    sudo systemctl start filebrowser

    # 检查服务是否成功启动
    sleep 2
    if systemctl is-active --quiet filebrowser; then
        echo "FileBrowser服务启动成功！"
    else
        echo "警告: FileBrowser服务可能未成功启动，请检查状态: sudo systemctl status filebrowser"
    fi

    # 获取服务器IP
    SERVER_IP=$(curl -s ifconfig.me || wget -qO- ifconfig.co || hostname -I | awk '{print $1}')

    echo "============================================================"
    echo "FileBrowser安装完成！"
    echo "============================================================"
    echo "管理员用户名: $admin_user"
    echo "管理员密码: $admin_password"
    echo "访问地址: http://$SERVER_IP:$port"
    echo "文件存储位置: $file_path"
    echo "数据库位置: $DB_PATH"
    echo "============================================================"
    echo "管理命令:"
    echo "启动服务: sudo systemctl start filebrowser"
    echo "停止服务: sudo systemctl stop filebrowser"
    echo "重启服务: sudo systemctl restart filebrowser"
    echo "查看状态: sudo systemctl status filebrowser"
    echo "============================================================"
    
    if [ "$auto_install" != "true" ]; then
        echo ""
        echo "按任意键返回主菜单..."
        read -n 1
        show_menu
    fi
}

# 安装FileBrowser函数
install_filebrowser() {
    echo "开始安装FileBrowser..."

    # 检查系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        echo "检测到系统: $OS"
    else
        echo "无法检测系统类型，将尝试使用通用安装方法"
        OS="Unknown"
    fi

    # 检查是否已安装curl
    if ! command -v curl &> /dev/null; then
        echo "安装curl..."
        if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
            sudo apt-get update
            sudo apt-get install -y curl
        elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Red Hat"* ]] || [[ "$OS" == *"Fedora"* ]]; then
            sudo yum install -y curl
        else
            echo "请手动安装curl后再运行此脚本"
            exit 1
        fi
    fi

    # 安装FileBrowser
    echo "下载并安装FileBrowser..."
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

    # 创建配置目录
    echo "创建配置目录..."
    mkdir -p ~/.config/filebrowser

    # 设置存储路径
    echo "请输入文件存储路径 (默认: /home/files):"
    read -r file_path
    file_path=${file_path:-/home/files}
    
    # 确保存储路径存在
    mkdir -p "$file_path"
    
    # 设置端口
    echo "请输入端口 (默认: 8080):"
    read -r port
    port=${port:-8080}
    
    # 设置数据库路径
    DB_PATH="$HOME/.config/filebrowser/filebrowser.db"
    
    # 初始化配置
    echo "初始化FileBrowser配置..."
    filebrowser config init --address 0.0.0.0 --port "$port" --root "$file_path" --database "$DB_PATH"

    # 设置管理员用户和密码
    echo "请设置管理员用户名 (默认: admin):"
    read -r admin_user
    admin_user=${admin_user:-admin}
    
    echo "请设置管理员密码 (默认: admin):"
    read -r admin_password
    admin_password=${admin_password:-admin}

    # 创建管理员用户
    echo "创建管理员用户..."
    filebrowser users add "$admin_user" "$admin_password" --perm.admin --database "$DB_PATH"
    
    if [ $? -ne 0 ]; then
        echo "创建用户失败，尝试删除已存在的用户后重新创建..."
        filebrowser users rm "$admin_user" --database "$DB_PATH"
        filebrowser users add "$admin_user" "$admin_password" --perm.admin --database "$DB_PATH"
    fi

    # 创建systemd服务
    echo "创建systemd服务..."
    cat > filebrowser.service << EOL
[Unit]
Description=FileBrowser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser --address 0.0.0.0 --port $port --root "$file_path" --database "$DB_PATH"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

    # 安装服务
    echo "安装systemd服务..."
    sudo mv filebrowser.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable filebrowser
    sudo systemctl start filebrowser

    # 检查服务是否成功启动
    sleep 2
    if systemctl is-active --quiet filebrowser; then
        echo "FileBrowser服务启动成功！"
    else
        echo "警告: FileBrowser服务可能未成功启动，请检查状态: sudo systemctl status filebrowser"
    fi

    # 获取服务器IP
    SERVER_IP=$(curl -s ifconfig.me || wget -qO- ifconfig.co || hostname -I | awk '{print $1}')

    echo "FileBrowser安装完成！"
    echo "管理员用户名: $admin_user"
    echo "管理员密码: $admin_password"
    echo "请访问 http://$SERVER_IP:$port 来使用FileBrowser"
    echo "请务必登录后立即修改默认密码！"
    echo ""
    echo "文件存储位置: $file_path"
    echo "数据库位置: $DB_PATH"
    echo ""
    echo "管理命令:"
    echo "启动服务: sudo systemctl start filebrowser"
    echo "停止服务: sudo systemctl stop filebrowser"
    echo "重启服务: sudo systemctl restart filebrowser"
    echo "查看状态: sudo systemctl status filebrowser"
    
    echo ""
    echo "按任意键返回主菜单..."
    read -n 1
    show_menu
}

# 重置管理员密码函数
reset_admin_password() {
    echo "重置FileBrowser管理员密码..."
    
    # 获取数据库路径
    DB_PATH=$(get_db_path)
    
    if [ ! -f "$DB_PATH" ]; then
        echo "错误: 未找到FileBrowser数据库文件，请先安装FileBrowser"
        echo "数据库路径: $DB_PATH"
        echo ""
        echo "按任意键返回主菜单..."
        read -n 1
        show_menu
        return
    fi
    
    echo "当前数据库路径: $DB_PATH"
    
    # 列出所有用户
    echo "当前用户列表:"
    filebrowser users ls --database "$DB_PATH"
    
    echo "请输入要重置的用户名 (默认: admin):"
    read -r reset_user
    reset_user=${reset_user:-admin}
    
    echo "请输入新密码 (默认: admin):"
    read -r new_password
    new_password=${new_password:-admin}
    
    # 重置密码
    echo "重置用户 $reset_user 的密码..."
    filebrowser users update "$reset_user" --password "$new_password" --database "$DB_PATH"
    
    if [ $? -eq 0 ]; then
        echo "密码重置成功！"
        echo "用户名: $reset_user"
        echo "新密码: $new_password"
        
        # 重启服务应用更改
        echo "重启FileBrowser服务..."
        sudo systemctl restart filebrowser
    else
        echo "密码重置失败，可能是用户不存在"
        echo "尝试创建新的管理员用户..."
        filebrowser users add "$reset_user" "$new_password" --perm.admin --database "$DB_PATH"
        
        if [ $? -eq 0 ]; then
            echo "已创建新的管理员用户"
            echo "重启FileBrowser服务..."
            sudo systemctl restart filebrowser
        else
            echo "用户创建也失败，请检查FileBrowser安装状态"
        fi
    fi
    
    echo ""
    echo "按任意键返回主菜单..."
    read -n 1
    show_menu
}

# 卸载FileBrowser函数
uninstall_filebrowser() {
    echo "开始卸载FileBrowser..."
    
    # 停止并禁用服务
    echo "停止FileBrowser服务..."
    sudo systemctl stop filebrowser
    sudo systemctl disable filebrowser
    
    # 删除服务文件
    echo "删除服务文件..."
    sudo rm -f /etc/systemd/system/filebrowser.service
    sudo systemctl daemon-reload
    
    # 删除FileBrowser二进制文件
    echo "删除FileBrowser程序..."
    sudo rm -f /usr/local/bin/filebrowser
    
    # 删除配置文件
    echo "删除配置文件..."
    read -p "是否删除配置文件和数据库? (y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        rm -rf ~/.config/filebrowser
        echo "配置文件和数据库已删除"
    else
        echo "保留配置文件和数据库"
    fi
    
    echo "FileBrowser卸载完成！"
    echo ""
    echo "按任意键返回主菜单..."
    read -n 1
    show_menu
}

# 显示帮助信息
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "FileBrowser一键安装脚本"
    echo "用法:"
    echo "  $0                     交互式安装(显示菜单)"
    echo "  $0 --auto [选项]       自动安装(无交互)"
    echo ""
    echo "自动安装选项:"
    echo "  --path=PATH      指定文件存储路径 (默认: /home/files)"
    echo "  --port=PORT      指定端口 (默认: 8080)"
    echo "  --user=USER      指定管理员用户名 (默认: admin)"
    echo "  --password=PASS  指定管理员密码 (默认: admin)"
    echo "  --help, -h       显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --auto --path=/data/files --port=8888 --user=admin --password=secure123"
    exit 0
fi

# 显示主菜单(如果不是自动模式)
if [ "$auto_install" != "true" ]; then
    show_menu
fi 