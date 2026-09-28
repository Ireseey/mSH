#!/usr/bin/env bash
#
# rclone 安装脚本（wiserain/rclone，含 115 backend）
#
# 用法:
#   sudo bash rclone.sh                         # 安装最新版
#   sudo bash rclone.sh v1.75.1-332             # 指定版本
#   sudo bash rclone.sh --version v1.75.1-332
#   bash rclone.sh --user                       # 安装到 ~/.local/bin（无需 root）
#   bash rclone.sh --list                       # 列出近期发行版
#   bash rclone.sh --check                      # 对比已装版本与最新版
#   sudo bash rclone.sh --uninstall             # 卸载
#   sudo bash rclone.sh --force                 # 强制重装当前目标版本
#   sudo INSTALL_PREFIX=/usr/local/bin bash rclone.sh
#   GH_PROXY=https://ghfast.top sudo bash rclone.sh
#   GITHUB_TOKEN=ghp_xxx sudo bash rclone.sh    # 降低 GitHub API 限流
#
set -o errexit
set -o pipefail
set -o nounset

REPO="wiserain/rclone"
BIN_NAME="rclone"
GH_API="https://api.github.com/repos/${REPO}/releases"
GH_PROXY="${GH_PROXY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

ACTION="install"
REQ_VERSION=""
FORCE=0
USER_INSTALL=0
DRY_RUN=0
BACKUP=0
SKIP_CHECKSUM=0
LIST_LIMIT=15
# 不用 PREFIX：Termux 等环境会自带 PREFIX，避免把根前缀当成 bindir
CUSTOM_PREFIX="${INSTALL_PREFIX:-}"

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
${C_BOLD}rclone 安装脚本${C_RESET}  ·  ${REPO}（115 改版）

${C_BOLD}用法${C_RESET}
  $(basename "$0") [选项] [版本]

${C_BOLD}常用${C_RESET}
  $(basename "$0")                         安装最新稳定版
  $(basename "$0") v1.75.1-332             安装指定 tag
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
      --skip-checksum   跳过 SHA256 校验
      --dry-run         只解析版本和下载地址，不写入系统
  -l, --list            列出近期发行版
  -c, --check           检查更新
  -u, --uninstall       卸载
  -h, --help            显示帮助

${C_BOLD}环境变量${C_RESET}
  GH_PROXY          GitHub 代理前缀，例如 https://ghfast.top
  GITHUB_TOKEN      GitHub PAT，避免 API 匿名限流
  INSTALL_PREFIX    同 --prefix（不要用 PREFIX，以免和 Termux 冲突）
  RCLONE_ARCH       强制架构，例如 amd64 / arm64
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
        --skip-checksum)
            SKIP_CHECKSUM=1
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
    t="${t#rclone-}"
    t="${t#rclone }"
    if [[ "$t" != v* ]]; then
        t="v${t}"
    fi
    printf '%s' "$t"
}

in_termux() {
    [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d /data/data/com.termux/files/usr ]]
}

