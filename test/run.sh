#!/usr/bin/env bash
#
# 管理スクリプトの動作テスト。実ホストには一切触れない。
#
#   - HOME を使い捨てディレクトリに差し替える
#   - systemctl / loginctl / pgrep は PATH 先頭のスタブに差し替える
#   - /dev/shm は SHM_ROOT で使い捨てディレクトリに差し替える
#   - runner 本体 (config.sh など) は偽の tarball で用意する
#
# 使い方: test/run.sh
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ -z "${2:-}" ] || printf '%s\n' "${2//$'\n'/$'\n'       }" | sed '1s/^/       /'; }
# assert <名前> <失敗時に出す詳細> -- <成功すべきコマンド...>
assert() { local name="$1" detail="$2"; shift 3; if "$@"; then ok "$name"; else fail "$name" "$detail"; fi; }

# check <名前> <期待する終了コード> <出力に含まれるべき文字列 (空なら不問)> -- <コマンド...>
check() {
  local name="$1" want_rc="$2" want_out="$3"
  shift 4
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    fail "$name (終了コード $rc, 期待 $want_rc)" "$out"
  elif [ -n "$want_out" ] && [[ "$out" != *"$want_out"* ]]; then
    fail "$name (出力に '$want_out' が無い)" "$out"
  else
    ok "$name"
  fi
}

# 隔離環境を作る: 偽 HOME と PATH 先頭のスタブ。$1 = ディレクトリ名
new_env() {
  local d="$TMP/$1"
  mkdir -p "$d/home" "$d/bin" "$d/shm"
  : > "$d/calls.log"

  cat > "$d/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$d/calls.log"
EOF
  cat > "$d/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo yes
EOF
  # ジョブ実行中の Worker は居ない。pgrep -c は 0 件でも 0 を出力して exit 1 する (実物と同じ)。
  cat > "$d/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
case "$1" in -*c*) echo 0 ;; esac
exit 1
EOF
  chmod +x "$d/bin/"*
  ENV_DIR="$d"
}

# 偽の runner tarball を作る。$1 = 出力先, $2 = 版 (.version に書く), $3 = config.sh の挙動 (ok|fail)
make_tarball() {
  local out="$1" ver="$2" mode="$3" src
  src="$(mktemp -d "$TMP/tar.XXXXXX")"
  mkdir -p "$src/bin" "$src/externals/node20/bin"
  : > "$src/run.sh"; : > "$src/bin/Runner.Listener"; : > "$src/externals/node20/bin/node"
  echo '#!/usr/bin/env bash' > "$src/bin/runsvc.sh"
  echo "$ver" > "$src/.version"
  if [ "$mode" = fail ]; then
    printf '#!/usr/bin/env bash\necho "config.sh: 登録に失敗" >&2\nexit 1\n' > "$src/config.sh"
  else
    # shellcheck disable=SC2016  # スタブ側のシェルに展開させるので単一引用符で良い
    printf '#!/usr/bin/env bash\necho "$*" >> "$HOME/config.args"\ntouch .runner\n' > "$src/config.sh"
  fi
  chmod +x "$src/config.sh"
  tar czf "$out" -C "$src" .
}

# 隔離 HOME で add-actions-runners.sh を実行する
run_add() {
  env -i HOME="$ENV_DIR/home" PATH="$ENV_DIR/bin:/usr/bin:/bin" "$@"
}

# --- add-actions-runners.sh ---------------------------------------------------

new_env add-no-tarball; mkdir -p "$ENV_DIR/home/actions-runner"
check "add: tarball が無ければ理由を出して異常終了する" 1 "tarball が見つからない" -- \
  run_add "$REPO/add-actions-runners.sh" token 1

new_env add-no-token; mkdir -p "$ENV_DIR/home/actions-runner"
check "add: トークン未指定なら異常終了する" 1 "ORG_TOKEN が未指定" -- \
  run_add "$REPO/add-actions-runners.sh" "" 1

new_env add-config-fails; mkdir -p "$ENV_DIR/home/actions-runner"
make_tarball "$ENV_DIR/home/actions-runner/actions-runner-linux-x64-1.0.0.tar.gz" 1.0.0 fail
check "add: config.sh が失敗したら異常終了する" 1 "登録に失敗" -- \
  run_add "$REPO/add-actions-runners.sh" token 1
