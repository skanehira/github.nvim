# denops-gh.vim 移植対応表

- 種別: 調査・実装対応表
- 比較基準: denops-gh.vim `989f2d1ebf7d414ad8aa4d415a326caca836d30a`
- 確認日: 2026-10-29
- 対象: 補完を除く実装済み機能、画面、キー操作、公開インターフェース。
- 正本: 元の `denops/gh/action_issue.ts`、`autoload/gh.vim`、`buffer.ts`、`main.ts`、`doc/gh.txt` とLua版のコード。元のREADMEにあるTODOを実装済み機能として扱わない。

## 操作単位の比較

| 操作 | 移植元 | Lua版・確認方法 |
| --- | --- | --- |
| Issue一覧・検索 | `action_issue.ts` のlist/search、`github/issue.ts` | `features/issues/list.lua`。URI、対象repo、最大30件、検索、0件、失敗時の保持を`list_spec.lua`で確認。 |
| Issue作成 | テンプレート、本文、gh対話端末、成功後の操作 | `features/issues/create.lua`。実Neovim terminal＋fake ghで対象repo、本文、二重送信抑止、結果判定を`create_spec.lua`で確認。 |
| タイトル・本文編集 | `issues:edit/update`、`issues:edit:title/update:title` | `features/issues/edit.lua`。更新項目の分離、空タイトル拒否、未保存保護を`edit_spec.lua`で確認。 |
| 状態変更 | `issues:open/close` | `features/issues/state.lua`。単体／複数・部分失敗・結果未確認・再取得を`state_spec.lua`で確認。 |
| 担当者・ラベル | 一覧取得、入力、集合置換、空入力の全解除 | `features/issues/attributes.lua`。属性と候補の全ページ取得、失敗時の保護を`attributes_spec.lua`で確認。 |
| コメント一覧・プレビュー | `comments:list/preview` | `features/comments/list.lua`と`core/view.lua`。100件上限、本文全文、削除済み投稿者を`list_spec.lua`で確認。 |
| コメント投稿 | `comments:new/create` | `features/comments/create.lua`。対象、空本文、二重保存、保存中追記、成功後の一覧更新を`create_spec.lua`で確認。 |
| コメント編集 | `comments:edit/update` | `features/comments/edit.lua`。所属検証、PATCH、失敗・不明時の入力保持を`edit_spec.lua`で確認。 |
| ブラウザ起動 | Issue／コメントの単体・複数URL | `features/links/open.lua`。操作時点の対象固定と対象別の失敗を`open_spec.lua`で確認。 |
| URLコピー | Issue／コメント・作成後URL | `features/links/copy.lua`。順序、改行、対象なし、provider不在、結果未確認を`copy_spec.lua`で確認。 |
| 関連PR | `GhGetAssociatedPullRequest` | `features/related_pr.lua`。commitのみ／owner repo commit、該当なし、明示repoとcwdの分離を`related_pr_spec.lua`で確認。 |
| 導入・依存 | Denops登録、ghの設定読込み | Luaプラグイン読込み、任意setup、checkhealth。認証はgh管理。`setup_spec.lua`で確認。 |

## 検出した欠落と修正

