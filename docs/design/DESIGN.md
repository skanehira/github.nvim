<!-- product-mode: cli -->
# github.nvim 横断設計書

- 種別: 設計書
- 対象: denops-gh.vimのIssue操作のNeovim Lua移植

## 目的とスコープ

Issue・コメントの閲覧、作成、更新、状態変更、担当者・ラベル編集、URL操作、関連PRのURL確認を提供する。公開URIは`github://`とする。入力補完は今回対象外。将来github-actions.nvimとreview.nvimを統合できるよう、機能ごとの設定・状態・依存・画面を分離する。詳細な操作と受け入れ基準はUSECASES.md、機能別契約はfeatures/を正本とする。

## アーキテクチャと技術選定

Neovim Luaを使用し、最低版は実測した0.10.4とする。GitHub APIは認証をghへ委譲し、`gh api`を引数配列・JSON stdinで呼ぶ。Issue作成は`gh issue create -F <本文ファイル> -R github.com/<owner>/<repo>`の対話端末を使う。`github://`はBufReadCmd/BufWriteCmdで処理する。HTTPS入口は対象のGitHub Issue URLだけをBufAddで正規化し、標準netrwや他HTTPSハンドラを置換しない。

依存方向は、機能UI → 各機能の操作 → 共通のGitHub/Git・Neovimアダプタとする。共通部はプロセス実行、gh呼出、URI解析、対象リポジトリの識別、画面・要求の所有管理を担当する。Issueの本文とレビューの下書きは別モデルにする。Actionsとレビューの実装や既存データ移行は将来の統合時に設計する。

根拠: `gh-api-contracts`で実ghのREST/GraphQL・ページングと入力契約を確認、`nvim-runtime`で0.10.4のURI・非同期処理とnetrw共存を確認、`create-terminal`で0.10.4の対話端末・追記保護・二重起動抑止を確認した。実GitHub書込みはPoCで実行していない。詳細と再現コマンドはFEASIBILITY.mdを参照する。

## 開発・検証コマンド

前提はNeovim 0.10.4以上、git、gh、make、stylua、luacheck。テストランナーはplenary.nvimのコミット`74b06c6c75e4eeb3108ec01852001636d85a932b`で、プラグインのruntime依存には含めない。チェックアウトまたはworktreeごとにネットワーク接続のある環境で`make setup`を実行し、`.deps/plenary.nvim`に取得する。`.worktreeinclude`に複製対象はなく、`.deps/`は各worktreeで個別に用意する。

| コマンド | 用途 |
| --- | --- |
| `make setup` | テスト依存を取得し指定コミットへ切り替える。 |
| `make test` | `lua/`配下の`*_spec.lua`を全てheadless Neovimで実行する。 |
| `make test-file FILE=lua/github/test_environment_spec.lua` | 指定したテストファイルだけを実行する。 |
| `make lint` | Luaファイルのluacheckを実行する。 |
| `make check` | StyLuaによるフォーマット検査を実行する。 |

実装とテストは機能ごとに同じディレクトリへ置く。テストの各実行は一意の一時ディレクトリを作り、Neovimのconfig/data/state/cacheを分離して終了時に削除する。ローカルfake gh・fakeブラウザ・fakeクリップボードは各テストで生成し、テストはGitHub書込みや実クリップボードを使わない。固定ポートは使わず、必要な場合はOS割当ポートを使う。`.claude/worktrees/`はgitの追跡対象外とする。

上記セットアップと5コマンドは、独立したディレクトリで実行して確認済み。テストはNeovim 0.10.4と0.13 nightlyで実行済み。実際のNeovimバッファへのUTF-8書込み、標準ディレクトリの分離、意図的な失敗が全件・単一ファイル双方で非0になることを確認した。

## GitHub API一覧

| 操作 | gh経由のAPI | 担当 |
| --- | --- | --- |
| Issue検索、Issue詳細、担当者・ラベル全件、テンプレート、関連PR | GraphQL `gh api graphql` | issue-list、issue-edit、issue-attributes、issue-create、related-pr |
| Issueタイトル・本文・状態・担当者・ラベルの更新 | GraphQL `updateIssue` | issue-edit、issue-state、issue-attributes |
| コメント一覧・単体取得・投稿・更新 | REST `repos/{owner}/{repo}/issues/{number}/comments`、`repos/{owner}/{repo}/issues/comments/{id}` | comment-list、comment-create、comment-edit |
| 対話式のIssue作成 | `gh issue create` | issue-create |

GraphQLはJSON `{query, variables}`を`--input -`で渡し、RESTもメソッド・endpoint・stdinを明示する。結果は終了コード、stdout、stderr、GraphQL errorsを確認する。ラベル・担当者はpageInfoを終端までたどり、集合を完全取得できない場合は置換を許さない。コメント単体の`issue_url`を指定Issueと照合する。検索で返ったIssueのリポジトリを照合し、入力された条件で別リポジトリへ対象が広がらないようにする。

