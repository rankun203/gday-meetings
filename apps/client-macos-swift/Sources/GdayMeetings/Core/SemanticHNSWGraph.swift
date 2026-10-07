import Foundation
import USearchC

/// Owned only by SemanticSearchIndex's actor. No native pointer crosses an actor boundary.
final class SemanticHNSWGraph {
    private let handle: usearch_index_t
    let dimensions: Int
    private(set) var count = 0
    private var capacity = 0

    init(dimensions: Int) throws {
        self.dimensions = dimensions
        var options = usearch_init_options_t(
            metric_kind: usearch_metric_cos_k, metric: nil, quantization: usearch_scalar_i8_k,
            dimensions: dimensions, connectivity: 32, expansion_add: 128, expansion_search: 2000, multi: false)
        var error: usearch_error_t?
        let pointer = usearch_init(&options, &error)
        try Self.check(error)
        guard let pointer else { throw SearchProviderError.invalidResponse }
        handle = pointer
    }
    deinit {
        var error: usearch_error_t?
        usearch_free(handle, &error)
    }
    private static func check(_ error: usearch_error_t?) throws {
        if let error { throw ServiceError("Couldn’t access the search graph. \(String(cString: error))") }
    }
    func reserve(_ size: Int) throws {
        guard size > capacity else { return }
        var error: usearch_error_t?
        capacity = max(size, max(256, capacity * 2))
        usearch_reserve(handle, capacity, &error)
        try Self.check(error)
    }
    func add(key: Int64, bytes: Data) throws {
        guard key > 0, bytes.count == dimensions else { throw SearchProviderError.invalidResponse }
        try reserve(count + 1)
        var error: usearch_error_t?
        bytes.withUnsafeBytes { usearch_add(handle, UInt64(key), $0.baseAddress, usearch_scalar_i8_k, &error) }
        try Self.check(error)
        count += 1
    }
    func remove(key: Int64) throws {
        var error: usearch_error_t?
        let removed = usearch_remove(handle, UInt64(key), &error)
        try Self.check(error)
        count -= removed
    }
    private final class Filter {
        let excluded: Set<Int64>
        init(_ excluded: Set<Int64>) { self.excluded = excluded }
    }
    func search(_ vector: [Float], count requested: Int, excluding: Set<Int64>) throws -> [Int64] {
        guard vector.count == dimensions else { throw SearchProviderError.invalidResponse }
        let limit = min(requested, count)
        guard limit > 0 else { return [] }
        var keys = [UInt64](repeating: 0, count: limit)
        var distances = [Float](repeating: 0, count: limit)
        let filter = Filter(excluding)
        var error: usearch_error_t?
        let found = withExtendedLifetime(filter) {
            vector.withUnsafeBufferPointer { buffer in
                usearch_filtered_search(
                    handle, buffer.baseAddress, usearch_scalar_f32_k, limit,
                    { key, context in
                        guard let context, key <= UInt64(Int64.max) else { return 0 }
                        let filter = Unmanaged<Filter>.fromOpaque(context).takeUnretainedValue()
                        return filter.excluded.contains(Int64(key)) ? 0 : 1
                    }, Unmanaged.passUnretained(filter).toOpaque(), &keys, &distances, &error)
            }
        }
        try Self.check(error)
        return keys.prefix(found).map(Int64.init)
    }
    func save(_ url: URL) throws {
        var error: usearch_error_t?
        usearch_save(handle, url.path, &error)
        try Self.check(error)
    }
    func load(_ url: URL, expectedCount: Int) throws {
        var error: usearch_error_t?
        var options = usearch_init_options_t()
        usearch_metadata(url.path, &options, &error)
        try Self.check(error)
        guard options.dimensions == dimensions, options.quantization == usearch_scalar_i8_k,
            options.metric_kind == usearch_metric_cos_k
        else { throw SearchProviderError.invalidResponse }
        usearch_load(handle, url.path, &error)
        try Self.check(error)
        count = usearch_size(handle, &error)
        try Self.check(error)
        guard count == expectedCount else { throw SearchProviderError.invalidResponse }
        capacity = usearch_capacity(handle, &error)
        try Self.check(error)
        usearch_change_expansion_search(handle, 2000, &error)
        try Self.check(error)
    }
    var hardware: String {
        var error: usearch_error_t?
        guard let value = usearch_hardware_acceleration(handle, &error), error == nil else { return "unknown" }
        return String(cString: value)
    }
}
