# Project一覧とボードを開く

- 種別: 機能設計書
- 対象 UC: UC-014 (docs/design/USECASES.md)
- 対象ストーリー: US-020

## 何を作るか

UC-014の利用者操作を実現する。対象規則はBR-054〜BR-062。一覧とボードのfloat UIはprojects-ui、APIはprojects-api、ボードの閲覧はprojects-boardに従う。

## 入出力と振る舞い

### コマンド

- `:GitHub projects`は認証済みユーザーのProject一覧をfloatで開く。
- `:GitHub projects <owner>`は指定したユーザーまたはOrgのProject一覧をfloatで開く。`@me`は認証済みユーザーとして扱う。
- `:GitHub projects <owner> <number>`は一覧を経由せずに指定Projectのボードをfloatで開く。閉じたProjectを指定した場合はボードを開かず、Projectが閉じている旨を通知する。
- `:GitHub projects <number>`は認証済みユーザーの指定番号のボードを開く。第1引数が全て数字なら番号として扱う。閉じたProjectの場合はボードを開かず、閉じている旨を通知する。
- `:GitHub projects @me <number>`も認証済みユーザーのボードを開く。
- 引数が多すぎる場合、ownerが空・空白・`/`を含む場合、ownerが英数字とハイフン以外の場合、番号が正の整数でない場合は`Usage: GitHub projects [owner] [number]`を表示し、画面を開かない。`@me`はこの検証の対象外とする。
- Projectsはowner単位の対象であり、Gitリポジトリのoriginを必要としない。cwdがGit checkout外でも動作する。
- コマンドは`require("github.features.projects.list").open({owner, number, parent_win})`へ渡す。一覧・ボードの再利用と要求世代は各画面が管理し、コマンド側のbuffer世代ガードは使わない。

### 一覧の状態

- 一覧は`{owner, type, projects, selected, loading, error, generation, truncated}`を保持する。
- 開くときはownerをRESTで解決し、種別を確定してからProject一覧を取得する。owner省略時はREST `user`、指定時は`users/{login}`を使う。
- 読み込み中は一覧のヘッダに`Loading projects...`を表示する。owner解決に失敗した場合はfloatを開かず、理由を通知する。
- 取得結果は`closed`が偽のProjectだけを最大100件表示する。各Projectは`#<number> <title>  <items> items  <public|private>`の形式で表示し、タイトルは表示幅で切り詰める。開いているProjectが100件に達し、まだ続きがある場合は`Showing 100 projects`を表示する。
- 0件は`No open projects`を表示する。空の一覧でもfloatを開き、`r`で再取得できる。
- 初期選択は先頭のProjectとする。`j`/`k`で選択を移動し、端では移動しない。カーソルは選択行に置く。
- `r`は同じownerで再取得する。取得開始時に選択を解除せず、成功時はProject番号で選択を維持する。存在しなければ同じ位置へclampし、0件なら選択を外す。失敗時は直前の成功内容を保持し、ヘッダに理由を表示する。
- `q`/`<Esc>`で一覧を閉じる。子のボードが開いている場合はボードも閉じ、元のウィンドウへ戻る。

### ボードを開く

- 一覧で`<CR>`を押すと、選択中のProjectのボードを一覧の子画面として開く。ボードはProjectのフィールド・先頭ビューのフィルタ・項目を取得し、projects-boardの規則で描画する。
- 一覧から開いたボードの親は一覧のウィンドウとする。ボードを閉じると一覧へ戻り、一覧を閉じると元のウィンドウへ戻る。
- `:GitHub projects <owner> <number>`または`:GitHub projects <number>`で直接開いたボードの親は、コマンド実行時のウィンドウとする。
- ボードの取得に失敗した場合はボードのヘッダに理由を表示する。一覧は残し、選択を維持する。Projectが見つからない、またはアクセスできない場合はボードを開かず、理由を通知する。
- 同じProjectのボードが既に開いている場合は、既存のfloatをフォーカスして再取得する。二重に開かない。
- ボードの初回読み込みでは、Project詳細の後に項目を100件/pageで取得し、ヘッダに`Loading <fetched>/<total>...`を表示する。取得中も画面は操作でき、`q`で閉じられる。閉じた後に応答が届いても再作成しない。

### エラーと準備

- ghが未導入・未認証、または`project`スコープがない場合は、不足する準備の案内を表示し、一覧・ボードを開かない。Neovimの編集は継続できる。
- ownerが見つからない、またはアクセスできない場合は理由を表示し、一覧・ボードを開かない。
- Project一覧の取得に失敗した場合は一覧のfloatを開いたまま理由を表示し、`r`で再試行できる。初回でも空の一覧を残す。
- ボードの取得に失敗した場合はボードのfloatを開いたまま理由を表示する。再取得の失敗では直前の成功内容を保持する。
- 古い要求の応答や閉じた画面の応答は破棄し、別の画面を更新しない。

### 画面サイズと再利用

