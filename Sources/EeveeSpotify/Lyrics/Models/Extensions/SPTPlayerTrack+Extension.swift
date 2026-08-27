extension SPTPlayerTrack {
    var trackIdentifier: String {
        self.URI().spt_trackIdentifier()
    }

    /// 从 Spotify 的 metadata 字典提取歌曲时长（毫秒）。
    /// 键名在不同版本/平台可能是 duration / duration_ms / durationMs 等，
    /// 值可能是毫秒或秒字符串。取不到返回 nil（本地文件等），调用方应跳过时长校验。
    var trackDurationMilliseconds: Int? {
        for key in ["duration", "duration_ms", "durationMs", "durationInMilliseconds"] {
            guard let raw = metadata()[key] else { continue }
            // Int(raw) 处理整数串；Double(raw) 兜底小数串（如 "210.0"）。
            let value = Int(raw) ?? Int(Double(raw) ?? 0)
            guard value > 0 else { continue }
            // 小于 60000 视为秒（毫秒值的正常歌曲 ≥ 60s），换算成毫秒。
            // 若设备端实测值单位与假设不符，改这里即可。
            return value < 60000 ? value * 1000 : value
        }
        return nil
    }
}
