<!-- 変更履歴 [2026-10-28]: 補完機能の除外と計画レビューの指摘を反映 -->
<!-- 変更履歴 [2026-11-12]: Projects v2とfloatボードのPoC計画・結果を追加 -->
<!-- 変更履歴 [2026-11-13]: PR一覧の検索PoCを追加 -->
# github.nvim 技術検証

- 種別: 技術検証計画・結果
- 対象: 全17ユースケース（入力補完は今回の対象外）。技術的な不確実性を下記6件に集約する。
- 作成日: 2026-10-28
- 作業領域: `/tmp/github-nvim-spec.NAIY77`（既存のIssue検証）、`/tmp/github-nvim-projects-poc`（Projectsとfloatの検証）

## 前提と検証範囲

Neovim向けLua、公開URIは`github://`、GitHub通信はgh、認証管理はghに委ねる。初期版はIssue操作とProjects v2の閲覧・編集を対象とし、Actionsとレビューの機能・設定・状態を後から同居させる境界を設計する。機能ごとの承認を省いて一括進行する利用者の指示に基づき、リスク評価と成功基準を定めた。

PoCは実現可能性を確認する。GitHubへの書き込みは行わないことを原則とし、公開リポジトリへの読取要求、公式仕様、ローカルの制御可能な外部コマンドを使う。Projects v2の書き込み契約は、利用者の同意を得て、検証後に削除するスクラッチProjectでのみ確認した。実サービスへの更新・投稿・作成の動作確認は、今回のPoCの完了主張に含めない。PoCのスクリプトと結果は作業領域へ置き、コマンド・観測結果・制約を本書へ転記する。

## リスク一覧

| id | 対象 | 影響度 | 発生確率 | risk | 理由 |
| --- | --- | --- | --- | --- | --- |
| gh-api-contracts | 全GitHub通信、UC-002〜011・013 | 重大 | 中 | medium | REST/GraphQL、ページ境界、名前からIDの解決、関連PRの原本不整合をgh経由で確認する必要がある。 |
| nvim-runtime | URI、外部実行、入力保護、UC-001・002・004 | 重大 | 中 | medium | Neovim 0.10系を最低版候補にし、URIの読書き・コールバックの実行文脈・入力保護を実測する。 |
| create-terminal | Issue作成、UC-003 | 重大 | 中 | medium | ghの対話端末、本文受渡し、画面切替後の成功URL取得、失敗・二重実行の扱いが必要。 |
| projects-api | Projectsの読取・書込、UC-014〜017 | 重大 | 中 | medium | Projects v2のGraphQL、ページング、フィルタ、フィールド値の型、冪等性、反映遅延をgh経由で確認する必要がある。 |
| float-board | float UI、UC-014〜017 | 重大 | 中 | medium | Neovim 0.10.4のfloatで可変高さのカンバン、列ごとのスクロール、入力・確認・プレビューを実現する必要がある。 |
| pulls-search | PR一覧、UC-018 | 中 | 低 | low | GraphQL searchのtype:pr、Issue一覧の基盤再利用、30件上限、0件・失敗時の扱いをgh経由で確認する。 |

## PoC計画

### PoC: gh経由のGitHub API契約
<!-- POC_STATUS: id=gh-api-contracts, blocker=true, status=verified, confidence=0.82 -->

**id**: gh-api-contracts
**目的**: ghからREST・GraphQLを呼び、必要な読取・更新ペイロードの契約とリポジトリの固定方法を確かめる。
**risk**: medium
**blocker**: true

**スコープ**:
- 含む: 実ghの読取API実行、検索・Issue詳細・コメント・テンプレート・属性候補・関連PR、JSON入力のローカル検証、公式仕様。
- 含まない: 実GitHubへの作成・更新・投稿、認証情報ファイルの読取、トークンや私的データの出力。

