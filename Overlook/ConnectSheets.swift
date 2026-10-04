import SwiftUI

struct ManualConnectSheet: View {
    @Binding var isPresented: Bool
    @Binding var hostPort: String
    @Binding var port: String
    @Binding var password: String

    let onConnect: (String) -> Void

    @State private var submissionGate = ConnectSubmissionGate()

    private var canConnect: Bool {
        (try? ManualConnectionEndpoint.parse(hostPort: hostPort, port: port)) != nil
    }

    private var endpointValidationMessage: String? {
        guard !hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try ManualConnectionEndpoint.parse(hostPort: hostPort, port: port)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Connect")
                .font(.headline)

            TextField("Host or IP (optionally host:port)", text: $hostPort)
                .textFieldStyle(.roundedBorder)

            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)

            if let endpointValidationMessage {
                Text(endpointValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitConnection)

            HStack {
                Spacer()
                Button("Cancel") {
                    password = ""
                    isPresented = false
                }
                Button("Connect", action: submitConnection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding()
        .frame(width: 420)
        .onDisappear {
            password = ""
        }
    }

    private func submitConnection() {
        guard submissionGate.begin(when: canConnect) else { return }
        let passwordSnapshot = ConnectCredentialSnapshot.takeAndClear(&password)
        onConnect(passwordSnapshot)
        isPresented = false
    }
}

struct PasswordPromptSheet: View {
    @Binding var isPresented: Bool
    @Binding var password: String

    let onCancel: () -> Void
    let onConnect: (String) -> Void

    @State private var submissionGate = ConnectSubmissionGate()

    private var canConnect: Bool {
        ConnectSubmissionPolicy.canSubmitPassword(password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Required")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitConnection)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    password = ""
                    isPresented = false
                }
                Button("Connect", action: submitConnection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding()
        .frame(width: 420)
        .onDisappear {
            password = ""
        }
    }

    private func submitConnection() {
        guard submissionGate.begin(when: canConnect) else { return }
        let passwordSnapshot = ConnectCredentialSnapshot.takeAndClear(&password)
        onConnect(passwordSnapshot)
        isPresented = false
    }
}
