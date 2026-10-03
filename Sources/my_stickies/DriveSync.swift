import AppKit
import CryptoKit
import Darwin

/// Manual, one-shot sync of notes.json / trash_notes.json with a Google Drive file of the
/// same name (created under "drive.file" scope, so the app only ever sees files it made
/// itself). No Google SDK: OAuth2 PKCE via a loopback redirect (Network.framework) and the
/// Drive v3 REST API over URLSession, matching the "no deps" rule.
///
/// Conflict rule: if a file changed on both sides since the last sync, ask which wins.
/// Otherwise the changed side wins silently — that's what "press refresh" should feel like.
enum DriveSync {
    /// Registered once in Google Cloud Console as a "Desktop app" OAuth client. The secret
    /// isn't confidential for this client type — Google's own docs say so, since an installed
    /// app can't keep one — so it's fine committed here rather than asked of every user.
    /// Each person still authenticates their own Google account individually; this identifies
    /// the app, not a user.
    private enum App {
        static let clientID = "449580705148-e3kccm22oh1303tuvn6c7tlongda4lb5.apps.googleusercontent.com"
        static let clientSecret = "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"
    }

    private static let refreshTokenAccount = "refresh_token"

    static var isConnected: Bool { Keychain.get(refreshTokenAccount) != nil }

    /// A second ⌘R while one is in flight would open a second sign-in and, with no remote
    /// file yet, upload a duplicate notes.json.
    @MainActor private static var isRunning = false

