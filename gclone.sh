#!/usr/bin/env bash
#
# gclone 安装脚本（dogbutcat/gclone）
#
# 用法:
#   sudo bash gclone.sh                         # 安装最新版
#   sudo bash gclone.sh v1.73.3-mod1.6.2        # 指定版本
#   sudo bash gclone.sh --version v1.71.0-mod1.6.2
#   bash gclone.sh --user                       # 安装到 ~/.local/bin（无需 root）
#   bash gclone.sh --list                       # 列出近期发行版
#   bash gclone.sh --check                      # 对比已装版本与最新版
#   sudo bash gclone.sh --uninstall             # 卸载
#   sudo bash gclone.sh --force                 # 强制重装当前目标版本
#   sudo PREFIX=/usr/local/bin bash gclone.sh   # 自定义安装目录
#   GH_PROXY=https://ghfast.top sudo bash gclone.sh
#   GITHUB_TOKEN=ghp_xxx sudo bash gclone.sh    # 降低 GitHub API 限流
#
set -o errexit
set -o pipefail
set -o nounset

REPO="dogbutcat/gclone"
BIN_NAME="gclone"
GH_API="https://api.github.com/repos/${REPO}/releases"
GH_PROXY="${GH_PROXY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

ACTION="install"
REQ_VERSION=""
FORCE=0
USER_INSTALL=0
DRY_RUN=0
BACKUP=0
LIST_LIMIT=15
CUSTOM_PREFIX="${PREFIX:-}"

# --- 终端输出 ---
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GRN=$'\033[32m'
    C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'
    C_CYN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""
fi

log()  { printf '%s\n' "$*"; }
info() { printf '%sℹ%s %s\n' "${C_CYN}" "${C_RESET}" "$*" >&2; }
ok()   { printf '%s✔%s %s\n' "${C_GRN}" "${C_RESET}" "$*" >&2; }
warn() { printf '%s⚠%s %s\n' "${C_YEL}" "${C_RESET}" "$*" >&2; }
err()  { printf '%s✘%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
${C_BOLD}gclone 安装脚本${C_RESET}  ·  ${REPO}

${C_BOLD}用法${C_RESET}
  $(basename "$0") [选项] [版本]

${C_BOLD}常用${C_RESET}
  $(basename "$0")                         安装最新稳定版
  $(basename "$0") v1.73.3-mod1.6.2        安装指定 tag
  $(basename "$0") --user                  安装到 ~/.local/bin，无需 root
  $(basename "$0") --list                  列出近期版本
  $(basename "$0") --check                 查看已装版本 / 是否落后
  $(basename "$0") --uninstall             删除已安装的二进制

${C_BOLD}选项${C_RESET}
  -v, --version TAG     指定版本（可省略开头的 v）
  -f, --force           即使已是目标版本也重新下载安装
      --user            安装到 \$HOME/.local/bin
      --prefix DIR      安装目录（默认 Linux: /usr/bin，macOS: /usr/local/bin）
      --backup          覆盖前把旧二进制备份为 ${BIN_NAME}.bak
      --dry-run         只解析版本和下载地址，不写入系统
  -l, --list            列出近期发行版
  -c, --check           检查更新
  -u, --uninstall       卸载
  -h, --help            显示帮助

${C_BOLD}环境变量${C_RESET}
  GH_PROXY        GitHub 代理前缀，例如 https://ghfast.top
  GITHUB_TOKEN    GitHub PAT，避免 API 匿名限流
  PREFIX          同 --prefix
EOF
}

# --- 参数解析 ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -l|--list)
            ACTION="list"
            shift
            ;;
        -c|--check|--status)
            ACTION="check"
            shift
            ;;
        -u|--uninstall)
            ACTION="uninstall"
            shift
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        --user)
            USER_INSTALL=1
            shift
            ;;
        --prefix)
            [[ $# -ge 2 ]] || die "--prefix 需要目录参数"
            CUSTOM_PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            CUSTOM_PREFIX="${1#--prefix=}"
            shift
            ;;
        --backup)
            BACKUP=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -v|--version)
            [[ $# -ge 2 ]] || die "--version 需要版本号"
            REQ_VERSION="$2"
            shift 2
            ;;
        --version=*)
            REQ_VERSION="${1#--version=}"
            shift
            ;;
        -*)
            die "未知选项: $1  （使用 --help 查看用法）"
            ;;
        *)
            if [[ -n "$REQ_VERSION" ]]; then
                die "多余参数: $1"
            fi
            REQ_VERSION="$1"
            shift
            ;;
    esac
