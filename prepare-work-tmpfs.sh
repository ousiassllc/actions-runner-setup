#!/usr/bin/env bash
#
# runner の _work を tmpfs (/dev/shm) 上に用意する。
# systemd unit の ExecStartPre から呼ばれる。
#
# /dev/shm は再起動でクリアされるため、起動のたびに作り直す必要がある。
# _work 本体を tmpfs に置くことで、チェックアウト・node_modules・ビルド成果物の
# 書き込みが SSD ではなく RAM に向かう。
#
# ただし _work/_tool だけは SSD 上の tool-cache へ symlink して永続化する。
# ここが揮発すると setup-go / setup-bun が毎回ツールを再取得してしまい、
# ネットワークと tmpfs 容量の両方を無駄に消費する。
#
# 使い方: prepare-work-tmpfs.sh <runner番号>
#
set -euo pipefail

IDX="${1:?runner 番号が未指定}"

WORK="/dev/shm/actions-runner/$IDX/_work"
TOOL_CACHE="$HOME/actions-runner-$IDX/tool-cache"

mkdir -p "$WORK" "$TOOL_CACHE"

# _tool を SSD 側へ逃がす。既に正しい symlink なら触らない (冪等)。
if [ "$(readlink "$WORK/_tool" 2>/dev/null)" != "$TOOL_CACHE" ]; then
  rm -rf "$WORK/_tool"
  ln -s "$TOOL_CACHE" "$WORK/_tool"
fi
