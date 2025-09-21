#!/bin/bash

# --- 脚本配置与安全设置 ---
# 如果命令失败，立即退出
set -o errexit
# 如果管道失败，立即退出
set -o pipefail
# 将未设置的变量视为错误
set -o nounset

# --- 前置检查 ---
# 1. 检查 root 权限
if [[ $(id -u) -ne 0 ]]; then
   echo "❌ 此脚本必须以 root 用户身份运行。"
   exit 1
fi

# 2. 检查 systemd
if ! command -v systemctl >/dev/null 2>&1; then
    echo "❌ 抱歉，此脚本仅适用于带有 systemd 的 Linux 系统 (例如 Ubuntu 16.04+ / Centos 7+)。"
    exit 1
fi

# --- 主要安装逻辑 ---
echo "▶️ 开始安装最新版本的 gclone..."

# 1. 安装依赖 (curl, jq, unzip)
echo "🔩 正在安装依赖工具: curl, jq, unzip..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null
    apt-get install -y curl jq unzip >/dev/null
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl jq unzip >/dev/null
else
    echo "❌ 无法确定包管理器。请手动安装 curl, jq, 和 unzip。"
    exit 1
fi
echo "✅ 依赖安装完成。"

# 2. 判断系统架构
OSARCH=$(uname -m)
case $OSARCH in
    x86_64)  BINTAG=amd64 ;;
    i*86)    BINTAG=386 ;;
    aarch64) BINTAG=arm64 ;;
    arm64)   BINTAG=arm64 ;;
    armv7*)  BINTAG=arm-v7 ;; # 增加对 armv7 的精确匹配
    arm*)    BINTAG=arm ;;    # 保留 arm作为通用 armv6 等架构的回退
    *)
        echo "❌ 不支持的系统架构: $OSARCH"
        exit 1
        ;;
esac
echo "ℹ️ 检测到系统架构: $OSARCH (将匹配标签: $BINTAG)"

# 3. 从 GitHub API 获取最新版的下载地址 (关键修改)
echo "🌐 正在从 GitHub 获取最新版本下载地址..."
# ⭐【核心修改】: 使用了新的 jq 查询语句来适应 'gclone-vX.Y.Z-linux-ARCH.zip' 格式
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/dogbutcat/gclone/releases/latest | jq -r ".assets[] | select(.name | contains(\"linux-${BINTAG}\") and endswith(\".zip\")) | .browser_download_url")

if [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ 无法获取 gclone 的下载地址。请检查网络或确认该架构的 .zip 文件是否存在。"
    exit 1
fi
echo "✅ 成功获取下载地址: $DOWNLOAD_URL"

# 4. 下载、解压并安装
CLDBIN=/usr/bin/gclone
echo "📥 正在下载并安装 gclone 到 ${CLDBIN}..."

TMP_DIR=$(mktemp -d)
curl -sL "$DOWNLOAD_URL" -o "$TMP_DIR/gclone.zip"
unzip -p "$TMP_DIR/gclone.zip" "*/gclone" > ${CLDBIN}
rm -rf "$TMP_DIR"
chmod 0755 ${CLDBIN}
echo "🎉 gclone 安装成功!"

# 5. 验证安装
echo "🔍 验证安装版本:"
gclone version
