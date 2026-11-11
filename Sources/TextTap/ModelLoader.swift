/// Loads a model once, on first use, and loads it again after a failure.
actor ModelLoader<Model> {
    private let name: String
    private let load: () async throws -> Model
    private var loading: Task<Model, Error>?

    init(_ name: String, load: @escaping () async throws -> Model) {
        self.name = name
        self.load = load
    }

    func preload() async {
        do {
            _ = try await model()
        } catch {
            print("[TextTap] \(name) preload failed; will retry when needed")
        }
    }

    func model() async throws -> Model {
        if loading == nil {
            loading = Task { try await load() }
        }
        do {
            return try await loading!.value
        } catch {
            loading = nil
            throw error
        }
    }
}
