#!/usr/bin/env bash
# Single-file install/uninstall entry point. NAS backends are emitted into a temporary bundle.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME='taskcenter'
PLUGIN_LABEL='定时任务'
PLUGIN_VERSION='1.0.0'
UNINSTALL_NOTE='停用该用户调度并备份任务和日志；不会删除任务引用的脚本、容器或用户文件。'

# Shared frontend; keep this section consistent across the four manage.sh files.
set -Eeuo pipefail

installer_error() { printf '[错误] %s\n' "$*" >&2; exit 2; }
installer_info() { printf '[信息] %s\n' "$*"; }
installer_usage() {
    cat <<EOF
$PLUGIN_LABEL — $ACTION_LABEL

用法：
  bash $ENTRY [设备IP] [用户1,用户2]
  bash $ENTRY [--ip 192.168.31.100] [--users u123456789,u987654321]
  bash $ENTRY [--ip 192.168.31.100] --all-users

选项：
  --ip IP        远程 NAS 的 IPv4 地址；未填写时交互输入
  --users LIST   指定一个或多个用户，以逗号分隔
  --all-users    选择扫描到的全部符合条件的用户
  --list-users   仅显示用户及安装状态
  --dry-run      校验环境和用户，显示计划，不执行安装卸载
  --yes, -y      跳过卸载确认；非交互卸载必须明确提供
  --help, -h     显示此说明

NAS 本机自动直接执行，必须以 root 运行；WSL/Linux 自动使用 root SSH。
不指定用户时列出用户，支持序号多选（如 1,3）或输入 all。
仅扫描到一个用户时自动选择；非交互多用户场景必须指定用户。
安装会保留已有配置；卸载范围与保留数据会在执行前显示。
EOF
}
installer_ipv4() {
    local ip=$1 part
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local -a parts
    IFS=. read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do ((10#$part <= 255)) || return 1; done
}
installer_valid_user() { [[ $1 =~ ^u[0-9]+$ ]]; }
installer_require() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || installer_error "缺少命令：$command_name"
    done
}
installer_target_script() {
    if [[ $DIRECT == true ]]; then
        installer_emit_probe | /bin/sh -s -- "$@"
    else
        installer_emit_probe | ssh "${SSH_OPTIONS[@]}" "root@$NAS_IP" /bin/sh -s -- "$@"
    fi
}
installer_cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n ${REMOTE_DIR:-} && $REMOTE_DIR =~ ^/tmp/xiaomi-plugin\.[a-z]+\.[a-zA-Z0-9]+$ ]]; then
        ssh "${SSH_OPTIONS[@]}" -o BatchMode=yes "root@$NAS_IP" "rm -rf '$REMOTE_DIR'" >/dev/null 2>&1 ||
            printf '[提示] 远端暂存目录未清理，可手动删除：%s\n' "$REMOTE_DIR" >&2
    fi
    if [[ -n ${WORK_DIR:-} && $WORK_DIR =~ ^/tmp/xiaomi-plugin\.[a-z]+\.[a-zA-Z0-9]+$ ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    exit "$rc"
}
installer_select_users() {
    local raw=$1 row user state token found index
    USERS=(); STATES=(); SELECTED=()
    while IFS=$'\t' read -r user state; do
        [[ -n $user ]] || continue
        installer_valid_user "$user" || installer_error "设备返回了无效用户；请检查 SSH 输出。"
        [[ $state == installed || $state == available ]] || installer_error "设备返回了无效安装状态。"
        USERS+=("$user"); STATES+=("$state")
    done <<< "$raw"
    printf '\n可%s的用户：\n' "$ACTION_LABEL"
    for ((index=0; index<${#USERS[@]}; index++)); do
        state=未安装; [[ ${STATES[index]} != installed ]] || state=已安装
        printf '  %d) %s  [%s]\n' "$((index+1))" "${USERS[index]}" "$state"
    done
    if (("${#USERS[@]}" == 0)); then
        [[ $ACTION != uninstall ]] || { installer_info "没有已安装$PLUGIN_LABEL的用户，无需卸载。"; exit 0; }
        installer_error "没有可安装用户，请先在小米客户端创建用户并初始化存储池。"
    fi
    [[ $LIST_ONLY != true ]] || return 0
    if [[ $ALL_USERS == true ]]; then
        SELECTED=("${USERS[@]}")
        return
    fi
    if [[ -z $USER_SPEC ]]; then
        if (("${#USERS[@]}" == 1)); then
            USER_SPEC="${USERS[0]}"
            installer_info "自动选择唯一用户：$USER_SPEC"
        else
            [[ -t 0 ]] || installer_error "存在多个用户，请使用 --users 或 --all-users。"
            read -r -p '请选择用户序号（可用逗号多选，all 表示全部，q 退出）：' USER_SPEC || installer_error "输入已结束。"
            [[ $USER_SPEC != q ]] || exit 0
        fi
    fi
    if [[ $USER_SPEC == all ]]; then SELECTED=("${USERS[@]}"); return; fi
    [[ -n $USER_SPEC && $USER_SPEC != ,* && $USER_SPEC != *, && $USER_SPEC != *,,* ]] || installer_error "用户列表不能为空或包含空项。"
    local -a tokens
    IFS=', ' read -r -a tokens <<< "$USER_SPEC"
    for token in "${tokens[@]}"; do
        if [[ $token =~ ^[0-9]+$ && ${#token} -le 6 ]]; then
            index=$((10#$token))
            ((index >= 1 && index <= ${#USERS[@]})) || installer_error "用户序号超出范围：$token"
            user=${USERS[index-1]}
        else
            installer_valid_user "$token" || installer_error "无效用户：$token"
            user=$token
        fi
        found=false
        for row in "${USERS[@]}"; do [[ $row != "$user" ]] || found=true; done
        [[ $found == true ]] || installer_error "用户 $user 不在本次可$ACTION_LABEL列表中。"
        found=false
        for row in "${SELECTED[@]}"; do [[ $row != "$user" ]] || found=true; done
        [[ $found == true ]] || SELECTED+=("$user")
    done
    (("${#SELECTED[@]}" > 0)) || installer_error "未选择用户。"
}
installer_main() {
    ACTION=$1; shift
    case $ACTION in install) ACTION_LABEL=安装; ENTRY="manage.sh install";; uninstall) ACTION_LABEL=卸载; ENTRY="manage.sh uninstall";; *) installer_error "无效操作。";; esac
    NAS_IP=; USER_SPEC=; ALL_USERS=false; LIST_ONLY=false; DRY_RUN=false; ASSUME_YES=false
    DIRECT=false; WORK_DIR=; REMOTE_DIR=
    local arg raw answer user rc failures=0
    while (($#)); do
        arg=$1; shift
        case $arg in
            -h|--help) installer_usage; return;;
            --ip|--users)
                (($#)) && [[ -n $1 && $1 != --* ]] || installer_error "$arg 缺少参数。"
                if [[ $arg == --ip ]]; then
                    [[ -z $NAS_IP ]] || installer_error "设备 IP 重复指定。"; NAS_IP=$1
                else
                    [[ -z $USER_SPEC ]] || installer_error "用户重复指定。"; USER_SPEC=$1
                fi
                shift;;
            --all-users) ALL_USERS=true;;
            --list-users) LIST_ONLY=true;;
            --dry-run) DRY_RUN=true;;
            --yes|-y) ASSUME_YES=true;;
            --*) installer_error "未知选项：$arg";;
            *)
                if [[ $arg == *.* && -z $NAS_IP ]]; then NAS_IP=$arg
                elif [[ -z $USER_SPEC ]]; then USER_SPEC=$arg
                else installer_error "多余参数：$arg"; fi;;
        esac
    done
    [[ $ALL_USERS != true || -z $USER_SPEC ]] || installer_error "--all-users 不能与用户列表同时使用。"
    [[ -z $NAS_IP ]] || installer_ipv4 "$NAS_IP" || installer_error "无效 IPv4 地址：$NAS_IP"
    printf '\n%s — %s\n' "$PLUGIN_LABEL" "$ACTION_LABEL"
    printf '[1/5] 识别运行环境\n'
    if [[ -f /etc/config/plugin ]] && command -v plugincenter >/dev/null 2>&1; then
        [[ $(id -u) == 0 ]] || installer_error "已识别为 NAS 本机，请使用 root 运行。"
        DIRECT=true; installer_info "小米智能存储本机，直接执行。"
        [[ -z $NAS_IP ]] || installer_error "本机模式无需设备 IP；请移除 IP，避免误操作目标。"
    else
        if [[ -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
            installer_info "WSL，通过 root SSH 连接 NAS。"
        else
            installer_info "Linux/兼容终端，通过 root SSH 连接 NAS。"
        fi
        installer_require ssh
        if [[ -z $NAS_IP ]]; then
            [[ -t 0 ]] || installer_error "非交互环境请使用 --ip 指定设备 IP。"
            read -r -p '请输入小米智能存储 IPv4 地址：' NAS_IP || installer_error "输入已结束。"
        fi
        installer_ipv4 "$NAS_IP" || installer_error "无效 IPv4 地址：$NAS_IP"
    fi
    SSH_OPTIONS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
    [[ -t 0 ]] || SSH_OPTIONS+=(-o BatchMode=yes)
    printf '[2/5] 扫描用户与安装状态\n'
    if ! raw=$(installer_target_script --scan "$PLUGIN_NAME" "$ACTION"); then
        installer_error "设备检查或用户扫描失败；请检查 SSH 连接、root 权限及上方错误。"
    fi
    installer_select_users "$raw"
    [[ $LIST_ONLY != true ]] || return 0
    printf '\n[3/5] 核对执行计划\n'
    printf '  插件：%s\n  操作：%s\n  目标：%s\n' "$PLUGIN_LABEL" "$ACTION_LABEL" "${NAS_IP:-NAS 本机}"
    printf '  用户：%s\n' "${SELECTED[*]}"
    if [[ $ACTION == uninstall ]]; then
        printf '  范围：仅删除所选用户的本插件；配置及记录先备份到 /data/.taskcenter-backups/。\n'
        printf '  说明：%s\n' "$UNINSTALL_NOTE"
    else
        printf '  说明：保留已有任务和记录；多用户独立注册，共享调度助手，无额外监听端口。\n'
    fi
    installer_target_script --check "$PLUGIN_NAME" "$ACTION" "${SELECTED[@]}" ||
        installer_error "预检查失败，尚未执行$ACTION_LABEL。"
    if [[ $DRY_RUN == true ]]; then installer_info "预检查通过。仅显示计划，未执行$ACTION_LABEL。"; return; fi
    if [[ $ACTION == uninstall && $ASSUME_YES != true ]]; then
        [[ -t 0 ]] || installer_error "非交互卸载请检查计划后添加 --yes。"
        read -r -p '确认卸载以上用户的插件？输入 yes 继续：' answer || installer_error "输入已结束。"
        [[ $answer == yes ]] || { installer_info "已取消卸载。"; return; }
    fi
    installer_require mktemp tar cp
    [[ $DIRECT == true ]] || installer_require scp
    WORK_DIR=$(mktemp -d "/tmp/xiaomi-plugin.$PLUGIN_NAME.XXXXXX")
    trap installer_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    mkdir "$WORK_DIR/bundle"
    if [[ $ACTION == install ]]; then installer_emit_install > "$WORK_DIR/bundle/remote-install.sh"
    else installer_emit_uninstall > "$WORK_DIR/bundle/remote-uninstall.sh"; fi
    if [[ $ACTION == install ]]; then
        [[ -d $SCRIPT_DIR/payload ]] || installer_error "安装包缺少 payload 目录。"
        cp -R "$SCRIPT_DIR/payload" "$WORK_DIR/bundle/payload"
        if declare -F installer_prepare_payload >/dev/null; then installer_prepare_payload "$WORK_DIR/bundle"; fi
    fi
    printf '\n[4/5] 执行%s\n' "$ACTION_LABEL"
    if [[ $DIRECT != true ]]; then
        REMOTE_DIR=$(ssh "${SSH_OPTIONS[@]}" "root@$NAS_IP" "mktemp -d /tmp/xiaomi-plugin.$PLUGIN_NAME.XXXXXX") ||
            installer_error "无法创建 NAS 暂存目录。"
        [[ $REMOTE_DIR =~ ^/tmp/xiaomi-plugin\.[a-z]+\.[a-zA-Z0-9]+$ ]] || installer_error "NAS 返回了异常暂存路径。"
        tar -czf "$WORK_DIR/bundle.tgz" -C "$WORK_DIR" bundle
        scp "${SSH_OPTIONS[@]}" "$WORK_DIR/bundle.tgz" "root@$NAS_IP:$REMOTE_DIR/bundle.tgz"
        ssh "${SSH_OPTIONS[@]}" "root@$NAS_IP" "tar -xzf '$REMOTE_DIR/bundle.tgz' -C '$REMOTE_DIR'"
    fi
    local -a successes=() failed=()
    for user in "${SELECTED[@]}"; do
        printf '\n[用户 %s] 正在%s%s……\n' "$user" "$ACTION_LABEL" "$PLUGIN_LABEL"
        # Each backend runs in its own sh process: an error cannot be hidden by this if.
        if [[ $DIRECT == true ]]; then
            if /bin/sh "$WORK_DIR/bundle/remote-$ACTION.sh" "$user"; then rc=0; else rc=$?; fi
        else
            if ssh "${SSH_OPTIONS[@]}" "root@$NAS_IP" "/bin/sh '$REMOTE_DIR/bundle/remote-$ACTION.sh' '$user'"; then rc=0; else rc=$?; fi
        fi
        if ((rc == 0)); then successes+=("$user")
        else failed+=("$user"); failures=$((failures+1)); printf '[错误] %s %s失败（退出码 %s），请查看上方日志。\n' "$user" "$ACTION_LABEL" "$rc" >&2; fi
    done
    printf '\n[5/5] 执行结果\n'
    printf '  成功（%s）：%s\n' "${#successes[@]}" "${successes[*]:-无}"
    printf '  失败（%s）：%s\n' "${#failed[@]}" "${failed[*]:-无}"
    if ((failures > 0)); then
        printf '[提示] 已成功用户不回滚；请解决错误后只重试失败用户。\n' >&2
        return 1
    fi
    installer_info "$ACTION_LABEL完成。请重新打开手机 APP 或电脑客户端的插件列表。"
}

installer_emit_metadata() {
    printf '%s\n' '#!/bin/sh' 'set -eu' "PLUGIN_NAME='$PLUGIN_NAME'" "PLUGIN_LABEL='$PLUGIN_LABEL'" "PLUGIN_VERSION='$PLUGIN_VERSION'" "UNINSTALL_NOTE='$UNINSTALL_NOTE'"
}
installer_emit_nas_common() {
    cat <<'NAS_COMMON_SCRIPT'
#!/bin/sh
# Shared NAS checks and uninstall workflow; identical in all standalone packages.
nas_fail() { printf '[错误] %s\n' "$*" >&2; exit 1; }
nas_log() { printf '[信息] %s\n' "$*"; }
nas_valid_user() {
    case "$1" in u*) ;; *) return 1;; esac
    case "${1#u}" in ''|*[!0-9]*) return 1;; esac
}
nas_metadata() {
    NAS_PLUGIN=$1
    case "$NAS_PLUGIN" in
        mihomo) NAS_LABEL=Mihomo;;
        dockermanager) NAS_LABEL=docker;;
        quickshare) NAS_LABEL=文件快传;;
        taskcenter) NAS_LABEL=定时任务;;
        *) nas_fail "无效插件名称。";;
    esac
}
nas_require() {
    for nas_cmd in "$@"; do command -v "$nas_cmd" >/dev/null 2>&1 || nas_fail "NAS 缺少命令：$nas_cmd"; done
}
nas_environment() {
    [ "$(id -u)" = 0 ] || nas_fail "请以 root 身份在小米智能存储上执行。"
    [ -f /etc/config/plugin ] || nas_fail "未检测到小米智能存储配置。"
    nas_require jq plugincenter sort readlink mountpoint flock
}
nas_is_installed() {
    [ -d "/home/$1/plugin/$NAS_PLUGIN" ] || [ -L "/home/$1/plugin/$NAS_PLUGIN" ] ||
        { [ -f "/data/plugin/$1.list" ] && jq -e --arg p "$NAS_PLUGIN" '.[$p].install == true' "/data/plugin/$1.list" >/dev/null 2>&1; }
}
nas_scan() {
    nas_metadata "$1"; nas_action=$2
    nas_environment
    # Include accounts whose registration or home exists; never rely on find following symlinks.
    {
        for nas_item in /data/plugin/u*.list; do
            [ -f "$nas_item" ] || continue
            nas_candidate=${nas_item##*/}; nas_candidate=${nas_candidate%.list}
            nas_valid_user "$nas_candidate" && printf '%s\n' "$nas_candidate"
        done
        for nas_item in /home/u*; do
            [ -d "$nas_item" ] || continue
            nas_candidate=${nas_item##*/}
            nas_valid_user "$nas_candidate" && printf '%s\n' "$nas_candidate"
        done
    } | LC_ALL=C sort -u | while IFS= read -r nas_candidate; do
        nas_state=available
        if nas_is_installed "$nas_candidate"; then nas_state=installed; fi
        if [ "$nas_action" = uninstall ]; then
            [ "$nas_state" = installed ] || continue
        else
            id "$nas_candidate" >/dev/null 2>&1 || continue
            [ -d "/home/$nas_candidate" ] && [ -f "/data/plugin/$nas_candidate.list" ] || continue
        fi
        printf '%s\t%s\n' "$nas_candidate" "$nas_state"
    done
}
nas_pool_path() {
    # Strictly validate the whole path before creating, moving or removing anything.
    nas_path=$1; nas_kind=$2
    nas_pool=${nas_path#/nas/}; nas_pool=${nas_pool%%/*}
    case "$nas_pool" in pool*) ;; *) nas_fail "异常存储池路径：$nas_path";; esac
    case "${nas_pool#pool}" in ''|*[!0-9]*) nas_fail "异常存储池路径：$nas_path";; esac
    [ "$nas_path" = "/nas/$nas_pool/$NAS_USER/plugin/$nas_kind/$NAS_PLUGIN" ] || nas_fail "异常插件路径：$nas_path"
    mountpoint -q "/nas/$nas_pool" || nas_fail "存储池 /nas/$nas_pool 尚未挂载，请恢复硬盘挂载后重试。"
    [ -d "/nas/$nas_pool/$NAS_USER" ] || nas_fail "存储池内不存在用户 $NAS_USER。"
    nas_real=$(readlink -f "$nas_path" 2>/dev/null || true)
    [ -z "$nas_real" ] || [ "$nas_real" = "$nas_path" ] || nas_fail "插件路径重定向到其他位置：$nas_path"
}
nas_check_user() {
    NAS_USER=$1
    nas_valid_user "$NAS_USER" || nas_fail "无效用户：$NAS_USER（应为 u 后接数字）"
    [ -d "/home/$NAS_USER" ] || nas_fail "用户主目录不存在：$NAS_USER"
    id "$NAS_USER" >/dev/null 2>&1 || nas_fail "系统账户不存在：$NAS_USER"
    NAS_HOME="/home/$NAS_USER/plugin/$NAS_PLUGIN"
    [ ! -L "$NAS_HOME" ] || nas_fail "插件主目录不能为符号链接：$NAS_HOME"
    NAS_LIST="/data/plugin/$NAS_USER.list"
    if [ -f "$NAS_LIST" ]; then
        jq -e 'type == "object"' "$NAS_LIST" >/dev/null 2>&1 || nas_fail "插件清单损坏：$NAS_LIST"
    elif [ "$NAS_ACTION" = install ]; then
        nas_fail "插件清单不存在：$NAS_LIST"
    fi
    NAS_SRC="/nas/pool0/$NAS_USER/plugin/pluginsrc/$NAS_PLUGIN"
    NAS_TMP="/nas/pool0/$NAS_USER/plugin/plugintmp/$NAS_PLUGIN"
    if [ -L "$NAS_HOME/src" ]; then NAS_SRC=$(readlink "$NAS_HOME/src"); fi
    if [ -L "$NAS_HOME/tmp" ]; then NAS_TMP=$(readlink "$NAS_HOME/tmp"); else NAS_TMP="${NAS_SRC%/pluginsrc/*}/plugintmp/$NAS_PLUGIN"; fi
    nas_pool_path "$NAS_SRC" pluginsrc
    nas_pool_path "$NAS_TMP" plugintmp
    if [ "$NAS_ACTION" = uninstall ]; then nas_is_installed "$NAS_USER" || nas_fail "$NAS_USER 尚未安装$NAS_LABEL。"; fi
    NAS_WEB_ROOT=$(jq -r '.settings.nginx_plugin // "/data/plugin/www"' /etc/config/plugin)
    case "$NAS_WEB_ROOT" in /*) ;; *) nas_fail "插件网页根目录配置无效。";; esac
}
nas_prepare() {
    NAS_ACTION=$1; nas_metadata "$PLUGIN_NAME"
    nas_environment
    [ -n "${2:-}" ] || nas_fail "请显式指定插件用户；推荐运行 manage.sh install 或 manage.sh uninstall。"
    # Serialize installer operations across users and plugins that share helpers and icons.
    exec 7>/data/plugin/.local-plugin-installer.lock
    flock -w 60 -x 7 || nas_fail "另一个安装或卸载任务仍在执行，请稍后重试。"
    trap 'flock -u 7 2>/dev/null || true' 0
    nas_check_user "$2"
    nas_log "$NAS_LABEL：已校验用户 $NAS_USER、插件目录和存储池。"
}
nas_remove_entry() {
    [ -f "$NAS_LIST" ] || return 0
    exec 9>"/data/plugin/.$NAS_USER.plugins.lock"
    flock -x 9
    nas_next="$NAS_LIST.$NAS_PLUGIN-uninstall.$$"
    cp -p "$NAS_LIST" "$NAS_BACKUP/plugin-list.json"
    jq --arg p "$NAS_PLUGIN" 'del(.[$p])' "$NAS_LIST" > "$nas_next"
    chmod --reference="$NAS_LIST" "$nas_next"
    chown --reference="$NAS_LIST" "$nas_next"
    mv -f "$nas_next" "$NAS_LIST"
    flock -u 9
}
nas_other_users() {
    for nas_d in /home/u*/plugin/"$NAS_PLUGIN"; do
        [ ! -d "$nas_d" ] && [ ! -L "$nas_d" ] || return 0
    done
    for nas_f in /data/plugin/u*.list; do
        [ -f "$nas_f" ] || continue
        # If another user's registry is unreadable, preserve shared files.
        jq empty "$nas_f" >/dev/null 2>&1 || return 0
        if jq -e --arg p "$NAS_PLUGIN" '.[$p].install == true' "$nas_f" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}
