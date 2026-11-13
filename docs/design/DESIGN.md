<!-- product-mode: cli -->
<!-- 変更履歴 [2026-11-12]: Projects v2の閲覧・編集とfloat UIを追加 -->
<!-- 変更履歴 [2026-11-13]: PR一覧の閲覧・検索の設計を実装に合わせて追加 -->
# github.nvim 横断設計書

- 種別: 設計書
- 対象: denops-gh.vimのIssue操作のNeovim Lua移植とProjects v2の閲覧・編集、PR一覧の閲覧

## 目的とスコープ

Issue・コメントの閲覧、作成、更新、状態変更、担当者・ラベル編集、URL操作、関連PRのURL確認と、PR一覧の閲覧・検索を提供する。加えて、GitHub Projects v2のProject一覧・ボード閲覧、項目のフィールド編集、項目の追加・削除を提供する。公開URIは`github://`とする。Projectsはfloatウィンドウの画面とし、`github://` URIを持たない。入力補完は今回対象外。将来github-actions.nvimとreview.nvimを統合できるよう、機能ごとの設定・状態・依存・画面を分離する。詳細な操作と受け入れ基準はUSECASES.md、機能別契約はfeatures/を正本とする。

## アーキテクチャと技術選定

Neovim Luaを使用し、最低版は実測した0.10.4とする。GitHub APIは認証をghへ委譲し、`gh api`を引数配列・JSON stdinで呼ぶ。Issue作成は`gh issue create -F <本文ファイル> -R github.com/<owner>/<repo>`の対話端末を使う。Projectsは`gh api graphql`で読み書きし、一覧・ボード・編集・確認・プレビュー・ヘルプの画面は`nvim_open_win`のfloatウィンドウで表示する。`github://`はBufReadCmd/BufWriteCmdで処理する。HTTPS入口は対応するGitHub Issue URLとPR一覧URLだけをBufAddで正規化し、標準netrwや他HTTPSハンドラを置換しない。

依存方向は、機能UI → 各機能の操作 → 共通のGitHub/Git・Neovimアダプタとする。共通部はプロセス実行、gh呼出、URI解析、対象リポジトリの識別、画面・要求の所有管理を担当する。Projectsの画面は共通のfloat UI（`core/float.lua`）を使い、ProjectsのAPI層はowner解決、ページング、フィルタ、mutationを担当する。Issueの本文とレビューの下書きは別モデルにする。Actionsとレビューの実装や既存データ移行は将来の統合時に設計する。

根拠: `gh-api-contracts`で実ghのREST/GraphQL・ページングと入力契約を確認、`nvim-runtime`で0.10.4のURI・非同期処理とnetrw共存を確認、`create-terminal`で0.10.4の対話端末・追記保護・二重起動抑止を確認した。`projects-api`でProjects v2の読取・書込・ページング・フィルタ・冪等性・反映遅延を確認し、`float-board`で0.10.4のfloat描画・スクロール・入力系画面を確認した。Issueの実GitHub書込みはPoCで実行していない。Projectsの書込みは破棄前提のスクラッチProjectでのみ実行した。詳細と再現コマンドはFEASIBILITY.mdを参照する。

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

0.10.4はNeovimの公式リリースバイナリを取得し、PATHの先頭に置いて`nvim --version`で確認する。0.13 nightlyと併用する場合は、テスト実行ごとにPATHを切り替える。

上記セットアップと5コマンドは0.10.4で確認済み。0.13 nightlyでは`make test`と`make test-file`が`lua/github/features/issues/create_spec.lua:126`の`vim.bo[term].channel`で失敗する既知の問題がある。実際のNeovimバッファへのUTF-8書込み、標準ディレクトリの分離、意図的な失敗が全件・単一ファイル双方で非0になることを確認した。

## GitHub API一覧

