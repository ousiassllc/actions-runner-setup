# GitHub Actions self-hosted runner 管理 (ousiassllc org / このマシン)
#
# runner プロセス 1 個 = 同時 1 ジョブ (GitHub Actions の固定仕様)。
# 並列数を上げる方法は「別ディレクトリに runner インスタンスを増やす」しかない。
#
# 構成:
#   ~/actions-runner       … tarball と .env の供給元。runner としては使わない (登録解除済み)
#   ~/actions-runner-2..13 … 実働 runner。ユーザー systemd + linger で常駐
#
# 常駐は公式の svc.sh (root 必須) ではなくユーザー systemd を使うので sudo 不要。
#
# よく使うもの:
#   make fetch      runner の tarball を GitHub から取得
#   make tmpfs-on   _work を RAM (/dev/shm) に逃がして SSD 律速を外す
#   make add        runner を 12 台立てる
#   make status     全 runner の状態
#   make busy       いま何台がジョブを実行中か
#   make queue      ai-liver の CI キュー状況

SHELL      := /bin/bash
RUNNER_DIR := $(HOME)/actions-runner
ORG        := ousiassllc
NEW_RUNNER := https://github.com/organizations/$(ORG)/settings/actions/runners/new
RUNNER_LIST := https://github.com/organizations/$(ORG)/settings/actions/runners

# runner 本体は GitHub 公式リリースから取得する (tarball は 226MB なので git 管理外)。
# 更新する場合はここを上げて make fetch する。
RUNNER_VERSION ?= 2.336.0
TARBALL     := $(RUNNER_DIR)/actions-runner-linux-x64-$(RUNNER_VERSION).tar.gz
TARBALL_URL  = https://github.com/actions/runner/releases/download/v$(RUNNER_VERSION)/$(notdir $(TARBALL))

# 登録トークンは 1 時間で失効する。make token のページで再発行して .env.token に
# 書くか、コマンドラインで渡す: make add TOKEN=<新トークン>
#
# runner 自身が読む .env とは別ファイルにしてある。.env は各 runner ディレクトリに
# コピーされるので、そこにトークンを書くと CI ジョブから見える環境変数になる。
-include $(RUNNER_DIR)/.env.token
TOKEN ?=

# 立てる台数。ai-liver の Check は 8 ジョブ matrix なので 8 以上あれば 1 巡で消化できる。
COUNT ?= 12

# make logs N=2 / make stop N=2 などで対象を指定する
N ?= 2

UNIT_PREFIX := actions.runner.$(ORG).ousiass-desktop

.DEFAULT_GOAL := help

.PHONY: help fetch add status busy queue logs \
        tmpfs-on tmpfs-off tmpfs-status \
        stop start restart stop-all start-all restart-all \
        remove remove-legacy token

help:
	@echo "GitHub Actions self-hosted runner 管理 ($(ORG))"
	@echo
	@echo "セットアップ"
	@echo "  make fetch [RUNNER_VERSION=x.y.z] runner tarball を GitHub から取得"
	@echo "  make add [COUNT=12] [TOKEN=xxxx]  runner を追加登録して起動"
	@echo "  make remove-legacy [TOKEN=xxxx]   停止中の ousiass-desktop を org から登録解除"
	@echo
	@echo "ストレージ"
	@echo "  make tmpfs-on [N_LIST=\"2 3\"]      _work を /dev/shm に逃がす (要 stop-all)"
	@echo "  make tmpfs-off [N_LIST=...]       _work を SSD に戻す"
	@echo "  make tmpfs-status                 現在どちらを使っているか"
	@echo
	@echo "状態確認"
	@echo "  make status                       全 runner の service 状態"
	@echo "  make busy                         ジョブ実行中の台数と対象リポジトリ"
	@echo "  make queue                        ai-liver の CI キュー状況"
	@echo "  make logs N=2                     ousiass-desktop-2 のログを追う"
	@echo
	@echo "台数調整 (登録は残したまま稼働だけ止める)"
	@echo "  make stop N=9                     1 台停止 (実行中ジョブ完了後 / 最大5分待機)"
	@echo "  make start N=9 / restart N=9"
	@echo "  make stop-all / start-all / restart-all"
	@echo
	@echo "撤去"
	@echo "  make remove N=9 [TOKEN=xxxx]      1 台を org から登録解除してディレクトリ削除"
	@echo "  make token                        登録トークン発行ページを表示"

