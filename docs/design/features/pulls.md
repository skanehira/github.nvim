# PR一覧の閲覧

- 種別: 機能設計書
- 対象 UC: UC-018 (docs/design/USECASES.md)

## 何を作るか

UC-018の利用者操作を実現する。対象規則はBR-085〜BR-092。Issue一覧の検索・バッファ・描画・キーマップ・非同期要求の基盤を`pull`モードで再利用し、`type:pr`の検索とPR固有の状態表示を追加する。PRの作成・編集・レビュー・マージ・コメント投稿は対象外とし、閲覧・本文プレビュー・ブラウザ起動・URLコピー・検索に限定する。認証・実行・リポジトリ文脈と非同期の共通規約はDESIGN.md「横断規約」に従う。

## 入出力と振る舞い

- `:GitHub pulls [owner/repo]`と`github://owner/repo/pulls`、対応するHTTPS URLからPR一覧を開く。owner/repoを省略した場合は操作開始時のcwdでGitのoriginを解決し、`github://owner/repo/pulls`へ置き換える。hostはgithub.comとする。bufferごとにhost/owner/repo、最後に成功した検索条件、表示行とPRの対応、選択、要求世代を保持する。
- 初回の検索条件は`state:open`とし、GitHubの検索`type:pr`で最大30件を取得する。検索条件は`repo:<owner>/<repo> type:pr`を前置し、利用者の条件を後置する。返却順を保ち、30件を超える結果は取得しない。0件は成功結果として`0 pull requests`を表示する。
- 各行は番号・タイトル・状態（OPEN/CLOSED/MERGED）・`@担当者`・`(ラベル)`・コメント数（レビュー行のコメントを除く会話コメントの総数）を表示する。列はIssue一覧と共通で、タイトルは表示幅100で切り詰め、担当者は先頭2名、ラベルは先頭3件に制限する。内部の対象情報と属性は全件保持する。
- 番号・状態・担当者・ラベル・選択行にハイライトを付ける。MERGEDは`gh_pull_merged`、CLOSEDは`gh_issue_closed`、OPENは`gh_issue_open`を使う。カラースキーム変更時も既定色を定義する。
- `j`/`k`でカーソルを移動し、`gg`/`G`で先頭/末尾へ移動する。`<C-j>`/`<C-k>`はカーソル行の選択印をトグルして次/前の行へ移動する。端では移動せず、行がない場合は何もしない。
- `K`はカーソル行のPRの本文を読み取り専用のプレビューに表示する。本文は検索結果の`body`を使い、追加の取得はしない。プレビューは共有のMarkdown窓で、`q`で閉じる。一覧のフォーカスは残す。
- `<C-o>`は選択中のPRのURLをブラウザで開く。選択がなければカーソル行のPRを開く。`ghy`は同じ対象のURLをクリップボードへ書き込む。どちらも操作後に対象の選択を解除する。
- `ghs`は現在の検索条件を初期値にした下端の1行入力を開く。Enterで確定して一覧へ戻り、`q`/`<C-c>`で中止する。空または現在の条件と同じ入力は送信しない。確定時は同じリポジトリで再取得し、失敗時は直前の結果と検索条件を保持する。
- `:edit!`は最後に成功した検索条件で再取得する。再取得の開始時に選択を解除し、失敗しても戻さない。
- Issue固有のキー（`ghn`、`ghe`、`ght`、`gha`、`ghl`、`ghm`、`ghc`、`gho`）はPR一覧に登録しない。`<Plug>(gh:pull:search)`、`<Plug>(gh:pull:preview)`、`<Plug>(gh:pull:select:next)`、`<Plug>(gh:pull:select:prev)`、`<Plug>(gh:pull:yank)`、`<Plug>(gh:pull:view)`を公開する。
- 検索結果の`__typename`が`PullRequest`であることとrepository identityを照合し、別リポジトリの結果やPR以外の項目を混入させない。cwdが変わっても一覧を開いた時の対象を使う。
- 古い応答や閉じた一覧の応答で、表示や別の画面を更新しない。検索中に一覧を閉じても再作成しない。

