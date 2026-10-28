# 関連PRのURL確認

- 種別: 機能設計書
- 対象 UC: UC-013 (docs/design/USECASES.md)

## 何を作るか

関連PRのURL確認を実現する。UC-013のBR-051、BR-052、BR-053に従う。

## 入出力と振る舞い

`:GhGetAssociatedPullRequest <commit>`または`:GhGetAssociatedPullRequest <owner> <repo> <commit>`を受ける。commitは必須。対象hostはgithub.comのみ。3引数はgithub.comのリポジトリを指定し、Git checkout不要。1引数は操作開始時cwdのoriginからhost/owner/repoを解決し、github.com以外なら対応していないhostを案内して照会せず拒否する。関連PRの先頭1件のURLを表示し、commitなし・対象なし・エラーは区別して案内する。

## API

gh GraphQL `repository(owner:$owner,name:$repo) { object(expression:$commit) { __typename ... on Commit { associatedPullRequests(first:1) { nodes { url } } } } }`をJSON変数で送る。`object`がnullまたは`__typename`が`Commit`以外ならコミットが見つからない旨を表示する。明示repoではgitを呼ばず、github.comを照会する。GitHub/Git実行・認証はDESIGN.md「横断規約」参照。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| 関連PRのURL確認の制御・表示 | 機能 | `lua/github/features/related_pr.lua` |
| 関連PRコマンドの登録 | plugin入口 | `plugin/github_related_pr.lua` |
| 振る舞いの単体・結合検証 | テスト | `lua/github/features/related_pr_spec.lua` |

## エッジケースの決定

空: commit未指定は使用法を案内。境界: 関連PRは先頭1件、0件は該当なし。エラー: origin解決・非github.com host・commit不存在（Commit以外のobjectを含む）・権限・通信を案内する。並行: リポジトリとcwdを要求開始時に固定する。再表示: 操作ごとに対象を解決し、全repo共通の結果キャッシュを使わない。

コマンド結合テストでは`runtime plugin/github_related_pr.lua`を読み込む。setup機能の実装には依存しない。

## テスト方針

| 受け入れ基準 (docs/design/USECASES.md) | レベル |
| --- | --- |
| （US-019）owner・repo・commitを明示して実行すると、Git checkout外でもそのコミットの関連PR先頭1件のURLが表示される。 | 結合 |
| （US-019）Gitリポジトリ内でcommitだけを指定すると、操作開始時のoriginに対応するリポジトリの関連PR URLが表示される。 | 結合 |
| （US-019）コミットを指定して関連PRを照会し、コミットが存在しないか関連PRが0件だった場合は、見つからないことが表示される。 | 結合 |
| （US-019）引数が不正な状態、リポジトリを解決できない状態、または通信できない状態で関連PRを照会すると、理由が表示され、引数や対象の指定に不足がある場合は必要な指定も案内され、別リポジトリの結果は表示されない。 | 結合 |
| （US-019）コミット引数を省略して関連PRの照会を実行すると、必須のコミット指定が案内され、暗黙のHEADで照会されない。 | 結合 |