| 操作 | gh経由のAPI | 担当 |
| --- | --- | --- |
| Issue/PR検索、Issue詳細、担当者・ラベル全件、テンプレート、関連PR | GraphQL `gh api graphql` | issue-list、issue-edit、issue-attributes、issue-create、related-pr、pulls |
| PR一覧の検索（本文含む） | GraphQL `search(type:ISSUE, query:"repo:... type:pr ...")` | pulls |
| Issueタイトル・本文・状態・担当者・ラベルの更新 | GraphQL `updateIssue` | issue-edit、issue-state、issue-attributes |
| コメント一覧・単体取得・投稿・更新 | REST `repos/{owner}/{repo}/issues/{number}/comments`、`repos/{owner}/{repo}/issues/comments/{id}` | comment-list、comment-create、comment-edit |
| 対話式のIssue作成 | `gh issue create` | issue-create |
| Project一覧・owner解決 | REST `user`、`users/{login}`、GraphQL `user`/`organization.projectsV2` | projects-list、projects-api |
| Projectのフィールド・ビュー・項目 | GraphQL `projectV2`、`items`、`fields`、`views` | projects-board、projects-api |
| ボードの本文プレビュー | GraphQL `repository.issueOrPullRequest`（`body`） | projects-board |
| 項目のフィールド更新・解除 | GraphQL `updateProjectV2ItemFieldValue`、`clearProjectV2ItemFieldValue` | projects-field-edit、projects-api |
| 既存Issue/PRのnode ID解決 | GraphQL `repository.issueOrPullRequest` | projects-item-manage、projects-api |
| 項目の追加（既存Issue/PR・下書き） | GraphQL `addProjectV2ItemById`、`addProjectV2DraftIssue` | projects-item-manage、projects-api |
| 項目の削除 | GraphQL `deleteProjectV2Item` | projects-item-manage、projects-api |

GraphQLはJSON `{query, variables}`を`--input -`で渡し、RESTもメソッド・endpoint・stdinを明示する。結果は終了コード、stdout、stderr、GraphQL errorsを確認する。ラベル・担当者はpageInfoを終端までたどり、集合を完全取得できない場合は置換を許さない。コメント単体の`issue_url`を指定Issueと照合する。検索で返ったIssueのリポジトリを照合し、入力された条件で別リポジトリへ対象が広がらないようにする。

ProjectsはownerをREST `user`/`users/{login}`でユーザーとOrgに分けて解決し、GraphQLの`projectsV2`/`projectV2`で取得する。項目は`items`を100件/pageで`pageInfo`を辿り、`query`フィルタ、`orderBy:{field:POSITION,direction:ASC}`、`archivedStates:[NOT_ARCHIVED]`を指定する。`max_items`で打ち切った場合は画面に示す。フィールド値は`ProjectV2FieldValue`の型（text/number/date/singleSelectOptionId）に合わせ、解除は`clearProjectV2ItemFieldValue`を使う。`addProjectV2ItemById`は冪等であり、一時的な競合エラーは再実行できる。書き込み後は応答でローカル状態を更新し、自動再送しない。

PR一覧はIssue一覧の検索・バッファ・描画・キーマップ・非同期要求の基盤を`pull`モードで再利用し、GraphQL `search`の`type:pr`で最大30件を取得する。表示はIssue一覧と同じ列（番号・タイトル・状態・担当者・ラベル・コメント数）とし、MERGEDはCLOSEDと区別する。本文プレビューは検索で取得済みの`body`を使い、追加のクエリを発行しない。PRの作成・編集・レビュー・マージ・コメント投稿は対象外。

## CLI・公開インターフェース

