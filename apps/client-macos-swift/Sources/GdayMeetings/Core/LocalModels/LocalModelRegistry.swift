import FluidAudio
import Foundation

enum LocalModelID: String, CaseIterable, Identifiable, Codable, Sendable {
    case nemotronLow, nemotronFast, nemotronFast32, nemotronFast128, nemotronOffline, nemotronFast32SplitW8A8,
        nemotronC128SplitW8A8, community1, granite97M, granite311M
    var id: String { rawValue }
    var nemotronPreset: String? {
        switch self {
        case .nemotronLow: return "low"
        case .nemotronFast: return "fast"
        case .nemotronFast32: return "fast32"
        case .nemotronFast128: return "fast128"
        case .nemotronOffline: return "offline"
        case .nemotronFast32SplitW8A8: return "fast32-split-w8a8"
        case .nemotronC128SplitW8A8: return "c128-split-w8a8"
        case .community1, .granite97M, .granite311M: return nil
        }
    }
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
    var inputBufferSeconds: Double? = nil
    var speakerCapacity: Int? = nil
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
    private static let nemotronAssets: [LocalModelAsset] = [
        .init(
            path: "learnable_sil_emb.bin", remotePath: "learnable_sil_emb.bin", bytes: 2048,
            digest: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"),
        .init(
            path: "Nemotron3Diarizer_fast.mlmodelc/analytics/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "f874278778095b9abfc07106fcbd0e877a8fd5dc34444c7a74331735b41eee68"),
        .init(
            path: "Nemotron3Diarizer_fast.mlmodelc/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast.mlmodelc/coremldata.bin", bytes: 752,
            digest: "cc3b262b0ac3028a749943bfe5b2502bd0e5d12c057b0d4d1fd2a2bbf9e4f1b2"),
        .init(
            path: "Nemotron3Diarizer_fast.mlmodelc/model.mil",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast.mlmodelc/model.mil", bytes: 501600,
            digest: "9c70146a2a3b2425baf384dc6d3258580608f28f"),
        .init(
            path: "Nemotron3Diarizer_fast.mlmodelc/weights/weight.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast.mlmodelc/weights/weight.bin", bytes: 198_560_128,
            digest: "5efb213341eb1d772d662d852a9a9cf9f45372a599862e16035880742c491967"),
        .init(
            path: "Nemotron3Diarizer_fast128.mlmodelc/analytics/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "a71e06616a3ae7bddef06ce5dfc7fe523a286e489f63a8da2fc4f1e940d560a4"),
        .init(
            path: "Nemotron3Diarizer_fast128.mlmodelc/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc/coremldata.bin", bytes: 758,
            digest: "ebcca7245d8d774305752b9f2b79433ad1858f8a06df3b326e0ae6305d981d25"),
        .init(
            path: "Nemotron3Diarizer_fast128.mlmodelc/model.mil",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc/model.mil", bytes: 502794,
            digest: "255bb15747cbd135feb9ff2413425431427c2f92"),
        .init(
            path: "Nemotron3Diarizer_fast128.mlmodelc/weights/weight.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc/weights/weight.bin", bytes: 198_590_592,
            digest: "e8c90d2d0e16787a420de6805fd5b7a95c116fac0163208b5bc4d8a9ae459ca4"),
        .init(
            path: "Nemotron3Diarizer_fast32.mlmodelc/analytics/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast32.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "7932ba85d07f09ba8feff996e1278f376a9139e31141d2827021f1c225e590ae"),
        .init(
            path: "Nemotron3Diarizer_fast32.mlmodelc/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast32.mlmodelc/coremldata.bin", bytes: 755,
            digest: "fbc2d4dc25147427269e4774a5b8e3dd6b613e8c8458d74c7462a1a377dbae75"),
        .init(
            path: "Nemotron3Diarizer_fast32.mlmodelc/model.mil",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast32.mlmodelc/model.mil", bytes: 501830,
            digest: "265b5a9f4928a0aa312ef2c73272fa6c5ecebb80"),
        .init(
            path: "Nemotron3Diarizer_fast32.mlmodelc/weights/weight.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_fast32.mlmodelc/weights/weight.bin", bytes: 198_566_016,
            digest: "7353d8e7a5d29a8d15edf86dbf40bed4e82b7b8f456f302d5cdcbf850ed25358"),
        .init(
            path: "Nemotron3Diarizer_low.mlmodelc/analytics/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_low.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "1ec46d7392b470ebfaac473123de9e5bc62630972b01349b929bf6e48e067c6c"),
        .init(
            path: "Nemotron3Diarizer_low.mlmodelc/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_low.mlmodelc/coremldata.bin", bytes: 752,
            digest: "2c2c82efc948433cb47b60aceb4917182e2e00d1d79097b8898adfd615b0c5f8"),
        .init(
            path: "Nemotron3Diarizer_low.mlmodelc/model.mil",
            remotePath: "monolithic/v2/Nemotron3Diarizer_low.mlmodelc/model.mil", bytes: 503842,
            digest: "8005abdfaaa138437fb86fc292e0fdb787873e8b"),
        .init(
            path: "Nemotron3Diarizer_low.mlmodelc/weights/weight.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_low.mlmodelc/weights/weight.bin", bytes: 198_617_472,
            digest: "88307e2c51d1877de59803299354f689e70cad7f8892a197764d5f3626089495"),
        .init(
            path: "Nemotron3Diarizer_offline.mlmodelc/analytics/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "491594df92282a4f2cef65e96d236e210a5c4627063e37e822ec858aaaad416d"),
        .init(
            path: "Nemotron3Diarizer_offline.mlmodelc/coremldata.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/coremldata.bin", bytes: 758,
            digest: "8b790c919c65744648c17290a26d3371e0e55db655310e7f8445080757b0bf08"),
        .init(
            path: "Nemotron3Diarizer_offline.mlmodelc/model.mil",
            remotePath: "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/model.mil", bytes: 505274,
            digest: "2f649fd4fc3c1bc613ab4c80c63b24f33681d309"),
        .init(
            path: "Nemotron3Diarizer_offline.mlmodelc/weights/weight.bin",
            remotePath: "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/weights/weight.bin", bytes: 198_654_080,
            digest: "bab76e5f190d0e4a4e174e7fcb1e9beea58c6b2be56e665e2cac8fba6d10f7f1"),
        .init(
            path: "pre_encode_proj_t.bin", remotePath: "pre_encode_proj_t.bin", bytes: 2_097_152,
            digest: "eb15b89e7af9813331a7d8db02e83e30bf97463d272c748e72086bafd4e81c60"),
        .init(
            path: "Nemotron3Diarizer_c128_split_w8a8.mlmodelc/analytics/coremldata.bin",
            remotePath: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "9522ac23edf90deb9bc4d3ef97ca435a90df499d346c4806351784b5a8decb60"),
        .init(
            path: "Nemotron3Diarizer_c128_split_w8a8.mlmodelc/coremldata.bin",
            remotePath: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/coremldata.bin", bytes: 605,
            digest: "777c6c6240baef5973b99b6984e9bb3a1f6a4812de28d3c65317be8911491421"),
        .init(
            path: "Nemotron3Diarizer_c128_split_w8a8.mlmodelc/model.mil",
            remotePath: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/model.mil", bytes: 759134,
            digest: "d7325998b1af8b074618901b351238bd92d23de3"),
        .init(
            path: "Nemotron3Diarizer_c128_split_w8a8.mlmodelc/weights/weight.bin",
            remotePath: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/weights/weight.bin", bytes: 99_249_792,
            digest: "9a4c5de6ba011560713206b76c357d99ee596d1f1a58c66368b82834f9e12f95"),
        .init(
            path: "Nemotron3Diarizer_s32_split_w8a8.mlmodelc/analytics/coremldata.bin",
            remotePath: "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/analytics/coremldata.bin", bytes: 243,
            digest: "3241bd5be194abbf0f625be8bd639b5c2035359594a6a513d70e9159e294ce39"),
        .init(
            path: "Nemotron3Diarizer_s32_split_w8a8.mlmodelc/coremldata.bin",
            remotePath: "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/coremldata.bin", bytes: 603,
            digest: "b349771fbdb19443fb0af32b6c061fdb183d58e54c0b6376c2fbdca0a9941b70"),
        .init(
            path: "Nemotron3Diarizer_s32_split_w8a8.mlmodelc/model.mil",
            remotePath: "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/model.mil", bytes: 759102,
            digest: "3087d5d4317d82bf884464a7e94c4fc1b8a9e74d"),
        .init(
            path: "Nemotron3Diarizer_s32_split_w8a8.mlmodelc/weights/weight.bin",
            remotePath: "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/weights/weight.bin", bytes: 99_237_504,
            digest: "99e2ae43ac6a513abf99951b35a75fb6bc51d2287c3c1af48a9657d917e57aed"),
    ]
    static func descriptor(_ id: LocalModelID) -> LocalModelDescriptor {
        switch id {
        case .granite97M, .granite311M:
            return semanticDescriptor(id)
        case .nemotronLow, .nemotronFast, .nemotronFast32, .nemotronFast128, .nemotronOffline, .nemotronFast32SplitW8A8,
            .nemotronC128SplitW8A8:
            let preset = id.nemotronPreset!
            let config = Nemotron3Config.preset(named: preset)!
            let name = String(config.modelFileName.dropLast(".mlmodelc".count))
            return .init(
                id: id, title: "Nemotron " + preset,
                repository: "FluidInference/nemotron-3-diarization-coreml",
                revision: "25a90f97f254428d4b30374b76af9c74fdee8327",
                assets: nemotronAssets.filter {
                    $0.path.hasPrefix(name + ".mlmodelc/") || $0.path == "learnable_sil_emb.bin"
                        || (config.splitGraph && $0.path == "pre_encode_proj_t.bin")
                },
                modelNames: [name], inputBufferSeconds: config.latencySeconds, speakerCapacity: 8)
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