## CLI・公開インターフェース

| 入口 | 操作 |
| --- | --- |
| `github://owner/repo/issues` | Issue一覧。対応するGitHub HTTPS URLも受ける。 |
| `github://owner/repo/issues/new` | Issue作成。 |
| `github://owner/repo/issues/<number>` | Issue本文編集。 |
| `github://owner/repo/issues/<number>/assignees`、`/labels` | 担当者・ラベル編集。 |
| `github://owner/repo/issues/<number>/comments`、`/comments/new`、`/comments/<comment-id>` | コメント一覧・投稿・編集。comment-idは数値database ID。 |
| `:GhGetAssociatedPullRequest <commit>` または `:GhGetAssociatedPullRequest <owner> <repo> <commit>` | 関連PR先頭1件のURLを表示する。 |
| `require('github').setup(opts)` | 初期版は`nil`または空テーブルを受け付ける。設定キーの追加は将来の機能統合時に行う。詳細はsetup設計を参照。 |

一覧の既定キーマップは`ghs`検索、`K`プレビュー、`ghn`作成、`ghe`本文編集、`ght`タイトル編集、`ghc`/`gho`状態変更、`gha`/`ghl`担当者・ラベル、`ghm`コメント、`<C-j>`/`<C-k>`選択、`<C-o>`ブラウザ、`ghy`コピー。各バッファの操作は機能設計を参照する。

## 横断規約

- 初期版はgithub.comを対象とし、github:// URIとowner/repo明示指定のhostはgithub.comとする。originがgithub.com以外の場合は対象外として案内する。GitHub上の対象はhost・owner・repoで識別し、ローカルrepo・worktree・操作開始時cwdとは分ける。API応答やキャッシュは機能・対象・画面ごとに区別する。
- git/gh実行器、ブラウザ、クリップボードと時刻などの外界は注入可能にする。シェルへ入力を連結しない。認証ファイルを直接読まず、秘密をログに出さない。
- 一覧の`<C-j>`/`<C-k>`はカーソル行の選択印をトグルし、次/前の行へ移動する。一覧の再取得を開始した時点で選択を解除し、取得が失敗しても戻さない。
- 同一編集バッファで保存処理中の追加保存は抑止して処理中と案内し、送信後の追記は未保存として保持する。
- 非同期結果はバッファIDと要求世代に紐付け、閉じた画面や古い要求から他画面を更新しない。保存は送信時点の内容とchangedtickを保持し、後からの追記を未保存として残す。
- 失敗時は利用者に対象と理由を案内し、入力を保持する。書込みの結果が不明な場合は自動再送しない。複数Issueの更新は対象単位の結果を報告する。
- 同じ項目の同時編集はGitHubが最後に受け付けた保存を正とする。各更新は対象項目だけを送り、別項目を巻き戻さない。
- ActionsのYAML依存・レビューのworktree/永続状態はIssue機能に要求しない。ghや認証はGitHub操作の時点で確認する。

## 既知の制約

- ghはIssueを作成済みでも添付失敗で非0終了しうる。非0だけで未作成と断定せずURLと状態を案内する。
- GitHub検索結果は最大30件、コメント一覧は最大100件。画面のページ送りは初期版対象外。属性編集に必要な内部ページングは実施する。
- HTTPSのBufAdd正規化はnetrwと既存の未保存バッファで実測済み。他pluginのBufAdd順序、複数窓、全URI形式はPoC未検証であり、実装時の統合テストで確かめる。対象外URLと他pluginの入力を破壊しない。
- Neovim 0.10.0〜0.10.3は未検証。最低版を0.10.4とする。
- plenaryのテスト子Neovimは`-u NONE`を継承しないため、実行環境から`VIMINIT`と`EXINIT`を除いて利用者の初期化を避ける。

## 未解決の論点

将来のActions・レビュー統合時の公開API互換、既存レビューの保存先・worktree移行、キーと画面の互換方針は、その統合時に決める。

## 用語・成果物一覧

| 名称 | 定義・生成者 | 利用者 |
| --- | --- | --- |
| USER_STORIES.md | フェーズ1のストーリー正本 | USECASES.md、設計レビュー |
| USECASES.md | フェーズ3のフロー・受け入れ基準正本 | 機能設計、issue、実装 |
| FEASIBILITY.md | フェーズ4・5のPoC計画と結果 | 横断・機能設計 |
| 対象リポジトリ | host・owner・repoと必要なローカルpathを分離した操作文脈 | URI、gh、各画面 |

## 依拠する外部事実

2026-10-28に移植元の固定コミット`989f2d1ebf7d414ad8aa4d415a326caca836d30a`、github-actions.nvim `6c8089c3950eec64f2da06a070e792c9ab4a4948`、review.nvim `3e78a1eab4189e5b5bef9c826dd06fdd8c203c18`、lazy.nvim `306a05526ada86a7b30af95c5cc81ffba93fef97`を調査した。公式資料と実行結果はFEASIBILITY.mdに記載する。
