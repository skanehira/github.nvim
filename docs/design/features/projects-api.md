# Projects v2のAPI層

- 種別: 機能設計書
- 対象 UC: なし（Projectsの共通API）
- 対象ストーリー: US-020〜US-023

## 何を作るか

Projects v2のowner解決、Project一覧、Projectのフィールド・ビュー・項目の取得、項目のフィールド更新・解除、項目の追加・削除をgh経由で提供する。対象規則はBR-054〜BR-084。認証・実行・リポジトリ文脈と非同期の共通規約はDESIGN.md「横断規約」、gh adapterの契約はfoundation設計に従う。

## 入出力と振る舞い

### 対象とowner解決

- 対象は`{host, owner, type}`。hostはgithub.comとする。
- `:GitHub projects`でownerを省略した場合、REST `user`で認証済みユーザーの`login`と`type`を取得する。`@me`も同じ扱いにする。
- ownerを指定した場合、REST `users/{login}`で`login`と`type`を取得する。`type`は`User`または`Organization`。
- ユーザーとOrgは別のクエリで解決する。1つのクエリで`user(login:)`と`organization(login:)`の両方を指定すると、存在しない側でクエリ全体が失敗するため、種別を先に確定してから片方だけを問い合わせる。
- ownerの形式は英数字とハイフンとし、空・空白・`/`を含む値は拒否する。GitHubが返した`login`を以後の識別に使う。
- ownerが存在しない、またはアクセスできない場合は`not_found`または`forbidden`として理由を返す。

### Project一覧

- 確定した種別に応じて`user(login:)`または`organization(login:)`の`projectsV2(first:100, after:)`を取得する。`pageInfo`を辿り、開いているProjectが100件になるまで取得する（最大10ページ）。
- 取得する項目は`id`、`number`、`title`、`items.totalCount`、`public`、`closed`、`url`、接続の`totalCount`、`pageInfo{hasNextPage, endCursor}`。
- `closed`が真のProjectは一覧から除く。開いているProjectだけを返す。
- 開いているProjectが100件に達し、まだ`hasNextPage`が真、または10ページに達した場合は、打ち切ったことを示す`truncated`を付ける。一覧のページ送りは対象外（再実行で先頭から取り直す）。
- 0件は空配列として返し、エラーにしない。

### Project詳細

- `projectV2(number:)`から`id`、`number`、`title`、`url`、`public`、`closed`、`items.totalCount`を取得する。
- `fields(first:50)`から`__typename`、`id`、`name`、`dataType`、単一選択フィールドの`options {id, name, color}`を取得する。フィールドは先頭50件までとし、超えるProjectでは後続のフィールドを編集対象に表示しない。
- `views(first:10)`から`number`、`name`、`layout`、`filter`を取得する。先頭10件までとし、最小の`number`のビューを先頭ビューとして、その`filter`を初期フィルタにする。`filter`がnullなら空のフィルタにする。ビューの切替・保存は対象外。
- 列に使うフィールドは、`group_by`（既定`Status`）と名前が一致する単一選択フィールドとする。一致するものがなければ最初の単一選択フィールド、単一選択フィールドがなければ1列（`nil`）とする。
- フィールドの並びはAPIの返却順とする。単一選択の選択肢順もAPIの返却順とし、値のない項目は末尾の値なし列に置く。
- 編集可能なフィールドは`dataType`が`TEXT`、`NUMBER`、`DATE`、`SINGLE_SELECT`のカスタムフィールドとする。`TITLE`、`ASSIGNEES`、`LABELS`、`LINKED_PULL_REQUESTS`、`MILESTONE`、`REPOSITORY`、`REVIEWERS`、`PARENT_ISSUE`、`SUB_ISSUES_PROGRESS`、`CREATED`、`UPDATED`、`CLOSED`は除外する。`isIssueField`は実測で全フィールドfalseだったため判定に使わない。
- 単一選択の選択肢は`id`、`name`、`color`を保持する。`id`は短い文字列であり、表示名と混同しない。

