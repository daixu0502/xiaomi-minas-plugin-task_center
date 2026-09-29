#!/bin/sh
set -eu
status=${1:-running};enabled=${2:-true};u=${3:-${PLUG_USER:-}};case "$u" in u[0-9]*) ;;*)exit 1;;esac
src=$(CDPATH= cd "$(dirname "$0")/.."&&pwd);list="/data/plugin/$u.list";info="/home/$u/plugin/taskcenter/INFO";front="$src/ui/config";lock="/data/plugin/.$u.plugins.lock";[ -f "$list" ]&&[ -f "$info" ]||exit 1
exec 9>"$lock";flock -x 9;t="$list.taskcenter.$$";jq --slurpfile f "$front" --slurpfile i "$info" --arg s "$status" --argjson e "$enabled" --argjson n "$(date +%s)" '.taskcenter=((.taskcenter//{})+{resource:{mpk:"",icon:"",preview:null},status:$s,install:true,upgrade:false,enable:$e,changetime:$n,icon:"/icon/taskcenter.icon",progress:"100",frontend:$f[0],info:($i[0]|del(.abstract)),online:true})' "$list">"$t";jq empty "$t";chmod --reference="$list" "$t" 2>/dev/null||chmod 0644 "$t";chown --reference="$list" "$t" 2>/dev/null||true;mv -f "$t" "$list";flock -u 9

