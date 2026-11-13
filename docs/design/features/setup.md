# 導入と初期化

- 種別: 機能設計書
- 対象 UC: UC-001 (docs/design/USECASES.md)、UC-014〜UC-017のProjects設定

## 何を作るか

UC-001の利用者操作を実現する。対象規則はBR-001, BR-002, BR-003, BR-004, BR-005。Projectsの設定（`group_by`、`column_width`、`max_items`）を検証し、既定値を適用する。認証・実行・リポジトリ文脈と非同期の共通規約はDESIGN.md「横断規約」に従う。

## 入出力と振る舞い

- `require('github').setup(opts)`は共通設定を適用し、再実行でも重複したaugroupやマッピングを作らない。初期化時にネットワーク接続や認証確認を行わない。`opts`は`nil`または空テーブル、および`projects`テーブルを受け付ける。`projects`の許容キーは`group_by`（文字列、既定`Status`）、`column_width`（整数、20〜80、既定36）、`max_items`（整数、1〜10000、既定1000）。`projects`以外のトップレベルキー、`projects`内の未知キー、不正な型・範囲外の値は、設定項目または型が未対応である理由を示して拒否し、部分的に設定を適用しない。
- `projects`を省略した場合と`projects = {}`の場合は既定値を使う。`group_by`は前後の空白を除いた1文字以上の文字列とし、空文字は拒否する。`column_width`と`max_items`は整数のみを受け付け、小数・文字列・範囲外は拒否する。
- 正規化した設定は`lua/github/core/config.lua`に保持する。Projectsの画面は新しい設定を次の取得・再描画から使い、設定変更で既存のfloat画面を強制的に閉じない。
- 起動時のURI登録と遅延ディスパッチはfoundationの`plugin/github.lua`とrouterが担当する。外部依存やActions固有の初期化は、対象機能を使う時に評価する。
- GitHub HTTPS Issue URLのBufAddによる正規化は共通URI adapterの契約を使用する。既存の同名bufferがある場合は未保存の変更を守って既存bufferへ切り替える。

正常系の操作:

| # | アクター | アクション |
| --- | --- | --- |
| 1 | 開発者 | github.nvimをNeovimへ追加する。 |
| 2 | 開発者 | 必要な設定を登録し、Neovimを起動する。設定を省略した項目には既定値を使う。 |
| 3 | github.nvim | Issue操作の入口を利用可能にする。 |
| 4 | 開発者 | `:edit github://owner/repo/issues`で対象リポジトリのIssue一覧を開く。 |
| 5 | github.nvim | このGitHub操作に必要なghの準備状況を確認する。 |
| 6 | github.nvim | ghを使って指定先へのIssue操作を開始し、UC-002の一覧表示へ進む。 |

代替フロー:

#### A: 個別の設定を省略する（ステップ2の代替）

| # | アクター | アクション |
| --- | --- | --- |
| 2a | 開発者 | 個別の設定を指定せずにgithub.nvimを読み込む。 |
| 2b | github.nvim | 既定値を使ってIssue操作の入口を利用可能にする。 |

→ ステップ4へ進む。

#### B: 準備の案内を確認してから再実行する（例外フローE1の後）

| # | アクター | アクション |
| --- | --- | --- |
| E1a | 開発者 | 案内に従ってghを導入するか、ghの認証を完了する。 |
| E1b | 開発者 | Issue一覧を開く操作を再実行する。 |

→ ステップ5へ戻る。

例外フロー:

#### E1: ghが未導入、またはGitHub操作に利用できる認証がない（ステップ5）

| # | アクター | アクション |
| --- | --- | --- |
| 5a | github.nvim | ghの導入または認証が必要であることを識別する。 |
| 5b | github.nvim | 不足する準備に応じて、ghの導入または認証の案内を表示する。 |
| 5c | 開発者 | Neovimで通常の編集を続けるか、案内された準備を行う。 |

GitHub側のリポジトリへのアクセス拒否や通信障害は、Issue取得を扱うUC-002で記述する。

## API

Neovim上の入口とgh認証の共通契約はDESIGN.md「CLI・公開インターフェース」「横断規約」を参照。`require('github').setup(opts)`は`projects`設定を検証・正規化し、`core/config.lua`へ渡す。初期化はAPIを呼ばず、操作時に必要なghの導入・認証不足を報告する。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| 公開入口 `require('github').setup` | 公開API | `lua/github/init.lua` |
| `:checkhealth github` の診断 | health | `lua/github/health.lua` |
| 設定の検証・正規化とProjects既定値 | 設定 | `lua/github/features/setup.lua` |
| 設定の保持 | 共通 | `lua/github/core/config.lua` |
| 導入と初期化の振る舞いの検証 | テスト | `lua/github/features/setup_spec.lua` |

共通URI・プロセス・repo文脈の実装はfoundation設計に属し、操作固有コードは本機能が所有する。既存の`init.lua`、`health.lua`、`setup.lua`、`setup_spec.lua`を拡張し、`core/config.lua`はProjects設定のために新規作成する。実行器・時刻・外界は注入する。

## エッジケースの決定

- 空: `setup(nil)`、`setup({})`、`setup({projects = {}})`は既定値で初期化する。
- 境界: Neovim 0.10.4以上を対象とし、実測していない0.10.0〜0.10.3を最低版に含めない。`column_width`は20〜80、`max_items`は1〜10000。`group_by`は前後の空白を除いて1文字以上。
- エラー: 未知のトップレベルキー・`projects`内の未知キー・不正な型・範囲外は、理由を表示して拒否し、既存の設定を部分的に変更しない。gh未導入・未認証でも通常のNeovim起動を妨げず、操作時に準備方法を案内する。
- 並行: setupの再実行は設定を置き換え、二重登録しない。既存のfloat画面は強制的に閉じない。
- 再表示: 既存の未保存bufferを再利用し、別窓で開いても入力を維持する。HTTPS正規化はnetrwと他pluginのBufAdd順序・複数窓を統合テストする。

## テスト方針

| 受け入れ基準 (docs/design/USECASES.md) | レベル |
| --- | --- |
| （US-001）Denops・Denoがない環境でgithub.nvimを導入してNeovimを起動すると、起動が完了し、Issue操作の入口を利用できる。 | 結合 |
| （US-001）ghが導入・認証済みの環境でIssue一覧を開くと、ghを通じて指定したリポジトリへのIssue操作を開始できる。 | 結合 |
| （US-001）ghが未導入または未認証の環境でNeovimを起動してIssue操作を試みると、通常の編集を継続できる状態で、不足する導入または認証の案内が表示される。 | 結合 |
| （US-001）Actions向けのYAML解析やTelescopeがない環境でIssue一覧を開くと、これらの導入を要求されずに一覧を利用できる。 | 結合 |

受け入れ基準に加え、`projects`設定の既定値、型・範囲・未知キーの拒否、再実行時の冪等性、既存画面を閉じないことを単体テストする。