    @MainActor
    static func run(store: Store) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            try await sync(store: store)
        } catch {
            presentError(error)
        }
    }

    static func disconnect() {
        Keychain.delete(refreshTokenAccount)
    }

    /// Runs `body`, and on failure re-throws with `label` prefixed so the alert says which
    /// leg of the sync broke instead of just the raw system error.
    private static func step<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as DriveSyncError {
            throw error // already labeled by a nested step
        } catch {
            let ns = error as NSError
            throw DriveSyncError.message("[\(label)] \(error.localizedDescription) (\(ns.domain) #\(ns.code))")
        }
    }

    // MARK: Orchestration

    @MainActor
    private static func sync(store: Store) async throws {
        store.saveNow()

        // A stored token Google no longer honors (revoked, or the 7-day expiry for OAuth apps
        // still in "Testing") falls through to a fresh sign-in instead of failing forever.
        var accessToken: String?
        if let existing = Keychain.get(refreshTokenAccount) {
            do {
                accessToken = try await step("refresh access token") { try await refreshAccessToken(refreshToken: existing) }
            } catch DriveSyncError.revoked {
                Keychain.delete(refreshTokenAccount)
            }
        }
        if accessToken == nil {
            let refreshToken = try await step("sign in") { try await signIn() }
            Keychain.set(refreshToken, account: refreshTokenAccount)
            accessToken = try await step("refresh access token") { try await refreshAccessToken(refreshToken: refreshToken) }
        }
        guard let accessToken else { return }

        var state = SyncStateStore.load()
        let notesPlan = try await plan(displayName: "Notes", fileName: "notes.json",
                                        localURL: Store.fileURL, record: state.notes, accessToken: accessToken)
        let trashPlan = try await plan(displayName: "Trash", fileName: "trash_notes.json",
                                        localURL: Store.trashURL, record: state.trash, accessToken: accessToken)

        var resolution: ConflictResolution = .auto
        let conflicting = [notesPlan, trashPlan].filter { $0.action == .conflict }
        if !conflicting.isEmpty {
            guard let chosen = presentConflict(names: conflicting.map(\.displayName)) else { return }
            resolution = chosen
        }

        let files: [(SyncPlan, URL, WritableKeyPath<SyncState, SyncRecord?>)] = [
            (notesPlan, Store.fileURL, \.notes),
            (trashPlan, Store.trashURL, \.trash),
        ]
        for (plan, localURL, recordPath) in files {
            guard let applied = try await apply(plan, resolution: resolution, accessToken: accessToken) else { continue }
            if let data = applied.downloaded {
                // No await from here to the reload, so an edit made while the download was in
                // flight is either caught by the hash check or can't happen at all.
                store.saveNow()
                let onDisk = (try? Data(contentsOf: localURL)) ?? Data()
                guard sha256Hex(onDisk) == plan.localHash else {
                    throw DriveSyncError.message("\(plan.displayName) changed on this Mac during the sync. Sync again.")
                }
                try data.write(to: localURL, options: .atomic)
                store.reloadFromDisk()
            }
            // Saved per file: if the next file fails, this one mustn't look changed on both sides.
            state[keyPath: recordPath] = applied.record
            SyncStateStore.save(state)
        }
    }

    private static func plan(displayName: String, fileName: String, localURL: URL,
                              record: SyncRecord?, accessToken: String) async throws -> SyncPlan {
        let localData = (try? Data(contentsOf: localURL)) ?? Data()
        let localHash = sha256Hex(localData)
        let remoteFile = try await step("look up \(displayName) on Drive") {
            try await findFile(named: fileName, preferredID: record?.fileId, accessToken: accessToken)
        }

        let localChanged = record?.localHash != localHash
        let remoteChanged = (remoteFile?.md5Checksum ?? "") != (record?.remoteMD5 ?? "")
        let action = SyncDecision.action(remoteExists: remoteFile != nil,
                                          localChanged: localChanged, remoteChanged: remoteChanged)

        return SyncPlan(displayName: displayName, fileName: fileName, action: action,
                         localData: localData, localHash: localHash, remoteFile: remoteFile)
    }

    /// Never writes local files itself — a download is handed back for `sync` to write, so
    /// the write happens on the main actor right next to the Store reload.
    private static func apply(_ plan: SyncPlan, resolution: ConflictResolution,
                               accessToken: String) async throws -> AppliedSync? {
        var action = plan.action
        if action == .conflict {
            switch resolution {
            case .keepLocal: action = .upload
            case .keepDrive: action = .download
            case .auto: return nil
            }
        }

        switch action {
        case .none:
            guard let remote = plan.remoteFile else { return nil }
            return AppliedSync(record: SyncRecord(fileId: remote.id, localHash: plan.localHash,
                                                  remoteMD5: remote.md5Checksum ?? ""))

        case .upload:
            let uploaded: DriveFile = try await step("upload \(plan.displayName) to Drive") {
                if let remote = plan.remoteFile {
                    return try await updateFile(id: remote.id, data: plan.localData, accessToken: accessToken)
                } else {
                    return try await uploadNewFile(named: plan.fileName, data: plan.localData, accessToken: accessToken)
                }
            }
            return AppliedSync(record: SyncRecord(fileId: uploaded.id, localHash: plan.localHash,
                                                  remoteMD5: uploaded.md5Checksum ?? ""))

        case .download:
            guard let remote = plan.remoteFile else { return nil }
            let data = try await step("download \(plan.displayName) from Drive") {
                try await downloadFile(id: remote.id, accessToken: accessToken)
            }
            return AppliedSync(record: SyncRecord(fileId: remote.id, localHash: sha256Hex(data),
                                                  remoteMD5: remote.md5Checksum ?? ""),
                               downloaded: data)

        case .conflict:
            return nil
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Alerts

    @MainActor
    private static func presentConflict(names: [String]) -> ConflictResolution? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Google Drive Sync Conflict"
        alert.informativeText = "\(names.joined(separator: " and ")) changed on both this Mac and "
            + "Google Drive since the last sync. Which should win?"
        alert.addButton(withTitle: "Keep This Mac")
        alert.addButton(withTitle: "Keep Google Drive")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepLocal
        case .alertSecondButtonReturn: return .keepDrive
        default: return nil
        }
    }

    @MainActor
    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Google Drive Sync Failed"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: OAuth

    private static func signIn() async throws -> String {
        let verifier = randomURLSafeString()
        let challenge = codeChallenge(for: verifier)
        let (code, redirectURI) = try await performLoopbackAuthorization(codeChallenge: challenge)
        let tokens = try await step("exchanging authorization code") {
            try await exchangeCodeForTokens(code: code, redirectURI: redirectURI, verifier: verifier)
        }
        guard let refreshToken = tokens.refresh_token else {
            throw DriveSyncError.message("Google didn't return a refresh token. Disconnect and sign in again — "
                + "this can happen if the app was already authorized without requesting offline access.")
        }
        return refreshToken
    }

    private static func randomURLSafeString(_ length: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Opens the system browser for consent, then catches the redirect on a loopback
    /// listener — the flow Google's "Desktop app" OAuth clients expect.
    ///
    /// Raw POSIX sockets (socket/bind/listen/accept), not Network.framework: NWListener
    /// consistently threw NWError 22 (EINVAL) from listener.start() on at least one real
    /// machine regardless of parameters (plain, and pinned to 127.0.0.1 + an explicit port),
    /// which points at something intercepting Network.framework itself (VPN/EDR/MDM software
    /// is a known cause) rather than a parameter mistake. Raw sockets sidestep that layer.
    private static func performLoopbackAuthorization(codeChallenge: String) async throws -> (code: String, redirectURI: String) {
        let (socketFD, port) = try openLoopbackSocket()

        let redirectURI = "http://127.0.0.1:\(port)/"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: App.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authURL = components.url else {
            Darwin.close(socketFD)
            throw DriveSyncError.message("Couldn't build the Google sign-in URL.")
        }

        NSWorkspace.shared.open(authURL)
        let code = try await step("waiting for Google sign-in redirect") {
            try await acceptAuthorizationCode(on: socketFD)
        }
        return (code, redirectURI)
    }

    /// socket() + bind() to 127.0.0.1 with an OS-assigned port + listen(). Each failure names
    /// the exact syscall and errno so a real failure here reads nothing like the old NWError.
    private static func openLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // let the OS assign a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = posixError("bind")
            Darwin.close(fd)
            throw error
        }

        guard listen(fd, 8) == 0 else {
            let error = posixError("listen")
            Darwin.close(fd)
            throw error
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            let error = posixError("getsockname")
            Darwin.close(fd)
            throw error
        }

        return (fd, UInt16(bigEndian: boundAddress.sin_port))
    }

    /// Blocks on poll()/accept()/read() on a background thread — plain blocking calls, not
    /// Network.framework — and resolves once the browser hits the redirect with a code.
    /// The timeout is poll()'s, on the same thread that owns `socketFD`, so the socket is
    /// closed exactly once. Closing it from a separate timer instead double-closed it after a
    /// successful sign-in, by which point the fd number may belong to something else.
    private static func acceptAuthorizationCode(on socketFD: Int32) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try receiveAuthorizationCode(on: socketFD) })
            }
        }
    }

    /// Loops over connections rather than taking the first: browsers open speculative
    /// connections that never send a request, and may ask for /favicon.ico. Taking only the
    /// first left sign-in hanging on an idle socket while the real redirect sat unaccepted.
    private static func receiveAuthorizationCode(on socketFD: Int32) throws -> String {
        defer { Darwin.close(socketFD) }
        let deadline = Date().addingTimeInterval(180)

        while true {
            let remainingMS = Int32(deadline.timeIntervalSinceNow * 1000)
            guard remainingMS > 0 else { throw DriveSyncError.message("Sign-in timed out.") }

            var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, remainingMS)
            if ready < 0 {
                if errno == EINTR { continue }
                throw posixError("poll")
            }
            guard ready > 0 else { throw DriveSyncError.message("Sign-in timed out.") }

            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                throw posixError("accept")
            }
            if let result = handleRedirect(on: clientFD) { return try result.get() }
        }
    }

    /// nil means "not the redirect" (an idle preconnect, a favicon fetch) — keep listening.
    private static func handleRedirect(on clientFD: Int32) -> Result<String, Error>? {
        defer { Darwin.close(clientFD) }

        // A browser that has already hung up must not SIGPIPE the whole app on write().
        var on: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var readTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(clientFD, &buffer, buffer.count)
        guard bytesRead > 0 else { return nil }
        let requestText = String(decoding: buffer[0..<bytesRead], as: UTF8.self)

        guard let requestLine = requestText.components(separatedBy: "\r\n").first,
              let path = requestLine.components(separatedBy: " ").dropFirst().first,
              let query = URLComponents(string: "http://127.0.0.1\(path)") else {
            respond(on: clientFD, status: "400 Bad Request", message: "Bad request.")
            return nil
        }

        let items = query.queryItems ?? []
        if let authCode = items.first(where: { $0.name == "code" })?.value {
            respond(on: clientFD, status: "200 OK",
                    message: "Signed in \u{2014} you can close this tab and return to my-stickies.")
            return .success(authCode)
        }
        if let reason = items.first(where: { $0.name == "error" })?.value {
            respond(on: clientFD, status: "200 OK",
                    message: "Sign-in didn\u{2019}t complete (\(reason)). You can close this tab.")
            return .failure(DriveSyncError.message("Google sign-in failed: \(reason)."))
        }
        respond(on: clientFD, status: "404 Not Found", message: "Not found.")
        return nil
    }

    private static func respond(on clientFD: Int32, status: String, message: String) {
        let body = "<html><body>\(message)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(body)"
        response.utf8CString.withUnsafeBufferPointer { buffer in
            _ = write(clientFD, buffer.baseAddress, buffer.count - 1) // drop the trailing NUL
        }
    }

    private static func posixError(_ call: String) -> DriveSyncError {
        let code = errno
        return DriveSyncError.message("[\(call)()] errno \(code) - \(String(cString: strerror(code)))")
    }

    private static func exchangeCodeForTokens(code: String, redirectURI: String, verifier: String) async throws -> TokenResponse {
        try await postToken([
            "code": code,
            "client_id": App.clientID,
            "client_secret": App.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
    }

    private static func refreshAccessToken(refreshToken: String) async throws -> String {
        try await postToken([
            "refresh_token": refreshToken,
            "client_id": App.clientID,
            "client_secret": App.clientSecret,
            "grant_type": "refresh_token",
        ]).access_token
    }

    private static func postToken(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(params)
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 400,
           (try? JSONDecoder().decode(TokenError.self, from: data))?.error == "invalid_grant" {
            throw DriveSyncError.revoked
        }
        try checkOK(response, data)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        let pairs = params.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)="
                + "\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    // MARK: Drive REST

    /// Several files can share the name (e.g. one re-created after a manual delete). Stick with
    /// the one the last sync matched; otherwise take the oldest so repeat syncs agree.
    private static func findFile(named name: String, preferredID: String?, accessToken: String) async throws -> DriveFile? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "name = '\(name)' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,md5Checksum)"),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "orderBy", value: "createdTime"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response, data)
        let files = try JSONDecoder().decode(DriveFileList.self, from: data).files
        return files.first { $0.id == preferredID } ?? files.first
    }

    private static func uploadNewFile(named name: String, data fileData: Data, accessToken: String) async throws -> DriveFile {
        let boundary = "my-stickies-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(Data("{\"name\":\"\(name)\"}\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--".utf8))

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,md5Checksum")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response, data)
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    private static func updateFile(id: String, data fileData: Data, accessToken: String) async throws -> DriveFile {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media&fields=id,md5Checksum")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = fileData
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response, data)
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    private static func downloadFile(id: String, accessToken: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response, data)
        return data
    }

    private static func checkOK(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = (String(data: data, encoding: .utf8) ?? "").prefix(200)
            throw DriveSyncError.message("Google Drive returned an error (\(status)): \(body)")
        }
    }
}

