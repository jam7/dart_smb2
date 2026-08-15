# 設計: ファイルの書き込み (P1)

- 作成: 2026-08-15 / 状態: approved (P1、2026-08-15 に実サーバーで確認)
- 対応仕様: spec.md (S-01 〜 S-06)

## 全体像

読み取りと同じ形にする。`Smb2Tree` が開く役、返ってきたオブジェクトが読み書き
する役、という分担が既にあるので、書き込みはその鏡像として入る。

```
Smb2Tree.openRead(path)   → Smb2FileReader  (既存)
Smb2Tree.createNew(path)  → Smb2FileWriter  (追加)

Smb2FileWriter.write(bytes)
   └ 位置を同期的に確定 → maxWriteSize ごとに分割 → WriteRequest を送る
Smb2FileWriter.close()
   └ CloseRequest を送り、応答を待つ
```

新しいファイルは 3 つ。`lib/src/protocol/messages/write.dart` (メッセージ)、
`lib/src/file/file_writer.dart` (writer)、`test/write_test.dart`。
既存ファイルへの変更は `client.dart` に `createNew` を足すことと、
`create.dart` に書き込み用のアクセスマスクを 1 つ足すこと、
`dart_smb2.dart` の export 1 行だけ。

## D-01: 開く口は `Smb2Tree.createNew` (実現する仕様: S-01)

```dart
Future<Smb2FileWriter> createNew(String path);
```

Create 要求を 1 通送り、応答の `FileId` を持った writer を返す。フィールドは
読み取り側と同じ組み合わせで、`maxReadSize` の代わりに `maxWriteSize` を渡す。

| フィールド | 値 | 理由 |
|---|---|---|
| `CreateDisposition` | `FILE_CREATE` | 既にあれば**サーバーが**失敗させる (S-01) |
| `CreateOptions` | `FILE_NON_DIRECTORY_FILE` | 同名のディレクトリがあれば `STATUS_FILE_IS_A_DIRECTORY` |
| `DesiredAccess` | 下記 `AccessMask.write` | |
| `ShareAccess` | `FILE_SHARE_READ` | 書いている最中に他から読むのは許す。**他からの書き込みと削除は許さない** — 1 本のファイルを 2 人が同時に書く筋書きが P1 に無いため |

`AccessMask.write` を `create.dart` に足す:

```dart
static const int write =
    fileWriteData | fileReadAttributes | fileWriteAttributes | synchronize;
```

`fileReadAttributes` を含めるのは、Create の応答から `EndOfFile` を読むため
(P3 の追記で必要になる。P1 では使わないが、アクセス権は開くときにしか決められ
ないので最初から入れておく)。

## D-02: `WriteRequest` / `WriteResponse` (実現する仕様: S-02, S-03)

`read.dart` の鏡像として `write.dart` を書く。構造体の形は [MS-SMB2] 2.2.21:

```dart
class WriteRequest {
  final FileId fileId;
  final int offset;
  final Uint8List data;
  Smb2Header buildHeader({required int sessionId, required int treeId});
  Uint8List encode();
}

class WriteResponse {
  final int count;   // サーバーが受け取ったバイト数
  static WriteResponse decode(Uint8List body);
}
```

`creditCharge` は読み取りと同じ `ceil(length / 65536)`。**応答の `Count` を
読むこと**が S-05 の土台で、「送った量」ではなく「サーバーが受け取ったと
言った量」を積む。

## D-03: `Smb2FileWriter` (実現する仕様: S-02, S-03, S-05)

```dart
class Smb2FileWriter {
  Future<void> write(Uint8List bytes);
  Future<void> close();
  int get written;
}
```

内部の状態は 4 つ: `_position` (次に書く位置)、`_written` (サーバーが受け取ったと
答えた合計)、`_closed`、`_broken` (D-05)。

### ADR-01: 位置は `await` の前に確定する

- **背景**: P1 は直列に送るが、次の段階 (P5) で 1 回の `write` の中を並列化し、
  さらに呼び出し元が `await` せずに `write` を連打する使い方も想定している
- **選択肢**: (a) 送信が終わってから位置を進める (b) 呼ばれた瞬間に位置を確定し、
  送信はその後
- **決定**: (b)。`write` の本体は次の 3 行で始まる:

  ```dart
  final at = _position;
  _position += bytes.length;
  return _sendBlocks(at, bytes);
  ```

- **理由**: (a) だと、`await` を挟まずに `write(a); write(b);` と呼ばれたとき
  両方が同じ位置を見て**領域が重なる**。(b) なら割り当ては呼ばれた順に済んで
  いるので重ならない。**API の形ではなくこの 3 行の順序が並列化の可否を決める**
  ので、直列のうちから正しい形にしておく

## D-04: 1 回の要求は 1MB まで (実現する仕様: S-03)