done

normalize_tag() {
    local t="${1:-}"
    [[ -z "$t" ]] && return 0
    t="${t#gclone-}"
    t="${t#gclone }"
    if [[ "$t" != v* ]]; then
        t="v${t}"
    fi
    printf '%s' "$t"
}

# --- 平台 ---
detect_platform() {
    local kernel arch
    kernel="$(uname -s)"
    arch="$(uname -m)"

    case "$kernel" in
        Linux)      OS_SLUG="linux" ;;
        Darwin)     OS_SLUG="osx" ;;
        FreeBSD)    OS_SLUG="freebsd" ;;
        NetBSD)     OS_SLUG="netbsd" ;;
        OpenBSD)    OS_SLUG="openbsd" ;;
        *)
            die "不支持的操作系统: $kernel"
            ;;
    esac

    case "$arch" in
        x86_64|amd64)   ARCH_SLUG="amd64" ;;
        i386|i486|i586|i686|x86) ARCH_SLUG="386" ;;
        aarch64|arm64)  ARCH_SLUG="arm64" ;;
        armv7l|armv7*)  ARCH_SLUG="arm-v7" ;;
        armv6l|armv6*)  ARCH_SLUG="arm-v6" ;;
        arm*)           ARCH_SLUG="arm" ;;
        mips64el|mipsel|mipsle) ARCH_SLUG="mipsle" ;;
        mips64|mips)    ARCH_SLUG="mips" ;;
        *)
            die "不支持的系统架构: $arch"
            ;;
    esac

    # Apple Silicon 一定走 osx-arm64；Rosetta 下 uname -m 可能是 x86_64
    if [[ "$OS_SLUG" == "osx" && "$ARCH_SLUG" == "amd64" ]] && [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
        if [[ "${GCLONE_ARCH:-}" == "amd64" ]]; then
            warn "检测到 Apple Silicon，但 GCLONE_ARCH=amd64，将安装 Intel 版"
        else
            ARCH_SLUG="arm64"
            info "检测到 Apple Silicon，使用 osx-arm64"
        fi
    fi

    ASSET_KEY="${OS_SLUG}-${ARCH_SLUG}"
}

default_bindir() {
    if [[ -n "$CUSTOM_PREFIX" ]]; then
        printf '%s' "${CUSTOM_PREFIX%/}"
        return
    fi
    if [[ "$USER_INSTALL" -eq 1 ]]; then
        printf '%s' "${HOME}/.local/bin"
        return
    fi
    case "$OS_SLUG" in
        osx)
            if [[ -d /opt/homebrew/bin && -w /opt/homebrew/bin ]]; then
                printf '%s' "/opt/homebrew/bin"
            else
                printf '%s' "/usr/local/bin"
            fi
            ;;
        *)
            printf '%s' "/usr/bin"
            ;;
    esac
}

need_root_for() {
    local path="$1"
    local dir
    dir="$(dirname "$path")"
    if [[ -e "$path" ]]; then
        [[ -w "$path" ]] && return 1
        return 0
    fi
    if [[ -d "$dir" && -w "$dir" ]]; then
        return 1
    fi
    return 0
}

# --- HTTP ---
with_proxy() {
    local url="$1"
    if [[ -n "$GH_PROXY" ]]; then
        GH_PROXY="${GH_PROXY%/}"
        printf '%s/%s' "$GH_PROXY" "$url"
    else
        printf '%s' "$url"
    fi
}

