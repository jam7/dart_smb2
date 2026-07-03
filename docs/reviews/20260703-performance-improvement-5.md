# 修正 5: Compound Request (A-2 本命)

対象レビュー: [20260703-performance-review.md](20260703-performance-review.md)

## 現状の問題

小ファイル読み (`Smb2Tree.readRange`) は Create → Read → Close の 3 コマンドを
それぞれ 1 往復ずつ発行する。修正 2 で Close は非待機になったが、Create → Read の
2 往復 + Close 送信は残っている。サムネイルや ZIP エントリのような
「開いて 1 回読んで閉じる」パターンでは往復回数がそのまま遅延になる。

## 方針

SMB2 の Compound Request (related operations) で Create+Read+Close を
**1 パケット・1 往復**にする。

### プロトコル仕様 (MS-SMB2)

- 複数のリクエストを 1 つのトランスポートメッセージに連結する。各ヘッダの
  `NextCommand` に「このヘッダ先頭から次のヘッダ先頭までのオフセット
  (8 バイト境界にパディング)」を入れ、最後のリクエストは 0
- 2 番目以降のヘッダに `SMB2_FLAGS_RELATED_OPERATIONS (0x04)` を立てると、
  前のリクエストの結果 (Create の FileId) を引き継ぐ。その際 Read/Close の
  FileId は全バイト 0xFF のセンチネルにする
- MessageId とクレジットは**リクエストごと**に消費する (Create=1、
  Read=ceil(len/64KB)、Close=1)
- サーバーは応答を 1 パケットに連結して返すことも、別々に返すこともある。
  受信側は両方を処理できる必要がある

### 変更点

1. **Multiplexer 受信ループ**: 1 パケットに複数の応答が連結されているケースに対応。
   `nextCommand` を辿ってサブメッセージに分割し、それぞれの MessageId で dispatch
   する (compound を使わなくても正しさに影響しない一般化)
2. **Sender に `sendCompound(List<(header, body)>)` を追加**:
   - 予算予約を「合計 creditCharge + リクエスト数ぶんの in-flight スロット」で
     原子的に行う (`tryReserveBudget` に slots 引数を追加)
   - MessageId をリクエストごとの charge ぶん連番で割り当て、2 番目以降に
     related フラグ、`nextCommand` チェーンと 8 バイトパディングを設定して
     1 回の `sendRaw` で送信
   - 応答 future のリストを返す
3. **`FileId.related`**: 全バイト 0xFF のセンチネル定数を追加
4. **`Smb2Tree.readRange`**: `length <= maxReadSize` なら compound パスを使用
   - Create (read access) + Read (related) + Close (related) を 1 往復で発行
   - Create 失敗 → 例外 (Read/Close の応答にはハンドラを付けて消費し、
     unhandled error を出さない)
   - Read が STATUS_END_OF_FILE → 空データ (既存の FileReader と同じ意味論)
   - Close 失敗 → warning ログのみ (修正 2 と同じ)
   - `length > maxReadSize` は従来どおり openRead → readRange (並列分割) → close
5. **FakeConnection**: compound リクエストを `nextCommand` で分割して `sent` に
   積むよう拡張 (既存テストは nextCommand=0 なので影響なし)

### アプリ側の変更 (dart_smb2 コミット後)

`SmbSource.readRange` と画像先頭読みヘルパーが手書きの
openRead → readRange → close を行っているのを `tree.readRange` 呼び出しに変更する
(timeout は呼び出し全体に付け替え)。ZIP のエントリ読み (archive_reader の
readRange コールバック) と動画プロキシの再接続パスがこの経路。

## 安全性の検討

- **クレジット**: 合計 charge (1MB Read なら 1+16+1=18) を送信前に予約する。
  修正 1 のゲートがそのまま使える
- **応答順序**: related compound の応答は同一パケットでも別パケットでも
  MessageId で対応付けるため順序に依存しない
- **部分失敗**: Create が失敗すると後続の related リクエストにもエラー応答が
  返る (サーバー実装により STATUS_INVALID_PARAMETER 等)。すべての future を
  消費してからエラーを投げる
- **サーバー互換性**: compound は SMB 2.0 からの標準機能で Windows / Samba とも
  クライアント (Windows Explorer) が常用している。ただし実サーバーでの確認は必須

## テスト方針

- パケットエンコード: nextCommand チェーン (8 バイト整列)、related フラグ、
  MessageId の連番割り当て、FileId センチネル
- Multiplexer: 連結応答パケットが各 pending に正しく dispatch されること
- `readRange` compound: 正常系 (データ一致)、Create 失敗、Read EOF、
  応答が別々に返るケース、応答が連結で返るケース
- 予算: 合計 charge が残高を超える場合に送信が待たされること
- 既存テスト全パスの回帰確認

## 実装後の懸念点

実装・テスト完了 (ユニットテスト 116 件パス、うち今回追加 7 件)。以下は把握済みの残懸念:

1. **実サーバーでの検証は必須・未実施**。compound は標準機能だが、NAS 系の
   SMB 実装には related operations の癖があり得る。アプリ動作確認 (ZIP 表示、
   動画プロキシの再接続パス) と `Unexpected response` / `Invalid NextCommand`
   警告ログの監視を行う
2. **Create 失敗時の related 応答の扱いはサーバー依存** (同一エラー / 
   STATUS_INVALID_PARAMETER 等)。どの場合も future を消費してログに落とすだけ
   なので unhandled error にはならない
3. **readFile は非 compound のまま**。ファイルサイズが事前に不明で、Read 長を
   決められないため。アプリの小ファイル読みは一覧で得たサイズを使って
   readRange を呼ぶ経路に寄せる
4. **sendCompound のチェーン長は maxInflight 以下**に制限 (超えると永遠に
   予算が確保できないため ArgumentError)

### テスト基盤の修正 (FakeConnection のデッドロック)

budget テストが「受信ループが `_running=false` で終了した後に未配送イベントが
残る」タイミングで `FakeConnection.close()` がハングする問題を発見。
`StreamController.close()` の future は done イベントがリスナーに配送されるまで
完了しないため、購読者不在だと永久に待つ。実物の `Smb2Connection.close()` と
同様に `StreamIterator.cancel()` するよう修正した (プロダクションコードの
問題ではない)。

## 結果

- `lib/src/transport/multiplexer.dart`: 受信ループが NextCommand チェーンを辿って
  連結応答を分割 dispatch。`tryReserveBudget` に `slots` 引数を追加
- `lib/src/transport/sender.dart`: `sendCompound` を追加 (予算の一括予約、
  MessageId 連番割り当て、related フラグ、8 バイト整列の NextCommand チェーン)
- `lib/src/protocol/messages/create.dart`: `FileId.related` センチネルを追加
- `lib/src/client.dart`: `Smb2Tree.readRange` が maxReadSize 以下の範囲を
  compound Create+Read+Close (1 往復) で発行
- `test/fake_connection.dart`: compound リクエストの分割記録、
  `pushCompoundResponse`、close のデッドロック修正
- テスト追加: `test/compound_test.dart` (ワイヤフォーマット、応答が別々/連結、
  Create 失敗、EOF、非 compound フォールバック、予算ゲート)