# --- セットアップ -----------------------------------------------------------

# tarball は git 管理外なので、無ければ公式リリースから取得する。
# ダウンロードはリリース本文に記載された SHA256 と突き合わせて検証する。
fetch: $(TARBALL)

$(TARBALL):
	@echo ">>> actions/runner v$(RUNNER_VERSION) を取得 (約226MB)"
	curl -fL --progress-bar -o "$@.part" "$(TARBALL_URL)"
	@expected=$$(gh api repos/actions/runner/releases/tags/v$(RUNNER_VERSION) --jq .body \
	  | tr -d '\r\n' \
	  | sed -n 's/.*<!-- BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\).*/\1/p'); \
	actual=$$(sha256sum "$@.part" | cut -d' ' -f1); \
	if [ -z "$$expected" ]; then \
	  rm -f "$@.part"; echo "ERROR: リリース本文から SHA256 を取得できない" >&2; exit 1; fi; \
	if [ "$$expected" != "$$actual" ]; then \
	  rm -f "$@.part"; \
	  echo "ERROR: SHA256 不一致 (期待 $$expected / 実際 $$actual)" >&2; exit 1; fi; \
	mv "$@.part" "$@"; \
	echo ">>> 取得完了: $@"

add: guard-TOKEN fetch
	$(RUNNER_DIR)/add-actions-runners.sh "$(TOKEN)" "$(COUNT)"

# 停止中の旧 runner (~/actions-runner) を org の一覧から外す。
# ディレクトリと tarball は add の供給元なので消さない。
# 注意: removal token を要求されて失敗する場合は $(RUNNER_LIST) の UI から削除する。
remove-legacy: guard-TOKEN
	@if [ ! -f "$(RUNNER_DIR)/.runner" ]; then echo "既に登録解除済み"; exit 0; fi
	@if pgrep -f 'Runner\.Listener run' >/dev/null 2>&1; then \
	  echo "ERROR: Listener が稼働中。先に停止すること" >&2; exit 1; fi
	cd $(RUNNER_DIR) && ./config.sh remove --token "$(TOKEN)"
	@echo "登録解除した。一覧: $(RUNNER_LIST)"

# --- ストレージ -------------------------------------------------------------
# CI の書き込みが SSD の性能を超えるとダーティページが滞留し、全ジョブが I/O 待ちで
# ハングする。_work を tmpfs に置いて書き込みを RAM に逃がすことで律速を外す。
# 詳細な背景と _tool の扱いは tmpfs-switch.sh の冒頭コメントを参照。
#
# N_LIST で対象を絞れる: make tmpfs-on N_LIST="2 3"
N_LIST ?=

tmpfs-on:
	$(RUNNER_DIR)/tmpfs-switch.sh on $(N_LIST)

tmpfs-off:
	$(RUNNER_DIR)/tmpfs-switch.sh off $(N_LIST)

tmpfs-status:
	@df -h /dev/shm | awk 'NR==2{printf "/dev/shm: %s 使用 / %s (%s)\n", $$3, $$2, $$5}'
	@for d in $(HOME)/actions-runner-[0-9]*; do \
	  [ -d "$$d" ] || continue; \
	  if [ -L "$$d/_work" ]; then \
	    printf "  %-22s tmpfs  (%s)\n" "$$(basename $$d)" "$$(readlink $$d/_work)"; \
	  else \
	    printf "  %-22s SSD\n" "$$(basename $$d)"; \
	  fi; \
	done

# --- 状態確認 ---------------------------------------------------------------