if [ -e "$ENV_DIR/home/.config/systemd/user/actions.runner.ousiassllc.ousiass-desktop-2.service" ]; then
  fail "add: 登録に失敗した runner の unit が作られている"
elif grep -q 'enable' "$ENV_DIR/calls.log"; then
  fail "add: 登録に失敗した runner を enable している" "$(cat "$ENV_DIR/calls.log")"
else
  ok "add: 登録に失敗した runner の unit を作らず enable もしない"
fi

new_env add-newest; mkdir -p "$ENV_DIR/home/actions-runner"
make_tarball "$ENV_DIR/home/actions-runner/actions-runner-linux-x64-2.9.0.tar.gz" 2.9.0 ok
make_tarball "$ENV_DIR/home/actions-runner/actions-runner-linux-x64-2.10.0.tar.gz" 2.10.0 ok
mkdir -p "$ENV_DIR/home/actions-runner-3" && touch "$ENV_DIR/home/actions-runner-3/.runner"   # 設定済み = スキップ対象
check "add: 2 台追加できる (設定済みの番号は飛ばす)" 0 "完了: 2 台追加 (ousiass-desktop-2 ousiass-desktop-4)" -- \
  run_add "$REPO/add-actions-runners.sh" token 2
if [ "$(cat "$ENV_DIR/home/actions-runner-2/.version" 2>/dev/null)" = "2.10.0" ]; then
  ok "add: 版が複数あれば最新 (sort -V) を使う"
else
  fail "add: 最新版を使っていない" "$(cat "$ENV_DIR/home/actions-runner-2/.version" 2>/dev/null)"
fi

new_env add-explicit; mkdir -p "$ENV_DIR/home/actions-runner"
make_tarball "$ENV_DIR/home/actions-runner/actions-runner-linux-x64-2.9.0.tar.gz" 2.9.0 ok
make_tarball "$ENV_DIR/home/actions-runner/actions-runner-linux-x64-2.10.0.tar.gz" 2.10.0 ok
check "add: RUNNER_TARBALL を明示すればその版を使う" 0 "" -- \
  run_add RUNNER_TARBALL="$ENV_DIR/home/actions-runner/actions-runner-linux-x64-2.9.0.tar.gz" \
    "$REPO/add-actions-runners.sh" token 1
assert "add: 明示した版が使われている" "$(cat "$ENV_DIR/home/actions-runner-2/.version" 2>/dev/null)" -- \
  test "$(cat "$ENV_DIR/home/actions-runner-2/.version" 2>/dev/null)" = 2.9.0

# --- Makefile -------------------------------------------------------------------

new_env make-add; mkdir -p "$ENV_DIR/home/actions-runner"
cp "$REPO/add-actions-runners.sh" "$ENV_DIR/home/actions-runner/"
make_tarball "$ENV_DIR/home/actions-runner/actions-runner-linux-x64-2.336.0.tar.gz" 2.336.0 ok
secret="SECRET-TOKEN-0123456789"
out="$(env -i HOME="$ENV_DIR/home" PATH="$ENV_DIR/bin:/usr/bin:/bin" \
  make -f "$REPO/Makefile" add TOKEN="$secret" COUNT=1 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  fail "make add が失敗した (終了コード $rc)" "$out"
elif [[ "$out" == *"$secret"* ]]; then
  fail "make add: トークンが出力に出ている" "$out"
elif ! grep -q -- "--token $secret" "$ENV_DIR/home/config.args"; then
  fail "make add: config.sh にトークンが渡っていない" "$(cat "$ENV_DIR/home/config.args" 2>/dev/null)"
else
  ok "make add: トークンを出力に出さず config.sh へ渡す"
fi

new_env make-remove
run_make() { env -i HOME="$ENV_DIR/home" PATH="$ENV_DIR/bin:/usr/bin:/bin" make -f "$REPO/Makefile" "$@"; }
check "make remove: N 未指定 (既定値頼み) は拒否する" 2 "N が未指定" -- run_make remove TOKEN=x
check "make remove: N が数字でなければ拒否する"    2 "数字で指定"   -- run_make remove TOKEN=x N=../x
if grep -q . "$ENV_DIR/calls.log"; then
  fail "make remove: 拒否したのに systemctl を呼んだ" "$(cat "$ENV_DIR/calls.log")"
