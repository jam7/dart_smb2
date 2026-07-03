# 修正 4: 受信データのコピー削減 (B-1 + B-2)

対象レビュー: [20260703-performance-review.md](20260703-performance-review.md)

1MB の Read 応答 1 件あたり約 4MB の memcpy が発生している。CPU とメモリ帯域の
削減で、特にモバイル (タブレット) で効く。

## B-1: Read 応答の二重コピー

### 現状

`ReadResponse.decode` が `Uint8List.fromList(body.sublist(...))` で 2 回コピーする
(`sublist` で 1 回、`fromList` でさらに 1 回)。

### 方針

`Uint8List.sublistView(body, dataOffset, dataOffset + dataLength)` で**ゼロコピー**にする。

- データがパケット全体への view になるため、データが生きている間パケット全体
  (ヘッダ 64 バイト + Read 応答固定部 16 バイト) がメモリに保持されるが、Read 応答は
  ほぼ全体がデータなので無駄は 1% 未満
- readRange の分割読みでは各チャンクが結果バッファに `setRange` でコピーされる
  (計 1 コピー)。単発読みでは view がそのまま呼び出し元に渡る (0 コピー)

## B-2: 受信バッファの takeBytes / 再 add 方式

### 現状

`Smb2Connection._readExact` は必要量が溜まるたびに `BytesBuilder.takeBytes()` で
全連結 → 先頭を切り出し → 残りを再 add する。NetBIOS ヘッダ (4 バイト) 読みと
本体読みで 2 回 `takeBytes` が走るため、メッセージ本体は実質 2 回コピーされる。

### 方針

チャンクキュー + 読み出しカーソル方式に変更する。

- `Queue<Uint8List>` に受信チャンクを溜め、先頭チャンク内のオフセット
  (`_offsetInFirst`) を進めながら消費する
- `_readExact(length)`:
  - 先頭チャンクの残りだけで足りる場合は **`sublistView` を返す (0 コピー)**。
    小さいメッセージが 1 チャンクに収まる一般的なケースはこれで済む
  - チャンクをまたぐ場合は `length` ぶんの結果バッファを確保して詰める (1 コピー)
- 1MB Read 応答 1 件あたりの総コピー量: 約 4MB → 約 1〜2MB
  (連結 1 回 + readRange の setRange 1 回)

### テスト容易性のための付随変更

`Smb2Connection` は Socket 直結でユニットテストできないため、
`Smb2Connection.forTesting(Stream<Uint8List>, send コールバック)` を追加し、
チャンク境界をスクリプトして `readMessage` を検証できるようにする。

## 付随修正: `_parseEntries` の ByteData をループ外へ (レビュー D 項)

`QueryDirectoryResponse._parseEntries` がエントリごとにループ内で
`ByteData.sublistView(buffer)` を生成している。ループ外に出す
(修正 3 のドキュメントで宣言済みの対応)。

## 意味論の注意点 (view を返すことの影響)

- `readMessage` が返すパケットが受信チャンクへの view になり得るため、
  multiplexer が切り出す `body`、ReadResponse の `data` も同じバッキングを共有する。
  **受信側でバッファを書き換えるコードは存在しない** (decode は読むだけ) ので安全
- view の保持でバッキング配列全体が生き続けるのは B-1 と同様の性質。チャンクは
  高々 64KB 程度 (TCP 受信単位)、Read 応答は自前フレームなので実害なし

## テスト方針

- `readMessage`: 1 チャンクに複数メッセージ / メッセージがチャンクをまたぐ /
  NetBIOS ヘッダ自体がまたがる / keep-alive (0x85) の読み飛ばし / 途中切断で
  SocketException、の各ケースでバイト列が正しいこと
- `ReadResponse.decode`: データ内容の一致 (view でも従来と同じ値が読めること)、
  dataOffset/dataLength の境界チェックの回帰
- 既存の全テスト (multiplexer / file_reader / close / query_directory) がそのまま
  パスすること = 上位層は view/コピーの区別に依存していないことの確認

## 実装後の懸念点

実装・テスト完了 (ユニットテスト 109 件パス、うち今回追加 7 件)。
ReadResponse の view 化は file_reader の既存テストがバイト列一致で実スタック経由の
カバーをしている。以下は把握済みの残懸念:

1. **view によるチャンク保持**: 小さい応答の view が TCP チャンク (高々 64KB 程度) を
   保持する。応答は multiplexer で即座に消費されるため実害はないが、応答オブジェクトを
   長期保持する使い方をすると保持量が増える点は将来の API 利用者に注意
2. **返すバッファは呼び出し側で書き換えない前提**。receive 経路の decode はすべて
   読み取り専用なので現状は安全。書き換える利用が必要になったら copy を明示する
3. **実サーバーでの検証は未実施**。チャンク境界のばらつきは connection_test で
   スクリプト済みだが、実 TCP の分割パターンでの確認 (アプリ動作確認) を別途行う

## 結果

- `lib/src/transport/connection.dart`: 受信を チャンクキュー + カーソル方式に変更。
  チャンク内に収まる読みは 0 コピー、またぐ場合のみ 1 コピー。
  `Smb2Connection.forTesting` を追加してチャンク境界をスクリプト可能にした
- `lib/src/protocol/messages/read.dart`: Read 応答データを `sublistView` (0 コピー) に
- `lib/src/protocol/messages/query_directory.dart`: `_parseEntries` の
  `ByteData.sublistView` をループ外へ (レビュー D 項)
- テスト追加: `test/connection_test.dart` (複数メッセージ/チャンクまたぎ/keep-alive/
  切断/巨大メッセージ/sendRaw フレーミング)