| 入口 | 操作 |
| --- | --- |
| `:GitHub issues [owner/repo]`、`:GitHub pulls [owner/repo]` | Issue/PR一覧を開く。省略時は実行時cwdのGit originを使う。引数指定時はローカルcheckout不要。 |
| `github://issues`、`github://pulls`、`github://issues/new`、`github://issues/<number>...` | 下の`github://owner/repo/...`の各形式からowner/repoを省いた形式。開いた時点のcwdのGit originからリポジトリを解決し、同じ形式の`github://owner/repo/...`へ置き換える。各機能は置換後の形式だけを扱う。置換までは読取り専用。解決できなければエラーを表示し、空の読取り専用バッファを残す。`:edit`で再試行できる。対応HTTPS URLは持たない。 |
| `github://owner/repo/pulls` | PR一覧。対応HTTPS URLも受ける。最大30件、検索・プレビュー・選択・URLコピー・ブラウザに対応する。PRの作成・編集・レビュー・マージは対象外。 |
| `github://owner/repo/issues` | Issue一覧。対応するGitHub HTTPS URLも受ける。 |
| `github://owner/repo/issues/new` | Issue作成。 |
| `github://owner/repo/issues/<number>` | Issue本文編集。 |
| `github://owner/repo/issues/<number>/assignees`、`/labels` | 担当者・ラベル編集。 |
| `github://owner/repo/issues/<number>/comments`、`/comments/new`、`/comments/<comment-id>` | コメント一覧・投稿・編集。comment-idは数値database ID。 |
| `:GitHub related-pr [owner/repo] <commit>` | 関連PR先頭1件のURLを表示する。省略時はGit originを使う。既存`:GhGetAssociatedPullRequest <commit>` / `<owner> <repo> <commit>`も互換用に残す。 |
| `:GitHub projects [owner]` | Project一覧をfloatウィンドウで開く。owner省略時は認証済みユーザー、指定時はユーザーまたはOrg。`@me`は認証済みユーザーとして扱う。 |
| `:GitHub projects [owner] <number>` | 指定Projectのボードをfloatウィンドウで開く。owner省略時は認証済みユーザー。第1引数が数字のみなら番号として扱い、ownerは認証済みユーザーとする。 |
| `require('github').setup(opts)` | `nil`または空テーブル、および`projects`設定（`group_by`、`column_width`、`max_items`）を受け付ける。他のキーは拒否する。詳細はsetup設計を参照。 |

一覧の既定キーマップは`ghs`検索、`K`プレビュー、`ghn`作成、`ghe`本文編集、`ght`タイトル編集、`ghc`/`gho`状態変更、`gha`/`ghl`担当者・ラベル、`ghm`コメント、`<C-j>`/`<C-k>`選択、`<C-o>`ブラウザ、`ghy`コピー。各バッファの操作は機能設計を参照する。

PR一覧のキーマップは`j`/`k`/`gg`/`G`/`<C-j>`/`<C-k>`/`K`/`<C-o>`/`ghy`/`ghs`。`:edit!`で最後に成功した検索条件を再取得する。PRの作成・編集・レビュー・マージ・コメント投稿は対象外。

Projectsのキーマップは、一覧が`j`/`k`/`<CR>`/`r`/`q`/`<Esc>`、ボードが`h`/`l`/`j`/`k`/`H`/`L`/`g`/`G`/`K`/`<CR>`/`<C-o>`/`ghy`/`ghs`/`ghe`/`ghn`/`ghd`/`r`/`?`/`q`/`<Esc>`。フィールド編集は`j`/`k`/`<CR>`/`q`/`<Esc>`、単一選択の選択肢は`j`/`k`/`<CR>`/`q`/`<Esc>`、テキスト・数値・日付の入力は`<CR>`/`<C-c>`と通常モードの`q`、確認は`y`/`n`/`q`/`<Esc>`。追加の選択は`j`/`k`/`<CR>`/`q`/`<Esc>`、既存項目の指定は`<CR>`/`<C-c>`と通常モードの`q`、下書きのタイトルは`<CR>`で本文へ、`<C-c>`と通常モードの`q`で中止する。本文は`<C-s>`で追加、`q`/`<Esc>`で中止する。プレビューは`j`/`k`/`gg`/`G`/`<C-d>`/`<C-u>`/`q`/`<Esc>`、ヘルプは`j`/`k`/`gg`/`G`/`q`/`<Esc>`。Projectsはfloat画面のため、`github://` URIとHTTPS入口を持たない。

## 横断規約

