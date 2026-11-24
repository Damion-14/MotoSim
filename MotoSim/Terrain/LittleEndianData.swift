import Foundation

extension Data {
    func le16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func le32(_ offset: Int) -> UInt32 {
        UInt32(le16(offset)) | (UInt32(le16(offset + 2)) << 16)
    }
}
