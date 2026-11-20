import OSLog

final class LogManager {
    static let shared = LogManager()
    private let logger = Logger(subsystem: "com.stik.stikdebug", category: "Location")
    private init() {}

    func addInfoLog(_ message: String) { logger.info("\(message)") }
    func addErrorLog(_ message: String) { logger.error("\(message)") }
    func addDebugLog(_ message: String) { logger.debug("\(message)") }
    func addWarningLog(_ message: String) { logger.warning("\(message)") }
}
