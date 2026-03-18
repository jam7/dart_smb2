/// SMB2 command constants.
class Smb2Command {
  static const int negotiate = 0x0000;
  static const int sessionSetup = 0x0001;
  static const int logoff = 0x0002;
  static const int treeConnect = 0x0003;
  static const int treeDisconnect = 0x0004;
  static const int create = 0x0005;
  static const int close = 0x0006;
  static const int flush = 0x0007;
  static const int read = 0x0008;
  static const int write = 0x0009;
  static const int lock = 0x000A;
  static const int ioctl = 0x000B;
  static const int cancel = 0x000C;
  static const int echo = 0x000D;
  static const int queryDirectory = 0x000E;
  static const int changeNotify = 0x000F;
  static const int queryInfo = 0x0010;
  static const int setInfo = 0x0011;
  static const int oplockBreak = 0x0012;
}

/// SMB2 header flags.
class Smb2Flags {
  static const int serverToRedir = 0x00000001;
  static const int asyncCommand = 0x00000002;
  static const int relatedOperations = 0x00000004;
  static const int signed = 0x00000008;
  static const int dfsOperations = 0x10000000;
  static const int replayOperation = 0x20000000;
}