nas_uninstall() {
    nas_prepare uninstall "${1:-}"
    nas_require cp date chmod chown rm
    NAS_BACKUP="/data/.taskcenter-backups/$NAS_USER/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$NAS_BACKUP"
    chmod 0700 "$NAS_BACKUP"
    nas_log "停止所选用户的插件并备份配置……"
    # Shared helper removal is reference-aware and refuses active operations.
    # Legacy installations without the component retain the original uninstall path.
    if [ -f /data/.minas-privileged/component_admin.py ]; then
        python3 /data/.minas-privileged/component_admin.py remove --plugin "$NAS_PLUGIN" --user "$NAS_USER" ||
            nas_fail "公共权限组件正在使用，或撤销授权失败；未删除插件。"
    fi
    plugincenter -u "$NAS_USER" -p "$NAS_PLUGIN" disable >/dev/null 2>&1 || true
    for nas_data in etc var INFO; do
        if [ -e "$NAS_HOME/$nas_data" ]; then cp -a "$NAS_HOME/$nas_data" "$NAS_BACKUP/"; fi
    done
    if [ -d "/data/.taskcenter-system/users/$NAS_USER" ]; then cp -a "/data/.taskcenter-system/users/$NAS_USER" "$NAS_BACKUP/state"; fi
    nas_remove_entry
    case "$NAS_PLUGIN" in
        mihomo)
            nas_port=$(sed -n 's/^MIXED_PORT=\([0-9][0-9]*\)$/\1/p' "$NAS_HOME/etc/ports.env" 2>/dev/null | head -n 1)
            nas_helper=/data/plugin/.mihomo-system/mihomo-docker-proxy
            if [ -x "$nas_helper" ] && [ -n "$nas_port" ]; then
                "$nas_helper" disable "$nas_port" >/dev/null || nas_fail "无法撤销该用户的 Docker 代理。"
            fi
            rm -f "/etc/sudoers.d/mihomo-docker-proxy-$NAS_USER" "/etc/cron.d/mihomo-plugin-$NAS_USER"
            if [ -f /etc/sudoers.d/mihomo-docker-proxy ] && grep -q "^$NAS_USER[[:space:]]" /etc/sudoers.d/mihomo-docker-proxy; then rm -f /etc/sudoers.d/mihomo-docker-proxy; fi
            if [ -f /etc/cron.d/mihomo-plugin ] && grep -Fq "boot.sh $NAS_USER" /etc/cron.d/mihomo-plugin; then rm -f /etc/cron.d/mihomo-plugin; fi
            nas_hotplug=$(jq -r '.settings.system_hotplug // empty' /etc/config/plugin)
            if [ -n "$nas_hotplug" ]; then rm -f "$nas_hotplug/net/$NAS_USER.$NAS_PLUGIN"; fi;;
        dockermanager)
            rm -f "/etc/sudoers.d/dockermanager-$NAS_USER" "/etc/cron.d/dockermanager-$NAS_USER";;
        quickshare)
            rm -f "/etc/cron.d/quickshare-$NAS_USER";;
        taskcenter)
            rm -f "/etc/sudoers.d/taskcenter-$NAS_USER"
            : # Shared user state is removed and backed up by component_admin.
            ;;
    esac
    rm -f "$NAS_WEB_ROOT/$NAS_USER/$NAS_PLUGIN"
    # Paths were checked in full by nas_check_user; repeat immediately before removal.
    nas_pool_path "$NAS_SRC" pluginsrc; nas_pool_path "$NAS_TMP" plugintmp
    rm -rf "$NAS_SRC" "$NAS_TMP" "$NAS_HOME"
    if ! nas_other_users; then
        case "$NAS_PLUGIN" in
            mihomo)
                if ! ls /etc/sudoers.d/mihomo-docker-proxy* >/dev/null 2>&1; then
                    rm -f /data/plugin/.mihomo-system/mihomo-docker-proxy
                    rmdir /data/plugin/.mihomo-system 2>/dev/null || true
                fi;;
            dockermanager)
                if ! ls /etc/sudoers.d/dockermanager-u* >/dev/null 2>&1; then
                    rm -f /data/plugin/.dockermanager-system/docker-manager-helper
                    rmdir /data/plugin/.dockermanager-system 2>/dev/null || true
                fi;;
            taskcenter)
                if ! ls /etc/sudoers.d/taskcenter-u* >/dev/null 2>&1; then
                    rm -f /data/.taskcenter-system/task-center-helper /data/.taskcenter-system/task_schedule.py /data/.taskcenter-system/task_maintenance.py /etc/cron.d/taskcenter
                    rmdir /data/.taskcenter-system/users 2>/dev/null || true
                    rmdir /data/.taskcenter-system 2>/dev/null || true
                fi;;
        esac
        rm -f "/data/plugin/www/icon/$NAS_PLUGIN.icon"
    fi
    systemctl reload crond.service >/dev/null 2>&1 || true
    nas_log "$NAS_USER 的$NAS_LABEL已卸载。"
    nas_log "配置及记录备份：$NAS_BACKUP"
    nas_log "$UNINSTALL_NOTE"
}
# Direct read-only entry points used by the frontend over SSH.
case "${1:-}" in
    --scan)
        set -eu
        [ "$#" = 3 ] || nas_fail "扫描参数错误。"
        case "$3" in install|uninstall) ;; *) nas_fail "无效操作。";; esac
        nas_scan "$2" "$3";;
    --check)
        set -eu
        nas_metadata "$2"; NAS_ACTION=$3; shift 3
        case "$NAS_ACTION" in install|uninstall) ;; *) nas_fail "无效操作。";; esac
        nas_environment
        for nas_selected in "$@"; do nas_check_user "$nas_selected"; done;;
