# dart_smb2 パフォーマンスレビュー (2026-07-03)

高速化の余地と並列処理の十分性の観点で、ライブラリ全体 (約 2,500 行) とアプリ側での
実際の使われ方 (動画プロキシ、ZIP リーダー、サムネイル取得) を突き合わせてレビューした結果。

## 結論

多重化の基盤 (MessageId ベースの並列リクエスト + 専用受信ループ) はよくできているが、
**その並列性を活かせていない呼び出しパスが 2 つ**あり、そこが実効性能のボトルネック。
特に `readRange` の分割読みが直列なのは、動画プロキシと ZIP 展開に直撃する。
また、並列度を上げる前提として**クレジット管理が未完成**な点がリスク。

## A. 並列処理が不十分な箇所 (効果大)

### A-1. `readRange` の分割読みが直列 — 最重要

`lib/src/file/file_reader.dart:70-77` — maxReadSize (1MB) を超えるレンジは
while ループで 1 ブロックずつ await しており、multiplexer が全く使われない。
スループットは `blockSize / RTT` に張り付く (RTT 20ms なら 1MB ブロックで最大 50MB/s、
64KB なら 3.2MB/s)。

影響先:

- **動画プロキシ** (`image-viewer/lib/services/video/smb_proxy_server.dart:131`) —
  HTTP Range 要求ごとに `readRange` を呼ぶため、動画シーク・再生のスループットが頭打ち
- **ZIP エントリ展開** (`image-viewer/packages/archive_reader/lib/src/zip/zip_reader.dart:58`) —
  1MB 超の圧縮エントリを `readRange` 一発で読むため同様

結果バッファは固定長で各チャンクの書き込み先が独立しているため、チャンクを並行発行する
だけでパイプライン化できる (in-flight 上限は multiplexer が管理済み)。

### A-2. 小ファイル読みが 3 往復 (Create → Read → Close)

`lib/src/client.dart:151-158` の `Smb2Tree.readRange` は Create、Read、Close を
それぞれ 1 RTT ずつ、計 3 往復。サムネイルのような小ファイル大量取得ではレイテンシが 3 倍。

対策は 2 段階:

1. **低コスト版**: Close の応答を await せずに返す (送信だけして結果はログ処理)。
   即 1 RTT 削減
2. **本命**: Compound Request (Create+Read+Close を 1 パケット化)。ヘッダの
   `nextCommand` と related operations フラグの実装で 3 RTT → 1 RTT。
   サムネイルバッチへの効果が最も大きい

### A-3. `listDirectory` のページングバッファが 64KB 固定

`lib/src/protocol/messages/query_directory.dart:36` — `outputBufferLength = 65536`。
ページングは前の応答を見てから次を出す構造上直列にしかできないため、
1 往復あたりの取得量を増やすのが唯一のレバー。negotiate 済みの maxTransactSize
(通常 1MB 以上) まで引き上げれば、大ディレクトリで往復回数が最大 1/16。

注意: その際 `buildHeader` で `creditCharge = ceil(outputBufferLength / 65536)` の
設定が必要 (現状 charge=1 のまま大バッファを要求するとプロトコル違反)。

## B. 高速化の余地 (コピー削減)

### B-1. Read 応答データの二重コピー

`lib/src/protocol/messages/read.dart:85` — `Uint8List.fromList(body.sublist(...))` は
`sublist` で 1 回、`fromList` でもう 1 回コピーする。1MB ブロックごとに 2MB の memcpy。
`body.sublist(...)` 単独 (1 コピー) か `Uint8List.sublistView` (ゼロコピー。Read 応答は
ほぼ全体がデータなのでパケットを保持しても無駄が少ない) にできる。

### B-2. 受信バッファの takeBytes / 再 add 方式

`lib/src/transport/connection.dart:43-63` — メッセージ境界のたびに `takeBytes()` で
全連結 → 分割 → 残りを再 add しており、NetBIOS ヘッダ読み (4 バイト) と本体読みで
メッセージ本体が実質 2 回コピーされる。読み出しカーソル方式にすれば 1 回で済む。
B-1 と合わせると 1MB 受信あたりのコピーが約 4MB → 1MB になる。

### B-3. `readAhead` デフォルト 3 は控えめ

`lib/src/file/file_reader.dart:110` — 3 × 1MB のパイプラインは LAN では十分だが、
高レイテンシ環境では不足しがち。接続ダイアログのベンチ機能で実測して 4〜6 に
上げる価値がある。

## C. 並列度を上げる前の注意 (正しさの前提)

### C-1. クレジット管理が「加算のみ」

`lib/src/transport/multiplexer.dart:118-120` — サーバーの grant を `_availableCredits` に
足すだけで、送信時に消費も残高チェックもしていない。1MB Read は creditCharge=16 なので
in-flight 32 件なら 512 クレジット消費だが、クライアントは付与済みかどうかを確認せず
送信する。Samba は寛容でも Windows Server は超過時に切断し得る。
A-1/A-2 で並列度を上げるとこのリスクが顕在化するため、送信時に残高を待つゲートを
セットで入れるべき。

### C-2. `_streamRead` の short read でデータ欠落の可能性

`lib/src/file/file_reader.dart:118-141` — 各ブロックのオフセットを事前計算しているため、
サーバーがミッドファイルで要求長未満を返した場合 (稀だが仕様上は許容)、次ブロックとの
間に穴が空いたまま yield される。`_readOnce` に要求長まで読み直すループを入れるか、
short read を検出してエラーにすべき。

## D. 細かい点

- `lib/src/transport/sender.dart:64-81` — send lock は臨界区間 (`sender.dart:46-57`) に
  await が一切ないため、シングルスレッドの Dart では何も守っていない。削除すれば
  リクエストごとの microtask 往復も減る (簡素化が主目的)
- `lib/src/protocol/messages/query_directory.dart:135` — `ByteData.sublistView(buffer)` が
  エントリごとにループ内で生成される。ループ外へ
- `lib/src/file/file_reader.dart:60` — `offset > _fileSize` のとき `clamp(0, 負値)` が
  ArgumentError を投げる (性能ではなく edge case)

## 推奨する優先順位

1. **C-1 (クレジットゲート) + A-1 (readRange 並列化)** をセットで — 動画・ZIP に即効
2. **A-2 低コスト版 (Close 非待機)** — 数行でサムネイル 1 RTT 削減
3. **A-3 (QueryDirectory バッファ拡大)** — 大ディレクトリ一覧の体感改善
4. **B-1/B-2 (コピー削減)** — CPU とメモリ帯域の削減、モバイルで効く
5. **A-2 本命 (Compound Request)** — 効果は最大だが実装量も最大なので最後
