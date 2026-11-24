import Foundation

final class ThermalSensor {
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var observer: NSObjectProtocol?

    init(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    func arm() {
        guard observer == nil else { return }
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        let onChange = onChange
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: operations
        ) { _ in onChange() }
    }

    func disarm() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }
}
