import BuildDistroUpload
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Zips a dSYMs folder the way Xcode's tools expect, next to nothing else.
func zipFolder(_ folder: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let output = directory.appending(path: "dSYMs.zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, output.path]
    try ditto.run()
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else { fail("couldn't zip \(folder.path)") }
    return output
}

/// Exposes the result to later workflow steps and the run summary.
func writeGitHubOutputs(_ build: Build, environment: [String: String]) {
    if let path = environment["GITHUB_OUTPUT"], let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data("url=\(build.url)\nnumber=\(build.number)\n".utf8))
        try? handle.close()
    }
    if let path = environment["GITHUB_STEP_SUMMARY"], let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data("Build distributed: [#\(build.number)](\(build.url))\n".utf8))
        try? handle.close()
    }
}

// CI captures stdout through a pipe; line buffering shows progress as it happens.
setvbuf(stdout, nil, _IOLBF, 0)

/// The build the server created, kept so a later failure can be reported on it.
actor StartedBuild {
    var build: Build?
    func set(_ build: Build) { self.build = build }
}

func failedBuild(_ build: Build, _ reason: String) -> Build {
    var build = build
    build.state = "failed"
    build.failureReason = reason
    return build
}

let environment = ProcessInfo.processInfo.environment
let options: Options
do {
    options = try Options(arguments: Array(CommandLine.arguments.dropFirst()), environment: environment)
} catch Options.ParseError.help {
    print(Options.usage)
    exit(0)
} catch {
    fail("\(error)")
}

do {
    var artifacts = [try LocalArtifact(kind: "ipa", fileURL: options.ipa)]
    if let dsyms = options.dsyms {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: dsyms.path, isDirectory: &isFolder)
        artifacts.append(try LocalArtifact(kind: "dsyms", fileURL: isFolder.boolValue ? try zipFolder(dsyms) : dsyms))
    }

    let uploader = Uploader(
        client: BuildDistroClient(server: options.server, apiKey: options.apiKey),
        concurrency: options.concurrency
    )
    let reporter = options.gitHub.flatMap { target in options.gitHubToken.map { GitHubReporter(target: target, token: $0) } }
    let started = StartedBuild()

    do {
        var build = try await uploader.upload(artifacts, metadata: options.metadata) { build in
            await started.set(build)
            await reporter?.started(build)
        }
        if options.wait {
            build = try await uploader.waitUntilProcessed(build, timeout: options.timeout)
            print("Ready to install: \(build.url)")
        }
        await reporter?.finished(build)
        writeGitHubOutputs(build, environment: environment)
    } catch let UploadError.buildFailed(reason) {
        if let build = await started.build { await reporter?.finished(failedBuild(build, reason)) }
        throw UploadError.buildFailed(reason: reason)
    } catch {
        if let build = await started.build { await reporter?.uploadFailed(build, error: error) }
        throw error
    }
} catch {
    fail("\(error)")
}
