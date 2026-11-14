# Projectsのfloat UI

- 種別: 機能設計書
- 対象 UC: UC-014〜UC-017（共通UI）
- 対象ストーリー: US-020〜US-023

## 何を作るか

Projectsの一覧・ボード・フィールド編集・追加・削除・確認・プレビュー・ヘルプをfloatウィンドウで表示する共通UIを提供する。対象規則はBR-057、BR-060〜BR-071、BR-076、BR-082。`core/float.lua`のスタック・ジオメトリ・ライフサイクルを使い、画面固有の描画とキーマップは本機能が持つ。

## 入出力と振る舞い

### 画面の種類

| 画面 | 用途 | 親 | 既定サイズ（編集領域の比率） |
| --- | --- | --- | --- |
| 一覧 | Project一覧 | 元のウィンドウ | 幅70%、高さ70% |
| ボード | カンバン | 一覧または元のウィンドウ | 幅90%、高さ90% |
| フィールド編集 | 編集可能フィールドの一覧 | ボード | 幅50%、高さ60% |
| 選択肢 | 単一選択の選択肢 | フィールド編集 | 幅40%、高さ60% |
| 1行入力 | フィルタ・既存項目・タイトル・数値・日付 | ボード・フィールド編集・追加 | 幅50%、高さ1 |
| 本文入力 | 下書きIssueの本文 | 追加 | 幅70%、高さ60% |
| 確認 | 削除確認 | ボード | 幅40%、高さ3 |
| プレビュー | 本文プレビュー | ボード | 幅70%、高さ70% |
| ヘルプ | キー操作 | ボード | 幅70%、高さ60% |
| 追加の選択 | 既存Issue/PRか下書きかの選択 | ボード | 幅40%、高さ4 |

比率は`target_size(ratio_w, ratio_h)`で計算する。編集領域は`vim.o.columns - 2`と`vim.o.lines - 2`とし、幅・高さは1以上にclampする。中央配置は`row = floor((vim.o.lines - height - 2) / 2)`、`col = floor((vim.o.columns - width - 2) / 2)`とし、負の座標にしない。ボーダーは`rounded`、`style`は`minimal`。比率で開く画面は`target_size`で得た`width`/`height`を`open`に渡す。固定高さの画面（1行入力・確認・追加の選択）は`height`と`fixed_height=true`で開き、幅だけを比率で再計算する。

### 共通の画面規則

- floatはタブページごとのスタックで管理する。各画面は親ウィンドウを保持し、閉じたときは親→スタックの前の画面→元のウィンドウの順にフォーカスを戻す。
- 同じ名前の画面が既にある場合は再利用し、内容を再取得する。ボードは`projects-board:<host>:<owner>:<number>`、一覧は`projects-list:<host>:<owner>`で識別する。同じProjectのボードを二重に開かない。
- 子画面は親のボード/一覧が閉じたら閉じる。親が外部から閉じられた場合も子画面を閉じ、無効なwindowを操作しない。
- バッファは`buftype=nofile`、`bufhidden=wipe`、`swapfile=false`。読み取り専用画面は`modifiable=false`、入力画面は`modifiable=true`。filetypeは一覧`gh-projects-list`、ボード`gh-projects-board`、フィールド編集`gh-projects-editor`、プレビュー`gh-projects-preview`、ヘルプ`gh-projects-help`、入力`gh-projects-input`とする。
- 窓は`wrap=false`、`number=false`、`relativenumber=false`、`cursorline=false`、`signcolumn=no`、`foldcolumn=0`、`list=false`、`spell=false`、`scrolloff=0`とする。ボーダーと背景は既定の`FloatBorder`/`NormalFloat`を使う。ボードのfloatはボーダー色だけをissueカードの`GitHubProjectsCardBorder`に合わせるため、`FloatBorder:GitHubProjectsCardBorder`の`winhighlight`を設定する。`NormalFloat`は既定のまま、ボーダー形状は`rounded`。列・カード・ヘッダの背景は画面内のextmarkで表現する。
- `VimResized`で全画面の幅・高さ・中央配置を再計算する。ボードと一覧は選択と列ごとの表示位置を保って再描画する。子画面は中央へ再配置する。
- 読み込み中は対象画面のヘッダに進行状況を表示する。ページ取得では`取得済み/総数`を更新する。失敗時は理由をエラー表示し、再取得では直前の成功内容を保持する。
- キーマップはバッファローカルに設定し、`silent=true`、`nowait=true`とする。マウス操作は対象外とし、独自のマウス割当をしない。
- 入力画面は`startinsert`で開始する。`<CR>`で確定、`<C-c>`で中止する。`<Esc>`は挿入モードを抜け、通常モードの`q`で中止する。ヘッドレスでは挿入モードの実操作を検証できないため、テストではマッピングの登録と通常モードのコールバックを確認する。
- 選択項目の先頭行にカーソルを置き、列ヘッダと項目をextmarkで強調する。`modifiable=false`の画面では`nvim_buf_set_lines`の後に`modifiable`を戻す。