- 一覧は移植元のコンパクトな列表示を使う。窓の再利用・検索バッファ・開き方・公開PlugとUserイベントはMIGRATION_PARITY.mdとdoc/github.txtに対応を記載する。
- 仮想バッファはnolist・nonumber・nowrap・cursorline・bufhidden=hideを基本とし、プラグインが開く窓では、通常バッファへ戻ると元の窓設定を復元する。利用者・他プラグインによる標準分割はNeovimの設定継承に従い、新規窓全体をフックして変更しない。進行中の取得・保存は対象バッファへ表示する。
- 本文のCRLFはLFへ正規化する。変更のない既存編集バッファの保存は更新を送らない。

- 初期版はgithub.comを対象とし、github:// URIとowner/repo明示指定のhostはgithub.comとする。originがgithub.com以外の場合は対象外として案内する。GitHub上の対象はhost・owner・repoで識別し、ローカルrepo・worktree・操作開始時cwdとは分ける。API応答やキャッシュは機能・対象・画面ごとに区別する。
- git/gh実行器、ブラウザ、クリップボードと時刻などの外界は注入可能にする。シェルへ入力を連結しない。認証ファイルを直接読まず、秘密をログに出さない。
- Issue/PR一覧の`<C-j>`/`<C-k>`はカーソル行の選択印をトグルし、次/前の行へ移動する。Issue/PR一覧の再取得を開始した時点で選択を解除し、取得が失敗しても戻さない。Projects一覧はProject番号で選択を維持する。
- 同一編集バッファで保存処理中の追加保存は抑止して処理中と案内し、送信後の追記は未保存として保持する。
- 非同期結果はバッファIDと要求世代に紐付け、閉じた画面や古い要求から他画面を更新しない。保存は送信時点の内容とchangedtickを保持し、後からの追記を未保存として残す。
- 失敗時は利用者に対象と理由を案内し、入力を保持する。書込みの結果が不明な場合は自動再送しない。複数Issueの更新は対象単位の結果を報告する。
- 同じ項目の同時編集はGitHubが最後に受け付けた保存を正とする。各更新は対象項目だけを送り、別項目を巻き戻さない。
- ActionsのYAML依存・レビューのworktree/永続状態はIssue機能に要求しない。ghや認証はGitHub操作の時点で確認する。
- Projectsはfloatウィンドウの画面とし、`github://` URIとHTTPS入口を持たない。`:GitHub projects [owner]`と`:GitHub projects [owner] <number>`を入口にする。
- floatは`core/float.lua`で開き、タブページごとのスタックで管理する。各floatは親ウィンドウを保持し、閉じたときは親→スタックの前の画面→元のウィンドウの順にフォーカスを戻す。同じ名前の画面は再利用して再取得する。バッファは`buftype=nofile`、`bufhidden=wipe`、`swapfile=false`とし、読み取り専用画面は`modifiable=false`にする。`VimResized`で画面比率と中央配置を再計算して再描画する。
- ボードは列幅を固定し、表示できる列だけを描画する。`h`/`l`で選択列を移動し、画面外へ出るときは表示列をスクロールする。列ごとに縦の表示位置を持ち、`j`/`k`では選択列だけをスクロールする。選択項目の先頭行にカーソルを置き、列ヘッダと項目をextmarkで強調する。
- Projectsの列は`group_by`（既定Status）と名前が一致する単一選択フィールドの選択肢順とし、値のない項目は末尾の値なし列に置く。`group_by`が見つからなければ最初の単一選択フィールドを使い、単一選択フィールドがなければ1列（`nil`）にする。項目は100件/pageで取得し、`query`フィルタ、`orderBy POSITION`、`archivedStates NOT_ARCHIVED`を指定する。`max_items`で打ち切った場合は画面に示す。フィルタの0件は成功結果として扱い、取得エラーと区別する。
- ProjectsのフィルタはGitHubのProjectフィルタ文字列をそのまま使う。初期条件は`number`が最小のビューのフィルタとし、`ghs`で変更できる。空のフィルタは全件、変更なしは再取得しない。
- Projectsの編集対象は単一選択・テキスト・数値・日付のカスタムフィールドに限定する。組み込みフィールド（Title・Assignees・Labelsなど）は`dataType`で除外し、既存のIssue操作に委ねる。値の解除は`clearProjectV2ItemFieldValue`を使う。書込み後はmutationの応答でローカル状態を更新し、ボードを再描画する。自動の再取得・再送はしない。`group_field`の単一選択の変更では項目を新しい列へ移し、それ以外の単一選択は値を更新して同じ列に留まる。選択は項目IDで維持する。
- Projectsの追加は`addProjectV2ItemById`（冪等）と`addProjectV2DraftIssue`、削除は`deleteProjectV2Item`を使う。削除はProjectから項目を外すだけでIssue/PR自体を削除しない。一時的な競合エラーは理由を表示し、利用者の再操作を受け付ける。子画面は親のボード/一覧が閉じたら閉じる。入力中の内容は失敗時に保持する。
- Projectsの取得・書込みは画面IDと要求世代に紐付け、閉じた画面や古い要求で他の画面を更新しない。ボードを閉じた後に応答が届いても再作成しない。