### 項目

- `items(first:100, after:, query:filter, orderBy:{field:POSITION, direction:ASC}, archivedStates:[NOT_ARCHIVED])`を取得する。
- `items_page`は1回の呼び出しで1ページだけ取得し、`{items, total_count, has_next, end_cursor}`を返す。`has_next`が真なのに`endCursor`がない応答は不正として扱う。
- `items`は`items_page`を`pageInfo.hasNextPage`と`endCursor`で辿り、`max_items`（既定1000）に達するまで取得する。達した場合は`truncated=true`とし、`totalCount`は打ち切り前の総数を保持する。ボードは`items_page`を直接使い、最初のページだけを待って描画し、残りはスクロール時に取得する。
- 各項目は`id`、`type`、`isArchived`、`content`、`fieldValues`を保持する。`isArchived`が真の項目は描画しない。
- `content`は次のunionを扱う。
  - Issue: `number`、`title`、`state`、`url`、`repository.nameWithOwner`、`labels(first:2){totalCount, nodes}`、`assignees(first:1){totalCount, nodes}`、`subIssuesSummary{total, completed}`、`closedByPullRequestsReferences(first:2){totalCount, nodes}`。
  - PullRequest: `number`、`title`、`state`、`url`、`repository.nameWithOwner`、`labels(first:2){totalCount, nodes}`、`assignees(first:1){totalCount, nodes}`。
  - DraftIssue: `title`、`body`。
  - REDACTED: 内容なし。`type="REDACTED"`として返し、描画側がredactedと表示する。
- カードはラベル2件・担当者1件・関連PR2件だけを表示するため、取得件数も表示件数に合わせる。`totalCount`は全件数を返すので`+N`の表示に使える。
- `fieldValues(first:50)`から単一選択・テキスト・数値・日付の値と`field{id, dataType}`を取得する。組み込みフィールドの値は無視する。単一選択は`optionId`と`name`を保持する。フィールド名は詳細の`fields`から引くため、項目側では取得しない。
- 内部モデルは`{id, type, content, values, archived}`。`values`はフィールドIDをキーとし、`{kind, value, option_id?, name?}`を保持する。列の値は`group_field`のIDで引く。`content`はラベル・担当者・関連PRの`totalCount`も保持し、表示上限を超えた分の件数をUIが示せるようにする。
- 項目の総数と打ち切りは画面のヘッダに表示する。0件は成功結果として扱い、エラーにしない。

### フィールドの更新と解除

- `updateProjectV2ItemFieldValue(input:{projectId, itemId, fieldId, value})`を使い、選択したフィールドだけを更新する。
  - `TEXT`: `{text=<文字列>}`
  - `NUMBER`: `{number=<JSON数値>}`
  - `DATE`: `{date="YYYY-MM-DD"}`
  - `SINGLE_SELECT`: `{singleSelectOptionId=<選択肢ID>}`
- 値を解除する場合は`clearProjectV2ItemFieldValue(input:{projectId, itemId, fieldId})`を使う。
- 送信前に検証する。数値は`tonumber`で有限の数値になること、日付は`YYYY-MM-DD`形式で実在する日付であること、単一選択は選択肢IDがそのフィールドの選択肢に含まれること。空のテキストは解除として扱い、`clearProjectV2ItemFieldValue`を送る（値更新は送らない）。
- 成功時は項目IDと新しい値を返す。失敗時は種別と理由を返し、自動で再送しない。
- 同じフィールドの同時編集はGitHubが最後に受け付けた値を正とする。他のフィールドを巻き戻さない。

### 項目の追加

- 既存項目の指定は次の形式を受け付ける。
  - `https://github.com/<owner>/<repo>/issues/<number>`
  - `https://github.com/<owner>/<repo>/pull/<number>`
  - `<owner>/<repo>#<number>`
