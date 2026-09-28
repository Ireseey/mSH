#!/bin/bash
#
# 用法:
#   sudo bash rclone-mod.sh
#   sudo bash rclone-mod.sh v1.75.1-332          # 指定版本
#   GH_PROXY=https://ghfast.top sudo bash rclone-mod.sh
#   GITHUB_TOKEN=ghp_xxx sudo bash rclone-mod.sh  # 降低 API 限流
set -o errexit
set -o pipefail
set -o nounset

REPO="wiserain/rclone"
BIN_NAME="rclone"
INSTALL_PATH="/usr/bin/${BIN_NAME}"

# --- 前置检查 ---
# 1. 检查 root 权限
if [[ $(id -u) -ne 0 ]]; then
   echo "此脚本必须以 root 用户身份运行。"
   exit 1
fi

# --- 主要安装逻辑 ---
echo "开始安装最新版本的 wiserain/rclone（115 改版）..."

# 1. 安装依赖 (curl, jq, unzip)
echo "正在安装依赖工具: curl, jq, unzip..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null
    apt-get install -y curl jq unzip >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq unzip >/dev/null
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl jq unzip >/dev/null
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl jq unzip >/dev/null
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl jq unzip >/dev/null
else
    echo "无法确定包管理器。请手动安装 curl, jq, 和 unzip。"
    exit 1
fi
echo "依赖安装完成。"

# 2. 判断系统架构
# wiserain 发布包命名: rclone-<tag>-linux-<arch>.zip
# 例: rclone-v1.75.1-332-linux-amd64.zip
OSARCH=$(uname -m)
case $OSARCH in
    x86_64|amd64) BINTAG=amd64 ;;
    i*86|x86)     BINTAG=386 ;;
    aarch64)      BINTAG=arm64 ;;
    arm64)        BINTAG=arm64 ;;
    armv7*)       BINTAG=arm-v7 ;;
    armv6*)       BINTAG=arm-v6 ;;
    arm*)         BINTAG=arm ;;
    *)
        echo "不支持的系统架构: $OSARCH"
        exit 1
        ;;
esac
echo "检测到系统架构: $OSARCH (将匹配标签: linux-${BINTAG})"

# 3. 从 GitHub API 获取最新版的下载地址
echo "正在从 GitHub 获取发行版信息..."

GH_API="https://api.github.com/repos/${REPO}/releases"
GH_PROXY="${GH_PROXY:-}"
if [[ -n "$GH_PROXY" ]]; then
    GH_PROXY="${GH_PROXY%/}"
    echo "使用代理前缀: ${GH_PROXY}"
fi

curl_gh() {
    local url="$1"
    local args=(-fsSL --retry 3 --retry-delay 2)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    args+=(-H "Accept: application/vnd.github+json")
    if [[ -n "$GH_PROXY" ]]; then
        url="${GH_PROXY}/${url}"
    fi
    curl "${args[@]}" "$url"
}

# 可选: 第一个参数指定 tag，例如 v1.75.1-332
TAG_NAME="${1:-}"
if [[ -n "$TAG_NAME" ]]; then
    echo "使用指定版本: ${TAG_NAME}"
    API_RESPONSE=$(curl_gh "${GH_API}/tags/${TAG_NAME}")
else
    API_RESPONSE=$(curl_gh "${GH_API}/latest")
fi

if ! echo "$API_RESPONSE" | jq -e '.tag_name' >/dev/null 2>&1; then
    echo "无法解析 GitHub API 响应。"
    echo "可能是速率限制、仓库不可达或 tag 不存在。返回片段:"
    echo "$API_RESPONSE" | head -c 300
    echo
    exit 1
fi

TAG_NAME=$(echo "$API_RESPONSE" | jq -r '.tag_name')
echo "目标版本: ${TAG_NAME}"

# 若已安装同一改版版本则跳过
if command -v rclone >/dev/null 2>&1; then
    INSTALLED=$(rclone version 2>/dev/null | head -n1 || true)
    echo "当前已安装: ${INSTALLED:-未知}"
    if echo "$INSTALLED" | grep -Fq "$TAG_NAME"; then
        echo "已是目标版本，无需重复安装。"
        rclone version
        exit 0
    fi
fi

# 使用 jq 安全解析 (增加 ? 防止 null 异常)
# 资源名形如 rclone-v1.75.1-332-linux-amd64.zip，避免误匹配 .deb/.rpm
DOWNLOAD_URL=$(echo "$API_RESPONSE" | jq -r --arg arch "linux-${BINTAG}" '
    .assets[]?
    | select(.name | test("rclone-.*-" + $arch + "\\.zip$"))
    | .browser_download_url
' | head -n1)

if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
    echo "无法获取 ${REPO} 的 linux-${BINTAG}.zip 下载地址。"
    echo "可用资源:"
    echo "$API_RESPONSE" | jq -r '.assets[]?.name' || true
    exit 1
fi

if [[ -n "$GH_PROXY" ]]; then
    DOWNLOAD_URL="${GH_PROXY}/${DOWNLOAD_URL}"
fi
echo "成功获取下载地址: ${DOWNLOAD_URL}"

# 4. 下载、解压并安全安装
echo "正在下载并安装 rclone 到 ${INSTALL_PATH}..."

# 创建临时目录并注册清理钩子 (无论成功或失败都会触发)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL --retry 3 --retry-delay 2 "$DOWNLOAD_URL" -o "$TMP_DIR/rclone.zip"

# zip 内目录一般为 rclone-<tag>-linux-<arch>/rclone
if ! unzip -l "$TMP_DIR/rclone.zip" | awk '{print $NF}' | grep -Eq '(^|/)rclone$'; then
    echo "压缩包中未找到 rclone 二进制。"
    unzip -l "$TMP_DIR/rclone.zip" || true
    exit 1
fi

unzip -p "$TMP_DIR/rclone.zip" "*/rclone" > "$TMP_DIR/rclone_bin" \
    || unzip -p "$TMP_DIR/rclone.zip" "rclone" > "$TMP_DIR/rclone_bin"

if [[ ! -s "$TMP_DIR/rclone_bin" ]]; then
    echo "提取 rclone 二进制失败。"
    exit 1
fi

# 赋予执行权限并安全移动 (原子替换，避免覆盖到一半)
chmod 0755 "$TMP_DIR/rclone_bin"
chown root:root "$TMP_DIR/rclone_bin" 2>/dev/null || true
mv "$TMP_DIR/rclone_bin" "${INSTALL_PATH}"

# 可选 man page
if unzip -l "$TMP_DIR/rclone.zip" | awk '{print $NF}' | grep -Eq '(^|/)rclone\\.1$'; then
    if command -v mandb >/dev/null 2>&1; then
        mkdir -p /usr/local/share/man/man1
        unzip -p "$TMP_DIR/rclone.zip" "*/rclone.1" > /usr/local/share/man/man1/rclone.1 \
            || unzip -p "$TMP_DIR/rclone.zip" "rclone.1" > /usr/local/share/man/man1/rclone.1
        chmod 0644 /usr/local/share/man/man1/rclone.1
        mandb >/dev/null 2>&1 || true
    fi
fi

echo "rclone 改版安装成功!"

# 5. 验证安装
echo "验证安装版本:"
rclone version
echo
echo "这是 wiserain/rclone（含 115 backend），会覆盖系统里原有的 /usr/bin/rclone。"
echo "接下来可运行: rclone config"
echo "115 配置通常使用 cookie: UID=...; CID=...; SEID=...; KID=..."
echo "文档: https://github.com/wiserain/rclone"
