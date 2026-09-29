#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SRC="build/不许睡.app"
DST="/Applications/不许睡.app"
FRAG="/etc/sudoers.d/keepawake"
ME="$(id -un)"
PMSET=/usr/bin/pmset

[ -d "$SRC" ] || { echo "没有 $SRC，先运行 ./build.sh"; exit 1; }

echo "==> 1/2 检查免密授权"
if sudo -n -l "$PMSET" -a disablesleep 1 >/dev/null 2>&1; then
	echo "    已可用（现有白名单已覆盖这两条命令），不动系统文件"
else
	echo "    未授权，写入 $FRAG（仅限这两条命令）"
	DRAFT="$FRAG.draft"
	TMP="$(mktemp)"
	cat >"$TMP" <<EOF
# 不许睡 — 仅允许以下两条命令免密执行；其它 pmset 操作仍需管理员密码
$ME ALL=(root) NOPASSWD: $PMSET -a disablesleep 1, $PMSET -a disablesleep 0
EOF
	# 先落到带点的临时名，sudo 的 includedir 会忽略它，校验通过再改名，避免写坏 sudoers
	sudo install -m 0440 -o root -g wheel "$TMP" "$DRAFT"
	rm -f "$TMP"
	if ! sudo visudo -cf "$DRAFT"; then
		sudo rm -f "$DRAFT"
		echo "    语法校验失败，已回滚，系统未被改动"
		exit 1
	fi
	sudo mv "$DRAFT" "$FRAG"
	sudo -n -l "$PMSET" -a disablesleep 1 >/dev/null 2>&1 || { echo "    授权后自检失败"; exit 1; }
	echo "    完成"
fi

echo "==> 2/2 安装应用"
rm -rf "$DST"
cp -R "$SRC" "$DST"

echo
echo "完成。从「应用程序」或 Spotlight 打开「不许睡」，菜单栏会出现月亮图标。"
echo "卸载：./uninstall.sh"
