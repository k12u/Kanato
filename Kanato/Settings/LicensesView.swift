//
//  LicensesView.swift
//  Kanato
//

import SwiftUI

/// Kanato と同梱ソフトウェアのライセンス、およびダウンロードして使うモデルの帰属表示
struct LicensesView: View {
    let models: [ModelManifest.Model]
    @Environment(\.dismiss) private var dismiss

    /// アプリに同梱したライセンス表示（Kanato/Legal/ThirdPartyNotices.txt）
    static func bundledNotices(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Self.bundledNotices() ?? "ライセンス表示を読み込めませんでした")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    ForEach(models) { model in
                        ModelAttributionView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

/// モデルの帰属表示（作者・ライセンス・配布元へのリンク）
struct ModelAttributionView: View {
    let model: ModelManifest.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.name).font(.headline)
            if let attribution = model.license.attribution {
                Text(attribution).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                if let url = model.license.url {
                    Link("ライセンス: \(model.license.identifier)", destination: url)
                } else {
                    Text("ライセンス: \(model.license.identifier)")
                }
                Link("配布元（モデルカード）", destination: model.source.repositoryURL)
            }
            .font(.callout)
        }
    }
}

#Preview {
    LicensesView(models: (try? ModelManifest.loadBundled())?.models.filter(\.supportsLocalInference) ?? [])
}
