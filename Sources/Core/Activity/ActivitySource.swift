public protocol ActivitySource: AnyObject, Sendable {
    var descriptor: ActivitySourceDescriptor { get }

    func start(onReport: @escaping @Sendable (ActivityReport) -> Void) async -> ActivityReport

    func stop() async

    func statusNote() async -> String?
}