正常系の操作:

| # | アクター | アクション |
| --- | --- | --- |
| 1 | 開発者 | `:GitHub pulls`を実行する、または`github://owner/repo/pulls`を開く。 |
| 2 | github.nvim | ghの準備状況を確認し、対象リポジトリと初期条件`state:open`を保持する。 |
| 3 | github.nvim | `type:pr`で検索し、最大30件のPRを一覧に表示する。 |
| 4 | 開発者 | `j`/`k`でPRを選び、`K`で本文をプレビューする。 |
| 5 | 開発者 | `<C-o>`でブラウザを開く、`ghy`でURLをコピーする。 |
| 6 | 開発者 | `ghs`で検索条件を変更する、`:edit!`で再取得する。 |
| 7 | 開発者 | `:bdelete`で一覧を閉じる。 |

代替フロー:

- A1: `:GitHub pulls <owner/repo>`でorigin以外のリポジトリを指定する。
- A2: `ghs`で`state:closed`や`is:merged`などを指定する。
- A3: 検索結果が0件の場合、`0 pull requests`を表示する。
- A4: 検索結果が30件を超える場合、先頭30件だけを表示する。

例外フロー:

- E1: ghが未導入・未認証、または権限がない場合、失敗理由を通知し、初回の取得では`Pull request search failed`を一覧に表示する。
- E2: 検索に失敗した場合、理由を表示し、直前の結果と検索条件を保持する。
- E3: 画面を閉じた、または古い応答が届いた場合、他の画面を更新しない。
- E4: 対象リポジトリを解決できない場合、理由を表示し、空の読取り専用バッファを残す。`:edit`で再試行できる。

## API

GraphQL `search(first:30,type:ISSUE,query:"repo:<owner>/<repo> type:pr state:open ...")`で、各PRのrepository、`__typename`、id、number、title、state、body、URL、comments.totalCount、assignees、labelsを取得する。担当者・ラベルが件数制限で欠ける場合は`node(id:){... on PullRequest{...}}`で接続をページングする。本文プレビューは検索で取得済みの`body`を使い、追加のクエリを発行しない。PRの作成・編集・レビュー・マージ・コメント投稿のmutationは呼ばない。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| PR一覧の状態・検索・プレビュー・キーマップ（`pull`モード） | 機能 | `lua/github/features/issues/list.lua` |
| 行の整列・切り詰め・選択印 | 共通 | `lua/github/core/rows.lua` |
| `:GitHub pulls`の引数解析と画面起動 | 公開入口 | `lua/github/features/command.lua` |
| `github://.../pulls`の解析・整形とHTTPS URLの正規化 | 共通 | `lua/github/core/uri.lua` |
| `:GitHub`コマンドとURI routerの登録 | plugin入口 | `plugin/github.lua` |
| PR一覧の振る舞いの検証 | テスト | `lua/github/features/command_spec.lua`、`lua/github/features/issues/list_spec.lua`、`lua/github/core/rows_spec.lua`、`lua/github/core/uri_spec.lua`、`lua/github/core/router_spec.lua` |
| ヘルプとREADMEの記載 | docs | `doc/github.txt`、`README.md` |

Issue一覧の`pull`モードとして実装し、検索種別（`type:pr`/`PullRequest`）、PR固有の状態表示、0件・失敗時の文言だけを分岐する。Issue一覧の状態・操作は`pull`モードでは登録しない。実行器・gh・時刻・ブラウザ・クリップボードは注入し、テストではfake ghを使う。

## エッジケースの決定

