# 修正 3: QueryDirectory バッファ拡大 (A-3)

対象レビュー: [20260703-performance-review.md](20260703-performance-review.md)

## 現状の問題

`QueryDirectoryRequest.outputBufferLength` が 65536 固定。ディレクトリのページングは
「前の応答を見てから次を出す」構造上直列にしかできないため、1 往復あたりの取得量が
そのまま一覧の所要時間を決める。FileBothDirectoryInformation は 1 エントリ約 100〜150
バイトなので、64KB では 1 往復あたり約 500 エントリ。数千ファイルのディレクトリでは
往復が 10 回近く発生する。

## 方針

negotiate 済みの maxTransactSize までバッファを拡大し、往復回数を最大 1/16 に減らす。

- `NegotiateResponse.maxTransactSize` を `Smb2Client` に保存する (現状 decode 済みだが
  未保存)。maxReadSize と同様に**上限 1MB でキャップ** (メモリと creditCharge=16 を
  上限にするため。SMB 2.1 の実サーバーはほぼ 1MB 以上を報告する)
- `Smb2Tree` に `maxTransactSize` を引き渡し、`listDirectory` が
  `QueryDirectoryRequest(outputBufferLength: maxTransactSize)` を発行する
- **`buildHeader` で `creditCharge = ceil(outputBufferLength / 65536)` を設定する**
  (必須。現状の charge=1 のまま 64KB 超のバッファを要求するのはプロトコル違反で、
  Windows Server は切断し得る)。修正 1 のクレジットゲートが charge=16 を正しく
  会計するので、送信側の追加変更は不要
- `QueryDirectoryRequest` のデフォルト値 65536 は変えない (呼び出し側が明示指定)

## 安全性の検討

- **クレジット残高との関係**: charge=16 の要求は残高 16 以上を要って送信される
  (修正 1 のゲート)。接続直後で残高が少ない場合、in-flight 0 件なら liveness
  フォールバックで送信されるが、各リクエストが 32 クレジットを要求し実サーバーは
  それに応えるため、ハンドシェイク 4 往復後の残高はまず足りる。フォールバック発動時は
  warning ログが出るので実機ログで監視する
- **MessageId 消費**: charge=16 は MessageId を 16 個消費するが、`allocateMessageId`
  が charge ぶん予約済みなので対応不要
- **応答サイズ**: 応答は NetBIOS フレーム (最大 16MB 級) の範囲内なので受信側の
  変更は不要。`QueryDirectoryResponse.decode` の bounds チェックも既存のまま有効

## テスト方針

- `buildHeader` の creditCharge: 64KB → 1、64KB+1 → 2、1MB → 16
- `encode` の OutputBufferLength フィールドに指定値が入ること
- `Smb2Tree.listDirectory` が tree の maxTransactSize を outputBufferLength として
  送信すること (FakeConnection で送信パケットを検査)
- 複数ページの応答 (継続 → noMoreFiles) でエントリが結合されること (回帰確認)

## 実装後の懸念点

実装・テスト完了 (ユニットテスト 102 件パス、うち今回追加 3 件)。以下は把握済みの残懸念:

1. **接続直後の charge=16 と残高**: connectTree 直後の listDirectory で残高が 16 未満
   だと liveness フォールバック (warning ログ) が発動し得る。実サーバーは
   リクエストごとの 32 クレジット要求に応えるため、ハンドシェイク後の残高で通常は
   足りる。実機ログで `insufficient credits` を監視する
2. **1 ページの decode 量が最大 16 倍**: `_parseEntries` はループ内でエントリごとに
   `ByteData.sublistView` を生成しており (レビュー D 項)、大ページでは無駄が増える。
   修正 4 (コピー削減) でまとめて対処する
3. **サーバーが要求より小さいページを返すのは正常** (paging は既存ロジックのまま
   動く)。要求値はあくまで上限

## 結果

- `lib/src/protocol/messages/query_directory.dart`: `buildHeader` が
  `creditCharge = ceil(outputBufferLength / 65536)` を設定
- `lib/src/client.dart`: negotiate の `maxTransactSize` を保存 (1MB キャップ)、
  `Smb2Tree` に引き渡し、`listDirectory` が `outputBufferLength` に使用
- テスト追加: `test/query_directory_test.dart` (creditCharge 計算、encode、
  listDirectory のバッファ指定 + ページング回帰)
