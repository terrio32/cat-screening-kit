import CoreGraphics
import CoreML
import Vision

public final actor ScaryCatScreener {
    private struct SCSModelContainer: @unchecked Sendable {
        let visionModel: VNCoreMLModel
        let modelFileName: String
        let request: VNCoreMLRequest
    }

    private var ovrModels: [SCSModelContainer] = []
    private let enableLogging: Bool

    /// バンドルのリソースから全ての .mlmodelc ファイルをロードしてスクリーナーを初期化
    /// - Parameter enableLogging: デバッグログの出力を有効にするかどうか（デフォルト: false）
    public init(enableLogging: Bool = false) async throws {
        // まずプロパティを初期化
        self.enableLogging = enableLogging

        // リソースバンドルの取得
        let bundle = Bundle.module
        guard let resourceURL = bundle.resourceURL else {
            if enableLogging {
                print("[ScaryCatScreener] [Error] リソースバンドルが見つかりません")
            }
            throw ScaryCatScreenerError.resourceBundleNotFound
        }

        if enableLogging {
            print("[ScaryCatScreener] [Debug] リソースバンドル: \(bundle.bundlePath)")
            print("[ScaryCatScreener] [Debug] リソースURL: \(resourceURL.path)")
        }

        // .mlmodelcファイルの検索
        let modelFileURLs = try await findModelFiles(in: resourceURL)
        guard !modelFileURLs.isEmpty else {
            if self.enableLogging {
                print("[ScaryCatScreener] [Error] バンドルのリソース内に.mlmodelcファイルが存在しません")
            }
            throw ScaryCatScreenerError.modelNotFound
        }

        // モデルのロード
        let loadedModels = try await loadModels(from: modelFileURLs)
        guard !loadedModels.isEmpty else {
            throw ScaryCatScreenerError.modelNotFound
        }

        // 最終的なモデル配列を設定
        ovrModels = loadedModels

        if self.enableLogging {
            print(
                "[ScaryCatScreener] [Info] \(ovrModels.count)個のOvRモデルをロード完了: \(ovrModels.map(\.modelFileName).joined(separator: ", "))"
            )
        }
    }

    // MARK: - Public Screening API

    public nonisolated func screen(
        imageDataList: [Data],
        probabilityThreshold: Float = 0.95,
        enableLogging: Bool = false
    ) async throws -> SCSOverallScreeningResults {
        // 各画像のスクリーニングを直列で実行
        var results: [SCSIndividualScreeningResult] = []
        for (index, imageData) in imageDataList.enumerated() {
            let confidences = try await screenSingleImage(
                imageData,
                probabilityThreshold: probabilityThreshold,
                enableLogging: enableLogging
            )
            results.append(SCSIndividualScreeningResult(
                imageData: imageData,
                confidences: confidences,
                probabilityThreshold: probabilityThreshold,
                originalIndex: index
            ))
        }

        let overallResults = SCSOverallScreeningResults(results: results)

        if enableLogging {
            print(overallResults.generateDetailedReport())
        }

        return overallResults
    }

    // MARK: - Private API

    private nonisolated func screenSingleImage(
        _ imageData: Data,
        probabilityThreshold _: Float,
        enableLogging: Bool
    ) async throws -> [String: Float] {
        var confidences: [String: Float] = [:]

        // 各モデルを順番に処理
        for container in await ovrModels {
            do {
                let handler = VNImageRequestHandler(data: imageData, options: [:])
                try handler.perform([container.request])
                guard let observations = container.request.results as? [VNClassificationObservation] else {
                    if enableLogging {
                        print("[ScaryCatScreener] [Warning] モデル\(container.modelFileName)の結果が不正な形式")
                    }
                    continue
                }

                // 検出結果を収集
                for observation in observations
                    where observation.identifier.lowercased() != "rest" && observation.identifier
                    .lowercased() != "safe"
                {
                    confidences[observation.identifier] = observation.confidence
                }
            } catch {
                if enableLogging {
                    print(
                        "[ScaryCatScreener] [Error] モデル \(container.modelFileName) のVisionリクエスト失敗: \(error.localizedDescription)"
                    )
                }
                throw ScaryCatScreenerError.predictionFailed(originalError: error)
            }
        }

        // mouth_openのみが検出された場合の特別処理
        if let mouthOpenConfidence = confidences["mouth_open"], confidences.count == 1 {
            await resolveMouthOpenWithOvOModel(
                confidences: &confidences,
                imageData: imageData,
                enableLogging: enableLogging
            )
        }

        return confidences
    }

    /// mouth_openのみ検出された場合、OvOモデルでsafe判定を再確認し、必要ならmouth_openの信頼度を0にする
    private func resolveMouthOpenWithOvOModel(
        confidences: inout [String: Float],
        imageData: Data,
        enableLogging: Bool
    ) async {
        // OvOモデルを探す
        if let ovoContainer = await ovrModels.first(where: { $0.modelFileName.contains("OvO_mouth_open_vs_safe") }) {
            do {
                let handler = VNImageRequestHandler(data: imageData, options: [:])
                try handler.perform([ovoContainer.request])
                if let observations = ovoContainer.request.results as? [VNClassificationObservation],
                   let safeObservation = observations.first(where: { $0.identifier.lowercased() == "safe" }),
                   let mouthOpenObservation = observations
                   .first(where: { $0.identifier.lowercased() == "mouth_open" })
                {
                    // 信頼度の高い方のクラスを採用
                    if safeObservation.confidence > mouthOpenObservation.confidence {
                        confidences["mouth_open"] = 0
                        if enableLogging {
                            print("[ScaryCatScreener] [Info] OvOモデルによりsafeと判定され、mouth_openの信頼度を0に設定")
                        }
                    }
                }
            } catch {
                if enableLogging {
                    print("[ScaryCatScreener] [Warning] OvOモデルの検証に失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    /// リソースディレクトリ内の.mlmodelcファイルを検索
    private func findModelFiles(in resourceURL: URL) async throws -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey]

        if enableLogging {
            print("[ScaryCatScreener] [Debug] 検索ディレクトリ: \(resourceURL.path)")
        }

        guard let enumerator = fileManager.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: resourceKeys,
            options: .skipsHiddenFiles
        ) else {
            if enableLogging {
                print("[ScaryCatScreener] [Error] ディレクトリの列挙に失敗: \(resourceURL.path)")
            }
            throw ScaryCatScreenerError.modelLoadingFailed(originalError: ScaryCatScreenerError.modelNotFound)
        }

        var modelFileURLs: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "mlmodelc" {
            modelFileURLs.append(fileURL)
            if enableLogging {
                print("[ScaryCatScreener] [Debug] モデルファイルを検出: \(fileURL.lastPathComponent)")
            }
        }

        if enableLogging {
            print(
                "[ScaryCatScreener] [Debug] 検出されたモデル: \(modelFileURLs.map(\.lastPathComponent).joined(separator: ", "))"
            )
        }

        return modelFileURLs
    }

    /// モデルファイルからVisionモデルとリクエストを並列にロード
    private func loadModels(from modelFileURLs: [URL]) async throws -> [SCSModelContainer] {
        var collectedContainers: [SCSModelContainer] = []

        try await withThrowingTaskGroup(of: SCSModelContainer.self) { group in
            for url in modelFileURLs {
                group.addTask {
                    try await self.loadModel(from: url)
                }
            }

            for try await container in group {
                collectedContainers.append(container)
            }
        }

        return collectedContainers
    }

    /// 個別のモデルファイルからVisionモデルとリクエストをロード
    private func loadModel(from url: URL) async throws -> SCSModelContainer {
        // MLModelConfigurationの設定
        let config = MLModelConfiguration()
        config.computeUnits = .all

        // モデルのロード
        let mlModel = try MLModel(contentsOf: url, configuration: config)
        let visionModel = try VNCoreMLModel(for: mlModel)

        // Visionリクエストの設定
        let request = VNCoreMLRequest(model: visionModel)
        #if targetEnvironment(simulator)
            if #available(iOS 17.0, *) {
                let allDevices = MLComputeDevice.allComputeDevices
                for device in allDevices where device.description.contains("MLCPUComputeDevice") {
                    request.setComputeDevice(.some(device), for: .main)
                    break
                }
            } else {
                request.usesCPUOnly = true
            }
        #endif
        request.imageCropAndScaleOption = .scaleFit

        return SCSModelContainer(
            visionModel: visionModel,
            modelFileName: url.deletingPathExtension().lastPathComponent,
            request: request
        )
    }
}
