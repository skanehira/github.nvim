# 共通基盤

- 種別: 機能設計書
- 対象 UC: なし（複数機能が使う共通実装）

## 何を作るか

GitHub/Gitの外部コマンド実行、リポジトリ文脈、URIの解析・振分け、画面と非同期要求の所有管理、floatウィンドウの共通基盤、テスト・lint・format基盤を用意する。Issue固有の入出力は各機能設計を正本とし、将来のActions・レビューも同じ境界を利用できるようにする。

## 入出力と振る舞い

- 操作文脈は`{host, owner, repo, local_repo?, cwd?}`。GitHub識別子とローカルGit/worktreeのpathは別々に保持し、呼出し時に固定する。初期版はgithub.comのみを対象とし、github:// URIとowner/repo明示指定のhostはgithub.comとする。originが別hostなら対象外として案内する。
- 外部実行は`run(argv, {cwd?, stdin?, env?, timeout?}, callback)`を境界とする。argvは文字列配列、結果は`{code, signal, stdout, stderr}`または起動エラー。callbackはNeovimメインループで1回だけ呼ぶ。実行器は注入可能とし、トークンを引数・通知・ログに出さない。
- gh adapterは対象hostを明示し、GraphQLはJSON `{query, variables}`をstdinに渡す。RESTもmethod・endpoint・JSON stdinを明示する。対象は`{host, owner?, repo?}`で、repoを持たないProjectsのowner解決・GraphQL要求も扱う。非0終了、起動失敗、JSON不正、GraphQL errorsを成功扱いしない。GraphQL errorsはメッセージを含めて返し、呼出し側が種別を判断できるようにする。HTTP 4xxは`rejected`、それ以外の終了失敗は`unknown`とし、HTTPステータスコードを`status`に保持する。`status`がない失敗は`unknown`として扱う。書込み結果が不明な場合は自動再送しない。
- float UIは`core/float.lua`で提供する。`open(opts)`は`{name, parent?, width, height, row?, col?, border?, style?, focusable?}`を受け付け、タブページごとのスタックへ積む。`close(name)`は子画面を閉じ、親→スタックの前の画面→元のウィンドウの順にフォーカスを戻す。`focus(name)`は既存画面を再利用する。`resize_all()`は`VimResized`で画面比率と中央配置を再計算する。バッファは`buftype=nofile`、`bufhidden=wipe`、`swapfile=false`、読み取り専用画面は`modifiable=false`とし、窓は`wrap=false`、`number=false`、`relativenumber=false`、`cursorline=false`、`signcolumn=no`、`foldcolumn=0`にする。
- URI parserはDESIGN.md「CLI・公開インターフェース」のowner/repoを含む形式を解析し、正の整数のIssue番号とcomment database IDを検証する。未知の区分や余分なpathを受け入れない。解析結果は`{kind, host, owner, repo, issue_number?, comment_id?}`。公開URIとGitHub URLから同じ対象を導く。owner/repoを省いた形式は別の関数で解析し、`{kind, issue_number?, comment_id?}`を返す。受けるのは`github://`の直後が`issues`か`pulls`で、続きが通常の形式と同じものだけである。通常の形式は3番目の区切りが`issues`か`pulls`であることで区別でき、両方として解析できる名前は無い (例: `github://issues/repo/issues`はowner `issues`の一覧)。
- `plugin/github.lua`は起動時に共通routerを登録し、URI処理を可能にする。routerは該当機能を操作時に遅延読込する。テストでは`runtime plugin/github.lua`で登録する。
- routerは読込時に、まずowner/repoを省いた形式として解析する。解析できたら機能へ振り分けず、そのバッファを読取り専用にする。開いた時点のcwdを固定して`git`でoriginを解決し、そのバッファを表示している全windowを同じ形式の`github://owner/repo/...`へ切り替える。切替時の代替バッファは開く前のものを保つ。解決前に利用者がバッファを離れたら、エラーも切替も行わない。解決に失敗したらエラーを表示し、空の読取り専用バッファを残す。`:edit`で再試行でき、離れると消える。
- `BufAdd`で対応するGitHub HTTPS URLのみ正規化する。既存の正規バッファがある場合は、未保存データを持つバッファを破棄せず既存バッファへの切替を試みる。安全に統合できない場合はエラーを表示し、他バッファを破棄しない。対象外URLとnetrw・他のハンドラを維持する。
- 読込・保存は対象バッファID、操作文脈、要求世代を持つ。コールバックで有効性と世代を確認する。保存開始時のchangedtickを保持し、後続編集があればmodifiedを解除しない。

## API

共通規約はDESIGN.md「GitHub API一覧」「横断規約」参照。ghを使い、GitHub認証情報を直接読まない。テストでは外界を制御可能な実行器へ置換し、実GitHubの書込みを行わない。`core/float.lua`は`open(opts)`、`close(name)`、`focus(name)`、`resize_all()`、`is_open(name)`、`target_size(width_ratio, height_ratio)`、`centered(width, height)`を返す。`open`の`opts`は`{name, parent?, width, height, row?, col?, border?, style?, focusable?, fixed_height?}`。`width`/`height`から幅・高さの比率を復元し、`VimResized`では`fixed_height=true`でない限り両軸を再計算する。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| processとgh API | 外界アダプタ | `lua/github/core/process.lua`, `lua/github/core/gh.lua` |
| repo・URI・正規化 | ドメイン/外界 | `lua/github/core/repo.lua`, `lua/github/core/uri.lua`, `lua/github/core/router.lua` |
| floatウィンドウのスタック・ジオメトリ・リサイズ | UI基盤 | `lua/github/core/float.lua` |
| URI入口の自動登録 | plugin入口 | `plugin/github.lua` |
| 要求世代・buffer所有 | 状態/UI補助 | `lua/github/core/request.lua`, `lua/github/core/buffer.lua` |
| テスト・lint・format・CIの入口 | 開発基盤 | `Makefile`, `scripts/`, `.github/workflows/`, `.gitignore`, `.worktreeinclude` |

