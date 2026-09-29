#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

DST="/Applications/不许睡.app"
FRAG="/etc/sudoers.d/keepawake"
PMSET=/usr/bin/pmset

echo "==> 1/3 松开保活标志"
sudo "$PMSET" -a disablesleep 0
echo "    SleepDisabled 现在为 $(pmset -g | awk '$1=="SleepDisabled"{print $2}')"

echo "==> 2/3 移除应用"
rm -rf "$DST" 2>/dev/null || sudo rm -rf "$DST"

echo "==> 3/3 移除本项目写入的白名单"
if [ -f "$FRAG" ]; then
	sudo rm -f "$FRAG"
	echo "    已删除 $FRAG"
else
	echo "    本项目没有写入过白名单，跳过"
fi

echo
echo "完成。系统睡眠行为已交回 macOS 默认。"