status:
	@echo "=== ユーザー systemd service ==="
	@systemctl --user list-units 'actions.runner.*' --no-pager --all || true
	@echo
	@echo "=== プロセス数 ==="
	@printf "  Listener (待機中): %s 台\n" "$$(pgrep -cf 'Runner\.Listener run' || echo 0)"
	@printf "  Worker   (実行中): %s 台\n" "$$(pgrep -cf 'Runner\.Worker' || echo 0)"
	@echo
	@echo "=== linger / リソース ==="
	@loginctl show-user "$$(id -un)" -p Linger || true
	@free -g | awk '/Mem:/{printf "  RAM: %sGB 使用 / %sGB 全体 (%sGB 利用可)\n", $$3, $$2, $$7}'
	@awk '{printf "  Load: %s %s %s (32 コア)\n", $$1, $$2, $$3}' /proc/loadavg
	@df -h $(HOME) | awk 'NR==2{printf "  Disk: %s 空き / %s (%s 使用)\n", $$4, $$2, $$5}'
	@echo
	@echo "登録一覧: $(RUNNER_LIST)"

# 実働 runner は ~/actions-runner-N 配下で動くので、全ディレクトリの
# 最新 Worker ログから実行中リポジトリを拾う。
busy:
	@n=$$(pgrep -cf 'Runner\.Worker' || echo 0); \
	echo "ジョブ実行中: $$n 台"; \
	if [ "$$n" -gt 0 ]; then \
	  for d in $(HOME)/actions-runner-[0-9]*; do \
	    [ -d "$$d/_diag" ] || continue; \
	    log=$$(ls -t "$$d"/_diag/Worker_*.log 2>/dev/null | head -1); \
	    [ -n "$$log" ] || continue; \
	    [ -n "$$(find "$$log" -mmin -3 2>/dev/null)" ] || continue; \
	    repo=$$(grep -m1 -oE '$(ORG)/[a-z0-9._-]+' "$$log" 2>/dev/null | head -1); \
	    printf "  %-28s %s\n" "$$(basename $$d)" "$${repo:-?}"; \
	  done; \
	fi

queue:
	@cd $(HOME)/ousiassllc/ai-liver 2>/dev/null && \
	  gh run list --limit 6 --json databaseId,headBranch,name,status,conclusion \
	    --template '{{range .}}{{.databaseId}}  {{.headBranch}}  {{.name}}  {{.status}} {{.conclusion}}{{"\n"}}{{end}}' \
	  || echo "ai-liver リポジトリが見つからないか gh 未認証"

logs:
	journalctl --user -u $(UNIT_PREFIX)-$(N) -f

# --- 起動 / 停止 ------------------------------------------------------------
# KillSignal=SIGTERM + KillMode=process + TimeoutStopSec=5min なので、
# stop は「新規受付を止めて実行中ジョブが終わるのを待つ」挙動になる。

stop:
	systemctl --user stop $(UNIT_PREFIX)-$(N)

start:
	systemctl --user start $(UNIT_PREFIX)-$(N)

restart:
	systemctl --user restart $(UNIT_PREFIX)-$(N)

stop-all:
	systemctl --user stop 'actions.runner.*'

start-all:
	systemctl --user start 'actions.runner.*'

restart-all:
	systemctl --user restart 'actions.runner.*'

# --- 撤去 -------------------------------------------------------------------

remove: guard-TOKEN
	systemctl --user disable --now $(UNIT_PREFIX)-$(N)
	rm -f $(HOME)/.config/systemd/user/$(UNIT_PREFIX)-$(N).service
	systemctl --user daemon-reload
	cd $(HOME)/actions-runner-$(N) && ./config.sh remove --token "$(TOKEN)"
	rm -rf $(HOME)/actions-runner-$(N)
	@echo "ousiass-desktop-$(N) を撤去した"

# --- ヘルパー ---------------------------------------------------------------

token:
	@echo "$(NEW_RUNNER)"
	@echo "上記ページの ./config.sh --token ***** の値を使う (有効期限 1 時間)"

guard-%:
	@if [ -z "$($*)" ]; then \
	  echo "ERROR: $* が未指定です。例: make $(MAKECMDGOALS) $*=xxxx" >&2; \
	  echo "       トークン発行: $(NEW_RUNNER)" >&2; \
	  exit 1; \
	fi
