# Projectボードの閲覧

- 種別: 機能設計書
- 対象 UC: UC-015 (docs/design/USECASES.md)
- 対象ストーリー: US-021

## 何を作るか

UC-015の利用者操作を実現する。対象規則はBR-063〜BR-071。一覧とボードの起動はprojects-list、float UIの共通規則はprojects-ui、APIはprojects-api、フィールド編集と項目の追加・削除はそれぞれprojects-field-editとprojects-item-manageに従う。

## 入出力と振る舞い

### ボードの状態

- ボードは`{project, fields, group_field, columns, items, view, filter, selected, offsets, first_col, visible, loading, error, generation, truncated, body_cache}`を保持する。
- `columns`はグループフィールドの選択肢順に作り、値のない項目を末尾の値なし列に置く。グループフィールドの値が現在の選択肢にない項目も値なし列に置く。各列は`{key, name, color, items, count}`を持つ。値なし列は`{key=nil, no_value=true, name="値なし", items, count}`とする。単一選択フィールドがない場合は1列（`key=nil`）とする。
- `items`はAPIの項目位置順を保つ。項目は`{id, type, content, values, archived}`で、列の値はグループフィールドIDで引く。
- `selected`は`{column_index, item_id}`。空の列を選んだ場合は`item_id=nil`とし、列ヘッダを選択状態にする。
- `offsets`は列ごとの先頭項目のindex（1始まり）。`first_col`は表示する先頭列のindex、`visible`は表示列数。
- `filter`は初期状態では先頭ビューの`filter`（nullなら空）とし、`view`は先頭ビューの名前を保持する。`ghs`で変更した後は`view=nil`とする。
- `body_cache`は項目IDごとの本文を保持し、`r`とフィルタ適用で破棄する。
- `loading`は`nil`、`initial`、`refresh`、`filter`のいずれか。`error`は最後の失敗理由を保持する。`truncated`は`max_items`で打ち切ったことを示す。

### 描画

- 1行目は`<owner> / <title>  ·  <items> items  ·  filter: <filter>`を表示する。フィルタが先頭ビュー由来なら`view: <name>  ·  filter: <filter>`とする。読み込み中は`Loading <fetched>/<total>...`、打ち切り時は`Showing <max_items> of <total>`、失敗時は`Error: <理由>`を表示する。
- Project詳細の取得に失敗した場合はボードを開かず、理由を通知する。項目の取得に失敗した場合は、既に開いているボードのヘッダに`Error: <理由>`を表示し、直前の内容を保持する。
- 2行目は列ヘッダを表示する。`● <name> <count>`とし、選択肢の色を付ける。右端に`+`を表示する。値なし列は`○ 値なし <count>`とする。選択中の列ヘッダを`GitHubProjectsColumnSelected`で強調する。列ヘッダ行全体の背景は`GitHubProjectsColumnHeader`とする。ヘッダの背景はpriority 1、ラベルは2、列背景は0にして、ヘッダが列背景に上書きされないようにする。
- 列幅は`column_width`（既定36、20〜80）を最小幅として、表示領域に合わせて自動調整する。表示列数は`max(1, floor((inner_width + 1) / (column_width + 1)))`と列数の小さい方とし、実効列幅は`max(column_width, floor((inner_width - (表示列数 - 1)) / 表示列数))`とし、割り切れない余りは最後の表示列に加えて合計を`inner_width`にする。これにより右側に余白を残さない。列の区切りは半角スペース1セルとし、`│`は使わない。列数が表示幅を超える場合は横スクロールし、選択列が画面外に出るときは`first_col`を調整する。
- 列の本文は`GitHubProjectsColumnBg`の背景で塗る。列ごとに独立した縦の表示位置を持つ。`j`/`k`では選択中の列だけをスクロールし、他の列の位置を変えない。選択カードが表示領域より高い場合は先頭行を表示し、カーソルをタイトル行に置く。
- 項目カードは角丸の枠線付きで、背景`GitHubProjectsCard`、枠線`GitHubProjectsCardBorder`を使う。カード幅は列幅に合わせ、高さは内容に応じて変動する。枠線は背景より高いextmark priorityで描き、全辺を同じ枠線色にする。
  - Issue: 先頭行は`◉ <repo> #<number>`で、右端に担当者のログイン名を右寄せで表示する。`◉`はopenなら緑、closedなら紫。`<repo>`はリポジトリ名で、取得できない場合は省略する。タイトルは2行目以降に左寄せで表示し、省略せずカード幅に合わせて必要な行数だけ折り返す。
  - PR: 先頭行は`⇄ <repo> #<number>`で、右端に担当者のログイン名を右寄せで表示する。`⇄`はopenなら緑、mergedなら紫、closedなら赤。タイトルはIssueと同じく2行目以降に折り返す。
  - DraftIssue: 先頭行は`✎ <title>`。`✎`はグレー。タイトルは折り返す。
  - REDACTED: `[redacted]`を1行で表示する。