### ハイライト

| グループ | 既定リンク | 用途 |
| --- | --- | --- |
| グループ | 既定の色/属性 | 用途 |
| --- | --- | --- |
| `GitHubProjectsToolbar` | fg `#e6edf3`, bg `#161b22` | ボードのヘッダ行 |
| `GitHubProjectsHeader` | fg `#e6edf3`, bold | Project名・件数・フィルタのヘッダ |
| `GitHubProjectsColumnHeader` | bg `#161b22` | 列ヘッダ行の背景 |
| `GitHubProjectsColumnBg` | bg `#161b22` | 列の本文の背景 |
| `GitHubProjectsColumn` | fg `#e6edf3` | 列ヘッダの名前 |
| `GitHubProjectsColumnSelected` | fg `#ffffff`, bg `#1f6feb`, bold | 選択中の列ヘッダ |
| `GitHubProjectsCard` | fg `#e6edf3`, bg `#0d1117` | 項目カードの背景 |
| `GitHubProjectsCardBorder` | fg `#e6edf3`, bg `#0d1117` | 項目カードの枠線 |
| `GitHubProjectsCardSelected` | fg `#e6edf3`, bg `#161b22` | 選択中の項目カードの背景 |
| `GitHubProjectsCardSelectedBorder` | fg `#f1c40f`, bg `#161b22`, bold | 選択中の項目カードの枠線（太い黄色） |
| `GitHubProjectsCardTitle` | fg `#e6edf3`, bold | カードのタイトル |
| `GitHubProjectsNumber` | fg `#8b949e` | 項目番号・種別 |
| `GitHubProjectsMeta` | fg `#8b949e` | 件数・ラベル以外の補助情報 |
| `GitHubProjectsProgress` | fg `#3fb950` | サブIssue進捗の完了部分 |
| `GitHubProjectsProgressEmpty` | fg `#30363d` | サブIssue進捗の未完了部分 |
| `GitHubProjectsLabel` | fg `#e6edf3`, bg `#30363d` | 色情報のないラベルチップ |
| `GitHubProjectsLabelMore` | fg `#e6edf3`, bg `#30363d` | ラベルの`+N` |
| `GitHubProjectsAvatar` | fg `#ffffff`, bg `#1f6feb`, bold | 担当者アバターの既定色 |
| `GitHubProjectsEmpty` | fg `#8b949e` | 空の列・0件の案内 |
| `GitHubProjectsRedacted` | `Comment`へのリンク | redacted表示 |
| `GitHubProjectsError` | `DiagnosticError`へのリンク | エラー表示 |
| `GitHubProjectsLoading` | `DiagnosticWarn`へのリンク | 読み込み表示 |
| `GitHubProjectsColorGray` | fg `#8b949e` | 選択肢の色 |
| `GitHubProjectsColorRed` | fg `#f85149` | 選択肢の色 |
| `GitHubProjectsColorOrange` | fg `#d29922` | 選択肢の色 |
| `GitHubProjectsColorYellow` | fg `#d29922` | 選択肢の色 |
| `GitHubProjectsColorGreen` | fg `#3fb950` | 選択肢の色 |
| `GitHubProjectsColorPink` | fg `#db61a2` | 選択肢の色 |
| `GitHubProjectsColorPurple` | fg `#a371f7` | 選択肢の色 |
| `GitHubProjectsColorBlue` | fg `#58a6ff` | 選択肢の色 |

