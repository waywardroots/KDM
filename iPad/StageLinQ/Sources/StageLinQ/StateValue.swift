import Foundation

/// A StateMap value. Devices send small JSON objects such as
/// {"string":"8A","type":8}, {"value":124.0,"type":0} or {"state":true,"type":1}.
public enum StateValue: Equatable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    /// Valid JSON we don't have a field for, kept as text.
    case other(String)

    public init(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self = .other(json)
            return
        }
        if let s = obj["string"] as? String {
            self = .string(s)
        } else if let b = obj["state"] as? Bool {
            self = .bool(b)
        } else if let n = obj["value"] as? NSNumber {
            // JSONSerialization gives NSNumber for both numbers and booleans.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        } else if let n = obj["state"] as? NSNumber {
            self = .bool(n.boolValue)
        } else {
            self = .other(json)
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var number: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n == n.rounded() && abs(n) < 1e9 ? String(Int(n)) : String(format: "%.3f", n)
        case .bool(let b): return b ? "true" : "false"
        case .other(let s): return s
        }
    }
}