esac
NAS_COMMON_SCRIPT
}
installer_emit_probe() {
    installer_emit_metadata
    installer_emit_nas_common
}
installer_emit_install() {
    installer_emit_probe
    cat <<'NAS_INSTALL_SCRIPT'
INSTALLER_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
nas_prepare install "${1:-}"
PLUGIN_USER=$NAS_USER
fail() { nas_fail "$@"; }
u=$NAS_USER
name=$PLUGIN_NAME
version=$PLUGIN_VERSION
nas_require jq sha256sum plugincenter flock python3 sudo visudo systemctl runuser
[ -x /sbin/shutdown ] || fail "系统缺少 shutdown 命令"
B=$(CDPATH= cd "$(dirname "$0")"&&pwd);P="$B/payload";root="/home/$u/plugin";home="$root/$name";scripts="$home/scripts";list="/data/plugin/$u.list";[ -f "$list" ]&&jq empty "$list">/dev/null||exit 1
oldsrc="";[ -L "$home/src" ]&&oldsrc=$(readlink "$home/src" 2>/dev/null||true);case "$oldsrc" in */"$u"/plugin/pluginsrc/"$name")pool=${oldsrc%/pluginsrc/$name};;*)pool="/nas/pool0/$u/plugin";;esac
srcp="$pool/pluginsrc";tmpp="$pool/plugintmp";src="$srcp/$name";tmp="$tmpp/$name";webroot=$(jq -r '.settings.nginx_plugin//"/data/plugin/www"' /etc/config/plugin);web="$webroot/$u/$name";icon=/data/plugin/www/icon/taskcenter.icon;helperdir=/data/.minas-privileged;helper="$helperdir/minas-helper";sudoers="/etc/sudoers.d/taskcenter-$u";lock="/data/plugin/.$u.plugins.lock"
mkdir -p "$home" "$scripts" "$srcp" "$tmpp" "$(dirname "$web")" "$(dirname "$icon")" /etc/sudoers.d
python3 "$P/common/component_admin.py" install --plugin "$name" --user "$u" --payload "$P" --plugin-version "$version" || fail '公共权限组件安装失败'
# Existing scheduler state, task IDs, enabled flags and logs are preserved.