- タイトルの後に空行1行を置き、表示できるメタ情報がある場合だけ次の行を追加する。ラベルは最大2件を色付きチップで表示し、残りは`+N`とする。担当者は先頭のログイン名を先頭行の右端に右寄せで表示し、2名以上なら`+N`を付ける。サブIssueの進捗は`total > 0`のときだけ`<completed>/<total> <bar>`を表示し、バーはカードの右端まで埋める。完了部分は`GitHubProjectsProgress`の緑のブロック、未完了部分は`GitHubProjectsProgressEmpty`の塗りつぶしトラックで描く。関連PRは最大2件を`⇄ #<n>`で表示し、残りは`+N`とする。
- ラベル・担当者・関連PRは表示幅を超える分を切り詰めるか`+N`でまとめる。タイトルは折り返し、カードの行は列幅に満たない分を空白で埋める。カード間は空行1行で区切る。
- 空の列は列ヘッダと`—`を表示する。項目が0件のボードは列ヘッダと`No items`を表示する。フィルタが0件なら`No items match filter`を表示する。
- 選択中のカードは背景を`GitHubProjectsCardSelected`、枠線を`GitHubProjectsCardSelectedBorder`（太い黄色の二重線）にし、カーソルをタイトル行に置く。空の列を選んだ場合は列ヘッダにカーソルを置く。列ヘッダとカードの強調はextmarkで行い、再描画時に名前空間をクリアする。枠線はpriority 10、カード背景は1、内容は2、列背景は0にして、列背景がカードの背景・内容・枠線を上書きしないようにする。
- 描画の詳細（列幅、折り返し、ハイライト、extmark）はprojects-uiの規則を使う。

### ナビゲーション

- `h`/`l`で前/次の列、`j`/`k`で前/次の項目、`H`/`L`で先頭/末尾の列、`g`/`G`で先頭/末尾の項目へ移動する。端では移動しない。
- 列を移動したときは、その列の選択項目を同じindexにclampする。項目がない場合は列ヘッダを選ぶ。空の列では`j`/`k`は移動しない。
- 選択中の列と項目を強調し、画面外へ出るときは表示列・表示位置をスクロールする。
- 選択は項目IDで保持する。グループフィールドの変更で列が変わった場合は変更後の列の項目を選択する。追加した項目は列の末尾に置き、その項目を選択する。削除した項目の選択は次の項目、なければ前の項目、なければ列ヘッダへ移す。

### プレビュー

- `K`は選択項目の本文をプレビューする。Issue/PRは本文を取得し、下書きは取得済みの本文を使う。redactedはプレビューできないことを案内する。
- 本文は`repository.issueOrPullRequest(number){ __typename ... on Issue { body } ... on PullRequest { body } }`で取得する。項目の`repository.nameWithOwner`からowner/repoを解決する。取得成功時は`body_cache`に保持し、`r`とフィルタ適用で破棄する。
- プレビューはボードの子画面として開き、項目の種別・番号・タイトルをヘッダに表示し、本文を`filetype=gh-projects-preview`（構文はmarkdown）で表示する。`j`/`k`/`gg`/`G`/`<C-d>`/`<C-u>`でスクロールし、`q`/`<Esc>`で閉じる。ボードの選択は維持する。
- 取得中はヘッダに読み込み中を表示する。取得に失敗した場合は理由を表示し、ボードの選択を維持する。項目が削除済み・権限なしの場合は理由を表示する。

### 項目を開く

- `<CR>`は項目の種別に応じて動作する。
  - Issue: `github://<owner>/<repo>/issues/<number>`を新しいタブで開く。ボードは元のタブに残し、タブを戻ればボードを再開できる。
  - PR: ブラウザでURLを開く。
  - DraftIssue: プレビューを開く。
  - REDACTED: 開けないことを案内する。
- Issueを開くときは`tabnew`で新しいタブを作り、`github://`のBufReadCmdを通す。ボードのfloatウィンドウをIssueバッファで置き換えない。
- `<C-o>`はIssue/PRのURLをブラウザで開く。`ghy`はURLを`+`レジスタへ書き込む。下書きIssueとredactedはURLがないことを案内する。
- ブラウザ・クリップボードの失敗は理由を表示し、成功と断定しない。検知できない場合は結果未確認を案内する。

### フィルタ

