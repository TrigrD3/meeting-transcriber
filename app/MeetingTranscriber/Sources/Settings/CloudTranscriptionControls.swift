import SwiftUI

/// Whether the cloud-transcription consent alert is up. A reference type so
/// the alert's actions and a view test see the same flag (see
/// docs/architecture/gui-testing.md).
@MainActor
@Observable
final class CloudTranscriptionConsent {
    var isAsking = false

    /// The "Transcribe with" write: picking Cloud asks first until the user has
    /// confirmed once; On this Mac never asks.
    func request(_ enabled: Bool, in settings: AppSettings) {
        if enabled, !settings.cloudTranscriptionConsented {
            isAsking = true
        } else {
            settings.cloudTranscriptionEnabled = enabled
        }
    }

    func confirm(in settings: AppSettings) {
        settings.cloudTranscriptionConsented = true
        settings.cloudTranscriptionEnabled = true
        isAsking = false
    }

    func cancel() {
        isAsking = false
    }
}

/// Test Connection's state; a reference type for the same reason as
/// `CloudTranscriptionConsent`.
@MainActor
@Observable
final class CloudConnectionTest {
    private(set) var isRunning = false
    private(set) var result: CloudConnectionTestResult?
    private let session: URLSession
    /// The test in flight, kept so a view test can await it.
    private(set) var task: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func run(_ config: CloudTranscriptionConfiguration) {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        task = Task {
            result = await CloudTranscriptionEngine.testConnection(config, session: session)
            isRunning = false
        }
    }
}

/// The two choices of "Transcribe with". UI only: the stored settings stay
/// `cloudTranscriptionEnabled` plus the local engine, which stays selected for
/// Run Locally and for when cloud is off.
enum TranscriptionMethod: CaseIterable {
    case onThisMac
    case cloud

    var label: String {
        switch self {
        case .onThisMac: "On this Mac"
        case .cloud: "Cloud"
        }
    }
}

/// "Transcribe with": picking Cloud asks for consent first until the user has
/// confirmed once; Cancel leaves it on On this Mac.
struct TranscriptionMethodPicker: View {
    @Bindable var settings: AppSettings
    @Bindable var consent: CloudTranscriptionConsent

    var body: some View {
        Picker("Transcribe with", selection: Binding(
            get: { settings.cloudTranscriptionEnabled ? TranscriptionMethod.cloud : .onThisMac },
            set: { consent.request($0 == .cloud, in: settings) },
        )) {
            ForEach(TranscriptionMethod.allCases, id: \.self) { method in
                Text(method.label).tag(method)
            }
        }
        .accessibilityIdentifier(A11yID.transcriptionMethodPicker)
        .alert("Send meeting audio to the cloud?", isPresented: $consent.isAsking) {
            Button("Cancel", role: .cancel) { consent.cancel() }
            Button("Send to Cloud") { consent.confirm(in: settings) }
        } message: {
            Text(
                "Recordings queued while this is on are uploaded to "
                    + "\(CloudTranscriptionControls.host(of: settings.cloudTranscriptionBaseURL)) for transcription. "
                    + "Speaker identification stays on this Mac.",
            )
        }
    }
}

/// The rows "Transcribe with: Cloud" shows: endpoint fields, the cloud
/// language and the local model Run Locally falls back to.
struct CloudTranscriptionControls: View {
    @Bindable var settings: AppSettings
    var connectionTest: CloudConnectionTest
    var modelList: CloudModelList
    /// e.g. "Run Locally uses WhisperKit · Large V3 Turbo".
    var localFallback: String

    var body: some View {
        Text("Meeting audio is sent to \(Self.host(of: settings.cloudTranscriptionBaseURL)).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(A11yID.cloudTranscriptionHostNote)
        TextField("Base URL", text: $settings.cloudTranscriptionBaseURL, prompt: Text("https://api.openai.com/v1"))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.cloudTranscriptionBaseURLField)
        CloudModelRow(settings: settings, modelList: modelList)
        SecureField("API key", text: $settings.cloudTranscriptionAPIKey)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.cloudTranscriptionAPIKeyField)
        connectionTestRow
        Picker("Language", selection: $settings.cloudTranscriptionLanguage) {
            ForEach(PickerLanguages.whisperKit, id: \.code) { lang in
                Text(lang.label).tag(lang.code)
            }
        }
        .accessibilityIdentifier(A11yID.cloudTranscriptionLanguagePicker)
        Text(localFallback)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(A11yID.cloudTranscriptionLocalFallbackNote)
    }

    private var connectionTestRow: some View {
        HStack {
            Button {
                connectionTest.run(settings.cloudTranscriptionConfiguration)
            } label: {
                HStack(spacing: 4) {
                    if connectionTest.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Test Connection")
                }
            }
            .disabled(connectionTest.isRunning)
            .accessibilityIdentifier(A11yID.cloudTranscriptionTestButton)

            if let result = connectionTest.result {
                Label(result.message, systemImage: result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result == .success ? .green : .red)
                    .font(.caption)
                    .accessibilityIdentifier(A11yID.cloudTranscriptionTestStatus)
            }
        }
    }

    /// The host part of the base URL, or the entry itself when it has none.
    static func host(of baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)?.host ?? trimmed
    }
}
