#!/usr/bin/env bash
#
# runner の _work を tmpfs (/dev/shm) と SSD の間で切り替える。
#
# 背景:
#   CI の書き込み (checkout / node_modules / ビルド成果物) が SSD の書き込み
#   性能を超えるとダーティページが滞留し、書き込もうとする全プロセスが同期
#   ブロックされてジョブがハングする。_work を tmpfs に置いて書き込みを RAM
#   に逃がすことで、SSD を律速から外す。
#
#   _work/_tool だけは SSD 上の tool-cache へ symlink して永続化する。
#   揮発すると setup-go / setup-bun が毎回ツールを再取得してしまい、
#   ネットワークと tmpfs 容量の両方を無駄に消費する。
#
#   /dev/shm は sudo なしで使える既存の tmpfs。swap が無い環境なので、
#   /dev/shm のサイズ上限がそのまま安全弁として働く (溢れても ENOSPC で
#   ジョブが落ちるだけで OOM には至らない)。
#
# 使い方:
#   ./tmpfs-switch.sh on  [番号...]   省略時は unit が存在する全 runner
#   ./tmpfs-switch.sh off [番号...]
#
#   切り替え対象は必ず停止してから作業する。起動は呼び出し側で行う
#   (make start N=2 / make start-all)。
#
# 注意: on / off いずれも _work の中身は破棄される。CI の作業ディレクトリなので
#       次のジョブで再生成されるが、実行中のジョブがあってはいけない。
#
set -euo pipefail

MODE="${1:?on か off を指定してください}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE="$SCRIPT_DIR/prepare-work-tmpfs.sh"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PREFIX="actions.runner.ousiassllc.ousiass-desktop"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo ">>> $*"; }

[ -x "$PREPARE" ] || die "$PREPARE が無い (または実行権限が無い)"

# 対象 runner の番号を決める。引数が無ければ unit が存在するものを全部。
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=()
  for unit_file in "$UNIT_DIR/$UNIT_PREFIX"-*.service; do
    [ -e "$unit_file" ] || continue
    n="${unit_file##*-}"; n="${n%.service}"
    TARGETS+=("$n")
  done
fi
[ "${#TARGETS[@]}" -gt 0 ] || die "対象の runner が見つからない"

pgrep -f 'Runner\.Worker' >/dev/null 2>&1 && die "ジョブ実行中。先に make stop-all すること"

# unit の ExecStart 直前に ExecStartPre を差し込む (既にあれば何もしない)。
# /dev/shm は再起動でクリアされるため、起動のたびに作り直す必要がある。
add_prepare_hook() {
  local unit_file="$1" idx="$2"
  local line="ExecStartPre=$PREPARE $idx"
  grep -qxF "$line" "$unit_file" && return 0
  sed -i "/^ExecStartPre=.*prepare-work-tmpfs\.sh/d" "$unit_file"
  sed -i "/^ExecStart=/i $line" "$unit_file"
}

remove_prepare_hook() {
  sed -i "/^ExecStartPre=.*prepare-work-tmpfs\.sh/d" "$1"
}

switch_on() {
  local idx="$1"
  local dest="$HOME/actions-runner-$idx"
  local work="$dest/_work"
  local shm_work="/dev/shm/actions-runner/$idx/_work"
  local tool_cache="$dest/tool-cache"

  [ -d "$dest" ] || { log "[$idx] $dest が無いのでスキップ"; return 0; }

  if [ -L "$work" ]; then
    log "[$idx] 既に tmpfs ($(readlink "$work"))"
  else
    # ツールキャッシュは SSD 側へ退避してから _work を捨てる。
    # 同一ファイルシステム内なので mv なら実データのコピーが発生しない。
    # このマシンの SSD は書き込みが 11 MB/s しか出ないため、cp では数百 MB の
    # 退避に分単位でかかってしまう。
    if [ -d "$work/_tool" ] && [ ! -L "$work/_tool" ]; then
      # 中断などで不完全な退避が残っている可能性があるため作り直す。
      rm -rf "$tool_cache"
      log "[$idx] _tool を tool-cache へ退避 ($(du -sh "$work/_tool" 2>/dev/null | cut -f1))"
      mv "$work/_tool" "$tool_cache"
    fi
    rm -rf "$work"
    ln -s "$shm_work" "$work"
    log "[$idx] _work -> $shm_work"
  fi

  mkdir -p "$tool_cache"
  "$PREPARE" "$idx"

  local unit_file="$UNIT_DIR/$UNIT_PREFIX-$idx.service"
  [ -f "$unit_file" ] && add_prepare_hook "$unit_file" "$idx"
}

switch_off() {
  local idx="$1"
  local dest="$HOME/actions-runner-$idx"
  local work="$dest/_work"
  local tool_cache="$dest/tool-cache"

  [ -d "$dest" ] || { log "[$idx] $dest が無いのでスキップ"; return 0; }

  if [ -L "$work" ]; then
    rm -f "$work"
    rm -rf "/dev/shm/actions-runner/$idx"
  fi
  mkdir -p "$work"

  # 退避しておいたツールキャッシュを _work 配下へ戻す (mv なのでコピーは発生しない)。
  if [ -d "$tool_cache" ]; then
    rm -rf "$work/_tool"
    mv "$tool_cache" "$work/_tool"
  fi
  log "[$idx] _work を SSD へ戻した"

  local unit_file="$UNIT_DIR/$UNIT_PREFIX-$idx.service"
  [ -f "$unit_file" ] && remove_prepare_hook "$unit_file"
}

case "$MODE" in
  on)  for n in "${TARGETS[@]}"; do switch_on  "$n"; done ;;
  off) for n in "${TARGETS[@]}"; do switch_off "$n"; done ;;
  *)   die "不明なモード: $MODE (on か off)" ;;
esac

systemctl --user daemon-reload
log "完了。起動は make start-all / make start N=<n> で行う"