else
  ok "make remove: 拒否時は何も実行しない"
fi

new_env make-busy
out="$(run_make busy 2>&1)"
assert "make busy: Worker 0 件でも表示が崩れない" "$out" -- test "$out" = "ジョブ実行中: 0 台"
out="$(run_make status 2>&1)"
assert "make status: Worker 0 件の表示が崩れない" "$out" -- grep -qx '  Worker   (実行中): 0 台' <<<"$out"

# --- prepare-work-tmpfs.sh ------------------------------------------------------

new_env prepare
run_prepare() { env -i HOME="$ENV_DIR/home" PATH="/usr/bin:/bin" SHM_ROOT="$ENV_DIR/shm/actions-runner" "$@"; }
mkdir -p "$ENV_DIR/shm/actions-runner" && chmod 775 "$ENV_DIR/shm/actions-runner"   # 過去に作られた 775
check "prepare: 実行できる" 0 "" -- run_prepare "$REPO/prepare-work-tmpfs.sh" 5
assert "prepare: 入口ディレクトリを 700 にする (既存の 775 も是正)" "$(stat -c %a "$ENV_DIR/shm/actions-runner")" -- \
  test "$(stat -c %a "$ENV_DIR/shm/actions-runner")" = 700
assert "prepare: _tool を tool-cache へ symlink する" "$(readlink "$ENV_DIR/shm/actions-runner/5/_work/_tool")" -- \
  test "$(readlink "$ENV_DIR/shm/actions-runner/5/_work/_tool")" = "$ENV_DIR/home/actions-runner-5/tool-cache"
check "prepare: 数字以外の番号は拒否する" 1 "数字でない" -- run_prepare "$REPO/prepare-work-tmpfs.sh" '../x'

# --- tmpfs-switch.sh ------------------------------------------------------------

new_env switch
run_switch() { env -i HOME="$ENV_DIR/home" PATH="$ENV_DIR/bin:/usr/bin:/bin" SHM_ROOT="$ENV_DIR/shm/actions-runner" "$@"; }
unit_dir="$ENV_DIR/home/.config/systemd/user"
mkdir -p "$unit_dir" "$ENV_DIR/home/actions-runner-3/_work/_tool" "$ENV_DIR/home/actions-runner-4/_work/_tool"
echo cached > "$ENV_DIR/home/actions-runner-4/_work/_tool/marker"
# runner 3 は unit が無く、runner 4 にだけ unit がある
printf '[Service]\nExecStart=/x/runsvc.sh\n' > "$unit_dir/actions.runner.ousiassllc.ousiass-desktop-4.service"

check "switch on: unit の無い runner が混ざっても全体を止めない" 0 "完了" -- \
  run_switch "$REPO/tmpfs-switch.sh" on 3 4
assert "switch on: unit に ExecStartPre を差し込む" "" -- \
  grep -q "^ExecStartPre=$REPO/prepare-work-tmpfs.sh 4$" "$unit_dir/actions.runner.ousiassllc.ousiass-desktop-4.service"
is_link_and_file() { [ -L "$1" ] && [ -f "$2" ]; }
assert "switch on: _work は tmpfs へ、_tool は tool-cache へ退避する" "" -- \
  is_link_and_file "$ENV_DIR/home/actions-runner-4/_work" "$ENV_DIR/home/actions-runner-4/tool-cache/marker"

check "switch off: unit の無い runner が混ざっても全体を止めない" 0 "完了" -- \
  run_switch "$REPO/tmpfs-switch.sh" off 3 4
if grep -q ExecStartPre "$unit_dir/actions.runner.ousiassllc.ousiass-desktop-4.service"; then
  fail "switch off: ExecStartPre が残っている"
elif [ -d "$ENV_DIR/home/actions-runner-4/_work" ] && [ ! -L "$ENV_DIR/home/actions-runner-4/_work" ] \
  && [ -f "$ENV_DIR/home/actions-runner-4/_work/_tool/marker" ]; then
  ok "switch off: _work と _tool を SSD 側へ戻す"
else
  fail "switch off: 元に戻っていない"
fi

check "switch: 数字以外の番号は拒否する" 1 "数字でない" -- run_switch "$REPO/tmpfs-switch.sh" on '../x'

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
