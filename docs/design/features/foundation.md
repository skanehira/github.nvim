# 共通基盤

- 種別: 機能設計書
- 対象 UC: なし（複数機能が使う共通実装）

## 何を作るか

GitHub/Gitの外部コマンド実行、リポジトリ文脈、URIの解析・振分け、画面と非同期要求の所有管理、テスト・lint・format基盤を用意する。Issue固有の入出力は各機能設計を正本とし、将来のActions・レビューも同じ境界を利用できるようにする。

## 入出力と振る舞い

- 操作文脈は`{host, owner, repo, local_repo?, cwd?}`。GitHub識別子とローカルGit/worktreeのpathは別々に保持し、呼出し時に固定する。初期版はgithub.comのみを対象とし、github:// URIとowner/repo明示指定のhostはgithub.comとする。originが別hostなら対象外として案内する。
- 外部実行は`run(argv, {cwd?, stdin?, env?, timeout?}, callback)`を境界とする。argvは文字列配列、結果は`{code, signal, stdout, stderr}`または起動エラー。callbackはNeovimメインループで1回だけ呼ぶ。実行器は注入可能とし、トークンを引数・通知・ログに出さない。
- gh adapterは対象hostを明示し、GraphQLはJSON `{query, variables}`をstdinに渡す。RESTもmethod・endpoint・JSON stdinを明示する。非0終了、起動失敗、JSON不正、GraphQL errorsを成功扱いしない。書込み結果が不明な場合は自動再送しない。
- URI parserはDESIGN.md「CLI・公開インターフェース」の8形式を解析し、正の整数のIssue番号とcomment database IDを検証する。未知の区分や余分なpathを受け入れない。解析結果は`{kind, host, owner, repo, issue_number?, comment_id?}`。公開URIとGitHub URLから同じ対象を導く。
- `plugin/github.lua`は起動時に共通routerを登録し、URI処理を可能にする。routerは該当機能を操作時に遅延読込する。テストでは`runtime plugin/github.lua`で登録する。
- `BufAdd`で対応するGitHub HTTPS URLのみ正規化する。既存の正規バッファがある場合は、未保存データを持つバッファを破棄せず既存バッファへの切替を試みる。安全に統合できない場合はエラーを表示し、他バッファを破棄しない。対象外URLとnetrw・他のハンドラを維持する。
- 読込・保存は対象バッファID、操作文脈、要求世代を持つ。コールバックで有効性と世代を確認する。保存開始時のchangedtickを保持し、後続編集があればmodifiedを解除しない。

## API

共通規約はDESIGN.md「GitHub API一覧」「横断規約」参照。ghを使い、GitHub認証情報を直接読まない。テストでは外界を制御可能な実行器へ置換し、実GitHubの書込みを行わない。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| processとgh API | 外界アダプタ | `lua/github/core/process.lua`, `lua/github/core/gh.lua` |
| repo・URI・正規化 | ドメイン/外界 | `lua/github/core/repo.lua`, `lua/github/core/uri.lua`, `lua/github/core/router.lua` |
| URI入口の自動登録 | plugin入口 | `plugin/github.lua` |
| 要求世代・buffer所有 | 状態/UI補助 | `lua/github/core/request.lua`, `lua/github/core/buffer.lua` |
| テスト・lint・format・CIの入口 | 開発基盤 | `Makefile`, `scripts/`, `.github/workflows/`, `.gitignore`, `.worktreeinclude` |

テストは各Luaファイルに`*_spec.lua`を同居させる。基盤セットアップissueで実際のセットアップ・`make test`・`make test-file FILE=...`・`make lint`・`make check`を実行し、DESIGN.md「開発・検証コマンド」を実測結果で確定する。

## エッジケースの決定

- 空・最小: owner/repoや数値IDの欠落・空・0はエラー。入力の本文が空でもprocess stdinは空として渡す。
- 上限・境界: IDは正の整数。ページングは終了cursorを検査し、同一cursorの反復で無限ループしない。
- エラー: 不正なJSON、非0終了、GraphQL errors、起動失敗は対象と理由を返す。秘密情報の露出を避ける。
- 並行: 複数リポジトリ・画面の要求は独立。古い応答を破棄し、保存中の追記は残す。
- 再表示: 対象ごとに現在のバッファと要求世代を確認する。HTTPS正規化で既存のmodifiedバッファを上書きしない。

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