**実装内容**:
1. 公式CLI/API資料と移植元の要求を照合する。
2. 公開リポジトリに実ghでREST・GraphQLの読取要求を実行する。
3. 更新契約は公式仕様とローカルのJSONペイロード・引数・stdin検査で確認する。
4. 誤ったレスポンスを成功と判定しない対照を置く。

**成功基準**:
- 実ghでRESTとGraphQLの双方から、JSONを取得・解析できる。
- Issueのコメント総数、ラベル・担当者の取得、テンプレート、担当者・ラベルの検証に必要な候補を取得する契約が明らかになる。
- コメント単体取得と数値ID、所属Issueの確認に使うフィールド、関連PRの0件/ありの扱いを確認できる。
- ラベル・担当者の現在集合を欠けなく取得するためのページ情報と内部ページングを検証できる。
- リポジトリ・ホストを明示でき、JSON本文をシェル連結せずに渡す方式が定まる。
- 未確認の実書込を検証済みとせず、実装時の検証対象として区別する。

**失敗時の代替案**: 同じghのRESTとGraphQLの役割分担を変える。必要なら取得形状を小さくし、内部ページングで補完する。

### PoC: NeovimのURI・非同期処理
<!-- POC_STATUS: id=nvim-runtime, blocker=true, status=verified, confidence=0.85 -->

**id**: nvim-runtime
**目的**: 最低版候補のNeovim 0.10系でgithub://とHTTPS入口の読書き、非同期プロセスと入力保護の成立を確かめる。
**risk**: medium
**blocker**: true

**スコープ**:
- 含む: 隔離したNeovim、最小Luaスクリプト、必要なら公式配布の0.10系バイナリ、ローカルの制御可能な実行対象。
- 含まない: 利用者のNeovim設定の変更、プラグインの本実装、外部への書込。

**実装内容**:
1. BufReadCmd・BufWriteCmdでgithub://バッファを開いて保存し、対応するGitHubのHTTPS URLからも同じ対象を開く最小コードを実行する。
2. `vim.system`の引数・stdin・終了結果・scheduleと、編集対象の所有を検査する。
3. 保存中の追記と、検索条件を続けて変更したときの古い応答破棄を検査する。

**成功基準**:
- 実測したNeovimのパッチ版を記録し、その版でURIの読込・保存と日本語/改行を含む本文が扱える。実測版より古い版を保証したことにしない。
- callbackからUIを更新でき、古い応答・別バッファ・保存中の追記を区別できる。
- github://とHTTPS入口が同じ対象へ到達し、標準設定から隔離して検証できる。
- 保存中の追記が成功応答で消えず、古い検索応答を現在の結果へ反映しないことを対照つきで検査できる。

**失敗時の代替案**: 標準APIの呼出方法を変える。最低版を上げる判断が必要なら、その実測理由を残す。

### PoC: 対話端末によるIssue作成の制御
<!-- POC_STATUS: id=create-terminal, blocker=true, status=verified, confidence=0.85 -->

**id**: create-terminal
**目的**: ghの対話作成をNeovim端末で実行し、本文・対象・完了結果を処理元のバッファに結び付けられることを確かめる。
**risk**: medium
**blocker**: true

**スコープ**:
- 含む: 実Neovimの端末、ローカルの制御可能なgh代替、公式`gh issue create`のオプション、成功/失敗/結果未確認の再現。
- 含まない: 実GitHubのIssue作成、利用者の通常設定・クリップボードの変更。

**実装内容**:
1. 本文を一時ファイルで渡し、repoを明示して対話処理を起動する。
2. 処理中に現在バッファを変更し、端末の終了結果とURLを元の端末から取得する。
3. キャンセル・失敗・URL欠落、追加保存の制御を検査する。

**成功基準**:
- 本文・repoを引数配列と一時ファイルで正しく渡せる。
- current bufferが変わっても、所有する端末から成功URLを取得できる。
- 成功、失敗、結果未確認を識別し、失敗時に本文を残せる。
- 処理中の追加保存は追加の作成起動にならない。
- 対話の再現は代替プロセスであることを明示し、実ghの作成成功とは報告しない。

