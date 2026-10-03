/// A mutable value that only one dispatch queue reads and writes.
/// Network callbacks are `@Sendable`, but the AirPlay code runs them all on one serial queue.
final class QueueLocal<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
