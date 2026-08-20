#!/usr/bin/env bash
#
# ousiassllc org の self-hosted runner を同一マシンに追加登録する (sudo 不要版)。
#
# 背景:
#   runner プロセス 1 個 = 同時 1 ジョブ (GitHub Actions の固定仕様)。
#   並列数を上げる方法は「別ディレクトリに runner インスタンスを増やす」しかない。
#   ~/actions-runner は runner として使わない (org から登録解除済み)。
#   tarball と .env の供給元としてのみ参照する。
#
#   常駐は GitHub 公式の svc.sh (root 必須) を使わず、ユーザー systemd で行う。
#   `loginctl enable-linger` は polkit の org.freedesktop.login1.set-self-linger が
#   許可されているためパスワード不要で通る。
#
# 使い方:
#   ./add-actions-runners.sh <ORG_TOKEN> [台数(既定12)]
#
#   通常は Makefile 経由で使う: make add
#   tarball が無い場合は先に make fetch で公式リリースから取得する。
#
#   ORG_TOKEN は下記ページの ./config.sh --token ***** の値 (有効期限 1 時間):
#     https://github.com/organizations/ousiassllc/settings/actions/runners/new
#
# 確認:
#   systemctl --user list-units 'actions.runner.*' --no-pager
#   journalctl --user -u actions.runner.ousiassllc.ousiass-desktop-2 -f
#   https://github.com/organizations/ousiassllc/settings/actions/runners
#
# 取り消し (1台ぶん):
#   systemctl --user disable --now actions.runner.ousiassllc.ousiass-desktop-2
#   cd ~/actions-runner-2 && ./config.sh remove --token <ORG_TOKEN>
#
set -euo pipefail

TOKEN="${1:-}"
ADD_COUNT="${2:-12}"

ORG="ousiassllc"
ORG_URL="https://github.com/$ORG"
SRC_RUNNER="$HOME/actions-runner"
TARBALL="$(ls -1 "$SRC_RUNNER"/actions-runner-linux-x64-*.tar.gz 2>/dev/null | head -1)"
UNIT_DIR="$HOME/.config/systemd/user"
NAME_PREFIX="ousiass-desktop"

# 既存 .path から「セッション依存の一時パス」を除いた安定 PATH。
# /run/user/<uid>/fnm_multishells/* は tmpfs 上のシェルセッション固有ディレクトリで
# 再起動すると消えるため、新 runner には焼き付けない。
# node/go 等は workflow 側の setup-* action が _work/_tool に用意する。
STABLE_PATH="$HOME/.local/bin:/opt/nvim/bin:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/share/pnpm:$HOME/.cargo/bin:$HOME/.bun/bin:$HOME/.local/share/fnm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo ">>> $*"; }

[ -n "$TOKEN" ] || die "ORG_TOKEN が未指定。使い方: $0 <ORG_TOKEN> [台数]"
[ -n "$TARBALL" ] || die "runner の tarball が見つからない ($SRC_RUNNER)"
[[ "$ADD_COUNT" =~ ^[0-9]+$ ]] || die "台数が数値でない: $ADD_COUNT"

log "tarball  : $TARBALL"
log "追加台数 : $ADD_COUNT"
log "登録先   : $ORG_URL"
echo

# ログアウト・再起動後もユーザー service が動くようにする (パスワード不要)
if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != "yes" ]; then
  log "linger を有効化 (ログアウト後もユーザー service を維持)"
  loginctl enable-linger "$(id -un)"
else
  log "linger は既に有効"
fi

mkdir -p "$UNIT_DIR"

# ~/actions-runner-N を 1 台セットアップして user systemd unit を作る
setup_one() {
  local idx="$1"
  local dest="$HOME/actions-runner-$idx"
  local name="$NAME_PREFIX-$idx"
  local unit="actions.runner.$ORG.$name"

  if [ -f "$dest/.runner" ]; then
    log "スキップ: $dest は既に設定済み"
    return 1
  fi

  # 前回中断した残骸があれば消す (パスを厳密に検証してから rm する)
  if [ -d "$dest" ]; then
    case "$dest" in
      "$HOME/actions-runner-"[0-9]*)
        log "[$name] 未完了の $dest を削除して作り直す"
        rm -rf "$dest" ;;
      *) die "想定外の削除対象: $dest" ;;
    esac
  fi

  # tar は無出力だと固まったように見えるので必ず進捗を出す。
  # 展開後は約 675MB (externals/ の node 4 ディストリビューションで 595MB)。
  log "[$name] $dest に展開中 … 展開後 約675MB / 数十秒かかる (中断しないこと)"
  mkdir -p "$dest"
  local t0=$SECONDS
  tar xzf "$TARBALL" -C "$dest" --checkpoint=2000 --checkpoint-action=dot
  echo
  log "[$name] 展開完了 ($((SECONDS - t0)) 秒, $(du -sh "$dest" | cut -f1))"

  # 中断・破損を config.sh 実行前に検出する
  for required in config.sh run.sh bin/Runner.Listener bin/runsvc.sh externals/node20/bin/node; do
    [ -e "$dest/$required" ] || die "[$name] 展開が不完全: $dest/$required が無い。再実行してください"
  done

  log "[$name] org に登録"
  ( cd "$dest" && ./config.sh \
      --url "$ORG_URL" \
      --token "$TOKEN" \
      --name "$name" \
      --runnergroup Default \
      --work _work \
      --unattended \
      --replace )

  # config.sh は実行時シェルの PATH を .path に焼き付けるので安定版で上書きする
  log "[$name] .path を安定 PATH で上書き"
  printf '%s' "$STABLE_PATH" > "$dest/.path"
  cp "$SRC_RUNNER/.env" "$dest/.env" 2>/dev/null || printf 'LANG=ja_JP.UTF-8\n' > "$dest/.env"

  # svc.sh install が本来やる処理を自前で行う (root を避けるため)
  cp "$dest/bin/runsvc.sh" "$dest/runsvc.sh"
  chmod 755 "$dest/runsvc.sh"

  # KillMode=process / KillSignal=SIGTERM / TimeoutStopSec=5min は公式 template と同一。
  # 実行中ジョブを殺さず「新規受付を止めて、走っているジョブが終わったら終了」する。
  log "[$name] user unit $unit.service を作成"
  cat > "$UNIT_DIR/$unit.service" <<EOF
[Unit]
Description=GitHub Actions Runner ($ORG.$name)
After=network-online.target

[Service]
ExecStart=$dest/runsvc.sh
WorkingDirectory=$dest
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

  log "[$name] 起動"
  systemctl --user daemon-reload
  systemctl --user enable --now "$unit.service"
  return 0
}

created=()
idx=1
attempts=0
while [ "${#created[@]}" -lt "$ADD_COUNT" ] && [ "$attempts" -lt $((ADD_COUNT + 20)) ]; do
  idx=$((idx + 1))
  attempts=$((attempts + 1))
  if setup_one "$idx"; then
    created+=("$NAME_PREFIX-$idx")
    echo
  fi
done

echo "===================================================="
log "完了: ${#created[@]} 台追加 (${created[*]:-なし})"
echo
systemctl --user list-units 'actions.runner.*' --no-pager --all || true
echo
log "~/actions-runner 自体は runner として使わない (tarball と .env の供給元)。"
log "状態確認: make status / make busy / make queue"