# --- 平台 ---
detect_platform() {
    local kernel arch
    kernel="$(uname -s)"
    arch="$(uname -m)"

    if in_termux; then
        OS_SLUG="termux"
        case "$arch" in
            aarch64|arm64) ARCH_SLUG="aarch64" ;;
            armv7l|armv7*|arm) ARCH_SLUG="arm" ;;
            *) die "Termux 下不支持的架构: $arch" ;;
        esac
        ASSET_KEY="${OS_SLUG}-${ARCH_SLUG}"
        return 0
    fi

    case "$kernel" in
        Linux)      OS_SLUG="linux" ;;
        Darwin)     OS_SLUG="osx" ;;
        *)
            die "wiserain/rclone 预编译包主要提供 Linux / macOS / Termux / Windows。当前系统: $kernel"
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

    if [[ -n "${RCLONE_ARCH:-}" ]]; then
        ARCH_SLUG="$RCLONE_ARCH"
        info "使用 RCLONE_ARCH=${ARCH_SLUG}"
    elif [[ "$OS_SLUG" == "osx" && "$ARCH_SLUG" == "amd64" ]] && [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
        ARCH_SLUG="arm64"
        info "检测到 Apple Silicon，使用 osx-arm64"
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
    if [[ "$OS_SLUG" == "termux" ]]; then
        printf '%s' "${PREFIX:-/data/data/com.termux/files/usr}/bin"
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

default_mandir() {
    if [[ "$USER_INSTALL" -eq 1 ]]; then
        printf '%s' "${HOME}/.local/share/man/man1"
        return
    fi
    if [[ "$OS_SLUG" == "termux" ]]; then
        printf '%s' "${PREFIX:-/data/data/com.termux/files/usr}/share/man/man1"
        return
    fi
    printf '%s' "/usr/local/share/man/man1"
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
    elif need_cmd pkg && [[ "${OS_SLUG:-}" == "termux" ]]; then
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
    # tag: v1.75.1-332 ；官方 rclone 是 v1.75.1，改版带 -332 后缀，不会误判
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

pick_asset_url() {
    local json="$1"
    local name="$2"
    jq -r --arg name "$name" '
        .assets[]?
        | select(.name == $name)
        | .browser_download_url
    ' <<<"$json" | head -n1
}

file_sha256() {
    local f="$1"
    if need_cmd sha256sum; then
        sha256sum "$f" | awk '{print $1}'
    elif need_cmd shasum; then
        shasum -a 256 "$f" | awk '{print $1}'
    elif need_cmd openssl; then
        openssl dgst -sha256 "$f" | awk '{print $NF}'
    else
        return 1
    fi
}

verify_sha256() {
    local zip="$1"
    local sums="$2"
    local asset_name="$3"
    local expected actual
    expected="$(awk -v n="$asset_name" '$2 == n {print $1; exit}' "$sums")"
    if [[ -z "$expected" ]]; then
        warn "SHA256SUMS 中没有 ${asset_name}，跳过校验"
        return 0
    fi
    actual="$(file_sha256 "$zip")" || {
        warn "系统没有 sha256sum/shasum/openssl，跳过校验"
        return 0
    }
    if [[ "$expected" != "$actual" ]]; then
        err "SHA256 不匹配"
        err "  期望: $expected"
        err "  实际: $actual"
        die "下载文件可能损坏或被篡改，中止安装"
    fi
    ok "SHA256 校验通过"
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
    printf '\n  %-22s  %-12s  %s\n' "TAG" "发布日期" "包预览"
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
        printf '  %-22s  %-12s  %s\n' "$tag" "$date" "$asset"
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
            ok "已是最新改版"
        else
            warn "可以更新: $0"
            if grep -Eq 'rclone v[0-9.]+$' <<<"$inst" && ! grep -Eq -- '-[0-9]+$' <<<"$inst"; then
                info "当前看起来像官方 rclone，安装改版会覆盖这个二进制"
            fi
        fi
    else
        printf '  本机已装:   %s未安装%s\n' "${C_DIM}" "${C_RESET}"
        warn "尚未安装 rclone"
    fi
    echo
}

cmd_uninstall() {
    local path man
    path="$(installed_bin_path)"
    [[ -n "$path" && -e "$path" ]] || die "未找到已安装的 ${BIN_NAME}"
    if need_root_for "$path"; then
        [[ $(id -u) -eq 0 ]] || die "卸载 ${path} 需要 root，或改用 --prefix / --user"
    fi
    man="$(default_mandir)/rclone.1"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "dry-run: 将删除 $path"
        [[ -e "$man" ]] && warn "dry-run: 将删除 $man"
        return 0
    fi
    rm -f "$path"
    ok "已卸载: $path"
    if [[ -e "$man" ]]; then
        rm -f "$man"
        ok "已删除 man page: $man"
    fi
}

extract_bin() {
    local zip="$1"
    local dest="$2"
    if ! unzip -l "$zip" | awk '{print $NF}' | grep -Eq '(^|/)'"${BIN_NAME}"'$'; then
        err "压缩包中未找到 ${BIN_NAME} 二进制"
        unzip -l "$zip" || true
        die "资源包结构异常"
    fi
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

install_man() {
    local zip="$1"
    if ! unzip -l "$zip" | awk '{print $NF}' | grep -Eq '(^|/)rclone\.1$'; then
        return 0
    fi
    local mandir manfile
    mandir="$(default_mandir)"
    manfile="${mandir}/rclone.1"
    mkdir -p "$mandir"
    if ! unzip -p "$zip" "*/rclone.1" >"$manfile" 2>/dev/null; then
        unzip -p "$zip" "rclone.1" >"$manfile"
    fi
    chmod 0644 "$manfile"
    if need_cmd mandb; then
        mandb >/dev/null 2>&1 || true
    elif need_cmd makewhatis; then
        makewhatis >/dev/null 2>&1 || true
    fi
    info "已安装 man page: $manfile"
}

cmd_install() {
    ensure_deps
    local tag json download_url sums_url inst path asset_name
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
    asset_name="$(basename "${download_url%%\?*}")"
    sums_url="$(pick_asset_url "$json" "SHA256SUMS")"

    info "平台: $(uname -s)/$(uname -m)  →  ${ASSET_KEY}"
    info "安装到: ${INSTALL_PATH}"
    info "下载: ${download_url}"
    [[ -n "$sums_url" && "$sums_url" != "null" ]] && info "校验: SHA256SUMS"

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
    curl_download "$download_url" "${tmp}/rclone.zip"
    [[ -s "${tmp}/rclone.zip" ]] || die "下载失败"

    if [[ "$SKIP_CHECKSUM" -eq 1 ]]; then
        warn "已按 --skip-checksum 跳过 SHA256 校验"
    elif [[ -n "$sums_url" && "$sums_url" != "null" ]]; then
        curl_download "$sums_url" "${tmp}/SHA256SUMS"
        verify_sha256 "${tmp}/rclone.zip" "${tmp}/SHA256SUMS" "$asset_name"
    else
        warn "此版本没有 SHA256SUMS，跳过校验"
    fi

    extract_bin "${tmp}/rclone.zip" "${tmp}/${BIN_NAME}"
    chmod 0755 "${tmp}/${BIN_NAME}"
    if [[ $(id -u) -eq 0 ]]; then
        chown root:root "${tmp}/${BIN_NAME}" 2>/dev/null \
            || chown root:wheel "${tmp}/${BIN_NAME}" 2>/dev/null \
            || true
    fi

    if [[ "$BACKUP" -eq 1 && -e "$INSTALL_PATH" ]]; then
        cp -f "$INSTALL_PATH" "${INSTALL_PATH}.bak"
        info "已备份旧版本到 ${INSTALL_PATH}.bak"
    elif [[ -e "$INSTALL_PATH" ]]; then
        local old
        old="$(installed_version "$INSTALL_PATH")"
        if [[ -n "$old" ]] && ! version_matches "$old" "$tag"; then
            info "将覆盖现有 rclone: ${old}"
        fi
    fi

    mv -f "${tmp}/${BIN_NAME}" "$INSTALL_PATH"
    install_man "${tmp}/rclone.zip" || warn "man page 安装失败，可忽略"
    ok "${BIN_NAME} 改版安装成功"

    if ! [[ ":$PATH:" == *":${INSTALL_DIR}:"* ]]; then
        warn "${INSTALL_DIR} 不在 PATH 中。zsh/bash 可加入:"
        echo "    export PATH=\"${INSTALL_DIR}:\$PATH\""
    fi

    echo
    info "验证安装:"
    "$INSTALL_PATH" version || warn "已写入 ${INSTALL_PATH}，但 version 子命令执行失败"
    echo
    info "这是 wiserain/rclone（含 115 backend），会覆盖同路径上的官方 rclone。"
    info "接下来可运行: rclone config"
    info "115 常用 cookie: UID=...; CID=...; SEID=...; KID=..."
    info "文档: https://github.com/wiserain/rclone"
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