色はAPIの`color`（GRAY/RED/ORANGE/YELLOW/GREEN/PINK/PURPLE/BLUE）を対応するグループへ割り当てる。ラベルは色ごとに`GitHubProjectsLabel_<hex>`を、担当者はログインごとに`GitHubProjectsAvatar_<login>`を初回描画時に動的作成する。ラベルの文字色は背景色の輝度から黒/白を選ぶ。アバターの背景色はログインのハッシュから6色のパレットを選ぶ。すべての`GitHubProjects*`グループは`default=true`で定義し、利用者は`:hi`で上書きできる。設定キーは追加しない。

### 一覧の描画

- 1行目に`Projects for <owner> (<type>)  ·  <count> open`を表示する。読み込み中は`Loading projects...`、失敗時は`Error: <理由>`を表示する。
- 2行目以降に`#<number> <title>  <item_count> items  <public|private>`を表示する。表示幅を超えるタイトルは`...`で切り詰める。選択行を強調し、カーソルを選択行に置く。
- 0件は`No open projects`、読み込み中は行を消さずにヘッダへ進行状況を表示する。
- `j`/`k`で選択、`<CR>`でボードを開く、`r`で再取得、`q`/`<Esc>`で閉じる。再取得ではProject番号で選択を維持し、存在しなければ同じ位置へclampする。

### ボードの描画

- 1行目に`<owner> / <title>  ·  <items> items  ·  filter: <filter>`を表示する。フィルタが先頭ビュー由来なら`view: <name>  ·  filter: <filter>`とする。読み込み中は`Loading <fetched>/<total>...`、打ち切り時は`Showing <max_items> of <total>`、失敗時は`Error: <理由>`を表示する。行全体を`GitHubProjectsToolbar`で描画する。
- 2行目に列ヘッダを表示する。`● <name> <count>`とし、選択肢の色を付ける。値なし列は`○ 値なし <count>`とする。右端に`+`を表示する。選択中の列ヘッダは`GitHubProjectsColumnSelected`で強調し、名前・件数・`+`を白で描く。列ヘッダ行全体の背景は`GitHubProjectsColumnHeader`とする。ヘッダの背景はpriority 1、ラベルは2、列背景は0にして、ヘッダが列背景に上書きされないようにする。
- 列幅は設定`column_width`（既定36、20〜80）を最小幅として、表示領域に合わせて自動調整する。表示列数は`max(1, floor((inner_width + 1) / (column_width + 1)))`と列数の小さい方とし、実効列幅は`max(column_width, floor((inner_width - (表示列数 - 1)) / 表示列数))`とし、割り切れない余りは最後の表示列に加えて合計を`inner_width`にする。これにより右側に余白を残さない。列の区切りは半角スペース1セルとし、`│`は使わない。列数が表示幅を超える場合は横スクロールし、選択列が画面外に出るときは`first_col`を調整する。
- 各列の本文は`GitHubProjectsColumnBg`の背景で塗り、列ごとに独立した縦の表示位置（先頭項目のindex）を持つ。選択中の列だけを`j`/`k`でスクロールし、他の列の位置は変えない。
- 項目カードは角丸の枠線付きで、背景`GitHubProjectsCard`、枠線`GitHubProjectsCardBorder`を使う。カード幅は列幅に合わせ、高さは内容に応じて変動する。枠線は背景より高いextmark priorityで描き、上・左・右・下の全辺を同じ枠線色にする。
  - 上端は`╭─...─╮`、下端は`╰─...─╯`、内容行は`│ ... │`とする。選択中のカードは太い黄色の枠線にするため、上端`╔═...═╗`、下端`╚═...═╝`、内容行`║ ... ║`の二重線にする。
  - 枠線はextmark priority 10、カード背景は1、内容は2、列背景は0で描き、列背景がカードの背景・内容・枠線を上書きしないようにする。
  - Issue: 先頭行は`◉ #<number> <title>`。`◉`はopenなら緑、closedなら紫。タイトルは省略せず、カード幅に合わせて必要な行数だけ折り返す。2行目以降は番号プレフィックスの表示幅だけインデントする。
  - PR: 先頭行は`⇄ #<number> <title>`。`⇄`はopenなら緑、mergedなら紫、closedなら赤。タイトルはIssueと同じく折り返す。
  - DraftIssue: 先頭行は`✎ <title>`。`✎`はグレー。タイトルは折り返す。
  - REDACTED: `[redacted]`を1行で表示する。
