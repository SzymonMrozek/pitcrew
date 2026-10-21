import Foundation

/// Runs the upload protocol: start, parts in parallel, complete, and optionally
/// wait until the build is ready. Safe to run again after any failure: the
/// same idempotency key resumes the same build and skips parts already stored.
public struct Uploader: Sendable {
    public var client: BuildDistroClient
    public var concurrency: Int
    /// Rounds of "ask which parts are missing, upload them". Each part also
    /// retries on its own within a round.
    public var rounds: Int
    public var log: @Sendable (String) -> Void

    public init(client: BuildDistroClient, concurrency: Int = 6, rounds: Int = 4, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.client = client
        self.concurrency = max(1, concurrency)
        self.rounds = max(1, rounds)
        self.log = log
    }

    /// `started` runs once the server has created (or resumed) the build.
    public func upload(
        _ artifacts: [LocalArtifact],
        metadata: BuildMetadata,
        started: @Sendable (Build) async -> Void = { _ in }
    ) async throws -> Build {
        let request = StartRequest(
            idempotencyKey: metadata.idempotencyKey,
            commitSha: metadata.commitSHA,
            branch: metadata.branch,
            prNumber: metadata.pullRequest,
            runUrl: metadata.runURL,
            commitMessage: metadata.commitMessage,
            releaseNotes: metadata.releaseNotes,
            artifacts: artifacts.map { .init(kind: $0.kind, size: $0.size, filename: $0.fileURL.lastPathComponent) }
        )

        let build = try await client.start(request)
        log("Build #\(build.number): \(build.url)")
        await started(build)

        guard build.state == "uploading" else {
            log("Already \(build.state); nothing to upload.")
            return build
        }

        for round in 1 ... rounds {
            for artifact in artifacts where !(build.artifacts.first { $0.kind == artifact.kind }?.uploaded ?? false) {
                try await uploadMissingParts(of: artifact, buildID: build.id)
            }

            switch try await client.complete(buildID: build.id) {
            case let .completed(build):
                log("Uploaded; the build is \(build.state).")
                return build
            case let .incomplete(kind, missing) where round < rounds:
                log("\(kind) is missing parts \(missing); uploading them again.")
            case let .incomplete(kind, missing):
                throw UploadError.incomplete(kind: kind, missingParts: missing)
            }
        }
        preconditionFailure("unreachable: the last round returns or throws")
    }

    /// Polls until the build is ready or failed.
    public func waitUntilProcessed(_ build: Build, timeout: Duration, interval: Duration = .seconds(2)) async throws -> Build {
        let deadline = ContinuousClock.now + timeout
        var build = build

        while build.state == "uploading" || build.state == "processing" {
            guard ContinuousClock.now < deadline else { throw UploadError.timedOut(state: build.state) }
            try await client.retry.sleep(interval)
            build = try await client.build(id: build.id)
        }

        if build.state == "failed" { throw UploadError.buildFailed(reason: build.failureReason ?? "unknown") }
        return build
    }

    private func uploadMissingParts(of artifact: LocalArtifact, buildID: Int) async throws {
        // The first request learns the part count and what the bucket already has.
        let first = try await client.partURLs(buildID: buildID, kind: artifact.kind, numbers: [])
        let uploaded = Set(first.uploaded)
        let missing = (1 ... first.partCount).filter { !uploaded.contains($0) }
        guard !missing.isEmpty else { return }

        let name = artifact.fileURL.lastPathComponent
        if !uploaded.isEmpty { log("\(name): resuming, \(uploaded.count) of \(first.partCount) parts already stored.") }

        let progress = Progress(total: first.partCount, done: uploaded.count)
        // Presigned URLs expire, so they're requested in batches as uploads proceed.
        for batch in missing.chunked(into: 100) {
            let urls = try await client.partURLs(buildID: buildID, kind: artifact.kind, numbers: batch)
            let partSize = urls.partSize

            await withTaskGroup(of: Bool.self) { group in
                var pending = urls.urls.compactMap { key, value in Int(key).flatMap { number in URL(string: value).map { (number, $0) } } }
                    .sorted { $0.0 < $1.0 }[...]

                func next() -> (Int, URL)? { pending.popFirst() }

                for _ in 0 ..< concurrency {
                    guard let (number, url) = next() else { break }
                    group.addTask { await uploadPart(number, url, artifact, partSize, buildID) }
                }

                // A part that fails every retry is left for the next round, which
                // asks the server again which parts are missing.
                while let uploaded = await group.next() {
                    let done = uploaded ? await progress.increment() : await progress.done
                    if done == first.partCount || done % max(1, first.partCount / 10) == 0 {
                        log("\(name): \(done)/\(first.partCount) parts")
                    }
                    if let (number, url) = next() {
                        group.addTask { await uploadPart(number, url, artifact, partSize, buildID) }
                    }
                }
            }
        }
    }

    /// Returns whether the part was stored. An expired URL (403) isn't retried
    /// here; the next round gets a fresh one.
    @Sendable
    private func uploadPart(_ number: Int, _ url: URL, _ artifact: LocalArtifact, _ partSize: Int, _ buildID: Int) async -> Bool {
        do {
            let data = try readPart(number, of: artifact, partSize: partSize)
            try await client.retry.run { try await client.uploadPart(to: url, data: data) }
            await client.reportProgress(buildID: buildID, kind: artifact.kind, part: number, size: data.count)
            return true
        } catch {
            log("\(artifact.fileURL.lastPathComponent): part \(number) failed: \(error)")
            return false
        }
    }

    private func readPart(_ number: Int, of artifact: LocalArtifact, partSize: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: artifact.fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64((number - 1) * partSize))
        return try handle.read(upToCount: partSize) ?? Data()
    }
}

private actor Progress {
    let total: Int
    var done: Int

    init(total: Int, done: Int) {
        self.total = total
        self.done = done
    }

    func increment() -> Int {
        done += 1
        return done
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
