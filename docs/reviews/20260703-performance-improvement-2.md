# 修正 2: Close 応答の非待機化 (A-2 低コスト版)

対象レビュー: [20260703-performance-review.md](20260703-performance-review.md)

## 現状の問題

小ファイル読み (`Smb2Tree.readRange` / `readFile`) は Create → Read → Close の
3 往復で、うち最後の Close は「データ取得後の後始末」なのに呼び出し元が
その応答まで待たされる。サムネイルバッチのように open/read/close を大量に
繰り返す用途では、全体レイテンシの 1/3 が Close 待ちになる。
`listDirectory` も同様に最後の Close 1 往復ぶん待っている。

## 方針

Close は**送信して応答を待たない** (fire-and-forget) に変更する。

- 対象: `Smb2FileReader.close()` と `Smb2Tree._closeFile()` (listDirectory 用)
- `close()` は Close リクエストを sender のキューに乗せた時点で返る。
  応答は multiplexer が通常どおり受けて捨てる
- エラーは future に**同期的に**ハンドラを付けて warning ログに落とす
  (unhandled async error を出さない)。従来も Close のエラーは warning ログ
  のみで呼び出し元に伝えていないため、観測可能な意味論は変わらない
- API シグネチャは `Future<void>` のまま (呼び出し側の変更不要)

## 安全性の検討

- **応答は誰が受けるか**: multiplexer の pending に登録されるので、応答が来れば
  完了してスロットとクレジットの会計も正常に回る。接続断で応答が来ない場合は
  受信ループの後始末が completeError し、付けておいたハンドラがログに落とす
- **順序**: sender の送信ループは FIFO なので、close() 直後に同じツリーへ発行した
  リクエストに追い越されない (追い越されても SMB 的には別ハンドルなので無害)
- **disconnect との競合**: close() 直後に disconnect() しても、Logoff/切断で
  サーバー側のハンドルは破棄されるためリークしない
- **ハンドル数**: Close の完了を待たずに次の open に進めるが、Close 自体は
  in-flight 上限とクレジットの管理下にあるため、未処理 Close が無制限に
  溜まることはない

## テスト方針

- close() が Close リクエスト送信後、応答なしで完了すること
- Close にエラー応答が返っても throw も unhandled error も起きないこと
- Close 送信後に接続が閉じても unhandled error が起きないこと
- listDirectory が Close 応答なしでエントリを返すこと (`_closeFile` 側の確認)

## 実装後の懸念点

実装・テスト完了 (ユニットテスト 99 件パス、うち今回追加 4 件)。以下は把握済みの残懸念:

1. **close() の完了 = 送信完了ではない**。sender の budget 待ちに入った場合、close()
   が返った時点では Close はまだソケットに書かれていないことがある。送信キューは
   FIFO なので順序は保たれ、multiplexer の会計にも影響しない
2. **未応答の Close が in-flight スロットを占有する**。open/read/close を高速に
   繰り返すと、応答待ち Close が maxInflight (32) の一部を使う。応答は RTT 間隔で
   返ってくるため定常的には数件程度で、実害はないと判断。問題になったら Close の
   creditCharge=1 のみ先行返却する等の最適化余地あり
3. **実サーバーでの検証は未実施**。フェイク接続によるユニットテストのみ。アプリでの
   動作確認 (サムネイルバッチ、ディレクトリ一覧、ZIP、動画) を別途行う

## 結果

- `lib/src/file/file_reader.dart`: `close()` を fire-and-forget 化。エラーハンドラを
  同期的に付けて warning ログに落とす (unhandled async error を出さない)
- `lib/src/client.dart`: `Smb2Tree._closeFile()` も同様に fire-and-forget 化。
  テスト用に `Smb2Tree.forTesting` コンストラクタを追加 (ハンドシェイクなしで
  フェイク transport 上に tree を構築する。修正 3 の listDirectory テストでも使う)
- テスト追加: `test/close_test.dart` (close 非待機 3 件 + listDirectory 1 件)