- タイトルの後に空行1行を置き、表示できるメタ情報がある場合だけ次の行を追加する。
  - ラベルは最大2件を色付きチップ（` <name> `）で表示し、残りは`+N`とする。チップの背景はラベルの色、文字色は輝度に応じて黒/白とする。色情報がないラベルは`GitHubProjectsLabel`を使う。
  - 担当者は最大3名を右寄せの丸文字アバター（`Ⓐ`〜`Ⓩ`、英字以外は`●`）で表示し、残りは`+N`とする。アバターの背景はログインごとの動的グループを使う。
  - サブIssueの進捗は`total > 0`のときだけ`<completed>/<total> <bar> <percent>%`を表示する。バーは完了部分を`GitHubProjectsProgress`、未完了部分を`GitHubProjectsProgressEmpty`で描く。
  - 関連PRは最大2件を`⇄ #<n>`で表示し、残りは`+N`とする。
- 選択中のカードは背景を`GitHubProjectsCardSelected`、枠線を`GitHubProjectsCardSelectedBorder`（太い黄色の二重線）にし、カーソルをタイトル行に置く。空の列を選んだ場合は列ヘッダにカーソルを置く。
- カード間は空行1行で区切る。空の列は列ヘッダと`—`を表示する。項目が0件のボードは列ヘッダと`No items`を表示する。フィルタが適用されている場合は、項目が0件でも`No items match filter`を優先する。
- 列ヘッダとカードの強調はextmarkで行い、再描画時に名前空間をクリアする。カードの選択と列の選択は別のextmarkとする。

### ボードのナビゲーションと操作

- `h`/`l`で前/次の列、`j`/`k`で前/次の項目、`H`/`L`で先頭/末尾の列、`g`/`G`で先頭/末尾の項目へ移動する。端では移動しない。空の列では`j`/`k`は移動しない。
- 列を移動したときは、その列の選択項目を同じindexにclampする。項目がない場合は列ヘッダを選ぶ。
- `K`は選択項目の本文をプレビューする。Issue/PRは本文を取得し、下書きは取得済みの本文を使う。取得結果はボードの状態に保持し、`r`とフィルタ適用で破棄する。プレビューは`j`/`k`/`gg`/`G`/`<C-d>`/`<C-u>`でスクロールし、`q`/`<Esc>`で閉じる。
- `<CR>`はIssueなら`github://owner/repo/issues/<number>`を新しいタブで開き、ボードは元のタブに残す。PRならブラウザ、下書きならプレビューを開く。redactedは案内だけを表示する。
- `<C-o>`はIssue/PRのURLをブラウザで開く。`ghy`はURLを`+`レジスタへ書き込む。下書き・redactedはURLがないことを案内する。
- `ghs`は現在のフィルタを初期値にした1行入力を開く。`<CR>`で適用、`q`/`<C-c>`で中止する。空のフィルタは全件、変更なしは再取得しない。適用時は項目を再取得し、選択を項目IDで維持する。0件は成功結果として表示し、失敗時は直前の結果とフィルタを保持する。
- `r`は同じProject・フィルタで再取得する。取得開始時に選択を解除しない。成功時は項目IDで選択を維持し、存在しなければ同じ列の同じ位置へclampする。失敗時は直前の内容を保持する。
- `?`はキー操作のヘルプを重ねて表示する。`q`/`<Esc>`はボードを閉じ、子画面も閉じる。一覧から開いた場合は一覧へ、直接開いた場合は元のウィンドウへ戻る。
- 項目のフィールド変更で列が変わった場合は、変更後の列の項目を選択する。追加した項目は列の末尾に置き、その項目を選択する。削除した項目の選択は次の項目、なければ前の項目、なければ列ヘッダへ移す。

### フィールド編集の画面

