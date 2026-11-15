// Read-only parser for Steam's binary KeyValues files.
//
// Both UserGameStatsSchema_<app>.bin and the stats cache use this format.
// The app only needs to read the schema (to list achievements), so this is a
// small reader rather than a full DOM.
import Foundation

enum BKVNode {
    case section([(String, BKVNode)])
    case string(String)
    case int(Int32)
    case float(Float)
    case uint64(UInt64)
    case int64(Int64)
}

extension BKVNode {
    var children: [(String, BKVNode)]? {
        if case .section(let children) = self { return children }
        return nil
    }

    func child(_ name: String) -> BKVNode? {
        children?.first { $0.0 == name }?.1
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int32? {
        if case .int(let value) = self { return value }
        return nil
    }

    var isSection: Bool {
        if case .section = self { return true }
        return false
    }
}

enum BKVError: LocalizedError {
    case truncated
    case unsupportedType(UInt8)
    case notASection

    var errorDescription: String? {
        switch self {
        case .truncated: return "The KeyValues file ended unexpectedly."
        case .unsupportedType(let type): return "The KeyValues file uses an unknown type (\(type))."
        case .notASection: return "The KeyValues file does not start with a section."
        }
    }
}

enum BKV {
    static func parse(_ data: Data) throws -> BKVNode {
        var bytes = [UInt8](data)
        var offset = 0
        guard let (_, node) = try parseNode(&bytes, &offset, depth: 0) else {
            throw BKVError.truncated
        }
        guard node.isSection else { throw BKVError.notASection }
        return node
    }

    private static func parseNode(_ bytes: inout [UInt8], _ offset: inout Int,
                                  depth: Int) throws -> (String, BKVNode)? {
        guard depth <= 64 else { throw BKVError.truncated }
        guard offset < bytes.count else { throw BKVError.truncated }

        let type = bytes[offset]
        offset += 1
        if type == 8 { return nil } // END
        let name = try readName(&bytes, &offset)

        switch type {
        case 0:
            var children: [(String, BKVNode)] = []
            while true {
                guard offset < bytes.count else { throw BKVError.truncated }
                if bytes[offset] == 8 {
                    offset += 1
                    break
                }
                guard let child = try parseNode(&bytes, &offset, depth: depth + 1) else {
                    break
                }
                children.append(child)
            }
            return (name, .section(children))
        case 1:
            let value = try readName(&bytes, &offset)
            return (name, .string(value))
        case 2:
            return (name, .int(try readInt32(&bytes, &offset)))
        case 3:
            return (name, .float(Float(bitPattern: UInt32(bitPattern: try readInt32(&bytes, &offset)))))
        case 7:
            return (name, .uint64(try readUInt64(&bytes, &offset)))
        case 10:
            return (name, .int64(Int64(bitPattern: try readUInt64(&bytes, &offset))))
        default:
            throw BKVError.unsupportedType(type)
        }
    }

    private static func readName(_ bytes: inout [UInt8], _ offset: inout Int) throws -> String {
        let start = offset
        while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
        guard offset < bytes.count else { throw BKVError.truncated }
        let value = String(decoding: bytes[start..<offset], as: UTF8.self)
        offset += 1
        return value
    }

    private static func readInt32(_ bytes: inout [UInt8], _ offset: inout Int) throws -> Int32 {
        guard offset + 4 <= bytes.count else { throw BKVError.truncated }
        let value = bytes[offset..<offset + 4].reversed().reduce(Int32(0)) {
            ($0 << 8) | Int32($1)
        }
        offset += 4
        return value
    }

    private static func readUInt64(_ bytes: inout [UInt8], _ offset: inout Int) throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw BKVError.truncated }
        var value: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        offset += 8
        return value
    }
}
