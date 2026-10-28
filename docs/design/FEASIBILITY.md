<!-- 変更履歴 [2026-10-28]: 補完機能の除外と計画レビューの指摘を反映 -->
# github.nvim 技術検証

- 種別: 技術検証計画・結果
- 対象: 全12ユースケース（UC-012の補完機能は今回の対象外）。技術的な不確実性を下記3件に集約する。
- 作成日: 2026-10-28
- 作業領域: `/tmp/github-nvim-spec.NAIY77`

## 前提と検証範囲

Neovim向けLua、公開URIは`github://`、GitHub通信はgh、認証管理はghに委ねる。初期版はIssue操作を対象とし、Actionsとレビューの機能・設定・状態を後から同居させる境界を設計する。機能ごとの承認を省いて一括進行する利用者の指示に基づき、リスク評価と成功基準を定めた。

PoCは実現可能性を確認する。GitHubへの書き込みは行わず、公開リポジトリへの読取要求、公式仕様、ローカルの制御可能な外部コマンドを使う。実サービスへの更新・投稿・作成の動作確認は、今回のPoCの完了主張に含めない。PoCのスクリプトと結果は作業領域へ置き、コマンド・観測結果・制約を本書へ転記する。

## リスク一覧

| id | 対象 | 影響度 | 発生確率 | risk | 理由 |
| --- | --- | --- | --- | --- | --- |
| gh-api-contracts | 全GitHub通信、UC-002〜011・013 | 重大 | 中 | medium | REST/GraphQL、ページ境界、名前からIDの解決、関連PRの原本不整合をgh経由で確認する必要がある。 |
| nvim-runtime | URI、外部実行、入力保護、UC-001・002・004 | 重大 | 中 | medium | Neovim 0.10系を最低版候補にし、URIの読書き・コールバックの実行文脈・入力保護を実測する。 |
| create-terminal | Issue作成、UC-003 | 重大 | 中 | medium | ghの対話端末、本文受渡し、画面切替後の成功URL取得、失敗・二重実行の扱いが必要。 |

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
