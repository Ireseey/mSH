#!/bin/bash

# --- 脚本配置与安全设置 ---
set -o errexit
set -o pipefail
set -o nounset

# --- 前置检查 ---
# 1. 检查 root 权限
if [[ $(id -u) -ne 0 ]]; then
   echo "❌ 此脚本必须以 root 用户身份运行。"
   exit 1
fi

# (已移除单纯的 systemd 检查，除非你需要配置守护进程)

# --- 主要安装逻辑 ---
echo "▶️ 开始安装最新版本的 gclone..."

# 1. 安装依赖 (curl, jq, unzip)
echo "🔩 正在安装依赖工具: curl, jq, unzip..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null
    apt-get install -y curl jq unzip >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq unzip >/dev/null
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
    armv7*)  BINTAG=arm-v7 ;;
    arm*)    BINTAG=arm ;;
    *)
        echo "❌ 不支持的系统架构: $OSARCH"
        exit 1
        ;;
esac
echo "ℹ️ 检测到系统架构: $OSARCH (将匹配标签: $BINTAG)"

# 3. 从 GitHub API 获取最新版的下载地址
echo "🌐 正在从 GitHub 获取最新版本下载地址..."

# 获取 API 响应，防止因网络或限流导致直接失败
API_RESPONSE=$(curl -s https://api.github.com/repos/dogbutcat/gclone/releases/latest)

# 使用 jq 安全解析 (增加 ? 防止 null 异常)
DOWNLOAD_URL=$(echo "$API_RESPONSE" | jq -r ".assets[]? | select(.name | contains(\"linux-${BINTAG}\") and endswith(\".zip\")) | .browser_download_url")

if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
    echo "❌ 无法获取 gclone 的下载地址。"
    echo "🔍 API 响应信息可能为速率限制或文件不存在。返回片段: $(echo "$API_RESPONSE" | head -c 100)..."
    exit 1
fi
echo "✅ 成功获取下载地址: $DOWNLOAD_URL"

# 4. 下载、解压并安全安装
CLDBIN=/usr/bin/gclone
echo "📥 正在下载并安装 gclone 到 ${CLDBIN}..."

# 创建临时目录并注册清理钩子 (无论成功或失败都会触发)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 下载并提取二进制文件到临时目录
curl -sL "$DOWNLOAD_URL" -o "$TMP_DIR/gclone.zip"
unzip -p "$TMP_DIR/gclone.zip" "*/gclone" > "$TMP_DIR/gclone_bin"

# 赋予执行权限并安全移动 (原子替换)
chmod 0755 "$TMP_DIR/gclone_bin"
mv "$TMP_DIR/gclone_bin" "${CLDBIN}"

echo "🎉 gclone 安装成功!"

# 5. 验证安装
echo "🔍 验证安装版本:"
gclone version