- owner/repoと番号を検証し、GraphQL `repository(owner:, name:){ issueOrPullRequest(number:){ __typename ... on Issue { id } ... on PullRequest { id } } }`で1つのnodeを解決する。`__typename`でIssue/PRを判定し、nullなら`not_found`とする。`issue`と`pullRequest`を同時に問い合わせると非該当側がNOT_FOUNDになりクエリ全体が失敗するため、`issueOrPullRequest`を使う。
- `addProjectV2ItemById(input:{projectId, contentId})`を実行し、応答の`item`は項目一覧と同じcontent（labels/assignees/subIssuesSummary/closedByPullRequestsReferencesと各totalCount）とfieldValues（TEXT/NUMBER/DATE/SINGLE_SELECT）を要求して、完全な項目を返す。同じ項目IDが既にモデルにある場合は`duplicate=true`とし、重複を作らない。このmutationは冪等であり、既に追加済みの場合は既存項目を返す。
- 下書きIssueは`addProjectV2DraftIssue(input:{projectId, title, body})`で作成する。タイトルは前後の空白を除いて1文字以上とし、空白だけは拒否する。本文は空でもよい。
- 応答の項目を列の末尾に置く。列は項目のグループ値から決める。グループ値がない場合は値なし列に置く。
- 一時的な競合エラーは`conflict`として返し、利用者の再操作を受け付ける。自動で再送しない。

### 項目の削除

- `deleteProjectV2Item(input:{projectId, itemId})`を実行し、応答の`deletedItemId`を返す。
- 削除はProjectから項目を外すだけで、Issue/PR自体を削除しない。
- 既に対象が存在しない場合は`not_found`として返し、成功と断定しない。画面は直前の内容を保持し、利用者の再取得に委ねる。
- 成功時はモデルから項目を除く。失敗時はモデルを変更しない。

### エラー

- 種別は`auth`、`not_found`、`forbidden`、`validation`、`conflict`、`rate_limit`、`network`、`unknown`とする。
- ghが未導入・未認証、または`project`スコープがない場合は`auth`とする。
- GraphQL errorsのメッセージを含めて返す。`Could not resolve`は`not_found`、`temporary conflict`は`conflict`、型の不一致は`validation`、スコープ不足は`auth`、レート制限は`rate_limit`とする。
- 共通ghアダプタが返すHTTPステータス`status`から、401は`auth`、403は`forbidden`、404は`not_found`、422は`validation`、429は`rate_limit`、5xx・不正JSONは`unknown`とする。`status`がない起動失敗・通信失敗は`network`、`status`がないその他の失敗は`unknown`とする。
- 失敗時は対象と理由を利用者へ案内する。トークン・認証ファイルの内容をログや通知に出さない。
- 書込みの結果が不明な場合は成功と断定せず、自動再送しない。

### 反映遅延

- Projects APIは更新直後の読み取りが一時的に古い値を返すことがある。実測では約0〜3秒だった。
- 書込み後はmutationの応答でローカル状態を更新し、自動の再取得はしない。`r`による再取得を正とする。
- アーカイブ状態のフィルタも反映が遅れることがある。初期版はアーカイブ操作を対象外とするため、読み取り時の`archivedStates`だけを使う。

## API

owner解決はREST `gh api user`または`gh api users/{login}`を使う。Projectsの読み書きはGraphQLを`gh api graphql --input -`へJSON `{query, variables}`で渡す。

Project一覧（Orgの場合は`organization`）:

```graphql
query($owner: String!, $after: String) {
  user(login: $owner) {
    projectsV2(first: 100, after: $after) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes { id number title items { totalCount } public closed url }
    }
  }
}
```

Project詳細と項目（Orgの場合は`organization`）:

