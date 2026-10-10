import Foundation

enum ScannerProtocol {
    static func frame(_ metrics: CodexMetrics, version: Int) throws -> String {
        let left = metrics.usedPercent.map { String(max(0, min(100, 100 - $0))) } ?? "-1"
        let week = metrics.weekUsedPercent.map { String(max(0, min(100, 100 - $0))) } ?? "-1"
        let tokens = metrics.totalTokens.map(String.init) ?? "-1"
        if version >= 2 {
            return "CODEX2 \(left) \(tokens) \(week)\n"
        }
        guard metrics.usedPercent != nil, metrics.totalTokens != nil else {
            throw BridgeError.serial("扫描仪仍为旧协议 v1；请升级扫描仪固件以同步未知额度，其他设备同步不受影响")
        }
        return "CODEX \(left) \(tokens)" + (metrics.weekUsedPercent != nil ? " \(week)" : "") + "\n"
    }
}