- 空: 初回や検索で0件なら`0 pull requests`を表示する。
- 境界: 最大30件。30件を超える結果は取得せず、打ち切りの表示はしない。画面のページ送りは対象外。タイトルは表示幅100で切り詰め、担当者は先頭2名、ラベルは先頭3件を表示する。
- 状態: OPEN/CLOSED/MERGEDを表示し、MERGEDはCLOSEDと区別してハイライトする。
- エラー: 初回失敗は`Pull request search failed`を表示し、再取得失敗では直前の成功結果と条件を維持する。
- 並行: 同じbufferの新しい要求を優先し、閉鎖後や別bufferに古い応答を適用しない。
- 対象: Git checkout外でowner/repoを省略した場合は理由を表示し、空の読取り専用バッファを残す。owner/repoを指定した場合はGit checkout外でも開ける。
- URI: `github://owner/repo/pulls`の余分なpath、query、fragmentを拒否する。`github://pulls`はoriginから解決する。`pulls`以外の区分は他の機能へ渡す。
- 画面: 一覧は通常のバッファで、行を表示幅で切り詰める。同じ一覧を開き直した場合は既存バッファを再利用して再取得する。
- スコープ: PRの作成・編集・レビュー・マージ・コメント投稿は提供しない。Issue固有のキーも登録しない。

## テスト方針

| 受け入れ基準 (docs/design/USECASES.md) | レベル |
| --- | --- |
| （US-024）`:GitHub pulls`を実行すると、GitのoriginのリポジトリのPR一覧がバッファに表示され、各行に番号・タイトル・状態・担当者・ラベル・コメント数が表示される。 | 結合 |
| （US-024）`github://owner/repo/pulls`を開くと、そのリポジトリのPR一覧がバッファに表示される。対応するGitHubのHTTPS URLも同じ一覧として開く。 | 結合 |
| （US-024）`:GitHub pulls <owner/repo>`でorigin以外のリポジトリのPR一覧を開ける。 | 結合 |
| （US-024）`j`/`k`でカーソルが移動し、`<C-j>`/`<C-k>`でカーソル行の選択印をトグルして次/前の行へ移動する。 | 結合 |
| （US-024）PRを選んで`K`を実行すると本文がプレビューされ、`q`でプレビューだけが閉じ、一覧にフォーカスが残る。 | 結合 |
| （US-024）PRを選んで`<C-o>`を実行するとブラウザでPRのURLが開き、`ghy`でURLがクリップボードへ書き込まれる。選択中のPRがある場合は選択した全件が対象になり、操作後に選択が解除される。 | 結合 |
| （US-024）`ghs`で検索条件を入力してEnterを押すと、その条件のPRだけが表示される。`q`/`<C-c>`で中止するか、空または変更なしで確定すると、新しい検索を開始せず直前の結果と検索条件が維持される。 | 結合 |
| （US-024）検索結果が0件のときは`0 pull requests`が表示され、取得に失敗したときは理由が表示されて直前の結果と検索条件が保持される。 | 結合 |
| （US-024）`:edit!`で最後に成功した検索条件の再取得が行われ、失敗時は直前の結果と検索条件が保持される。 | 結合 |
| （US-024）MERGEDのPRはCLOSEDと区別して表示され、状態に応じたハイライトが付く。 | 結合 |
| （US-024）PR一覧ではIssueの作成・編集・状態変更・担当者・ラベル・コメントのキーが提供されず、PRの作成・編集・レビュー・マージ・コメント投稿も提供されない。 | 結合 |
| （US-024）検索結果が別リポジトリのPR、またはPR以外の項目だった場合は結果を採用せず、失敗理由を表示する。 | 結合 |
| （US-024）`github://pulls`は開いた時点のcwdのGit originからリポジトリを解決して`github://owner/repo/pulls`へ置き換える。解決できない場合は理由を表示し、空の読取り専用バッファを残して`:edit`で再試行できる。 | 結合 |
| （US-024）ghが未導入・未認証、または権限がないときは理由が表示され、初回の取得では`Pull request search failed`が一覧に表示される。 | 結合 |

受け入れ基準に加え、URIの余分なpath・query・fragmentの拒否、owner/repo省略時のorigin解決、Git checkout外での動作、検索条件の保持、0件・失敗・古い応答、ブラウザ・クリップボードのfake、選択のトグルとURL操作後の解除、担当者・ラベルのページング、同じ一覧の再利用を結合テストする。
