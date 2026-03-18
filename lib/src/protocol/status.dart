/// NT status codes used in SMB2.
class NtStatus {
  static const int success = 0x00000000;
  static const int moreProcessingRequired = 0xC0000016;
  static const int invalidParameter = 0xC000000D;
  static const int noSuchFile = 0xC000000F;
  static const int endOfFile = 0xC0000011;
  static const int accessDenied = 0xC0000022;
  static const int objectNameNotFound = 0xC0000034;
  static const int objectNameCollision = 0xC0000035;
  static const int logonFailure = 0xC000006D;
  static const int badNetworkName = 0xC00000CC;
  static const int notFound = 0xC0000225;
  static const int noMoreFiles = 0x80000006;
  static const int bufferOverflow = 0x80000005;
  static const int pending = 0x00000103;
  static const int cancelled = 0xC0000120;
  static const int userSessionDeleted = 0xC0000203;
  static const int networkSessionExpired = 0xC000035C;

  static bool isError(int status) => (status & 0xC0000000) == 0xC0000000;
  static bool isWarning(int status) => (status & 0x80000000) == 0x80000000 && !isError(status);
  static bool isSuccess(int status) => status == success || status == pending;

  static String describe(int status) {
    switch (status) {
      case success: return 'STATUS_SUCCESS';
      case moreProcessingRequired: return 'STATUS_MORE_PROCESSING_REQUIRED';
      case noMoreFiles: return 'STATUS_NO_MORE_FILES';
      case endOfFile: return 'STATUS_END_OF_FILE';
      case accessDenied: return 'STATUS_ACCESS_DENIED';
      case logonFailure: return 'STATUS_LOGON_FAILURE';
      case badNetworkName: return 'STATUS_BAD_NETWORK_NAME';
      case objectNameNotFound: return 'STATUS_OBJECT_NAME_NOT_FOUND';
      case noSuchFile: return 'STATUS_NO_SUCH_FILE';
      case bufferOverflow: return 'STATUS_BUFFER_OVERFLOW';
      case pending: return 'STATUS_PENDING';
      default: return '0x${status.toRadixString(16).padLeft(8, '0').toUpperCase()}';
    }
  }
}
