import SwiftUI

/// The cloud endpoint's speech-to-text models for the Model dropdown, and
/// whether the user picked "Custom…". A reference type so a view test can
/// await the fetch and see the same state the view does (see
/// docs/architecture/gui-testing.md).
@MainActor
@Observable
final class CloudModelList {
    /// Empty until a fetch returns models; the Model row is a text field until then.
    private(set) var models: [String] = []
    private(set) var isFetching = false
    /// Why the last fetch failed; nil after a success.
    private(set) var failure: String?
    /// "Custom…" chosen, so the text field shows even for a listed model.
    var customChosen = false
    private let session: URLSession
    /// The fetch in flight, kept so a view test can await it.
    private(set) var task: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// GETs `{baseURL}/models` with the key as a Bearer token. A redirect off
    /// the configured origin is refused, so the key goes nowhere else.
    func fetch(baseURL: String, apiKey: String) {
        guard !isFetching else { return }
        isFetching = true
        failure = nil
        task = Task {
            let result = await OpenAIProtocolGenerator.testConnection(
                endpoint: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: "",
                apiKey: apiKey.isEmpty ? nil : apiKey,
                refuseCrossOriginRedirects: true,
                session: session,
            )
            switch result {
            case let .success(ids):
                models = Self.speechModels(ids)

            case let .failure(error):
                models = []
                failure = "Couldn't fetch models: \(error.localizedDescription)"
            }
            isFetching = false
        }
    }

    /// The ids that look like speech-to-text, in the given order; all of them
    /// when none does, so a wrong guess hides nothing.
    static func speechModels(_ ids: [String]) -> [String] {
        let speech = ids.filter { id in
            let lowered = id.lowercased()
            return speechMarkers.contains { lowered.contains($0) }
        }
        return speech.isEmpty ? ids : speech
    }

    private static let speechMarkers = ["whisper", "transcribe", "asr", "stt"]
}

/// What the Model dropdown shows as selected.
enum CloudModelChoice: Hashable {
    case listed(String)
    case custom
}

/// The cloud Model row: a text field until the server's list arrives, then a
/// dropdown of it plus "Custom…", which brings the text field back. A saved
/// model the list lacks shows as Custom, unchanged.
struct CloudModelRow: View {
    @Bindable var settings: AppSettings
    var modelList: CloudModelList

    var body: some View {
        Group {
            if !modelList.models.isEmpty {
                Picker("Model", selection: choice) {
                    ForEach(modelList.models, id: \.self) { model in
                        Text(model).tag(CloudModelChoice.listed(model))
                    }
                    Text("Custom…").tag(CloudModelChoice.custom)
                }
                .accessibilityIdentifier(A11yID.cloudTranscriptionModelPicker)
            }
            if modelList.models.isEmpty || choice.wrappedValue == .custom {
                TextField("Model", text: $settings.cloudTranscriptionModel, prompt: Text("whisper-1"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(A11yID.cloudTranscriptionModelField)
            }
            fetchRow
        }
        .onAppear {
            if modelList.models.isEmpty, !modelList.isFetching,
               !settings.cloudTranscriptionBaseURL.isEmpty, !settings.cloudTranscriptionAPIKey.isEmpty {
                fetch()
            }
        }
    }

    private var choice: Binding<CloudModelChoice> {
        Binding(
            get: {
                let model = settings.cloudTranscriptionModel
                return modelList.customChosen || !modelList.models.contains(model) ? .custom : .listed(model)
            },
            set: { newValue in
                switch newValue {
                case let .listed(model):
                    modelList.customChosen = false
                    settings.cloudTranscriptionModel = model

                case .custom:
                    modelList.customChosen = true
                }
            },
        )
    }

    private var fetchRow: some View {
        HStack {
            Button {
                fetch()
            } label: {
                HStack(spacing: 4) {
                    if modelList.isFetching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(modelList.models.isEmpty ? "Fetch Models" : "Refresh Models")
                }
            }
            .disabled(modelList.isFetching)
            .accessibilityIdentifier(A11yID.cloudTranscriptionFetchModelsButton)

            if let failure = modelList.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(A11yID.cloudTranscriptionModelsFailure)
            }
        }
    }

    private func fetch() {
        modelList.fetch(baseURL: settings.cloudTranscriptionBaseURL, apiKey: settings.cloudTranscriptionAPIKey)
    }
}
