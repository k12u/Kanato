//
//  LocalModelController.swift
//  Kanato
//

import Foundation
import Observation

/// 設定画面から、ローカルモデルの取得・削除・状態表示を行う。
/// 取得・検証・配置は `ModelManager` が行い、ここは画面の状態だけを持つ。
@Observable
final class LocalModelController {
    private(set) var states: [String: InstallState] = [:]
    private(set) var downloadingModelID: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let manager: ModelManager?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    init(manager: ModelManager? = try? ModelManager.makeDefault()) {
        self.manager = manager
        // 前回の異常終了で残った一時ディレクトリを片付ける
        manager?.cleanUpStaging()
    }

    var isAvailable: Bool { manager != nil }

    func state(of model: ModelManifest.Model) -> InstallState {
        states[model.id] ?? .notInstalled
    }

    func refresh(_ models: [ModelManifest.Model]) {
        guard let manager else { return }
        for model in models {
            states[model.id] = manager.installState(of: model)
        }
    }

    func download(_ model: ModelManifest.Model) {
        guard let manager, downloadingModelID == nil else { return }
        downloadingModelID = model.id
        errorMessage = nil
        downloadTask = Task {
            do {
                try await manager.download(model)
                // 古いファイルを参照しているエンジンを解放する
                LocalEngineCache.shared.removeAll()
            } catch is CancellationError {
                // キャンセル時は何も表示しない（一時ファイルは ModelManager が削除する）
            } catch {
                errorMessage = Self.message(for: error)
            }
            downloadingModelID = nil
            states[model.id] = manager.installState(of: model)
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func delete(_ model: ModelManifest.Model) {
        guard let manager else { return }
        errorMessage = nil
        LocalEngineCache.shared.removeAll()
        do {
            try manager.delete(modelID: model.id)
        } catch {
            errorMessage = Self.message(for: error)
        }
        states[model.id] = manager.installState(of: model)
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
