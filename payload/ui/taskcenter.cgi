#!/bin/sh
set -u
DIR=$(CDPATH= cd -P "$(dirname "$0")"&&pwd -P);user=$(printf '%s\n' "$DIR"|sed -n 's#^/nas/pool[^/]*/\(u[0-9][0-9]*\)/plugin/pluginsrc/taskcenter/ui$#\1#p');[ -n "$user" ]||user=$(stat -c '%U' "$0" 2>/dev/null||true)
HELPER=/data/.minas-privileged/minas-helper;INFO="/home/$user/plugin/taskcenter/INFO"
json_header(){ printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'; }
static_header(){ printf 'Content-Type: %s\r\nCache-Control: no-cache, no-store, must-revalidate\r\n\r\n' "$1"; }
serve(){ p=${REQUEST_URI:-/index.html};p=${p%%\?*};case "$p" in */app.js)static_header 'application/javascript; charset=utf-8';cat "$DIR/app.js";;*/client-bridge.js)static_header 'application/javascript; charset=utf-8';cat "$DIR/client-bridge.js";;*/palette.css)static_header 'text/css; charset=utf-8';cat "$DIR/palette.css";;*/style.css)static_header 'text/css; charset=utf-8';cat "$DIR/style.css";;*)static_header 'text/html; charset=utf-8';cat "$DIR/index.html";;esac;exit; }
error(){ json_header;jq -n --arg error "$1" '{ok:false,error:$error}';exit; }
action=$(printf '%s' "${QUERY_STRING:-}"|tr '&' '\n'|sed -n 's/^action=\([A-Za-z0-9_-]*\)$/\1/p'|head -n1);[ -n "$action" ]||serve
[ "${REQUEST_METHOD:-GET}" = POST ]||error 'API 仅接受 POST 请求';[ -x "$HELPER" ]||error '权限助手未安装'
length=${CONTENT_LENGTH:-0};case "$length" in ''|*[!0-9]*)error '请求长度无效';;esac;[ "$length" -le 65536 ]||error '请求过大';body=$(dd bs=1 count="$length" 2>/dev/null);[ -n "$body" ]||body='{}';printf '%s' "$body"|jq empty>/dev/null 2>&1||error '请求不是有效 JSON'
case "$action" in list|templates|resources|save|toggle|run|delete|log|scheduler|schedule_preview|cleanup_preview|cancel_retry);;*)error '未知操作';;esac
request=$(printf '%s' "$body"|jq --arg action "$action" --arg pluginUser "$user" '.+{action:$action,pluginUser:$pluginUser}');response=$(printf '%s' "$request"|sudo -n "$HELPER" taskcenter 2>/dev/null)||error '无法调用权限助手';printf '%s' "$response"|jq empty>/dev/null 2>&1||error '助手返回无效数据';version=$(jq -r '.version//"1.0.0"' "$INFO" 2>/dev/null||echo 1.0.0);json_header;printf '%s' "$response"|jq --arg pluginVersion "$version" '.+{pluginVersion:$pluginVersion}'