curl_gh() {
    local url="$1"
    local args=(-fsSL --retry 3 --retry-delay 2 --connect-timeout 15)
    if [[ -n "$GITHUB_TOKEN" ]]; then
        args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    args+=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
    curl "${args[@]}" "$(with_proxy "$url")"
}

curl_download() {
    local url="$1"
    local dest="$2"
    local args=(-fL --retry 3 --retry-delay 2 --connect-timeout 20)
    if [[ -t 2 ]]; then
        args+=(--progress-bar)
    else
        args+=(-sS)
    fi
    curl "${args[@]}" "$(with_proxy "$url")" -o "$dest"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ensure_deps() {
    local missing=()
    local c
    for c in curl unzip; do
        need_cmd "$c" || missing+=("$c")
    done
    # list / check / install 都要用到 jq
    if [[ "$ACTION" != "uninstall" ]]; then
        need_cmd jq || missing+=("jq")
    fi
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    info "缺少依赖: ${missing[*]}，尝试自动安装"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "dry-run: 跳过依赖安装"
        return 0
    fi

    if need_cmd apt-get; then
        [[ $(id -u) -eq 0 ]] || die "安装依赖需要 root。请先手动安装: ${missing[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    elif need_cmd dnf; then
        [[ $(id -u) -eq 0 ]] || die "安装依赖需要 root。请先手动安装: ${missing[*]}"
        dnf install -y "${missing[@]}"
    elif need_cmd yum; then
        [[ $(id -u) -eq 0 ]] || die "安装依赖需要 root。请先手动安装: ${missing[*]}"
        yum install -y "${missing[@]}"
    elif need_cmd apk; then
        [[ $(id -u) -eq 0 ]] || die "安装依赖需要 root。请先手动安装: ${missing[*]}"
        apk add --no-cache "${missing[@]}"
    elif need_cmd pacman; then
        [[ $(id -u) -eq 0 ]] || die "安装依赖需要 root。请先手动安装: ${missing[*]}"
        pacman -Sy --noconfirm "${missing[@]}"
    elif need_cmd zypper; then
        [[ $(id -u) -eq 0 ]] || die "安装依赖需要 root。请先手动安装: ${missing[*]}"
        zypper --non-interactive install "${missing[@]}"
    elif need_cmd brew; then
        brew install "${missing[@]}"
    elif need_cmd pkg && [[ "$OS_SLUG" == "freebsd" ]]; then
        [[ $(id -u) -eq 0 ]] || die "安装依赖需要 root。请先手动安装: ${missing[*]}"
        pkg install -y "${missing[@]}"
    else
        die "无法确定包管理器，请手动安装: ${missing[*]}"
    fi
    ok "依赖已就绪: curl unzip jq"
}

installed_version() {
    local bin="$1"
    if [[ -x "$bin" ]]; then
        "$bin" version 2>/dev/null | head -n1 || true
        return 0
    fi
    if need_cmd "$BIN_NAME"; then
        command -v "$BIN_NAME" >/dev/null
        "$BIN_NAME" version 2>/dev/null | head -n1 || true
    fi
}

installed_bin_path() {
    if [[ -n "${INSTALL_PATH:-}" && -e "$INSTALL_PATH" ]]; then
        printf '%s' "$INSTALL_PATH"
        return
    fi
    if need_cmd "$BIN_NAME"; then
        command -v "$BIN_NAME"
        return
    fi
    printf '%s' "${INSTALL_PATH:-}"
}

version_matches() {
    local installed="$1"
    local tag="$2"
    [[ -z "$installed" ]] && return 1
    # tag: v1.73.3-mod1.6.2 ；输出通常含 gclone v1.73.3-mod1.6.2
    grep -Fq "$tag" <<<"$installed"
}

fetch_release_json() {
    local tag="${1:-}"
    local url
    if [[ -n "$tag" ]]; then
        url="${GH_API}/tags/${tag}"
        info "查询指定版本: ${tag}"
    else
        url="${GH_API}/latest"
        info "查询最新发行版"
    fi
    local body
    if ! body="$(curl_gh "$url")"; then
        die "请求 GitHub API 失败: $url"
    fi
    if ! jq -e '.tag_name' >/dev/null 2>&1 <<<"$body"; then
        err "无法解析 GitHub API 响应（限流、代理不可用或 tag 不存在）"
        printf '%s\n' "$body" | head -c 400
        echo
        if jq -e '.message' >/dev/null 2>&1 <<<"$body"; then
            err "GitHub: $(jq -r '.message' <<<"$body")"
        fi
        die "获取发行版信息失败"
    fi
    printf '%s' "$body"
}

pick_zip_url() {
    local json="$1"
    local key="$2"
    jq -r --arg key "$key" --arg bin "$BIN_NAME" '
        .assets[]?
        | select(.name | test("^" + $bin + "-.*-" + $key + "\\.zip$"))
        | .browser_download_url
    ' <<<"$json" | head -n1
}

cmd_list() {
    ensure_deps
    info "近期 ${REPO} 发行版（最多 ${LIST_LIMIT} 条）"
    local json
    json="$(curl_gh "${GH_API}?per_page=${LIST_LIMIT}")" || die "无法列出发行版"
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json"; then
        err "GitHub API 未返回列表"
        printf '%s\n' "$json" | head -c 400
        echo
        die "列出版本失败"
    fi
    printf '\n  %-28s  %-20s  %s\n' "TAG" "发布日期" "包预览"
    printf '  %s\n' "----------------------------------------------------------------"
    jq -r --arg key "$ASSET_KEY" --arg bin "$BIN_NAME" '
        .[] |
        . as $r |
        ($r.assets | map(.name) | map(select(test($bin + "-.*-" + $key + "\\.zip$"))) | first) as $asset |
        [
            $r.tag_name,
            ($r.published_at // "" | split("T")[0]),
            ($asset // "-")
        ] | @tsv
    ' <<<"$json" | while IFS=$'\t' read -r tag date asset; do
        printf '  %-28s  %-20s  %s\n' "$tag" "$date" "$asset"
    done
    printf '\n'
    info "安装指定版本:  sudo bash $0 <TAG>"
}

cmd_check() {
    ensure_deps
    local json latest inst path
    json="$(fetch_release_json "")"
    latest="$(jq -r '.tag_name' <<<"$json")"
    path="$(installed_bin_path)"
    inst="$(installed_version "${path:-}")"
    echo
    printf '  仓库最新:   %s%s%s\n' "${C_BOLD}" "$latest" "${C_RESET}"
    if [[ -n "$inst" ]]; then
        printf '  本机已装:   %s\n' "$inst"
        printf '  二进制路径: %s\n' "${path:-未知}"
        if version_matches "$inst" "$latest"; then
            ok "已是最新版本"
        else
            warn "可以更新: $0"
        fi
    else
        printf '  本机已装:   %s未安装%s\n' "${C_DIM}" "${C_RESET}"
        warn "尚未安装 gclone"
    fi
    echo
}

cmd_uninstall() {
    local path
    path="$(installed_bin_path)"
    [[ -n "$path" && -e "$path" ]] || die "未找到已安装的 ${BIN_NAME}"
    if need_root_for "$path"; then
        [[ $(id -u) -eq 0 ]] || die "卸载 ${path} 需要 root，或改用 --prefix / --user"
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "dry-run: 将删除 $path"
        return 0
    fi
    rm -f "$path"
    ok "已卸载: $path"
}

extract_bin() {
    local zip="$1"
    local dest="$2"
    if ! unzip -l "$zip" | awk '{print $NF}' | grep -Eq '(^|/)'"${BIN_NAME}"'$'; then
        err "压缩包中未找到 ${BIN_NAME} 二进制"
        unzip -l "$zip" || true
        die "资源包结构异常"
    fi
    # 优先匹配子目录中的同名文件
    if ! unzip -p "$zip" "*/${BIN_NAME}" >"$dest" 2>/dev/null; then
        unzip -p "$zip" "${BIN_NAME}" >"$dest"
    fi
    [[ -s "$dest" ]] || die "提取 ${BIN_NAME} 失败（空文件）"
    local size
    size="$(wc -c <"$dest" | tr -d ' ')"
    if [[ "$size" -lt 1000000 ]]; then
        die "提取结果过小 (${size} bytes)，下载可能损坏"
    fi
}

cmd_install() {
    ensure_deps
    local tag json download_url inst path
    tag="$(normalize_tag "$REQ_VERSION")"
    json="$(fetch_release_json "$tag")"
    tag="$(jq -r '.tag_name' <<<"$json")"
    ok "目标版本: ${tag}"

    INSTALL_DIR="$(default_bindir)"
    INSTALL_PATH="${INSTALL_DIR}/${BIN_NAME}"
    path="$INSTALL_PATH"
    inst="$(installed_version "$path")"
    if [[ -n "$inst" ]]; then
        info "当前已安装: ${inst}"
        if version_matches "$inst" "$tag" && [[ "$FORCE" -eq 0 ]]; then
            ok "已是目标版本，无需重复安装（需要重装请加 --force）"
            [[ -x "$path" ]] && "$path" version | head -n 8 || true
            exit 0
        fi
    fi

    download_url="$(pick_zip_url "$json" "$ASSET_KEY")"
    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        err "没有找到 ${ASSET_KEY}.zip"
        info "此版本可用资源:"
        jq -r '.assets[]?.name' <<<"$json" || true
        die "当前平台没有对应构建"
    fi
    info "平台: $(uname -s)/$(uname -m)  →  ${ASSET_KEY}"
    info "安装到: ${INSTALL_PATH}"
    info "下载: ${download_url}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "dry-run: 到此为止，不下载、不写入"
        exit 0
    fi

    if need_root_for "$INSTALL_PATH"; then
        [[ $(id -u) -eq 0 ]] || die "写入 ${INSTALL_PATH} 需要 root。可改用 --user 或 --prefix \$HOME/.local/bin"
    fi
    mkdir -p "$INSTALL_DIR"

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    info "正在下载（约数十 MB）..."
    curl_download "$download_url" "${tmp}/gclone.zip"
    [[ -s "${tmp}/gclone.zip" ]] || die "下载失败"

    extract_bin "${tmp}/gclone.zip" "${tmp}/${BIN_NAME}"
    chmod 0755 "${tmp}/${BIN_NAME}"
    if [[ $(id -u) -eq 0 ]]; then
        chown root:root "${tmp}/${BIN_NAME}" 2>/dev/null \
            || chown root:wheel "${tmp}/${BIN_NAME}" 2>/dev/null \
            || true
    fi

    if [[ "$BACKUP" -eq 1 && -e "$INSTALL_PATH" ]]; then
        cp -f "$INSTALL_PATH" "${INSTALL_PATH}.bak"
        info "已备份旧版本到 ${INSTALL_PATH}.bak"
    fi

    # 同文件系统上的原子替换
    mv -f "${tmp}/${BIN_NAME}" "$INSTALL_PATH"
    ok "${BIN_NAME} 安装成功"

    if ! [[ ":$PATH:" == *":${INSTALL_DIR}:"* ]]; then
        warn "${INSTALL_DIR} 不在 PATH 中。zsh/bash 可加入:"
        echo "    export PATH=\"${INSTALL_DIR}:\$PATH\""
    fi

    echo
    info "验证安装:"
    "$INSTALL_PATH" version || warn "已写入 ${INSTALL_PATH}，但 version 子命令执行失败"
}

# --- 入口 ---
if [[ -n "$GH_PROXY" ]]; then
    GH_PROXY="${GH_PROXY%/}"
    info "使用代理前缀: ${GH_PROXY}"
fi

detect_platform
INSTALL_DIR="$(default_bindir)"
INSTALL_PATH="${INSTALL_DIR}/${BIN_NAME}"

case "$ACTION" in
    list)      cmd_list ;;
    check)     cmd_check ;;
    uninstall) cmd_uninstall ;;
    install)   cmd_install ;;
    *)         die "未知动作: $ACTION" ;;
esac
