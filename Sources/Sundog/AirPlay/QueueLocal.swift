/// A mutable value that only one dispatch queue reads and writes.
/// Network callbacks are `@Sendable`. But the AirPlay code runs all of them on one serial queue.
final class QueueLocal<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