**失敗時の代替案**: 端末完了の取得方法を変える。対話操作の保持を前提とし、API直接作成への仕様変更を黙って採用しない。

### PoC: Projects v2のAPI契約
<!-- POC_STATUS: id=projects-api, blocker=true, status=verified, confidence=0.85 -->

**id**: projects-api
**目的**: gh経由でProjects v2の一覧・ボード・項目編集・追加・削除のAPI契約と、ページング・フィルタ・エラーの扱いを確かめる。
**risk**: medium
**blocker**: true

**スコープ**:
- 含む: 実ghのGraphQL/REST、ユーザー/OrgのProject一覧、Projectのフィールド・ビュー・項目、フィルタ、アーカイブ状態、100件ページング、単一選択・テキスト・数値・日付の更新と解除、項目の追加・削除、破棄前提のスクラッチProject。
- 含まない: 利用者の既存Projectの変更、Project・フィールド自体の作成/削除、複数選択・イテレーション、実装コードの作成。

**実装内容**:
1. スクラッチProjectを作成し、実Issue/PRと下書きIssueを追加する。
2. Project一覧・フィールド・ビュー・項目を取得し、ページングとフィルタを実行する。
3. 単一選択・テキスト・数値・日付の設定・解除、項目の追加・削除を実行し、応答と読み戻しを確認する。
4. 不正な値・存在しない対象・権限不足・一時的な競合のエラーを記録する。
5. 検証後にスクラッチProjectを削除する。

**成功基準**:
- ユーザーとOrgのProject一覧、Projectのフィールド・ビュー・項目を取得できる。
- 100件単位のページングで全項目を取得でき、フィルタとアーカイブ状態の指定が反映される。
- 単一選択・テキスト・数値・日付の設定と解除、項目の追加・削除が成功し、応答からローカル状態を更新できる。
- エラーの種類（入力不正・対象なし・権限・一時的な競合）を区別できる。
- スクラッチProjectを削除し、利用者の既存データを変更していない。

**失敗時の代替案**: 書き込みを`gh project`サブコマンドへ切り替える、または読み取り専用の範囲に縮小する。書き込みが成立しない場合は、フィールド編集・追加・削除を初期版の対象外とする判断を利用者に求める。

### PoC: floatウィンドウのカンバン描画
<!-- POC_STATUS: id=float-board, blocker=true, status=verified, confidence=0.85 -->

**id**: float-board
**目的**: Neovim 0.10.4で、可変高さの項目カード、列ごとの縦スクロール、横スクロール、選択・強調、入力・確認・プレビュー・ヘルプのfloat画面が成立することを確かめる。
**risk**: medium
**blocker**: true

**スコープ**:
- 含む: 隔離したNeovim 0.10.4と0.13、`nvim_open_win`のfloat、固定列幅のカンバン、列ごとの表示位置、extmark、カーソル、ウィンドウスタック、リサイズ、閉じた後のバッファ破棄、1行入力・確認・プレビュー・ヘルプのfloat。
- 含まない: 実装コードの作成、実GitHub通信、マウス操作、挿入モードの実UI操作（ヘッドレスでは検証できないため、マッピングの登録と通常モードの操作を確認する）。

**実装内容**:
1. 0.10.4と0.13で、固定列幅・可変高さのカードを並べたfloatを描画する。
2. 列ごとの縦位置、横スクロール、選択項目のカーソルとextmarkを検証する。
3. 複数floatのスタック、親への復帰、リサイズ、閉じた後のバッファ破棄を検証する。
4. 1行入力・確認・プレビュー・ヘルプのfloatとキーマップを検証する。
5. 日本語の表示幅と切り詰め、描画時間を測定する。

