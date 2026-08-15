# 実装とテスト: ファイルの書き込み (P1)

- 作成: 2026-08-15 / 状態: draft
- 対応設計: design.md

## D↔コード

| D | 実装 | 壊れたら落ちるテスト |
|---|---|---|
| D-01 開く口は `createNew` | `lib/src/client.dart` の `Smb2Tree.createNew` | T-01, T-02, T-17 |
| D-02 `WriteRequest` / `WriteResponse` | `lib/src/protocol/messages/write.dart` | T-12, T-13, T-03 |
| D-03 `Smb2FileWriter` | `lib/src/file/file_writer.dart` の `write` / `_sendBlocks` / `_writeOnce` | T-03, T-05, T-08, T-10 |
| D-04 1 回の要求は 1MB まで | `lib/src/client.dart` の `_negotiate` (`_oneMegabyte`) | T-16 |
| D-05 失敗した writer は以後拒む | `lib/src/file/file_writer.dart` の `_broken` | T-11 |
| D-06 `close` は待つ | `lib/src/file/file_writer.dart` の `close` | T-04, T-06, T-07 |
| D-07 既存の読み取りに手を入れない | 追加のみ (`file_reader.dart` は無変更) | 既存 132 件 + T-18 |
| D-08 テストは 2 段構え | `test/write_test.dart` / `test/integration/write_test.dart` | (この表そのもの) |

### 設計から変えた点 (実装して分かったこと)

- **D-01**: `Smb2Tree` が `maxWriteSize` を持っていなかったので、`Smb2Tree._` と
  `forTesting` に引数を 1 つ足した。design.md は「読み取りと同じ組み合わせで
  `maxReadSize` の代わりに `maxWriteSize` を渡す」と書いていたが、**渡す元が
  tree に無かった**。既存の呼び出し元への影響は無い (`forTesting` は既定値付き)
- **D-04**: 1MB の丸めが読み取りと transact にしか無く、`maxWriteSize` は
  サーバー申告のまま素通ししていた。3 行を名前付き定数 `_oneMegabyte` に
  そろえて、書き込みにも同じ上限をかけた。**既存 2 行の値は変えていない**

## S↔T

| S | 受入条件を確かめるテスト |
|---|---|
| S-01 名前を押さえてから書き始める | T-01, T-02 (`test/write_test.dart`)、T-17 (`test/integration/write_test.dart`) |
| S-02 渡した順にそのまま並ぶ | T-03〜T-07 (単体)、**T-14, T-15 (実サーバー)** |
| S-03 サーバーの上限は見えない | T-08, T-09 (単体)、**T-16 (実サーバー)** |
| S-04 失敗は分かる形で返る | T-02 (単体) |
| S-05 どこまで渡ったかを読める | T-10, T-11 (単体)、T-14 (実サーバー) |
| S-06 既存の読み取りを変えない | 既存テスト 132 件、T-18 (実サーバー) |

**S-02 と S-03 は単体だけでは足りない。** 偽サーバーは「受け取った」と答える
だけなので、**バイトが本当にそこにあるか**は答えられない。実経路を通すのは
T-14 / T-15 / T-16 で、いずれも書いたあとに読み直して比べている。

## 検証していないこと

- **(S-01) 権限の無い場所への `createNew`** — **実サーバーで 1 度観測した**
  (2026-08-15、書き込みを許さないディレクトリに対して):
  `Smb2Exception: Create file "..." failed (STATUS_ACCESS_DENIED)` が出て、
  例外は status を保持していた
  - **自動テストは足していない**。ライブラリ側の経路は「サーバーが返した
    status を例外に載せる」だけで、**status が何であっても同じ**。その経路は
    T-02 (衝突) が押さえており、定数を変えただけの 2 本目は情報を増やさない
  - 足すとすれば「権限の壊れたディレクトリが在り続けること」に依存する
    テストになり、**確かめる対象がライブラリからサーバーの設定に移る**
- **(S-04) 接続が切れたときに status を持たない例外になること**。実サーバーで
  途中切断を起こす手段が無い。単体側では `Smb2TimeoutException` の形を
  `request_expiry_test.dart` が押さえているが、**書き込み経路で**は未確認
- **(S-05) 失敗後の `written` が共有上のファイル長と一致すること**。単体では
  writer 側の数値しか見ておらず (T-11)、**実サーバーで書き込みを途中で
  失敗させる手段が無い**。権限や容量で失敗を作れる環境ができたら足す
- **(S-06) 書き込み中の読みが待たされる以上のことは起きない**、の「以上の
  こと」。T-18 は順に行うだけで、並行にはしていない
- テストが作ったファイルは**消していない** (削除は後の段階)。
  `SMB_WRITE_DIR` は手で掃除できる場所であることが前提