- 初期フィルタは先頭ビューの`filter`を使う。ビューの切替・保存はしない。
- `ghs`は現在のフィルタを初期値にした1行入力を開く。`<CR>`で適用、`q`/`<C-c>`で中止する。
- 空のフィルタは全件、変更なしは再取得しない。
- 適用時は新しいフィルタで項目を取得する。成功したらフィルタと項目を更新し、選択を項目IDで維持する。存在しなければ同じ列の同じ位置へclampし、0件なら列ヘッダを選ぶ。
- 取得に失敗したら新しいフィルタを採用せず、直前の項目とフィルタを保持して理由を表示する。読み込み中は新しいフィルタをヘッダに表示してよいが、失敗時は元のフィルタへ戻す。
- 0件は成功結果として表示し、エラーと区別する。無効なフィルタが0件として返る場合も、0件として表示する。
- フィルタの構文検証は行わない。GitHubのProjectフィルタ文字列をそのまま渡す。

### 再取得

- `r`は同じProject・フィルタで項目を再取得する。取得開始時に選択を解除しない。
- 成功時は項目を置き換え、選択を項目IDで維持する。存在しなければ同じ列の同じ位置へclampし、0件なら列ヘッダを選ぶ。`body_cache`を破棄する。
- 失敗時は直前の成功内容と選択を保持し、理由を表示する。
- 取得は100件/pageで行い、`max_items`で打ち切る。打ち切り時はヘッダに示す。取得中も画面は操作でき、`q`で閉じられる。

### ヘルプと終了

- `?`は一覧・ボード・フィールド編集・追加・削除のキー操作をヘルプのfloatで表示する。ボードは残る。`j`/`k`/`gg`/`G`でスクロールし、`q`/`<Esc>`で閉じる。
- `q`/`<Esc>`はボードを閉じ、子画面（プレビュー・ヘルプ・フィールド編集・追加・確認）も閉じる。一覧から開いた場合は一覧へ、直接開いた場合は元のウィンドウへ戻る。
- ボードを閉じた後に取得応答が届いても、ボードを再作成せず、他の画面を更新しない。

### 画面サイズと再利用

- ボードは幅90%・高さ90%を基本とし、projects-uiの`target_size`と中央配置を使う。
- `VimResized`で幅・高さ・表示列数を再計算し、選択と列ごとの位置を保って再描画する。
- 同じProjectのボードが既に開いている場合は既存をフォーカスして再取得する。別Projectのボードは別画面とし、タブページごとに管理する。
- 別タブのボードを操作・更新しない。

## API

`projects-api`の項目取得と本文取得を使う。項目は`items(first:100, after:, query:, orderBy:{field:POSITION,direction:ASC}, archivedStates:[NOT_ARCHIVED])`で取得し、`pageInfo`を辿る。本文は次のGraphQLで取得する。

```graphql
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issueOrPullRequest(number: $number) {
      __typename
      ... on Issue { body }
      ... on PullRequest { body }
    }
  }
}
```

`issueOrPullRequest`で1つのnodeを取得する。`issue`と`pullRequest`を同時に問い合わせると非該当側がNOT_FOUNDになりクエリ全体が失敗するため、このunionを使う。

ブラウザとクリップボードは既存の共通adapterを使う。Projectsは`github://` URIを持たないが、Issueを開くときは既存のIssue URIを使う。共通契約はDESIGN.md「GitHub API一覧」を参照する。

`board.lua`はフィールド編集と項目の追加・削除のために、次のモジュールAPIを公開する。`board.state(buf)`はボードの状態を返す。`board.selected_item(buf)`は選択中の項目を返す。`board.update_field(buf, item_id, field_id, value)`はフィールド値のローカル更新、グループフィールドなら列移動、選択の維持、再描画を行う。`board.add_item(buf, item)`と`board.remove_item(buf, item_id)`は項目の追加・削除をローカル状態へ反映し、再描画する。`board.select_item(buf, item_id)`は項目IDで選択を設定する。`board.refresh(buf)`は同じ条件で再取得する。これらのAPIは`board.lua`が所有し、フィールド編集と項目管理の機能は`board.lua`を変更しない。

`ghe`は`github.features.projects.field_edit.open(buf)`、`ghn`は`github.features.projects.item_manage.open_add(buf)`、`ghd`は`github.features.projects.item_manage.open_delete(buf)`を遅延requireして呼ぶ。モジュールが未実装の場合は`GitHub projects: <module> is not available`を案内する。

API層の項目`content`は`total_count`、`sub_issues`、`related_pulls`を持つが、`ui.card`は`totalCount`、`subIssuesSummary`、`closedByPullRequestsReferences`を読む。ボードは描画時にこれらの名前へ詰め替え、API層と共通UIのどちらも変更しない。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| ボードの状態・描画・ナビゲーション・フィルタ・プレビュー・再取得 | 機能 | `lua/github/features/projects/board.lua` |
| ボードの振る舞いの検証 | テスト | `lua/github/features/projects/board_spec.lua` |