## 既知の制約

- Neovimのクリップボードproviderは書込み失敗を同期的に返さない場合がある。`+`への書込みを要求した後、完了が確認できない場合は件数と結果未確認を案内する。検知できた失敗は成功と案内しない。

- ghはIssueを作成済みでも添付失敗で非0終了しうる。非0だけで未作成と断定せずURLと状態を案内する。
- Issue/PRのGitHub検索結果は最大30件、コメント一覧は最大100件。画面のページ送りは初期版対象外。属性編集に必要な内部ページングは実施する。
- HTTPSのBufAdd正規化はnetrwと既存の未保存バッファで実測済み。他pluginのBufAdd順序、複数窓、全URI形式はPoC未検証であり、実装時の統合テストで確かめる。対象外URLと他pluginの入力を破壊しない。
- Neovim 0.13 nightlyでは`create_spec.lua`の端末チャネル検証が失敗する。0.10.4では成功する。端末起動テストは0.10.4を基準にし、0.13 nightlyの修正は別途扱う。
- Neovim 0.10.0〜0.10.3は未検証。最低版を0.10.4とする。
- 実測したNeovim 0.13 nightlyの同梱netrwにはHTTPSハンドラがない。github.nvimは対象外のURLを処理せず、既存のハンドラがある場合は維持する。
- plenaryのテスト子Neovimは`-u NONE`を継承しないため、`VIMINIT`と`EXINIT`を除き、`XDG_CONFIG_DIRS`と`XDG_DATA_DIRS`を一時ディレクトリに指定して利用者の設定・ランタイム探索を分離する。
- Projects APIは更新直後の読み取りが一時的に古い値を返すことがある（実測で約0〜3秒）。書込み後はmutationの応答でローカル状態を更新し、自動の再取得はしない。`r`による再取得を正とする。
- Projectのフィルタはサーバ側で評価され、無効な条件でもエラーではなく0件を返すことがある。0件は成功結果として表示し、取得エラーと区別する。フィルタの構文検証は行わない。
- 項目は100件/page、最大`max_items`件（既定1000）、Project一覧は最大100件。Project一覧は開いているProjectが100件になるまで`pageInfo`を辿り（最大10ページ）、続きがあれば打ち切ったことを表示する。画面のページ送りと全件取得の保証はしない。上限で打ち切った場合はその旨を表示する。
- ビューは`number`が最小のビューのフィルタだけを初期条件に使い、切替・保存はしない。`groupByFields`は空だったため使わない。列は`group_by`で指定した単一選択フィールドから作る。項目の並び順変更・アーカイブ・Project/フィールド自体の作成/編集/削除は対象外。
- Projectのフィールドは最大50件、ビューは最大10件を取得する。超えるProjectでは先頭のみを使い、後続のフィールドは編集対象に表示しない。
- 編集対象は単一選択・テキスト・数値・日付のカスタムフィールドに限定する。複数選択・イテレーション、下書きIssueの追加後のタイトル・本文編集は対象外。組み込みフィールドは`dataType`（TITLE・ASSIGNEES・LABELSなど）で除外する。`isIssueField`は全フィールドでfalseだったため判定に使わない。
- floatは0.10.4と0.13で描画・スクロール・リサイズ・クローズを実測済み。0.10.4の`nvim_win_get_config`は`style`を返さないが表示は成立する。ヘッドレスでは挿入モードの実操作を検証できないため、実装時の統合テストで確認する。マウス操作は対象外。
- Projectsの参照・変更にはghの認証に`project`スコープが必要になる場合がある。権限不足・未認証は理由を表示する。閉じたProjectは一覧に表示せず、内容を取得できない項目はredactedと表示する。
- PR一覧は閲覧・検索・本文プレビュー・ブラウザ・URLコピーに限定し、PRの作成・編集・レビュー・マージ・コメント投稿は対象外。`<Plug>(gh:pull:search)`、`<Plug>(gh:pull:preview)`、`<Plug>(gh:pull:select:next)`、`<Plug>(gh:pull:select:prev)`、`<Plug>(gh:pull:yank)`、`<Plug>(gh:pull:view)`を公開する。
- Projectsの書込みPoCは破棄前提のスクラッチProjectでのみ実行し、検証後に削除した。利用者の既存Projectのデータは変更していない。

