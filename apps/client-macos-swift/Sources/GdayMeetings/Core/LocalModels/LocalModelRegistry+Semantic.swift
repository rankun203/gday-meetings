import Foundation

extension LocalModelRegistry {
    static func semanticDescriptor(_ id: LocalModelID) -> LocalModelDescriptor {
        switch id {
        case .granite97M:
            return .init(
                id: id, title: "Granite 97M Multilingual R2",
                repository: "rankun203/granite-embedding-97m-multilingual-r2-coreml", revision: "mixed-fp16-v1",
                assets: [
                    .init(
                        path: "LICENSE", remotePath: "mixed-fp16/LICENSE",
                        bytes: 11358, digest: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/analytics/coremldata.bin",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/analytics/coremldata.bin",
                        bytes: 243, digest: "772dbc924d0bfe1b02ed2e54fbc2301acf4c8c59a452aefa85909dd0dedd361e"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/coremldata.bin",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/coremldata.bin",
                        bytes: 323, digest: "1333f4e76f922c219781f5adc639bba4e433d107844e4f70a87ec6f3dc7d06e2"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/metadata.json",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/metadata.json",
                        bytes: 6391, digest: "d849ca546929edfb50cf056d9541eb32e15e80171bfbf04ca99dad63d532a714"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/model.mil",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/model.mil",
                        bytes: 2_148_983, digest: "5ca77a40917dfc4899ab2d1776df69c6b5ce16abf07a8132fa0284300ab01abb"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/weights/weight.bin",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/weights/weight.bin",
                        bytes: 195_080_064, digest: "64d91d605a99c0c5f77bc2ce50df062703c75ac550082987a1a589ad29b53b25"),
                    .init(
                        path: "special_tokens_map.json", remotePath: "mixed-fp16/special_tokens_map.json",
                        bytes: 871, digest: "013787ee251ff611722479197c00853b62113ad303cb0a36524231783c676c69"),
                    .init(
                        path: "tokenizer.json", remotePath: "mixed-fp16/tokenizer.json",
                        bytes: 25_301_583, digest: "b834474f27fe47b502a850d5e04bec921c4cdc311172b2f96462fecc955e7981"),
                    .init(
                        path: "tokenizer_config.json", remotePath: "mixed-fp16/tokenizer_config.json",
                        bytes: 12860, digest: "6ed69389e30a8ecabfce2f9ebcdf0c908b34056f24d994340f2f216521c057d5"),
                ], modelNames: ["SemanticEncoder"])
        case .granite311M:
            return .init(
                id: id, title: "Granite 311M Multilingual R2",
                repository: "rankun203/granite-embedding-311m-multilingual-r2-coreml", revision: "mixed-fp16-v1",
                assets: [
                    .init(
                        path: "LICENSE", remotePath: "mixed-fp16/LICENSE",
                        bytes: 11358, digest: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/analytics/coremldata.bin",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/analytics/coremldata.bin",
                        bytes: 243, digest: "f5acc4ff4552f0a18b54f6aaf59579462a45fc64d3a624f7f13f9ca124c14f7a"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/coremldata.bin",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/coremldata.bin",
                        bytes: 323, digest: "fa720d0e25962191fb0679e8e0046719dcf5a0d00cea3c744b007d642681cd00"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/metadata.json",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/metadata.json",
                        bytes: 6397, digest: "d579233d9f0c0286bd155d7261869f795588ec013d5689c45ea968d9feef7d25"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/model.mil",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/model.mil",
                        bytes: 2_476_841, digest: "42f8758960afc5dc4ffbc61fd3bb5bf9fcee89ebdc6c7881dea1d978b52ee993"),
                    .init(
                        path: "SemanticEncoder.mlmodelc/weights/weight.bin",
                        remotePath: "mixed-fp16/SemanticEncoder.mlmodelc/weights/weight.bin",
                        bytes: 623_740_992, digest: "ff959f96605649c55cb5a3e38989cf78cac09b58783802389cd6759fb67fde0a"),
                    .init(
                        path: "special_tokens_map.json", remotePath: "mixed-fp16/special_tokens_map.json",
                        bytes: 694, digest: "cb9e60dcf4d8d314315cb3e761fe4c2e664fda8dbf66d7815372b2639e381182"),
                    .init(
                        path: "tokenizer.json", remotePath: "mixed-fp16/tokenizer.json",
                        bytes: 33_384_733, digest: "2a85a62391e03054dc571ab4e178ddcbe1c04bd02dd332aa970cc13e0b8b3755"),
                    .init(
                        path: "tokenizer_config.json", remotePath: "mixed-fp16/tokenizer_config.json",
                        bytes: 1_155_500, digest: "7947bdf0378520e69ca412b8c4dacd1cffa8aef099f851fdd5c65aa27c6b36a0"),
                ], modelNames: ["SemanticEncoder"])
        default: preconditionFailure("Not a semantic model")
        }
    }
}