- `ghe`は選択項目の編集可能フィールドを一覧表示する。各行は`<name>  <current value>`とし、値がない場合は`未設定`とする。編集可能なフィールドがない場合は`No editable fields`を表示する。
- `j`/`k`でフィールドを選び、`<CR>`で編集を開く。`q`/`<Esc>`で閉じる。
- 単一選択は選択肢の画面を開く。各行は`● <name>`とし、現在値を示す。末尾に`値を解除`を置く。`<CR>`で適用、`q`/`<Esc>`で中止する。
- テキスト・数値・日付は1行入力を開く。現在値を初期値とし、`<CR>`で適用、`<C-c>`で中止する。空の入力は解除とする。
- 適用に成功したら選択肢/入力の画面を閉じ、フィールド編集の現在値を更新する。ボードはローカル状態を更新し、グループフィールドの単一選択の変更では項目を新しい列へ移し、それ以外の単一選択は同じ列に留まる。選択は項目IDで維持する。
- 適用に失敗したら選択肢/入力の画面を閉じず、理由を表示して入力を保持する。ボードは変更しない。
- ボードを閉じたらフィールド編集と子画面を閉じる。

### 追加・削除の画面

- `ghn`は`既存のIssue/PR`と`下書きIssue`の選択画面を開く。`j`/`k`で選び、`<CR>`で次へ、`q`/`<Esc>`で中止する。
- 既存項目は1行入力でURLまたは`owner/repo#number`を受け付ける。`<CR>`で追加、`<C-c>`で中止する。入力不正・解決失敗は理由を表示して入力を保持する。
- 下書きはタイトルの1行入力の後、本文の複数行入力へ進む。タイトルは`<CR>`で本文へ、`<C-c>`で流れを中止する。本文は`filetype=markdown`、`modifiable=true`とし、`<C-s>`で追加、`q`/`<Esc>`で中止する。本文は空でもよい。タイトルが空白だけなら送信しない。
- 追加に成功したら新しい項目を選択してスクロールする。重複追加は既存項目を選択し、重複を作らなかったことを案内する。一時的な競合は理由を表示し、再操作を受け付ける。現在のフィルタに一致しない項目は表示対象に加えず、追加成功とフィルタ解除の案内を表示する。
- `ghd`は選択項目の確認画面を開く。`y`で削除、`n`/`q`/`<Esc>`で中止する。削除に成功したら項目をモデルから除き、次の項目/前の項目/列ヘッダへ選択を移す。失敗時はモデルを変更せず理由を表示する。
- redacted項目は削除できるが、本文プレビュー・移動・URL操作はできない。

### プレビューとヘルプ

- プレビューは項目の種別・番号・タイトルをヘッダに表示し、本文を`filetype=gh-projects-preview`（構文はmarkdown）、`modifiable=false`で表示する。読み込み中・失敗時はヘッダに状態を表示する。`q`/`<Esc>`で閉じる。
- ヘルプは一覧・ボード・フィールド編集・追加・削除のキーを表形式で表示する。`j`/`k`/`gg`/`G`でスクロールし、`q`/`<Esc>`で閉じる。ボードは残る。

## API

外部APIは持たない。`core/float.lua`の`open(opts)`、`close(name)`、`focus(name)`、`resize_all()`、`is_open(name)`、`target_size(width_ratio, height_ratio)`、`centered(width, height)`を使う。画面固有のデータはProjects API層から受け取り、UIはghを直接呼ばない。ハイライトは`core/highlight.lua`にグループを追加する。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| floatのスタック・ジオメトリ・リサイズ・クローズ | UI基盤 | `lua/github/core/float.lua` |
| float基盤の検証 | テスト | `lua/github/core/float_spec.lua` |
| Projectsの画面の共通部品（ヘッダ、入力、確認、プレビュー、ヘルプ、描画補助、キーマップ登録） | 機能UI | `lua/github/features/projects/ui.lua` |
| Projects UIの検証 | テスト | `lua/github/features/projects/ui_spec.lua` |
| ハイライトグループの追加 | UI補助 | `lua/github/core/highlight.lua` |
| ヘルプとREADMEの更新 | docs | `doc/github.txt`, `README.md`（docs/helpの子が所有） |

画面固有の状態・操作はprojects-list、projects-board、projects-field-edit、projects-item-manageの「実装の配置」を参照する。`ui.lua`は共通部品だけを持ち、各画面のファイルを所有しない。`doc/github.txt`のProjectsの節には`*github-projects*`タグを付け、`:help github-projects`でジャンプできるようにする。

## エッジケースの決定