stage="$srcp/.$name.new.$$";old="$srcp/.$name.old.$$";rm -rf "$stage";mkdir -p "$stage";cp -R "$P/files" "$stage/files";cp -R "$P/ui" "$stage/ui";chmod 0755 "$stage/files/"*.sh "$stage/ui/taskcenter.cgi";chmod 0644 "$stage/ui/index.html" "$stage/ui/app.js" "$stage/ui/client-bridge.js" "$stage/ui/"*.css "$stage/ui/config";[ ! -d "$src" ]||mv "$src" "$old";mv "$stage" "$src";[ ! -d "$old" ]||rm -rf "$old"
cp "$P/scripts/control" "$scripts/control";chmod 0755 "$scripts/control";rm -f "$home/src" "$home/tmp";ln -s "$src" "$home/src";mkdir -p "$tmp";ln -s "$tmp" "$home/tmp"
digest="$tmp/d.$$";find "$src" -type f|LC_ALL=C sort|while IFS= read -r f;do sha256sum "$f"|cut -d' ' -f1;done>"$digest";abstract=$(sha256sum "$digest"|cut -d' ' -f1);rm -f "$digest";size=$(du -sk "$src"|awk '{print $1*1024}');now=$(date +%s)
jq -n --arg v "$version" --arg a "$abstract" --argjson n "$now" --argjson z "$size" '{plugin:"taskcenter",name:"定时任务",id:19094,version:$v,tags:["tool"],timestamp:$n,desc:"任务模板、定时执行与运行记录",developer:"Local",publisher:"Local",changelog:"公共权限组件、增强计划、前置条件与联动、安全清理、失败重试",system:false,size:$z,port:"",type:"standard",forceupgrade:false,ext:{admin:true},hotplug:[],abstract:$a}'>"$home/INFO"
rm -f "$web";ln -s "$src/ui" "$web";python3 "$P/make_icon.py" "$icon";chmod 0644 "$icon"
entry="$tmp/e.$$";jq -n --slurpfile f "$src/ui/config" --slurpfile i "$home/INFO" --argjson n "$now" '{resource:{mpk:"",icon:"",preview:null},status:"running",install:true,upgrade:false,enable:true,changetime:$n,icon:"/icon/taskcenter.icon",progress:"100",frontend:$f[0],info:($i[0]|del(.abstract)),online:true}'>"$entry";exec 9>"$lock";flock -x 9;backup="$list.pre-taskcenter.$now";cp -p "$list" "$backup";l="$list.taskcenter.$$";jq --slurpfile e "$entry" '.taskcenter=$e[0]' "$list">"$l";jq empty "$l";chmod --reference="$list" "$l" 2>/dev/null||chmod 0644 "$l";chown --reference="$list" "$l" 2>/dev/null||chown "$u:$u" "$l";mv -f "$l" "$list";flock -u 9;rm -f "$entry"
# Common component owns protected modules, sudo rules and the shared cron entry.
chown -R "$u:$u" "$home" "$src" "$tmp";chown -h "$u:$u" "$home/src" "$home/tmp" "$web";chmod 0700 "$home" "$src" "$tmp";chmod 0755 "$src/ui"
printf '{"action":"list","pluginUser":"%s"}' "$u"|runuser -u "$u" -- sudo -n "$helper" taskcenter|jq -e '.ok==true'>/dev/null||{ echo '错误：定时任务自检失败'>&2;exit 1;}
# Do not call the enable hook here: it would silently re-enable a disabled scheduler.
systemctl is-active --quiet crond.service || fail '系统 crond 服务未运行，请检查后重新安装'
echo "定时任务 $version 已安装。";echo "安装前清单备份：$backup"
NAS_INSTALL_SCRIPT
}
installer_emit_uninstall() {
    installer_emit_probe
    printf '%s\n' 'nas_uninstall "${1:-}"'
}
manage_usage() {
    cat <<EOF
$PLUGIN_LABEL — 安装与卸载
  bash manage.sh                         交互菜单
  bash manage.sh install [选项]           安装或更新
  bash manage.sh uninstall [选项]         卸载
  bash manage.sh install --help           查看安装参数
  bash manage.sh uninstall --help         查看卸载参数

NAS 本机自动直接执行；WSL/Linux 自动通过 root SSH 连接。
支持 --ip、--users、--all-users、--list-users、--dry-run 和 --yes。
EOF
}
if (($# == 0)); then
    [[ -t 0 ]] || { manage_usage; installer_error "非交互运行请指定 install 或 uninstall。"; }
    printf '\n%s — 安装与卸载\n  1) 安装 / 更新\n  2) 卸载\n  0) 退出\n' "$PLUGIN_LABEL"
    read -r -p '请选择操作：' choice || installer_error "输入已结束。"
    case $choice in 1) set -- install;; 2) set -- uninstall;; 0|q) exit 0;; *) installer_error "无效选项。";; esac
fi
case $1 in
    install|uninstall) operation=$1; shift; installer_main "$operation" "$@";;
    -h|--help) manage_usage;;
    *) manage_usage; installer_error "未知操作：$1";;
esac