共通モジュールの呼出し方は次のとおり。`process.run(argv, opts, callback)`は`callback(result, error)`、`gh.new(run)`は`graphql(target, query, variables, callback)`と`rest(target, method, endpoint, body, callback)`を返し、成功時はJSON、失敗時は`{target, reason, errors?, kind?, status?}`を返す。`target`は`{host, owner?, repo?, cwd?}`で、repoを持たないProjectsの要求も扱う。REST PATCHの失敗には`kind`としてHTTP 4xxの拒否を`rejected`、それ以外の終了失敗を`unknown`で返し、`status`にHTTPステータスコードを保持する。起動失敗や不正JSONも書込み側で結果不明として扱う。`gh.paginate(fetch, callback)`は各ページの`{items, pageInfo}`を終端まで集める。`repo.explicit(owner, repo)`は明示対象を生成し、`repo.resolve(cwd, run, callback)`はoriginとローカルpathを調べる。`uri.parse`と`uri.format`は対象と正規URIを相互変換する。`request.begin(buf)`と`request.apply(token, callback)`は画面と要求世代を照合する。`buffer.begin_save(buf)`は本文行とchangedtickを固定し、`buffer.finish_save(snapshot, success)`は後続編集を保護する。routerは機能の`read(buf, target)`または`write(buf, target)`を操作時に呼ぶ。`float.open(opts)`はwindowとbufferを返し、`float.close(name)`はスタックから外してバッファを破棄する。`float.focus(name)`は既存画面を再利用し、`float.resize_all()`は`VimResized`で全画面を再配置する。

テストは各Luaファイルに`*_spec.lua`を同居させる。基盤セットアップissueで実際のセットアップ・`make test`・`make test-file FILE=...`・`make lint`・`make check`を実行し、DESIGN.md「開発・検証コマンド」を実測結果で確定する。

## エッジケースの決定

- 空・最小: owner/repoや数値IDの欠落・空・0はエラー。入力の本文が空でもprocess stdinは空として渡す。floatのwidth/heightは1以上とし、parentが無効なら元のウィンドウへ戻す。
- 上限・境界: IDは正の整数。ページングは終了cursorを検査し、同一cursorの反復で無限ループしない。画面が小さい場合はfloatの幅・高さを1以上にclampし、中央配置を負の座標にしない。スタックの深さに固定上限を設けない。
- エラー: 不正なJSON、非0終了、GraphQL errors、起動失敗は対象と理由を返す。秘密情報の露出を避ける。同じ名前の画面は再利用し、親が閉じられたら子画面を閉じる。無効なwindow/bufferを操作しない。
- 並行: 複数リポジトリ・画面の要求は独立。古い応答を破棄し、保存中の追記は残す。floatのスタックはタブページごとに分け、別タブの画面を閉じたり更新したりしない。
- 再表示: 対象ごとに現在のバッファと要求世代を確認する。HTTPS正規化で既存のmodifiedバッファを上書きしない。`VimResized`で全floatを再配置し、閉じた画面を応答で再作成しない。

## テスト方針

| 確かめること（タスク説明から起こした） | レベル |
| --- | --- |
| 正当なURIと対応するHTTPS URLを開くと同じ対象が得られ、対象外のHTTPSは既存ハンドラが処理する。 | 結合 |
| 同じ対象の未保存バッファが存在するときHTTPSから開いても内容とmodified状態が維持される。 | 結合 |
| 他pluginのBufAddと複数窓がある状態で対象URIを開いても、無関係なバッファを破棄しない。 | 結合 |
| 日本語・改行・引用符を含む本文を渡すと、注入された実行器が同一のstdinと引数配列を受け取る。 | 単体 |
| 異なるリポジトリの並行要求が逆順で返っても、それぞれ元の画面だけが更新される。 | 結合 |
| 保存待ちの間に本文を追記して成功応答を受け取ると、追記が未保存として残る。 | 結合 |
| 実行エラーまたはGraphQL errorsを返した場合、成功にせず対象と理由を返す。 | 単体 |
| floatのスタックで複数画面を開き、閉じると親→前の画面→元のウィンドウへフォーカスが戻る。 | 結合 |
| 0.10.4でfloatの幅・高さ・中央配置・リサイズが画面内に収まる。 | 結合 |
| 画面が小さい場合も幅・高さが1以上で、中央配置が負の座標にならない。 | 単体 |
| 親画面を閉じると子画面も閉じ、無効なwindowを操作しない。 | 結合 |
| repoを持たないtargetでowner解決のRESTとProjectsのGraphQLを呼べる。 | 単体 |
| GraphQL errorsのメッセージを返し、成功扱いしない。 | 単体 |
| 同じ名前の画面を開くと既存を再利用し、二重に開かない。 | 結合 |
| タブを切り替えても別タブのfloatを閉じたり更新したりしない。 | 結合 |