**成功基準**:
- 0.10.4で、列幅固定のカンバン、列ごとの縦スクロール、横スクロール、選択の強調が表示できる。
- 項目数が多い場合も実用的な時間で再描画できる。
- floatのスタック、親への復帰、リサイズ、閉じた後のバッファ破棄が成立する。
- 1行入力・確認・プレビュー・ヘルプのfloatがキー操作で成立する。
- 日本語を含むタイトルの表示幅を超えないように切り詰められる。
- ヘッドレスで検証できない挿入モードの実操作を、検証済みと報告しない。

**失敗時の代替案**: 通常の分割ウィンドウ + 一時バッファへ変更する。または、列幅を固定せず1列ずつ表示する。0.10.4で成立しないAPIがあれば、最低版の引き上げを利用者に相談する。

### PoC: PR一覧の検索
<!-- POC_STATUS: id=pulls-search, blocker=false, status=verified, confidence=0.85 -->

**id**: pulls-search
**目的**: GraphQL `search`の`type:pr`でPRの検索と必要な項目を取得できることを確かめる。
**risk**: low
**blocker**: false

**スコープ**:
- 含む: 公開リポジトリのPR検索、`number`/`title`/`state`/`body`/`url`/`repository`/`comments`/`assignees`/`labels`の取得、30件上限、0件の扱い。
- 含まない: PRの作成・編集・レビュー・マージ・コメント投稿、実GitHubへの書込み。

**実装内容**:
1. `gh api graphql`で`search(type:ISSUE, query:"repo:... type:pr state:open", first:30)`を実行する。
2. `PullRequest`の`number`/`title`/`state`/`body`/`url`/`repository`/`comments`/`assignees`/`labels`を取得する。
3. 0件と30件超の扱いを確認する。

**成功基準**:
- 実ghで`type:pr`の検索結果と必要なフィールドを取得できる。
- 0件を成功結果として扱い、30件を超える場合は先頭30件を表示する方針が定まる。
- PRの作成・編集・レビューのmutationを呼ばない。

**失敗時の代替案**: REST `search/issues`の`type:pr`へ切り替える。

## PoC 結果

各計画の実行結果を以下に記録する。

### gh-api-contracts — verified (confidence 0.82)
- 検証日: 2026-10-28
- 観測した事実: `python3 /tmp/github-nvim-spec.NAIY77/poc-gh-api-contracts/poc.py` exit 0。実ghでREST・GraphQL読取、ラベル4ページ、ユーザー候補2ページ、コメント所属、関連PRあり/なし、更新スキーマを確認。無効GraphQLはexit 1。
- 結論: 読取・入力契約は成功基準を満たす。複数担当者を持つ実Issueと実GitHub書込は未検証。
- 推奨アプローチ: gh apiに--hostnameを明示し、owner/repoを固定したRESTパスまたはGraphQL変数を引数配列とJSON stdinで渡す。Issueのlabel・assignee接続をそれぞれpageInfo/endCursorで最後まで走査し、更新対象の完全な集合を得る。コメント単体のissue_urlを指定Issueと照合し、関連PRはassociatedPullRequests(first:1)のnodesを検査する。更新の本番動作は実装時に別途検証する。
- 参照: https://cli.github.com/manual/gh_api 、https://docs.github.com/en/rest/issues/comments 、https://docs.github.com/en/graphql/reference

### create-terminal — verified (confidence 0.85)
- 検証日: 2026-10-28
- 観測した事実: Neovim 0.10.4および0.13 nightlyで実端末とローカル代替ghを使い、成功・失敗・URL欠落・非0終了とURLの組合せ、バッファ切替、追記、二重起動を検証。対照のガード無効化では失敗を検出した。実GitHub書込みは未実施。
- 結論: 成功基準を満たす。ghはIssue作成済みでも添付失敗時に非0終了する場合があり、結果を未作成と断定しない。
- 推奨アプローチ: gh issue createに-F本文一時ファイルと-R明示リポジトリを引数配列で渡す。端末バッファIDと本文バッファIDとchangedtickを保持し、終了後に所有する端末からURLを取得する。作成中は追加起動を抑止し、追記があれば成功後も本文を保持する。非0またはURL欠落は結果を確認してから再操作する。
- 参照: https://cli.github.com/manual/gh_issue_create 、https://github.com/neovim/neovim/blob/master/runtime/doc/terminal.txt

