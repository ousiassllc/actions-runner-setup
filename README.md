# actions-runner-setup

GitHub Actions の self-hosted runner を 1 台のマシンに複数常駐させるための管理ツール（ousiassllc org 用）。

runner プロセス 1 個 = 同時 1 ジョブ という GitHub Actions の固定仕様があるため、並列数を上げる手段は「別ディレクトリに runner インスタンスを増やす」ことに限られる。このリポジトリはその増設・状態確認・撤去を `make` に集約する。

常駐には root が必要な公式の `svc.sh` を使わず、ユーザー systemd + linger を使うので **sudo 不要**。

## 構成

| パス | 役割 |
| --- | --- |
| `~/actions-runner` | このリポジトリ。tarball と `.env` の供給元。runner としては使わない（org から登録解除済み） |
| `~/actions-runner-2` 〜 `-13` | 実働 runner。ユーザー systemd + linger で常駐 |
| `~/.config/systemd/user/actions.runner.ousiassllc.ousiass-desktop-N.service` | 各 runner の unit |

runner 本体（`bin/` `externals/` `config.sh` など GitHub 公式配布物）と tarball、実行時生成物（`_work/` `_diag/` `.runner` `.credentials`）は git 管理外。`.gitignore` は「全無視 + 明示許可」方式で、認証情報の混入を防いでいる。

## セットアップ

```bash
# 1. runner 本体を GitHub 公式リリースから取得（約226MB / SHA256 検証つき）
make fetch

# 2. 登録トークンを用意する（有効期限 1 時間）
make token                        # 発行ページの URL を表示
cp .env.token.example .env.token  # TOKEN=... を書く

# 3. runner を 12 台立てる
make add
```

トークンは `make add TOKEN=xxxx` のようにコマンドラインから渡すこともできる。

> **注意**: トークンは runner 自身が読む `.env` ではなく `.env.token` に書く。`.env` は `add-actions-runners.sh` が各 runner ディレクトリにコピーするため、そこに書くと CI ジョブから見える環境変数になってしまう。

## 使い方

```
make fetch [RUNNER_VERSION=x.y.z] runner tarball を GitHub から取得
make add [COUNT=12] [TOKEN=xxxx]  runner を追加登録して起動
make remove-legacy [TOKEN=xxxx]   停止中の ousiass-desktop を org から登録解除

make status                       全 runner の service 状態 + リソース
make busy                         ジョブ実行中の台数と対象リポジトリ
make queue                        ai-liver の CI キュー状況
make logs N=2                     ousiass-desktop-2 のログを追う

make stop N=9                     1 台停止（実行中ジョブ完了後 / 最大5分待機）
make start N=9 / restart N=9
make stop-all / start-all / restart-all

make remove N=9 [TOKEN=xxxx]      1 台を org から登録解除してディレクトリ削除
make token                        登録トークン発行ページを表示
```

`make` を引数なしで実行するとこのヘルプが出る。

## 設計上の要点

- **停止は安全**: unit は公式 template と同じ `KillMode=process` / `KillSignal=SIGTERM` / `TimeoutStopSec=5min`。`make stop` は実行中ジョブを殺さず、新規受付を止めて完了を待つ。
- **PATH を焼き付けない**: `config.sh` は実行時シェルの PATH を `.path` に書き込むが、`/run/user/<uid>/fnm_multishells/*` のようなセッション固有パスは再起動で消える。そのため安定 PATH で上書きしている。node/go 等は workflow 側の `setup-*` action が `_work/_tool` に用意する。
- **展開の完全性を検証**: 1 台あたり展開後 約675MB。`config.sh` を叩く前に必須ファイルの存在を確認し、中断・破損を検出する。
- **linger は sudo 不要**: polkit の `org.freedesktop.login1.set-self-linger` が許可されているため、`loginctl enable-linger` がパスワードなしで通る。

## runner のバージョン更新

```bash
make fetch RUNNER_VERSION=2.337.0
```

恒常的に上げる場合は `Makefile` の `RUNNER_VERSION` を書き換える。既存 runner は作り直し（`make remove N=<n>` → `make add`）で新バージョンになる。

## 参考

- 登録 runner 一覧: https://github.com/organizations/ousiassllc/settings/actions/runners
- トークン発行: https://github.com/organizations/ousiassllc/settings/actions/runners/new