```graphql
query($owner: String!, $number: Int!, $after: String, $filter: String) {
  organization(login: $owner) {
    projectV2(number: $number) {
      id number title url public closed
      fields(first: 50) {
        nodes {
          __typename
          ... on ProjectV2FieldCommon { id name dataType }
          ... on ProjectV2SingleSelectField { options { id name color } }
        }
      }
      views(first: 10) { nodes { number name layout filter } }
      items(first: 100, after: $after, query: $filter, orderBy: {field: POSITION, direction: ASC}, archivedStates: [NOT_ARCHIVED]) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          id type isArchived
          content {
            __typename
            ... on Issue {
              number title state url
              repository { nameWithOwner }
              labels(first: 2) { totalCount nodes { name color } }
              assignees(first: 1) { totalCount nodes { login } }
              subIssuesSummary { total completed }
              closedByPullRequestsReferences(first: 2) { totalCount nodes { number url } }
            }
            ... on PullRequest {
              number title state url
              repository { nameWithOwner }
              labels(first: 2) { totalCount nodes { name color } }
              assignees(first: 1) { totalCount nodes { login } }
            }
            ... on DraftIssue { title body }
          }
          fieldValues(first: 50) {
            nodes {
              __typename
              ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { id dataType } } }
              ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { id dataType } } }
              ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { id dataType } } }
              ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { id dataType } } }
            }
          }
        }
      }
    }
  }
}
```

項目のフィールド更新・解除:

```graphql
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
  updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: $value}) {
    projectV2Item { id }
  }
}

mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!) {
  clearProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId}) {
    projectV2Item { id }
  }
}
```

項目の追加（既存Issue/PR）と下書き:

```graphql
mutation($projectId: ID!, $contentId: ID!) {
  addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
    item {
      id type isArchived
      content { __typename ... on Issue { number title state url } ... on PullRequest { number title state url } ... on DraftIssue { title body } }
      fieldValues(first: 50) { nodes { __typename ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { id name dataType } } } ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { id name dataType } } } ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { id name dataType } } } ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { id name dataType } } } } }
    }
  }
}

mutation($projectId: ID!, $title: String!, $body: String) {
  addProjectV2DraftIssue(input: {projectId: $projectId, title: $title, body: $body}) {
    projectItem {
      id type isArchived
      content { ... on DraftIssue { title body } }
      fieldValues(first: 50) { nodes { __typename ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { id name dataType } } } ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { id name dataType } } } ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { id name dataType } } } ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { id name dataType } } } } }
    }
  }
}
```

追加・下書きの応答も、項目一覧と同じcontent（labels/assignees/subIssuesSummary/closedByPullRequestsReferencesと各totalCount）とfieldValuesを要求する。上の抜粋は形を示すための省略形である。

Issue/PRのnode ID解決:

```graphql
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issueOrPullRequest(number: $number) {
      __typename
      ... on Issue { id }
      ... on PullRequest { id }
    }
  }
}
```

`issueOrPullRequest`はIssueとPRのどちらか一方だけを返す。`__typename`で種別を判定し、nullなら`not_found`とする。`issue`と`pullRequest`を同時に問い合わせると非該当側がNOT_FOUNDになりクエリ全体が失敗するため、このunionを使う。

項目の削除:

```graphql
mutation($projectId: ID!, $itemId: ID!) {
  deleteProjectV2Item(input: {projectId: $projectId, itemId: $itemId}) {
    deletedItemId
  }
}
```

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| owner解決・Project一覧・詳細・項目のページング・mutation・モデル変換 | 機能API | `lua/github/features/projects/api.lua` |
| Projects APIの振る舞いの検証 | テスト | `lua/github/features/projects/api_spec.lua` |
| repoを持たないtargetとGraphQL errorsの返却 | 共通 | `lua/github/core/gh.lua` |
| `group_by`・`max_items`の読み出し | 共通 | `lua/github/core/config.lua` |
| `projects`設定の検証 | 設定 | `lua/github/features/setup.lua` |
| ヘルプとREADMEの更新 | docs | `doc/github.txt`, `README.md`（docs/helpの子が所有） |