// MARK: - Pure decision logic (covered by SelfTest)

enum SyncAction: Equatable { case none, upload, download, conflict }

enum SyncDecision {
    /// Whichever side changed since the last successful sync wins; both changing is a conflict.
    static func action(remoteExists: Bool, localChanged: Bool, remoteChanged: Bool) -> SyncAction {
        guard remoteExists else { return .upload }
        switch (localChanged, remoteChanged) {
        case (false, false): return .none
        case (true, false): return .upload
        case (false, true): return .download
        case (true, true): return .conflict
        }
    }
}

// MARK: - Wire types

private struct SyncPlan {
    let displayName: String
    let fileName: String
    let action: SyncAction
    let localData: Data
    let localHash: String
    let remoteFile: DriveFile?
}

private enum ConflictResolution { case keepLocal, keepDrive, auto }

private struct AppliedSync {
    let record: SyncRecord
    var downloaded: Data? = nil
}

private struct DriveFile: Decodable {
    let id: String
    let md5Checksum: String?
}

private struct DriveFileList: Decodable { let files: [DriveFile] }

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
}

private struct TokenError: Decodable { let error: String }

enum DriveSyncError: LocalizedError {
    case message(String)
    /// The token endpoint said `invalid_grant`: the refresh token is dead and only a new
    /// sign-in will fix it.
    case revoked
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .revoked: return "Google rejected the stored sign-in (invalid_grant). Sync again to sign in."
        }
    }
}

// MARK: - Sync state (which remote file id + content hash we last matched)

private struct SyncRecord: Codable {
    var fileId: String
    var localHash: String
    var remoteMD5: String
}

private struct SyncState: Codable {
    var notes: SyncRecord?
    var trash: SyncRecord?
}

private enum SyncStateStore {
    static let url = Store.fileURL.deletingLastPathComponent().appendingPathComponent("drive_sync_state.json")

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    static func save(_ state: SyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Keychain (refresh token only; access tokens are always re-derived, never cached)

private enum Keychain {
    private static let service = "com.shastraw.my-stickies.google-drive"

    static func set(_ value: String, account: String) {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