元コードのパスは[固定コミットのツリー](https://github.com/skanehira/denops-gh.vim/tree/989f2d1ebf7d414ad8aa4d415a326caca836d30a)を基準とする。

| ID | 欠落・差分 | 元の根拠 | 修正と回帰検証 |
| --- | --- | --- | --- |
| P01 | 列揃え、日本語幅、コンパクトな列順 | `action_issue.ts:282-305`、`utils/formatter.ts` | `core/rows.lua`で番号・タイトル・状態・@担当者・(ラベル)・コメント総数を整列。`rows_spec.lua`とIssue一覧結合テスト。 |
| P02 | 長いタイトルと属性の表示制限 | `action_issue.ts:285-299` | 表示幅100超を省略、先頭2担当者・3ラベル。内部の全データを維持。UTF-8、幅境界、入力非変更を`rows_spec.lua`で検証。 |
| P03 | コメントの@投稿者・列揃え | `action_issue.ts:319-325` | `core/rows.lua`で投稿者列を整列し、本文先頭行を表示。日本語・削除済み・CRLFを検証。 |
| P04 | 番号・状態・担当者・ラベル・投稿者のハイライト | `autoload/gh.vim:5-29`、`syntax/gh-issues*.vim` | `core/highlight.lua`と表示範囲。実バッファの範囲、選択、再描画時の除去、カラースキーム変更を検証。 |
| P05 | プレビューの再利用・フォーカス・Markdown・q | `action_issue.ts:989-1034` | `core/view.lua`。同タブ内の共有窓を更新し一覧のフォーカスを維持。別タブ・連続更新・qを`view_spec.lua`で実入力検証。 |
| P06 | 下端1行の検索バッファ | `autoload/gh.vim:193-234` | `core/view.lua`。Enterで適用、q/C-cで中止、空／同一条件は送信しない。複数窓・別タブでも最後の呼出窓へ戻り、再利用時は復帰先とcallbackを更新する。確定時に最新の成功条件と比較し、閉じた一覧への適用を防止。 |
| P07 | 開き方の選択 | `autoload/gh.vim:112-174,236-275` | 本文・属性・コメント一覧／投稿／編集でedit/new/vnew/tabnewを選択。`navigation_spec.lua`と`parity_spec.lua`で実窓・対象を検証。 |
| P08 | Issue新規作成時の横分割 | `action_issue.ts:210-214` | 一覧のghnでnewを使用し一覧を残す。Issue作成結合テスト。 |
| P09 | タイトルの1行窓と保存後の終了 | `action_issue.ts:947-986` | Issueごとに独立した1行窓を再利用。成功後に閉じ、送信後追記があれば残す。`parity_spec.lua`と`edit_spec.lua`。 |
| P10 | Issue本文からght/ghm/gha/ghl | `action_issue.ts:77-114` | 本文targetでタイトル・コメント・担当者・ラベルへ遷移。未保存本文を残す横分割と旧Plugの再マップを`parity_spec.lua`で検証。 |
| P11 | 公開Plugマッピング | `mapping.ts`、`doc/gh.txt:234-331` | `core/navigation.lua`を通じ旧`<Plug>(gh:issue:...)`名を登録し既定キーへ割当。全公開名は`doc/github.txt`。 |
| P12 | 仮想バッファの表示設定 | `buffer.ts:125-128`、`main.ts:62` | nolist・nonumber・nowrap・cursorline・bufhidden=hide・noswapfile。プラグインが開いた窓から通常バッファへ戻る際に、元の窓設定を復元。標準/APIの分割ではNeovimの設定継承を維持し、他プラグインの通常窓設定を上書きしない。`navigation_spec.lua`。 |
| P13 | 一覧・担当者のfiletype | `action_issue.ts:166,521-523,768` | gh-issues、gh-issues-comments、gh-issues-assignees。本文とpreviewはmarkdown、検索はissue-search。 |
| P14 | 公開Userイベント | `action_issue.ts:114,377,541,625,706,882`、`autoload/gh.vim:229` | gh_open_issue、gh_open_issue_assignees、gh_open_issue_labels、gh_open_issue_comment、gh_open_issue_searchを対象バッファの文脈で発火。`parity_spec.lua`と`view_spec.lua`。 |
| P15 | コピー／ブラウザ後の選択解除 | `autoload/gh.vim:177-190`、`action_issue.ts:433-447,914-928` | 操作対象を固定してから元一覧の選択を解除・再描画。失敗時も次操作へ選択を残さない。Issueとコメントの両経路を`parity_spec.lua`で検証。 |
| P16 | CRLF本文の正規化 | `github/issue.ts:119-121,145-148`、`action_issue.ts:687,1024` | Issue・コメント編集、preview、テンプレート本文をLFへ正規化。実URIから本文を検証。 |
| P17 | 未変更バッファの不要な更新 | `action_issue.ts:122,552,636,717` | 既存編集バッファの未変更保存でmutation/PATCHを送らない。取得済みの古い本文での意図しない上書きを防止。`parity_spec.lua`。 |
| P18 | 担当者名の大文字小文字・上限 | `github/user.ts:48-68`、`action_issue.ts:562-565` | loginを大文字小文字を区別せず照合・重複除去。10名超は送信前に案内して入力保持。ラベル名は従来どおり。`parity_spec.lua`。 |
| P19 | 取得・保存の進行表示 | `utils/helper.ts:124-136` | `core/progress.lua`。状態変更を含め対象バッファにLoading/Savingを表示し古い要求で新表示を消さない。`progress_spec.lua`と各操作の結合テスト。 |
| P20 | 配布ライセンスとNeovim help | `LICENSE`、`doc/gh.txt` | 元のMITライセンスを保持。`doc/github.txt`に全URI・キー・Plug・Userイベント・制約を記載。helptags生成とhelpジャンプを実Neovimで確認。 |
| P21 | テンプレートとBlankの順序 | `action_issue.ts:347` | 取得したテンプレートの順序を保持し、末尾にBlankを配置。Issue作成テスト。 |

## 維持する差分

| 差分 | 理由・扱い |
| --- | --- |
| URIはgithub:// | 利用者の明示指定。gh://は公開しない。対応GitHub HTTPS URLは正規化する。 |
| Lua/Neovimとgh CLI | 利用者の移植先・API実行方法の指定。認証ファイルを直接読まない。 |
| 補完なし | 利用者の明示除外。UserイベントとPlugは補完以外のカスタマイズにも使えるため保持。 |
| メニューはvim.ui.select | 開き方・テンプレート・作成後操作の選択肢は保持する。元の専用float／単一文字入力から、NeovimのUI providerに従うメニューに統合する。 |
| 標準/APIの新規分割 | 元と同じNeovim標準の窓設定継承に従う。github.nvimが開く窓は元の通常設定を個別に保存・復元するが、他プラグインの窓を管理するグローバルなWinNewフックは設置しない。 |
| 選択印は固定幅の行頭記号 | 元のsign columnから本文の固定2桁に変更。列位置と選択操作は維持し、gh_selectで色を付ける。 |
| C-kは現在行をトグル後に前行へ | 設計済みの選択契約。元の「前行移動後に選択」には戻さない。 |
| コメント総数はtotalCount | 元の取得済みコメント配列の長さによる過少表示を再現しない。 |
| 属性は全ページ取得 | 元の担当者10件・ラベル20件の読込み制限で集合を欠損させない。表示上限と保存対象の全データを分離。 |
| titleは表示幅で切る | 元のstringWidth判定後のJS sliceによる日本語・UTF-16の途中切断を再現しない。 |
| 0件の表示、URIとコメント所属の厳密検証 | 元の行残留、不正なパス受理、所属未確認を再現しない。 |
| 非同期要求・未保存入力を保護 | 保存中追記・古い応答・閉じたバッファ・二重送信への対処を維持。 |
| 空Issue本文を保存可能 | 合意済み。タイトルとコメントの空白入力拒否は維持。 |
| コピーの完了を断定しない | 利用者承認済み。providerから完了を確認できない場合は要求件数と結果未確認を案内。 |
| 作成の非0終了でも未作成と断定しない | ghが作成済みでも添付等で失敗しうるため、URLと結果不明を案内し自動再送しない。 |
| Pulls/README/files/Gist/Actions、コメント削除、画面ページ送りなし | 元ではTODOまたは未実装。将来のActions・レビュー統合の対象を今回へ追加しない。 |

## 検証と限界

現行Neovimと最低対応版0.10.4の双方で181シナリオが成功。`make lint`・`make check`、pluginファイルの追加lint/format検査は成功し、警告0件。helpタグ生成と公開タグへのジャンプ、受け入れ基準の被覆、差分の空白検査も成功した。

`make test`、`make lint`、`make check`とNeovim 0.10.4での結合テストを実行する。さらに実GitHubの`skanehira/github.nvim`に対し、実URI→検索1行バッファ→`state:closed`確定→27件の表示→`K`の反復を読み取り専用で確認した。この実行ではハイライト範囲81件、プレビュー窓の再利用、一覧フォーカスの維持を確認した。Neovimの実バッファ・窓・キー・イベント・extmarkを検証し、自動テストのGitHub通信・ブラウザ・クリップボードproviderは注入した実行器やfakeを使う。Issue作成は実Neovim terminal＋fake ghを含む。実GitHubへのIssue・コメントの作成や更新、実ブラウザ起動・実クリップボード変更は検証で行わない。画像による視覚比較と移植元Denopsの実行比較は未実施であり、元ソースとの静的比較とLua版の実動作検証を区別する。