API層は画面を持たない。画面は返されたモデルを描画し、mutationの結果でローカル状態を更新する。実行器・gh・時刻は注入し、テストではfake ghを使う。実GitHubの書込みはテストで行わない。実APIの契約はFEASIBILITY.mdの`projects-api`で確認済みであり、実装時のテストはfake ghで契約を再現する。

## エッジケースの決定

- owner: 存在しない、アクセスできない、`@me`、大文字小文字、空白・`/`を含む値。ユーザーとOrgを同時に問い合わせない。
- Project: 0件、100件超、閉じたProject、Projectが見つからない、フィールド0件、単一選択0件、`group_by`が見つからない、ビュー0件、先頭ビューのフィルタがnull。
- 項目: 0件、`max_items`打ち切り、フィルタ0件、無効なフィルタ、アーカイブ済み、redacted、内容がnull、ラベル・担当者が上限を超える、サブIssue進捗がnull、関連PRが0件。
- 値: 未設定、未知の選択肢ID、組み込みフィールド、複数選択・イテレーション、数値・日付の不正、空テキスト、選択肢の削除。
- mutation: 重複追加、一時的な競合、対象なし、権限不足、検証エラー、レート制限、結果不明。自動再送しない。
- 並行: 古い要求の応答、閉じた画面、別画面の更新。書込み後の自動再取得をしない。
- 安全: トークン・認証ファイルを読まない。シェルへ入力を連結しない。利用者の既存Projectをテストで変更しない。

## テスト方針

| 確かめること（タスク説明から起こした） | レベル |
| --- | --- |
| owner省略時にREST `user`で認証ユーザーのlogin/typeを取得し、指定時は`users/{login}`で取得する。 | 単体 |
| ユーザーとOrgを別クエリで解決し、片方の不存在で全体を失敗させない。 | 単体 |
| 開いているProjectだけを最大100件返し、100件に達するまでページングし、続きがあれば`truncated`を付ける。閉じたProjectを除外する。 | 単体 |
| Projectのフィールド・ビュー・先頭ビューのフィルタ・`group_by`の解決とフォールバックを行う。 | 単体 |
| 編集可能フィールドを`dataType`で絞り、組み込みフィールドを除外する。 | 単体 |
| 項目を100件/pageでページングし、`max_items`で打ち切り、`totalCount`と`truncated`を保持する。 | 単体 |
| 1ページだけを取得して`has_next`と`end_cursor`を返し、カーソルのない続きの応答を不正として拒否する。 | 単体 |
| `query`フィルタと`archivedStates`を要求に含め、0件を成功として返す。 | 単体 |
| Issue/PR/DraftIssue/REDACTEDのcontentとフィールド値を内部モデルへ変換する。 | 単体 |
| 単一選択・テキスト・数値・日付の更新と解除を正しい`ProjectV2FieldValue`で送る。 | 単体 |
| 不正な数値・日付・選択肢IDを送信前に拒否する。 | 単体 |
| 既存Issue/PRのURLと`owner/repo#number`を解決し、Issue/PRのnode IDを得る。 | 単体 |
| 既存項目の追加が冪等で、重複時に`duplicate=true`を返す。 | 単体 |
| 下書きIssueのタイトル必須と本文任意を検証する。 | 単体 |
| 項目の削除がProjectからのみで、Issue/PRを削除しない要求である。 | 単体 |
| GraphQL errors・HTTP 4xx・起動失敗を種別と理由に変換し、成功扱いしない。 | 単体 |
| 書込み失敗時に自動再送せず、結果不明を成功と断定しない。 | 単体 |
| 古い要求の応答や閉じた画面の応答で、別画面の状態を更新しない。 | 単体 |

実APIの契約はFEASIBILITY.mdの`projects-api`で確認済み。テストはfake ghで要求の形・ページング・エラー・モデル変換を検証し、実GitHubの書込みを行わない。
