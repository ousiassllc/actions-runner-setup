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

## ストレージ (`_work` の置き場所)

このマシンの CI は **SSD の書き込みが律速**になる。checkout / `bun install` / ビルド成果物の
書き込みが SSD の実効性能を超えるとダーティページが RAM に滞留し、上限に達した時点で
書き込もうとする全プロセスが同期ブロックされる。結果として load average が 3 桁まで跳ね、
ジョブが数十分〜1 時間以上 `in_progress` のままハングする。

対策として `_work` を tmpfs (`/dev/shm`) に置き、書き込みを RAM に逃がす。

```bash
make stop-all
make tmpfs-on        # 全 runner の _work を /dev/shm へ
make start-all
make tmpfs-status    # 現在どちらを使っているか
```

戻すときは `make tmpfs-off`。どちらも `_work` の中身は破棄されるため、実行中のジョブが
無い状態で行うこと (スクリプト側でも Worker が居たら中断する)。

設計上の要点:

- **`_tool` だけは SSD に残す** — `_work/_tool` は `actions-runner-N/tool-cache` への
  symlink にして永続化する。ここが揮発すると `setup-go` / `setup-bun` が毎回ツールを
  再取得し、ネットワークと tmpfs 容量の両方を無駄に消費する。
- **`/dev/shm` は再起動でクリアされる** — unit に `ExecStartPre` を差し込み、起動のたびに
  `prepare-work-tmpfs.sh` が作業ディレクトリと `_tool` symlink を作り直す。
- **swap が無いことが安全弁になる** — tmpfs は `/dev/shm` のサイズ (32GB) が上限なので、
  溢れてもジョブが ENOSPC で落ちるだけで OOM には至らない。ただし全 runner で共有する
  容量なので、台数を増やすときは 1 台あたりの `_work` 実サイズと突き合わせること。
- **sudo 不要** — 新規に tmpfs をマウントするのではなく、既存の `/dev/shm` を間借りする。
- **`/dev/shm` は他用途と共有** — 間借りである以上、runner 以外のプロセスが大きなデータを
  置くと runner 側が枯渇する。実例として Go の module cache 19GB が `/dev/shm` に複製され、
  32GB のうち runner が使えるのが 7GB 弱になったことがある。台数を増やす前とジョブが
  ENOSPC で落ちたときは `make tmpfs-status` で使用量を確認すること。
  `/dev/shm` 自体を広げるには `sudo mount -o remount,size=48G /dev/shm` (要パスワード)。

### 実測値 (2026-08-20)

| 対象 | 書き込み速度 |
| --- | --- |
| SSD (`/dev/sdc3`) direct | 26 MB/s |
| SSD buffered + fsync | 11 MB/s |
| tmpfs (`/dev/shm`) | 2.4 GB/s |

SSD は Kingmax の SATA 品で、23 時間で 430GB 書き込んだ後の値。正常な SATA SSD なら
300〜500 MB/s 出るところなので、SLC キャッシュを使い切って低速モードに落ちていると
見られる。tmpfs 化前は load average 522 / Dirty 8.4GB / Worker 5 本が 40 分以上ハング
という状態だったが、tmpfs 化後は load 1〜12 / Dirty 0〜400MB で安定した。

## 台数の決め方

現在は **1 台 (ousiass-desktop-2) のみ稼働**。残りは登録とディレクトリを残したまま
`disable` してある (`systemctl --user enable --now <unit>` で復帰する)。

1 台に絞ると次の 3 つが同時に解決する。

- **ポート競合** — service コンテナがホストポートを固定 (`5432:5432` など) していても、
  2 本目のジョブが走らないので衝突しない。ホストポートはマシン全体で 1 つしかないため、
  並列させるなら workflow 側でホスト側を省略して動的割当にする必要がある。
- **tmpfs の枯渇** — 32GB を 1 台が独占できる。
- **I/O の競合** — SSD が遅いこのマシンでは効果が大きい。

代償は CI 時間。ai-liver の Check (8 ジョブ) の実測は以下のとおり。

| | 時間 |
| --- | --- |
| 並列 (最長ジョブ) | 12 分 |
| 直列 (合計) | 44 分 |

重い 4 ジョブ (backend Postgres 12 分 / swagger 12 分 / backend vet+build 8 分 /
auth-boundary 8 分) で 40 分を占め、残り 4 ジョブは合計 1 分。他リポジトリの CI も
同じキューに並ぶ点に注意する。

台数を増やすときは、先に workflow の固定ポートを動的割当へ直すこと。

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
