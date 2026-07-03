# 修正 1: クレジットゲート (C-1) + readRange 並列化 (A-1)

対象レビュー: [20260703-performance-review.md](20260703-performance-review.md)

readRange の並列化はクレジット消費を一気に増やすため、クレジット管理の完成 (C-1) と
セットで実装する。

## C-1: クレジットゲートの設計

### 現状の問題

`Smb2Multiplexer` はサーバーの grant を `_availableCredits` に加算するだけで、
送信時に消費も残高チェックもしない。並列度を上げるとサーバーの許可量を超えて
送信し、切断され得る。

### 方針

送信予算 (budget) = 「in-flight スロット + クレジット残高」の予約を
multiplexer に一本化する。

- `tryReserveBudget(creditCharge)`: 同期メソッド。以下を原子的に判定・予約する
  (Dart はシングルスレッドなので、await を挟まない一連の処理は原子的)。
  1. `_pending.length >= maxInflight` なら false (スロット不足)
  2. `_availableCredits < creditCharge` かつ in-flight が 1 件以上あれば false
     (今後の応答で grant が来るのを待てる)
  3. 予約成立なら `_availableCredits -= creditCharge` して true
- `waitForBudget()`: 予算が空く可能性のあるタイミング (応答受信) まで待つ。
  sender は「tryReserveBudget → 失敗なら waitForBudget → リトライ」のループ。
- 受信ループは応答 1 件ごとに**待機者全員**を起こす (wake-all)。待機者ごとに必要な
  クレジット量が異なるため、1 人ずつ起こすと「先頭の大口が通れず後続の小口も
  詰まる」状態になり得る。全員起こして各自に再判定させる方が単純で正しい。
  STATUS_PENDING の中間応答も grant を運ぶので、そこでも起こす。

### デッドロック回避 (liveness フォールバック)

in-flight が 0 件のときは、今後クレジットが補充される契機がない。この状態で
残高不足のリクエストを待たせると永久に固まるため、**in-flight 0 件なら残高不足でも
送信を許可**し、warning ログを出して残高を 0 にクランプする。

- 根拠: 現状のコードは常に残高チェックなしで送信して動作している。フォールバックは
  「現状と同じ動作に縮退する」だけで、悪化はしない
- 発動場面: 接続直後に大きな Read (charge 16) を発行し、ハンドシェイクでの grant が
  少なかった場合など。実際のサーバー (Samba/Windows) はリクエストごとに 32 クレジット
  要求 (`creditRequestResponse = 32`) に応えるため、定常状態ではまず発動しない

### 変更点

- `multiplexer.dart`: `_inflightWaiters` → `_budgetWaiters` に改名し、
  `tryReserveBudget` / `waitForBudget` を追加。`acquireInflightSlot` と
  `isInflightFull` は sender 専用だったため削除 (公開 API には含まれない)
- `sender.dart`: 送信ループを budget 予約ベースに変更。予約 (同期) →
  MessageId 割り当て → 登録 → 送信までを await なしで行い、原子性を保つ
- 受信ループ終了時の後始末 (待機者への completeError) は従来どおり

## A-1: readRange 並列化の設計

### 方針

maxReadSize 超のレンジをチャンク分割し、**ワーカープール方式**で並行読みする。

- チャンク数とオフセットは事前計算 (結果バッファの書き込み先が互いに素)
- ワーカー数 = `readAhead` (デフォルト 4、引数で変更可)。共有カーソル
  (次チャンク index) をローカル変数で持ち、各ワーカーが順に取っていく
- 全チャンクを一斉発行しない理由: 巨大レンジ (数十 MB の ZIP エントリ等) が
  in-flight 32 スロットとクレジットを独占し、並行するサムネイル取得等を
  飢餓させるのを防ぐ。readAhead=4 でも直列比 4 倍のスループット
- 状態はすべて呼び出しローカル (インスタンス変数での共有はしない —
  CLAUDE.md の並行実行ルールに準拠)

### short read の扱い

従来の直列版は「要求長未満のチャンクが来たら打ち切って先頭からの連続分を返す」
だった。並列版も同じ意味論を保つ: 各チャンクの実受信長を記録し、完了後に
「先頭から連続して埋まっている長さ」を計算して返す。

### エラーの扱い

いずれかのチャンクが失敗したら `failed` フラグでワーカーの新規発行を止め、
最初のエラーを rethrow する (発行済みリクエストは multiplexer 側で応答を受けて
捨てられる)。

### 付随修正

- `readRange` 先頭に `offset >= _fileSize` ガードを追加。従来は
  `length.clamp(0, 負値)` が ArgumentError を投げていた (レビュー D 項)

## テスト方針

`Smb2Connection` の公開インターフェイス (sendRaw / readMessage / isClosed / close) を
実装したフェイク接続を作り、multiplexer + sender + file_reader を実際に結合して
スクリプト化した応答でテストする。

- クレジットゲート: 残高不足のリクエストが応答 (grant) 到着まで送信されないこと
- liveness フォールバック: in-flight 0 件なら残高不足でも送信されること
- wake-all: 大口が待機中でも grant 到着後に正しく解放されること
- readRange: 並列発行されること (応答を遅延させ、送信数が readAhead に達することを確認)、
  結果バイト列の一致、short read 時の prefix 返却、チャンク失敗時の例外伝播

## 実装後の懸念点

実装・テスト完了 (ユニットテスト 95 件パス)。以下は把握済みの残懸念:

1. **liveness フォールバックは厳格なサーバーで理論上切断され得る**。接続直後に
   charge 16 の Read を発行し、ハンドシェイクの grant が不足していた場合に発動する。
   実サーバー (Samba/Windows) はリクエストごとの 32 クレジット要求に応えるため
   実際にはまず起きないが、もし発生する環境が見つかったら「フォールバック送信」
   ではなく「残高に収まるよう Read サイズを縮小する」方式に切り替えるのが正道
2. **wake-all の公平性**: 応答ごとに待機者全員を起こして再判定させるため、
   厳密な FIFO ではない (大口の charge が待つ間に小口が先に通る)。ただし応答ごとに
   grant (32) > 小口の消費 (1) で残高は単調に増えるため、大口が恒久的に
   飢餓することはない。起床コストも同時待機者数 (高々数十) に比例するだけ
3. **readAhead=4 は readRange 呼び出しごと**。複数の readRange が並行すると
   合計はその倍数になるが、multiplexer の in-flight 32 とクレジット残高が
   全体の上限として効く (これが今回ゲートを入れた理由)
4. **short read 後の無駄読み**: あるチャンクが short だった場合でも、後続チャンクの
   読み込みは完了まで走る (結果は捨てられる)。short read 自体が稀なので許容
5. **実サーバーでの検証は未実施**。この環境ではフェイク接続によるユニットテストのみ。
   `test/integration/` のテスト (要 SMB サーバー) とアプリでの動作確認
   (動画シーク、ZIP 表示、サムネイルバッチ) を別途行うこと

## 結果

- `lib/src/transport/multiplexer.dart`: `tryReserveBudget` / `waitForBudget` を追加、
  受信ループが応答ごとに待機者全員を起床、`acquireInflightSlot` / `isInflightFull` は削除
- `lib/src/transport/sender.dart`: 送信ループを budget 予約ベースに変更
- `lib/src/file/file_reader.dart`: `readRange` をワーカープール方式で並列化
  (デフォルト readAhead=4)、`offset >= fileSize` ガード追加
- テスト追加: `test/fake_connection.dart` (フェイク接続)、`test/send_budget_test.dart`
  (クレジットゲート 6 件)、`test/file_reader_test.dart` (readRange 並列読み 8 件)