### nvim-runtime — verified (confidence 0.85)
- 検証日: 2026-10-28
- 観測した事実: Neovim 0.10.4でURI読書き、UTF-8 stdin、非同期応答、追記保護、古い応答の破棄を実行。対照を壊すと失敗。--cleanでnetrw競合を再現し、BufAddで対象URLを正規化する方法を実測。既存バッファの衝突時に未保存内容を保って再利用できた。
- 結論: 計画の成功基準を満たす。0.10.0〜0.10.3、他pluginのautocmd順序・複数窓・全URI形式は未検証。
- 推奨アプローチ: Neovim 0.10.4以上を実測済みの候補とし、github://のBufReadCmd/BufWriteCmd、vim.systemの引数配列・stdin・schedule_wrap、バッファIDとchangedtick、画面単位の要求世代を使う。HTTPS入口は標準netrwのhandlerを置換せず、BufAddで対象のGitHub Issue URLだけをgithub://へ正規化する。既存の同名バッファがある場合は新規の空バッファから既存バッファへ切替える。未保存データを持つバッファを破棄しないこと、他pluginとのautocmd順序・複数窓・全URI形式は実装時の統合テストで確認する。0.10.0〜0.10.3は未確認。
- 参照: https://github.com/neovim/neovim/blob/v0.10.4/runtime/doc/autocmd.txt 、https://github.com/neovim/neovim/blob/v0.10.4/runtime/doc/lua.txt

### projects-api — verified (confidence 0.85)
- 検証日: 2026-11-12
- 観測した事実: gh 2.103.3。スクラッチProject #10を作成し、Issue #27、PR #43、下書きIssueを追加。テキスト・数値・日付・単一選択の設定と解除、項目の削除を実行し、検証後にProject #10を削除した。ユーザーとOrgのProject一覧を取得し、存在しないownerを同時に指定するとクエリ全体が失敗することを確認。reedot/kintaily Project #2は274項目、3つのBOARD_LAYOUTビューとフィルタ文字列を持ち、`groupByFields`は0件だった。`items`は100件/pageで3ページ、約2.8秒で274件。GraphQLコストは1回1ポイント。`query`フィルタはサーバ側で適用され、`-status:完了`で45/46件、無効なフィルタはエラーではなく0件を返した。`archivedStates`は反映遅延があり、解除直後は同じ結果になることがあった。テキスト・数値・日付・単一選択の設定は成功し、読み戻しで対応する値と`field{name}`を確認。型が違う値はGraphQLのVALIDATIONエラーになった。`addProjectV2ItemById`は冪等で、初回に一時的な競合エラーが返り、再実行で成功した。`deleteProjectV2Item`と`updateProjectV2ItemPosition`（afterIdなしで先頭）を確認。項目の`content`はIssue/PR/DraftIssue/REDACTEDのunion。フィールドは`dataType`で判別でき、`isIssueField`はすべてfalseだった。
- 結論: 成功基準を満たす。ownerはユーザーとOrgに分けて解決し、ページングとフィルタをサーバ側で行い、書き込みは冪等性と一時的な競合を前提にする。読み取りの反映遅延があるため、書き込み後の自動再取得はせず、利用者の再取得を正とする。
- 推奨アプローチ: `gh api graphql --input -`にJSONをstdinで渡し、`ProjectV2FieldValue`を型に合わせて組み立てる。`items`は100件/pageで`pageInfo`を辿り、`max_items`で打ち切る。ownerはREST `user`/`users/<login>`で種別を確認する。フィルタの0件と取得エラーを区別する。書き込み後はmutationの応答でローカル状態を更新し、自動再送しない。
- 参照: https://docs.github.com/en/issues/planning-and-tracking-with-projects/understanding-fields 、https://docs.github.com/en/graphql/reference/objects#projectv2 、https://cli.github.com/manual/gh_project

