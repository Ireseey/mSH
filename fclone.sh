#!/bin/bash
# 设置默认的环境变量路径
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 定义彩色输出，方便阅读
GREEN="\033[32m"
NC="\033[0m" # No Color

function fclone_install()
{
    echo "正在检查 Fclone 是否已安装..."
    # 尝试执行 fclone --version，并将输出重定向到/dev/null来保持整洁
    if fclone --version &> /dev/null; then
        # $? -eq 0 表示上一条命令成功执行
        echo -e "${GREEN}检测到 Fclone 已安装! 版本信息如下:${NC}"
        fclone --version
    else
        echo "未检测到 Fclone，即将开始安装最新版本..."

        # 1. 安装必要的依赖工具 (curl, jq, unzip)
        # curl 用于访问API, jq 用于解析JSON响应, unzip 用于解压
        echo "正在安装依赖工具: curl, jq, unzip..."
        # 使用 DEBIAN_FRONTEND=noninteractive 避免安装过程中出现交互提示
        sudo DEBIAN_FRONTEND=noninteractive apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq unzip fuse

        # 2. 从 GitHub API 获取最新版本 Fclone 的下载地址
        echo "正在从 GitHub 获取最新版本信息..."
        # 使用 -s (silent) 使 curl 静默运行, -L 跟随重定向
        # 通过 jq 解析返回的 JSON 数据，找到 linux-amd64.zip 文件的下载URL
        LATEST_URL=$(curl -sL https://api.github.com/repos/mawaya/rclone/releases/latest | jq -r ".assets[] | select(.name | test(\"linux-amd64.zip$\")) | .browser_download_url")

        # 检查是否成功获取到 URL
        if [ -z "$LATEST_URL" ]; then
            echo -e "\033[31m错误：无法获取 Fclone 最新版本的下载地址。请检查网络或稍后再试。\033[0m"
            exit 1
        fi
        
        echo "成功获取最新版本下载地址: $LATEST_URL"

        # 3. 下载并安装 Fclone
        echo "正在下载最新版 Fclone..."
        # 创建一个临时目录来处理文件，避免污染系统
        WORK_DIR=$(mktemp -d)
        
        # 使用 wget 下载文件到临时目录，-q 安静模式，-O 指定输出文件名
        wget -qO "$WORK_DIR/fclone.zip" "$LATEST_URL"
        if [ $? -ne 0 ]; then
            echo -e "\033[31m错误：Fclone 下载失败。\033[0m"
            rm -rf "$WORK_DIR" # 清理临时目录
            exit 1
        fi

        echo "正在解压文件..."
        # -o 覆盖已存在文件，-d 指定解压目录
        unzip -o "$WORK_DIR/fclone.zip" -d "$WORK_DIR"
        
        echo "正在安装 Fclone 到 /usr/local/bin/..."
        # 使用 * 通配符匹配解压后带有版本号的文件夹名
        # 将 fclone 可执行文件移动到 /usr/local/bin，这是存放用户自行安装程序的推荐位置
        sudo mv "$WORK_DIR"/*/fclone /usr/local/bin/
        
        # 赋予可执行权限
        sudo chmod +x /usr/local/bin/fclone

        # 4. 清理临时文件
        echo "清理临时文件..."
        rm -rf "$WORK_DIR"

        # 5. 验证安装结果
        echo -e "${GREEN}Fclone 最新版安装成功!${NC}"
        echo "版本信息："
        fclone --version
    fi
}

# 执行安装函数
fclone_install