### ADR-02: サーバーが 8MB と言っても 1MB に丸める

- **背景**: 今のサーバーはネゴシエーションで `maxWrite: 8388608` (8MB) を
  申告する (2026-08-15 の実測)。読み取り側は `maxRead` を 1MB に丸めている
- **選択肢**: (a) サーバーの申告どおり 8MB (b) 読み取りと同じ 1MB
- **決定**: (b) 1MB
- **理由**: `creditCharge = ceil(length / 65536)` なので、**8MB の要求 1 通で
  128 credit を消費する**。サーバーが 1 応答で与えるのは 32 credit で、
  多重化の在庫も 32 なので、8MB を送るには credit の補充待ちが入る。1MB なら
  16 credit で、読み取りが 110MB/s 出ている実績もある。**速度のために大きく
  するのは P5 で測ってから**

## D-05: 一度失敗した writer は、以後受け付けない (実現する仕様: S-05)

### ADR-03: 失敗後に書き続けさせない

- **背景**: S-05 は「失敗したときの `written` は、共有上に残っているファイルの
  長さと等しい」と決めた
- **選択肢**: (a) 失敗しても次の `write` を受ける (b) 失敗したら以後すべて拒む
- **決定**: (b)。`_broken` を立て、以後の `write` は送信せずに例外を投げる
- **理由**: (a) だと、3 番目のブロックが失敗した後に 4 番目を書けてしまい、
  **ファイルの中に穴が空く**。長さは伸びるのに中身が欠けるので、`written` は
  もう長さと一致せず、S-05 が成り立たない。**穴の空いたファイルを作らせない**
  ことのほうが、書き続けられることより価値が高い
- **帰結**: 呼び出し元は失敗したら writer を捨てる。やり直すなら
  `createNew` からで、**その名前は既に存在する**ので消してからになる (P2)

## D-06: `close` は待つ (実現する仕様: S-02, S-04)

### ADR-04: 読み取りの close と違って、待って結果を見る

- **背景**: `Smb2FileReader.close()` は fire-and-forget で、失敗はログだけ。
  読み終えた後の close が失敗しても、既に手にしたバイト列は変わらないため
- **選択肢**: (a) 読み取りに揃えて投げっぱなし (b) 応答を待ち、失敗は例外
- **決定**: (b)
- **理由**: 書き込みの `close` は「**これで完成**」という宣言で、失敗を握り
  つぶすと**未完成のファイルを成功として返す**ことになる。読み取りとの
  非対称は意図的で、非対称の理由がこれ
- **帰結**: `close` は 2 度呼んでも良い (2 度目は何もしない)。1 度目で
  送った Close の応答を待ってから `_closed` を立てる

## D-07: 既存の読み取りに手を入れない (実現する仕様: S-06)

追加だけで済む形にする。`file_reader.dart` は 1 行も変えない。`client.dart` は
`createNew` の追加のみ。`create.dart` は定数の追加のみ。`dart_smb2.dart` に
`Smb2FileWriter` の export を足す。

`Smb2Tree` を書き込みで汚さないために writer を別ファイルに置く
(`lib/src/file/file_writer.dart`)。読み取りが `file_reader.dart` に居るのと同じ
分け方で、**tree は開くだけ、実際の I/O は開いて返したオブジェクト**という
既存の責務分担を保つ。

## D-08: テストは 2 段構え (実現する仕様: S-01 〜 S-06)

| 層 | 何を確かめるか | 仕掛け |
|---|---|---|
| 単体 | 要求の組み立て、分割の回数と長さ、位置の進み方、失敗後に拒むこと | `FakeConnection` + `Smb2Tree.forTesting` (既存) |
| 統合 | **本当に書けているか** — 読み直して一致、既存への衝突、長さ 0 | 実サーバー、`SMB_WRITE_DIR` (`/tmp`) |

単体だけでは S-02 の「読み直すと一致する」を確かめられない (偽サーバーは
書いたことにするだけ)。**統合テストが無い状態で緑になる形を作らない**のが
この 2 段構えの目的。

## S↔D 対応表 (ゲート G2 で確認)

| S | 対応する D |
|---|---|
| S-01 | D-01 |
| S-02 | D-02, D-03, D-06 |
| S-03 | D-02, D-03, D-04 |
| S-04 | D-06 |
| S-05 | D-03, D-05 |
| S-06 | D-07 |

## 依存の向き

```
client.dart (Smb2Tree)
    └→ file_writer.dart (Smb2FileWriter)
            └→ protocol/messages/write.dart
                    └→ protocol/header.dart, commands.dart, create.dart (FileId)
```

一方向。`file_writer.dart` は `client.dart` を知らない (sender と id だけ受け取る)
ので、読み取り側と同じく tree 無しでテストできる。
