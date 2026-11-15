# AGENTS.md

## 実装・検証

- Neovim の実装・検証は 0.10.4 を PATH の先頭に置いて行う。0.13.0-nightly では `lua/github/features/issues/create_spec.lua` の端末チャネル検証が失敗する（既知）。
- セットアップと検証コマンドは `docs/design/DESIGN.md`「開発・検証コマンド」に従う。
- 画面の表示や操作に関わる実装をしたら、テストが通った後に必ず実際の UI を表示して確認する。手段は `/utility-nvim-ui-capture` スキル（rtty のブラウザターミナルに Neovim を表示してスクリーンショットを撮る）とし、fixture と fake `gh` でデータを用意して実 API は使わない。確認した画面のスクリーンショットを完了報告に添える。確認できなかった場合は、その理由と「UI 未確認」を完了報告に明記する。
