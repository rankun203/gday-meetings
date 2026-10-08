import Foundation

enum LocalModelID: String, CaseIterable, Identifiable, Codable, Sendable {
    case community1, granite97M, granite311M
    var id: String { rawValue }

}

struct LocalModelAsset: Codable, Hashable, Sendable {
    let path: String
    let remotePath: String
    let bytes: Int64
    let digest: String
}

struct LocalModelDescriptor: Sendable {
    let id: LocalModelID
    let title: String
    let repository: String
    let revision: String
    let assets: [LocalModelAsset]
    var modelNames: [String]
    /// Embedding contracts the current extraction adapter can generate. Stored
    /// representations from earlier adapters keep their original type.
    var supportedEmbeddingTypes: [EmbeddingType] = []
    var downloadBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }
}

enum LocalModelRegistry {
    private static let communityAssets: [LocalModelAsset] = [
        .init(
            path: "Embedding.mlmodelc/analytics/coremldata.bin",
            remotePath: "Embedding.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
        .init(
            path: "Embedding.mlmodelc/coremldata.bin", remotePath: "Embedding.mlmodelc/coremldata.bin", bytes: 704,
            digest: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
        .init(
            path: "Embedding.mlmodelc/metadata.json", remotePath: "Embedding.mlmodelc/metadata.json", bytes: 2818,
            digest: "71c70e8c4972bbba271728ee32d9629a31498976"),
        .init(
            path: "Embedding.mlmodelc/model.mil", remotePath: "Embedding.mlmodelc/model.mil", bytes: 78432,
            digest: "39c8175875111f64245779cecad5185968a6db34"),
        .init(
            path: "Embedding.mlmodelc/weights/weight.bin", remotePath: "Embedding.mlmodelc/weights/weight.bin",
            bytes: 13_412_288, digest: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
        .init(
            path: "FBank.mlmodelc/analytics/coremldata.bin", remotePath: "FBank.mlmodelc/analytics/coremldata.bin",
            bytes: 243, digest: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
        .init(
            path: "FBank.mlmodelc/coremldata.bin", remotePath: "FBank.mlmodelc/coremldata.bin", bytes: 853,
            digest: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
        .init(
            path: "FBank.mlmodelc/metadata.json", remotePath: "FBank.mlmodelc/metadata.json", bytes: 3409,
            digest: "b48f04253ef4cd5f92ef76453c57d82ccee3ba31"),
        .init(
            path: "FBank.mlmodelc/model.mil", remotePath: "FBank.mlmodelc/model.mil", bytes: 15667,
            digest: "0e01e8a188d4fe7ee97866948c2ee159fe505248"),
        .init(
            path: "FBank.mlmodelc/weights/weight.bin", remotePath: "FBank.mlmodelc/weights/weight.bin",
            bytes: 1_776_896, digest: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
        .init(
            path: "PldaRho.mlmodelc/analytics/coremldata.bin", remotePath: "PldaRho.mlmodelc/analytics/coremldata.bin",
            bytes: 243, digest: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
        .init(
            path: "PldaRho.mlmodelc/coremldata.bin", remotePath: "PldaRho.mlmodelc/coremldata.bin", bytes: 763,
            digest: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
        .init(
            path: "PldaRho.mlmodelc/metadata.json", remotePath: "PldaRho.mlmodelc/metadata.json", bytes: 2749,
            digest: "b964649416a95f0d8b3f7155a9a1ef46b79543aa"),
        .init(
            path: "PldaRho.mlmodelc/model.mil", remotePath: "PldaRho.mlmodelc/model.mil", bytes: 7613,
            digest: "30c6a1b1bfb5a5a2a9498d52c9529c15ba9e3917"),
        .init(
            path: "PldaRho.mlmodelc/weights/weight.bin", remotePath: "PldaRho.mlmodelc/weights/weight.bin",
            bytes: 200192, digest: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
        .init(
            path: "Segmentation.mlmodelc/analytics/coremldata.bin",
            remotePath: "Segmentation.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
        .init(
            path: "Segmentation.mlmodelc/coremldata.bin", remotePath: "Segmentation.mlmodelc/coremldata.bin",
            bytes: 812, digest: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
        .init(
            path: "Segmentation.mlmodelc/metadata.json", remotePath: "Segmentation.mlmodelc/metadata.json", bytes: 3410,
            digest: "604d6f1f829f47120b5d291825e28a7ee01b5d18"),
        .init(
            path: "Segmentation.mlmodelc/model.mil", remotePath: "Segmentation.mlmodelc/model.mil", bytes: 43063,
            digest: "60b457187b267fd64cd00410f4165d218c4fe7d7"),
        .init(
            path: "Segmentation.mlmodelc/weights/weight.bin", remotePath: "Segmentation.mlmodelc/weights/weight.bin",
            bytes: 5_959_360, digest: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
        .init(
            path: "plda-parameters.json", remotePath: "plda-parameters.json", bytes: 89416,
            digest: "104dc2572aec3eb7d606a619fa738cdc43824cff"),
    ]
    static func descriptor(_ id: LocalModelID) -> LocalModelDescriptor {
        switch id {
        case .granite97M, .granite311M:
            return semanticDescriptor(id)
        case .community1:
            let names = ["Segmentation", "FBank", "Embedding", "PldaRho"]
            return .init(
                id: id, title: "Community-1",
                repository: "FluidInference/speaker-diarization-coreml",
                revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
                assets: communityAssets.filter { asset in
                    names.contains { asset.path.hasPrefix($0 + ".mlmodelc/") }
                        || asset.path == "plda-parameters.json"
                }, modelNames: names, supportedEmbeddingTypes: [.community1SpeechSpan])
        }
    }

}