項目・本文の取得はprojects-api、float・入力・確認・プレビュー・ヘルプの共通UIはprojects-ui、一覧との親子関係はprojects-listの子が実装する。本issueは`board.lua`と`board_spec.lua`を所有する。ボードはghを直接呼ばず、Projects API層からモデルを受け取る。テストではfake ghと`core/float.lua`を使い、実GitHubの書込みを行わない。`doc/github.txt`のボードのキー説明は実装issueで更新する。

## エッジケースの決定

- 空: 項目0件、単一選択フィールドなし（1列、`key=nil`）、空の列、フィルタ0件、選択項目なし。
- 境界: 表示列数、列幅、カードの高さ、`max_items`の打ち切り、ラベル・担当者・関連PRの表示上限。
- 長い文字列: 日本語を含むタイトルはカード幅で折り返す。ラベル・担当者・フィルタは表示幅を超える分を切り詰めるか`+N`でまとめる。
- 種別: Issue、PR、DraftIssue、REDACTED。アーカイブ済みは表示しない。
- プレビュー: 本文取得の失敗、削除済み、権限なし、redacted、下書きの本文。
- 移動: Issueの新しいタブ、PRのブラウザ、下書きのプレビュー、redactedの案内。
- URL: 下書き・redactedにURLがない、ブラウザ・クリップボードの失敗。
- フィルタ: 空、変更なし、0件、無効な条件、取得失敗、キャンセル。
- 再取得: 選択項目の消失、列の消失、0件、失敗。
- サイズ: 小さい画面、リサイズ、列幅が内側幅を超える場合。
- 並行: 古い応答、閉じた画面、別画面の更新。
- 連携: グループフィールドの変更で列が変わる、追加した項目の選択、削除後の選択。

## テスト方針

| 受け入れ基準 (docs/design/USECASES.md) | レベル |
| --- | --- |
| （US-021）ボードを開くと、列ごとに選択肢名と項目数が表示され、Issueは種別・番号・タイトル・ラベル・担当者・サブIssueの進捗・関連PR、PRは種別・番号・タイトル・ラベル・担当者、下書きIssueはタイトルが表示される。 | 結合 |
| （US-021）ボードで`h`/`l`を実行すると選択列が前後に移動し、画面外へ出るときは表示列がスクロールする。 | 結合 |
| （US-021）ボードで`j`/`k`を実行すると選択中の列の項目が前後に移動し、画面外へ出るときはその列が縦にスクロールする。 | 結合 |
| （US-021）`H`/`L`で先頭/末尾の列、`g`/`G`で先頭/末尾の項目へ移動し、選択中の列と項目が強調される。 | 結合 |
| （US-021）項目を選んで`K`を実行すると、その項目の本文がfloatウィンドウにプレビューされ、`q`でプレビューだけが閉じる。 | 結合 |
| （US-021）Issueの項目を選んで`<CR>`を実行すると、対応するIssueの編集バッファが開く。PRの項目ではブラウザが開き、下書きIssueではプレビューが開く。 | 結合 |
| （US-021）項目を選んで`<C-o>`を実行するとブラウザでURLが開き、`ghy`を実行するとURLが`+`レジスタへ書き込まれる。下書きIssueではURLがないことが案内される。 | 結合 |
| （US-021）`ghs`でフィルタを入力してEnterを押すと、その条件の項目だけがボードに表示される。空のフィルタで全件に戻り、`q`/`<C-c>`で中止すると直前の結果が維持される。 | 結合 |
| （US-021）フィルタに一致する項目がないときは0件であることが表示され、取得に失敗したときは理由が表示されて直前の結果とフィルタが保持される。 | 結合 |
| （US-021）`r`を実行すると同じProjectとフィルタで再取得され、選択中の項目が存在すれば選択が維持される。 | 結合 |
| （US-021）アーカイブ済みの項目は表示されず、内容を取得できない項目はredactedと表示されて本文プレビューと移動ができない。 | 結合 |
| （US-021）`?`でキー操作のヘルプがfloatで表示され、ボードは残る。 | 結合 |
| （US-021）ボードを開いた後で古い取得応答が届いても、新しい結果や別の画面が上書きされない。 | 結合 |

受け入れ基準に加え、空の列・0件のボード・フィルタ0件の表示、長い日本語タイトルの折り返しとカード高さの変動、列幅の自動調整と横スクロール、列ごとの縦位置の保持、選択項目の消失時のclamp、Issueを新しいタブで開くこと、PR/下書き/redactedの分岐、本文プレビューのキャッシュと失敗、`max_items`打ち切りの表示を結合テストする。