- 一覧は幅70%・高さ70%、ボードは幅90%・高さ90%を基本とし、projects-uiの`target_size`と中央配置を使う。
- `VimResized`で一覧・ボードを再配置する。ボードは表示列数を再計算し、選択と列ごとの位置を保つ。
- 一覧は`projects-list:<host>:<owner>`、ボードは`projects-board:<host>:<owner>:<number>`で識別し、タブページごとに管理する。別タブの画面は操作しない。
- 同じownerの一覧を再度開くと既存を再利用して再取得する。別ownerの一覧は別画面とする。

## API

`projects-api`のowner解決、Project一覧、Project詳細を使う。owner解決はREST `gh api user`または`gh api users/{login}`、Project一覧はGraphQL `projectsV2(first:100)`、Project詳細は`projectV2(number:)`を使う。Projectsは`github://` URIとHTTPS入口を持たず、コマンドだけを入口にする。共通契約はDESIGN.md「GitHub API一覧」を参照する。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| `:GitHub projects`の引数解析と画面起動 | 公開入口 | `lua/github/features/command.lua` |
| Project一覧の状態・取得・表示・再利用 | 機能 | `lua/github/features/projects/list.lua` |
| Project一覧の振る舞いの検証 | テスト | `lua/github/features/projects/list_spec.lua` |

owner解決・Project一覧・Project詳細はprojects-api、ボードの描画はprojects-board、float/UIはprojects-uiの子が実装する。本issueは`command.lua`、`list.lua`、`list_spec.lua`を所有する。一覧はProjects API層からモデルを受け取り、ghを直接呼ばない。テストではfake ghと`core/float.lua`を使い、実GitHubの書込みを行わない。`doc/github.txt`の`:GitHub projects`とキーの説明は実装issueで更新する。

## エッジケースの決定

- 引数: 0個、ownerのみ、owner+番号、番号のみ、`@me`、owner+番号+余分な引数、空文字、空白、`/`を含むowner、0・負数・小数の番号。
- owner: ユーザー、Org、存在しない、アクセスできない、大文字小文字。
- Project: 0件、1件、100件、100件超、閉じたProject、存在しない、アクセスできない。
- 準備: gh未導入、未認証、`project`スコープ不足、ネットワーク障害。
- 取得: 一覧の初回失敗、再取得失敗、ボードの初回失敗、項目の途中失敗、打ち切り。
- 再利用: 同じ一覧、同じボード、別owner、別Project、別タブ。
- 終了: 一覧の`q`、ボードの`q`、親ウィンドウの終了、子画面の終了。
- サイズ: 小さい画面、リサイズ、列幅が内側幅を超える場合。
- 並行: 古い応答、閉じた画面、別画面の更新。

## テスト方針

| 受け入れ基準 (docs/design/USECASES.md) | レベル |
| --- | --- |
| （US-020）ownerを省略して`:GitHub projects`を実行すると、認証済みユーザーの開いているProjectがfloatウィンドウに一覧表示され、各Projectの番号・タイトル・項目数・公開範囲が表示される。 | 結合 |
| （US-020）ownerにOrgのログインを指定して`:GitHub projects <owner>`を実行すると、そのOrgの開いているProjectがfloatウィンドウに一覧表示される。 | 結合 |
| （US-020）Project一覧で`j`/`k`でProjectを選び`<CR>`を実行すると、そのProjectのボードがfloatウィンドウに開き、単一選択フィールドの選択肢ごとの列と項目が表示される。 | 結合 |
| （US-020）`:GitHub projects <owner> <number>`を実行すると、一覧を経由せずにそのProjectのボードがfloatウィンドウに開く。 | 結合 |
| （US-020）対象のProjectが0件のときは一覧に0件であることが表示され、Projectが見つからない、またはアクセスできないときは理由が表示されてボードを開かない。 | 結合 |
| （US-020）ghが未導入または未認証のときに`:GitHub projects`を実行すると、不足する準備の案内が表示され、Neovimの編集を継続できる。 | 結合 |
| （US-020）同じownerのProject一覧、または同じProjectのボードを再度開くと、既存のfloatウィンドウが再利用されて再取得される。 | 結合 |
| （US-020）ボードで`q`または`<Esc>`を実行するとボードが閉じて一覧または元のウィンドウへ戻り、一覧で`q`または`<Esc>`を実行すると一覧が閉じて元のウィンドウへ戻る。 | 結合 |
| （US-020）ボード表示中にエディタのサイズが変わると、floatウィンドウが画面内に収まるように再配置される。 | 結合 |
| （US-020）取得に失敗したときは理由が表示され、再取得の失敗では直前の成功内容が保持される。 | 結合 |
| （US-020）ボードを閉じた後に取得応答が届いても、閉じた画面は再作成されず、他の画面も更新されない。 | 結合 |

受け入れ基準に加え、引数解析（ownerのみ・番号のみ・`@me`・不正値）、ownerのユーザー/Org解決、閉じたProjectの除外、100件超の打ち切り、一覧の再取得時の選択維持、Git checkout外での動作、別タブの画面を操作しないことを結合テストする。
