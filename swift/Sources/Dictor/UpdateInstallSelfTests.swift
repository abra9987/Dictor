// Самотесты установки обновления: скрипт помощника, замена приложения на
// подписанную копию, окно прогресса и защита от подменённого окружения.

import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testUpdateHelperScript() throws {
        try expect(
            shellSingleQuoted("a'b"),
            equals: "'a'\"'\"'b'",
            "shell quoting should preserve embedded single quotes"
        )
        try expect(
            (UPDATE_HELPER_LOG_PATH as NSString).deletingLastPathComponent,
            equals: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs"),
            "update helper log should live in the user's log directory"
        )
        // Раньше здесь проверялось ещё и окружение с Homebrew в PATH: обновление
        // ставилось через brew cask из апстримового tap. Раздача идёт образом со
        // своего канала, brew-путь удалён — остаётся одно окружение, системное.
        let systemEnv = systemToolProcessEnvironment(current: [
            "LANG": "en_GB.UTF-8",
            "USER": "dictor-user",
            "LOGNAME": "dictor-logname",
            "BASH_ENV": "/tmp/pwn.sh",
            "ENV": "/tmp/pwn.sh",
            "SHELLOPTS": "xtrace",
            "RUBYOPT": "-r/tmp/pwn.rb",
            "DYLD_INSERT_LIBRARIES": "/tmp/pwn.dylib",
            "HOMEBREW_BOTTLE_DOMAIN": "https://example.test",
            "PATH": "/tmp/bin",
        ])
        try expect(systemEnv["HOME"], equals: Optional(NSHomeDirectory()),
                   "system tool environment should set HOME explicitly")
        try expect(systemEnv["LOGNAME"], equals: Optional("dictor-logname"),
                   "system tool environment should preserve a safe LOGNAME value")
        for key in ["ENV", "SHELLOPTS", "RUBYOPT", "HOMEBREW_BOTTLE_DOMAIN"] {
            try expect(systemEnv[key], equals: String?.none,
                       "system tool environment should not inherit \(key)")
        }
        try expect(systemEnv["PATH"], equals: Optional("/usr/bin:/bin:/usr/sbin:/sbin"),
                   "system tool environment should not include Homebrew or inherited PATH entries")
        try expect(systemEnv["LANG"], equals: Optional("en_GB.UTF-8"),
                   "system tool environment should preserve a safe locale")
        try expect(systemEnv["USER"], equals: Optional("dictor-user"),
                   "system tool environment should preserve a safe USER value")
        for key in ["BASH_ENV", "DYLD_INSERT_LIBRARIES"] {
            try expect(systemEnv[key], equals: String?.none,
                       "system tool environment should not inherit \(key)")
        }

        let directScript = dictorDirectUpdateHelperScript(
            pid: 123,
            targetVersion: "9.8.7",
            statePath: "/tmp/dictor-update.state",
            stagedAppPath: "/tmp/work/release/Dictor.app",
            workDirectory: "/tmp/work",
            backupAppPath: "/Applications/.Dictor-update-backup-test.app",
            appPath: "/Applications/Dictor.app",
            language: .english
        )
        for fragment in [
            "PANEL_PID=123",
            "TARGET_VERSION='9.8.7'",
            "STAGED_APP='/tmp/work/release/Dictor.app'",
            "BACKUP_APP='/Applications/.Dictor-update-backup-test.app'",
            "wait_for_panel_exit || rollback",
            "SERVICE=\"gui/$(/usr/bin/id -u)/\(AGENT_LABEL)\"",
            "launchctl bootout \"$SERVICE\"",
            // Окно — отдельный процесс, и оно переживало подмену бандла:
            // финальный `open` тогда лишь поднимал уже живое приложение,
            // нового процесса не появлялось, и службу ставить было некому.
            // Обновление проходило, а диктовка исчезала.
            "/usr/bin/pkill -f \"$APP_PATH/Contents/MacOS/Dictor\"",
            // И служба поднимается явно, а не в надежде на запущенное
            // приложение: диктовка — то, ради чего Dictor стоит на машине.
            "/bin/launchctl bootstrap \"gui/$(/usr/bin/id -u)\" \"$AGENT_PLIST\"",
            "/bin/mv \"$APP_PATH\" \"$BACKUP_APP\" || rollback",
            "/usr/bin/ditto \"$STAGED_APP\" \"$APP_PATH\" || rollback",
            "/usr/bin/codesign --verify --deep --strict \"$APP_PATH\"",
            "if [ -d \"$BACKUP_APP\" ]; then",
            "state \"complete\" 'Dictor v9.8.7 is installed.'",
        ] {
            guard directScript.contains(fragment) else {
                throw SelfTestFailure.failed("direct update helper missing fragment: \(fragment)")
            }
        }
        // Лог открывает вызывающий и передаёт скрипту готовый дескриптор.
        // Скрипт, который откроет путь сам, пишет туда с чужими правами.
        for fragment in ["LOG=", ">>\"$LOG\"", ">\"$LOG\"", "prepare_log"] {
            guard !directScript.contains(fragment) else {
                throw SelfTestFailure.failed("direct update helper should not reopen a log path: \(fragment)")
            }
        }
        let directTmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictor-direct-update-self-test-\(UUID().uuidString).sh")
        try directScript.write(to: directTmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directTmp) }
        let directProc = Process()
        directProc.executableURL = URL(fileURLWithPath: "/bin/bash")
        directProc.arguments = ["-n", directTmp.path]
        directProc.standardOutput = Pipe()
        directProc.standardError = Pipe()
        try directProc.run()
        directProc.waitUntilExit()
        guard directProc.terminationStatus == 0 else {
            throw SelfTestFailure.failed("direct update helper script should pass bash -n")
        }

        let fm = FileManager.default
        let helperRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictor-update-helper-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: helperRoot, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: helperRoot) }

        let helperPath = try writePrivateUpdateHelperScript(directScript,
                                                            directory: helperRoot.path,
                                                            fileName: "helper.sh")
        var createdStat = stat()
        guard lstat(helperPath, &createdStat) == 0 else {
            throw SelfTestFailure.failed("update helper script file should exist")
        }
        try expect((createdStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "update helper script should be a regular file")
        try expect(Int(createdStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "update helper script should be private to the current user")
        try expect(Int(createdStat.st_nlink),
                   equals: 1,
                   "update helper script should not be hard-linked")
        try expect(
            String(data: try Data(contentsOf: URL(fileURLWithPath: helperPath)), encoding: .utf8),
            equals: directScript,
            "update helper script file should contain the generated script"
        )

        let existing = helperRoot.appendingPathComponent("existing.sh")
        try Data("existing\n".utf8).write(to: existing)
        var existingRejected = false
        do {
            _ = try writePrivateUpdateHelperScript("bad",
                                                   directory: helperRoot.path,
                                                   fileName: "existing.sh")
        } catch {
            existingRejected = true
        }
        try expect(existingRejected, equals: true,
                   "update helper script writer should reject existing files")
        try expect(
            String(data: try Data(contentsOf: existing), encoding: .utf8),
            equals: "existing\n",
            "update helper script writer should leave existing files untouched"
        )

        let target = helperRoot.appendingPathComponent("target.sh")
        try Data("target\n".utf8).write(to: target)
        let link = helperRoot.appendingPathComponent("linked.sh")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        var symlinkRejected = false
        do {
            _ = try writePrivateUpdateHelperScript("bad",
                                                   directory: helperRoot.path,
                                                   fileName: "linked.sh")
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected, equals: true,
                   "update helper script writer should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "update helper script writer should leave symlink targets untouched"
        )

        let preferredLog = helperRoot.appendingPathComponent("Dictor-update.log")
        let helperLog = try openPrivateUpdateHelperLog(preferredPath: preferredLog.path,
                                                       fallbackDirectory: helperRoot.path)
        helperLog.handle.write(Data("log\n".utf8))
        helperLog.handle.closeFile()
        try expect(helperLog.path, equals: preferredLog.path,
                   "update helper log should use the preferred path when safe")
        var logStat = stat()
        guard lstat(preferredLog.path, &logStat) == 0 else {
            throw SelfTestFailure.failed("update helper log file should exist")
        }
        try expect((logStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "update helper log should be a regular file")
        try expect(Int(logStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "update helper log should be private to the current user")
        try expect(Int(logStat.st_nlink),
                   equals: 1,
                   "update helper log should not be hard-linked")
        try expect(
            String(data: try Data(contentsOf: preferredLog), encoding: .utf8),
            equals: "log\n",
            "update helper log should receive helper output"
        )

        let linkedLogTarget = helperRoot.appendingPathComponent("linked-log-target.log")
        try Data("target log\n".utf8).write(to: linkedLogTarget)
        let linkedLog = helperRoot.appendingPathComponent("linked-log.log")
        try fm.createSymbolicLink(at: linkedLog, withDestinationURL: linkedLogTarget)
        let fallbackForSymlink = try openPrivateUpdateHelperLog(preferredPath: linkedLog.path,
                                                                fallbackDirectory: helperRoot.path)
        fallbackForSymlink.handle.write(Data("fallback\n".utf8))
        fallbackForSymlink.handle.closeFile()
        try expect(fallbackForSymlink.path == linkedLog.path,
                   equals: false,
                   "update helper log should fall back when preferred path is a symlink")
        try expect(
            String(data: try Data(contentsOf: linkedLogTarget), encoding: .utf8),
            equals: "target log\n",
            "update helper log fallback should leave symlink targets untouched"
        )

        let hardLogTarget = helperRoot.appendingPathComponent("hard-log-target.log")
        try Data("hard target\n".utf8).write(to: hardLogTarget)
        let hardLog = helperRoot.appendingPathComponent("hard-log.log")
        try fm.linkItem(at: hardLogTarget, to: hardLog)
        let fallbackForHardLink = try openPrivateUpdateHelperLog(preferredPath: hardLog.path,
                                                                 fallbackDirectory: helperRoot.path)
        fallbackForHardLink.handle.write(Data("hard fallback\n".utf8))
        fallbackForHardLink.handle.closeFile()
        try expect(fallbackForHardLink.path == hardLog.path,
                   equals: false,
                   "update helper log should fall back when preferred path is hard-linked")
        try expect(
            String(data: try Data(contentsOf: hardLogTarget), encoding: .utf8),
            equals: "hard target\n",
            "update helper log fallback should leave hard-linked targets untouched"
        )
    }

    static func testDirectUpdateReplacement() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dictor-update-replacement-test-\(UUID().uuidString)",
                                    isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let currentApp = applications.appendingPathComponent("Dictor.app", isDirectory: true)
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        let stagedApp = workDirectory
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent("Dictor.app", isDirectory: true)
        let backupApp = applications.appendingPathComponent(".Dictor-update-backup.app",
                                                             isDirectory: true)
        let statePath = root.appendingPathComponent("state.txt")
        let helperPath = root.appendingPathComponent("helper.sh")
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        try makeSyntheticSignedUpdateApp(at: currentApp, version: "1.0.0")
        try makeSyntheticSignedUpdateApp(at: stagedApp, version: "9.8.7")
        try Data("starting\tStarting update…\n".utf8).write(to: statePath)
        defer { try? fileManager.removeItem(at: root) }

        let script = dictorDirectUpdateHelperScript(
            pid: Int32.max,
            targetVersion: "9.8.7",
            statePath: statePath.path,
            stagedAppPath: stagedApp.path,
            workDirectory: workDirectory.path,
            backupAppPath: backupApp.path,
            appPath: currentApp.path,
            language: .english,
            relaunch: false,
            // Never the real label: this script is executed, not just
            // parsed, and its bootout line would otherwise uninstall the
            // dictation service of whoever is running the tests.
            agentLabel: "com.raul.dictor.self-test-\(UUID().uuidString)"
        )
        try expect(
            script.contains(AGENT_LABEL),
            equals: false,
            "an update helper script that the tests actually execute must not name the real launchd service"
        )
        try script.write(to: helperPath, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperPath.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let processOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SelfTestFailure.failed("direct update replacement failed: \(processOutput)")
        }

        if selfTestHasSigningIdentity {
            try DictorUpdateInstaller.validateApp(at: currentApp,
                                                  expectedVersion: "9.8.7")

            // Обратная сторона пиннинга: сборка с чужой подписью обязана
            // отлетать. Без этой проверки регрессия в требовании прошла бы
            // незамеченной — «валидный» бандл валиден в обоих случаях.
            let foreignApp = root.appendingPathComponent("Foreign.app", isDirectory: true)
            try makeSyntheticSignedUpdateApp(at: foreignApp, version: "9.8.7", identity: "-")
            let renamed = root.appendingPathComponent("Dictor.app", isDirectory: true)
            try fileManager.moveItem(at: foreignApp, to: renamed)
            var rejected = false
            do {
                try DictorUpdateInstaller.validateApp(at: renamed, expectedVersion: "9.8.7")
            } catch {
                rejected = true
            }
            try expect(rejected, equals: true,
                       "an ad-hoc signed build must not satisfy the pinned code requirement")
        } else {
            log("self-test: no 'Dictor Dev' identity, skipping pinned signature checks")
        }
        try expect(fileManager.fileExists(atPath: backupApp.path), equals: false,
                   "successful direct update should remove its backup")
        try expect(fileManager.fileExists(atPath: workDirectory.path), equals: false,
                   "successful direct update should remove staged files")
        try expect(UpdateProgressState.read(from: statePath.path)?.phase,
                   equals: Optional("complete"),
                   "successful direct update should report completion")
    }

    private static func makeSyntheticSignedUpdateApp(at appURL: URL,
                                                     version: String,
                                                     identity: String? = nil) throws {
        guard let sourceExecutable = Bundle.main.executableURL else {
            throw SelfTestFailure.failed("self-test executable URL is unavailable")
        }
        let fileManager = FileManager.default
        let executableDirectory = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executableURL = executableDirectory.appendingPathComponent("Dictor")
        try fileManager.copyItem(at: sourceExecutable, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: executableURL.path)
        let info: [String: Any] = [
            "CFBundleExecutable": "Dictor",
            "CFBundleIdentifier": "com.raul.dictor",
            "CFBundleName": "Dictor",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info,
                                                          format: .xml,
                                                          options: 0)
        try infoData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let signing = DictorAgentService.run(
            "/usr/bin/codesign",
            ["--force", "--deep", "--sign", identity ?? selfTestSigningIdentity(), appURL.path])
        guard signing.status == 0 else {
            throw SelfTestFailure.failed("could not sign synthetic update app: \(signing.output)")
        }
    }

    /// Апдейтер ставит только сборки, подписанные «Dictor Dev»
    /// (UPDATE_SIGNING_CERT_SHA1), поэтому синтетический бандл подписываем
    /// тем же сертификатом. Ad-hoc остаётся запасным вариантом для машин без
    /// сертификата — там проверка подписи в тесте пропускается.
    private static func selfTestSigningIdentity() -> String {
        let identities = DictorAgentService.run(
            "/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        return identities.output.contains("\"Dictor Dev\"") ? "Dictor Dev" : "-"
    }

    private static var selfTestHasSigningIdentity: Bool {
        selfTestSigningIdentity() != "-"
    }

    static func testUpdateProgressState() throws {
        let launch = UpdateProgressLaunch(arguments: [
            UPDATE_PROGRESS_ARGUMENT,
            "/tmp/dictor.state",
            "/tmp/dictor.log",
            "9.8.7",
            "/tmp/\(UPDATE_PROGRESS_APP_PREFIX)test.app",
        ])
        try expect(launch != nil, equals: true,
                   "update progress launch arguments should parse")
        try expect(launch?.targetVersion, equals: Optional("9.8.7"),
                   "update progress launch should retain target version")
        try expect(
            UpdateProgressLaunch(arguments: [UPDATE_PROGRESS_ARGUMENT, "", "/tmp/dictor.log", "9.8.7", "/tmp/app"]) != nil,
            equals: false,
            "update progress launch should reject empty paths"
        )

        let statePath = try createPrivateUpdateProgressStateFile()
        defer { try? FileManager.default.removeItem(atPath: statePath) }

        var st = stat()
        guard lstat(statePath, &st) == 0 else {
            throw SelfTestFailure.failed("update progress state file should exist")
        }
        try expect((st.st_mode & S_IFMT) == S_IFREG, equals: true,
                   "update progress state file should be regular")
        try expect(Int(st.st_nlink), equals: 1,
                   "update progress state file should not be hard-linked")
        try expect(Int(st.st_mode & mode_t(0o777)), equals: 0o600,
                   "update progress state file should be private to the current user")

        let initial = UpdateProgressState.read(from: statePath)
        try expect(initial?.phase, equals: Optional("starting"),
                   "update progress state should default to starting")
        try expect(initial?.message, equals: Optional("Starting update..."),
                   "update progress state should default to the startup message")

        // Файл состояния в бою пишет bash-хелпер строками «фаза\tсообщение» —
        // проверяется контракт чтения на таком же сыром содержимом. Раньше
        // тут проверялась Swift-функция записи, которую продакшн не вызывал.
        guard let stateHandle = FileHandle(forWritingAtPath: statePath) else {
            throw SelfTestFailure.failed("update progress state file should be writable")
        }
        stateHandle.truncateFile(atOffset: 0)
        stateHandle.write(Data("installing\tCopying files...\n".utf8))
        stateHandle.closeFile()
        let installing = UpdateProgressState.read(from: statePath)
        try expect(installing?.phase, equals: Optional("installing"),
                   "update progress read should take the phase before the first tab")
        try expect(installing?.message, equals: Optional("Copying files..."),
                   "update progress read should take the message after the tab")

        let safeCleanupPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)test.app")
        try expect(isSafeUpdateProgressCleanupPath(safeCleanupPath), equals: true,
                   "update progress cleanup should allow copied temp app bundles")
        try expect(isSafeUpdateProgressCleanupPath("/Applications/Dictor.app"), equals: false,
                   "update progress cleanup should reject non-temp app bundles")
        let unsafeTempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("Dictor.app")
        try expect(isSafeUpdateProgressCleanupPath(unsafeTempPath), equals: false,
                   "update progress cleanup should reject temp app bundles without the copied-helper prefix")
    }

    static func testHostileRegistryEnvDetection() throws {
        try expect(
            detectedHostileRegistryEnvVars(in: [:]),
            equals: [],
            "empty environment should not flag any registry override"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["HF_TOKEN": "redacted",
                                                "PATH": "/usr/bin"]),
            equals: [],
            "unrelated env vars (incl. HF_TOKEN) must not flag as hostile"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["REGISTRY_URL": "https://evil.example/"]),
            equals: ["REGISTRY_URL"],
            "REGISTRY_URL must be flagged"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["MODEL_REGISTRY_URL": "https://evil.example/"]),
            equals: ["MODEL_REGISTRY_URL"],
            "MODEL_REGISTRY_URL must be flagged"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["REGISTRY_URL": "",
                                                "MODEL_REGISTRY_URL": ""]),
            equals: ["MODEL_REGISTRY_URL", "REGISTRY_URL"],
            "an empty-string value still represents a tampered launch env"
        )
    }
}
#endif
