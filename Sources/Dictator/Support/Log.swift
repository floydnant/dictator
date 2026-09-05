import OSLog

enum Log {
    static let audio = Logger(subsystem: "com.floyd.dictator", category: "audio")
    static let speech = Logger(subsystem: "com.floyd.dictator", category: "speech")
    static let hotkey = Logger(subsystem: "com.floyd.dictator", category: "hotkey")
    static let inject = Logger(subsystem: "com.floyd.dictator", category: "inject")
    static let app = Logger(subsystem: "com.floyd.dictator", category: "app")
}