## 未解決の論点

将来のActions・レビュー統合時の公開API互換、既存レビューの保存先・worktree移行、キーと画面の互換方針は、その統合時に決める。

Projectsのビュー切替、項目の並び順変更、アーカイブ、複数選択・イテレーションの編集、下書きIssueの追加後のタイトル・本文編集は初期版の対象外とし、必要になった時点で設計する。Projectsのキーマップは初期版では固定キーマップとし、`<Plug>`マッピングを公開しない。将来の要望に応じて検討する。

## 用語・成果物一覧

| 名称 | 定義・生成者 | 利用者 |
| --- | --- | --- |
| USER_STORIES.md | フェーズ1のストーリー正本 | USECASES.md、設計レビュー |
| USECASES.md | フェーズ3のフロー・受け入れ基準正本 | 機能設計、issue、実装 |
| FEASIBILITY.md | フェーズ4・5のPoC計画と結果 | 横断・機能設計 |
| 対象リポジトリ | host・owner・repoと必要なローカルpathを分離した操作文脈 | URI、gh、各画面 |
| Project | GitHub Projects v2のProject。owner（ユーザーまたはOrg）と番号で識別する。 | projects-list、projects-board、projects-api |
| ボード | 単一選択フィールドの選択肢で列を作るカンバン画面。 | projects-board |
| floatウィンドウ | `nvim_open_win`で開く浮動ウィンドウ。画面スタックで管理する。 | Projectsの全画面 |
| フィールド | Projectのカスタムフィールド。単一選択・テキスト・数値・日付を編集対象とする。 | projects-field-edit |
| 項目 | Projectに追加されたIssue・PR・下書きIssue。 | projects-board、projects-item-manage |

## 依拠する外部事実

2026-10-28に移植元の固定コミット`989f2d1ebf7d414ad8aa4d415a326caca836d30a`、github-actions.nvim `6c8089c3950eec64f2da06a070e792c9ab4a4948`、review.nvim `3e78a1eab4189e5b5bef9c826dd06fdd8c203c18`、lazy.nvim `306a05526ada86a7b30af95c5cc81ffba93fef97`を調査した。2026-11-12にgoogle-calendar.nvimのコミット`53645a6ce448e0da9d7ca0d6a4ce412ac52cea9a`をfloat画面の参考として調査し、GitHub Projects v2の[Projectsのフィールド](https://docs.github.com/en/issues/planning-and-tracking-with-projects/understanding-fields)、[Projectsのフィルタ](https://docs.github.com/en/issues/planning-and-tracking-with-projects/customizing-views-in-your-project/filtering-projects)、[ProjectV2](https://docs.github.com/en/graphql/reference/objects#projectv2)、[gh project](https://cli.github.com/manual/gh_project)を参照した。Projectsの読取・書込とfloat描画はFEASIBILITY.mdの`projects-api`と`float-board`で実測した。公式資料と実行結果はFEASIBILITY.mdに記載する。