### float-board — verified (confidence 0.85)
- 検証日: 2026-11-12
- 観測した事実: Neovim 0.10.4と0.13で、`nvim_open_win`の`relative=editor`、`style=minimal`、`border=rounded`のfloatを描画。0.10.4の`nvim_win_get_config`は`style`を返さないが、表示は成立。`title`は両方で使えるが、ハイライトの扱いが異なるため、ヘッダはバッファ行で描く。固定列幅20、可変高さ1〜4行、5列×200項目のカンバンを描画し、列ごとの縦位置、横スクロール、選択項目のカーソルとextmarkが成立。100フレームの描画は約12ms（0.10.4/0.13とも）。日本語の表示幅は`strdisplaywidth`で計算し、`...`付きの切り詰めが成立。複数floatのスタック、親ウィンドウへの復帰、`VimResized`の自動コマンド、`nvim_win_set_config`によるリサイズ、`bufhidden=wipe`によるバッファ破棄が成立。1行入力・確認・プレビュー・ヘルプのfloatと通常モードのキーマップが成立。ヘッドレスでは`startinsert`が挿入モードへ入らないため、挿入モードの実操作は未検証。挿入モードの`<CR>`マッピングは登録を確認。ヘッドレスのUIサイズは80×24で、実UIの比率・中央配置は`vim.o.columns`/`lines`から計算する。
- 結論: 成功基準を満たす。0.10.4でカンバンと入力系floatが成立する。挿入モードの実操作は実装時の統合テストで確認する。
- 推奨アプローチ: `core/float.lua`にスタック・ジオメトリ・リサイズ・クローズを集約し、ボードは固定列幅と列ごとの表示位置を持つ。描画はバッファ行とextmarkで行い、カーソルは選択項目の先頭行に置く。`VimResized`で再配置し、`bufhidden=wipe`で閉じたバッファを破棄する。ヘッドレスでは挿入モードを検証できないため、マッピング登録と通常モードの操作をテストし、実UIの確認を統合テストに残す。
- 参照: https://github.com/neovim/neovim/blob/v0.10.4/runtime/doc/api.txt 、https://github.com/skanehira/google-calendar.nvim/blob/53645a6ce448e0da9d7ca0d6a4ce412ac52cea9a/lua/google-calendar/ui/window.lua

### pulls-search — verified (confidence 0.85)
- 検証日: 2026-11-13
- 観測した事実: gh 2.103.3。`gh api graphql`で`repo:skanehira/github.nvim type:pr state:open`は0件、`repo:cli/cli type:pr state:open`は`issueCount:56`、先頭5件を取得。`number`、`title`、`state`、`body`、`url`、`repository.nameWithOwner`、`comments`、`assignees`、`labels`（totalCount付き）を確認。`isDraft`、`reviewDecision`、`author`も取得できるが、本機能の表示には使わない。`first:5`で5件、30件上限の指定が成立。PRの作成・編集・レビューのmutationは呼んでいない。
- 結論: 成功基準を満たす。0件は成功結果、30件を超える場合は先頭30件を表示する。`search`の`PullRequest`で必要なフィールドを取得できる。
- 推奨アプローチ: `search(first:30,type:ISSUE,query:"repo:... type:pr state:open")`で`repository`、`number`、`title`、`state`、`body`、`url`、`comments.totalCount`、`assignees`、`labels`を取得する。担当者・ラベルは`node(id:){... on PullRequest{...}}`でページングする。本文プレビューは検索で取得済みの`body`を使う。PRの作成・編集・レビューは呼ばない。
- 参照: https://docs.github.com/en/graphql/reference/queries#search 、https://docs.github.com/en/graphql/reference/objects#pullrequest 、https://cli.github.com/manual/gh_search_prs