- 画面が小さい: 幅・高さを1以上にclampし、実効列幅を`min(max(column_width, 自動調整幅), inner_width)`とする。内側幅が1列分未満の場合は1列だけ表示する。カード幅が10未満の場合は枠線なしの1行表示にフォールバックし、タイトルを内側幅で切り詰める。
- 列数: 1列でも動く。表示列数は設定値を最小幅として計算し、実効幅を広げて余白を残さない。端ではスクロールしない。
- 空: 一覧0件、ボード0件、空の列、フィルタ0件、編集可能フィールド0件、選択項目なし。
- 長い文字列: 日本語を含むタイトルは`strdisplaywidth`で折り返す。ラベル・担当者・フィルタは表示幅を超える分を切り詰めるか`+N`でまとめる。
- カードの高さ: タイトルの折り返しでカードの高さは変動する。選択カードが表示領域より高い場合は先頭行を表示し、カーソルをタイトル行に置く。
- リサイズ: `VimResized`で再配置し、選択と列ごとの位置を保つ。子画面も中央へ再配置する。
- タブ: ボードを含むタブページが閉じられた場合、`TabClosed`でそのタブのスタックと画面状態を破棄し、以後の応答を無視する。
- 親の終了: 親のボード/一覧が閉じたら子画面を閉じる。外部で親ウィンドウが閉じられた場合も子画面を閉じる。
- 再利用: 同じ名前の画面は既存をフォーカスして再取得する。別タブの画面は操作しない。
- 入力: 挿入モードの`<CR>`/`<C-c>`、通常モードの`q`、空入力、入力中の失敗。
- エラー: 読み込み・プレビュー・ブラウザ・クリップボード・mutationの失敗。成功と断定しない。
- 並行: 古い応答、閉じた画面、別画面の更新。要求世代で破棄する。
- マウス: 独自割当をしない。既定のマウス動作は対象外。

## テスト方針

| 確かめること（タスク説明から起こした） | レベル |
| --- | --- |
| floatのスタックで一覧→ボード→フィールド編集を開き、閉じると親→前の画面→元のウィンドウへフォーカスが戻る。 | 結合 |
| 同じ名前の画面を開くと既存を再利用し、二重に開かない。 | 結合 |
| 親のボードを閉じると子画面も閉じ、無効なwindowを操作しない。 | 結合 |
| 0.10.4で幅・高さ・中央配置・`VimResized`の再配置が画面内に収まる。 | 結合 |
| 画面が小さい場合も幅・高さが1以上で、中央配置が負の座標にならない。 | 単体 |
| 列幅がウィンドウ幅に合わせて自動調整され、右側に余白が残らない。列数が表示幅を超えると横スクロールし、選択列が画面外に出ない。 | 結合 |
| 列ごとの縦位置を保持し、選択列の`j`/`k`だけがスクロールする。 | 結合 |
| 日本語を含む長いタイトルが省略されず、カード幅に合わせて複数行に折り返され、カードの高さが変動する。ラベル・担当者は列幅を超えない。 | 単体 |
| 空の列・0件のボード・フィルタ0件で、ヘッダと案内が表示され、クラッシュしない。 | 結合 |
| 一覧・ボード・フィールド編集・選択肢・入力・確認・プレビュー・ヘルプのキーマップが登録され、通常モードで動作する。 | 結合 |
| 挿入モードの`<CR>`/`<C-c>`マッピングが登録され、ヘッドレスで通常モードのコールバックを検証できる。 | 単体 |
| 列ヘッダ・選択列・選択カードの枠線/背景・番号・ラベルチップ・アバター・進捗・redacted・エラーのextmarkが正しい行/列に付く。 | 結合 |
| 色（GRAY/RED/ORANGE/YELLOW/GREEN/PINK/PURPLE/BLUE）が対応するハイライトグループへ割り当てられる。 | 単体 |
| 読み込み中・失敗・打ち切りの表示がヘッダに反映され、再取得失敗では直前の内容が残る。 | 結合 |
| 別タブのfloatを閉じたり更新したりしない。 | 結合 |

受け入れ基準は各UCの機能設計（projects-list、projects-board、projects-field-edit、projects-item-manage）に記載する。本設計は共通UIの検証条件を持つ。
