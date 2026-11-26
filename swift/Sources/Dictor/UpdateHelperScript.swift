import AppKit

func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

func sanitizedEnvironmentValue(_ value: String?) -> String? {
    guard let value,
          !value.isEmpty,
          !value.utf8.contains(0),
          !value.contains(where: { $0.isNewline }) else {
        return nil
    }
    return value
}

func trustedProcessEnvironment(path: String,
                                       current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var env: [String: String] = [
        "HOME": NSHomeDirectory(),
        "PATH": path,
        "SHELL": "/bin/zsh",
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": sanitizedEnvironmentValue(current["LANG"]) ?? "en_US.UTF-8",
    ]

    if let user = sanitizedEnvironmentValue(current["USER"]) {
        env["USER"] = user
    }
    if let logname = sanitizedEnvironmentValue(current["LOGNAME"]) ?? env["USER"] {
        env["LOGNAME"] = logname
    }
    if let encoding = sanitizedEnvironmentValue(current["__CF_USER_TEXT_ENCODING"]) {
        env["__CF_USER_TEXT_ENCODING"] = encoding
    }

    return env
}

func systemToolProcessEnvironment(current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    trustedProcessEnvironment(path: "/usr/bin:/bin:/usr/sbin:/sbin", current: current)
}

func dictorDirectUpdateHelperScript(pid: pid_t,
                                           targetVersion: String,
                                           statePath: String,
                                           stagedAppPath: String,
                                           workDirectory: String,
                                           backupAppPath: String,
                                           appPath: String,
                                           language: InterfaceLanguage,
                                           relaunch: Bool = true,
                                           // Parameterised for one reason: the self-test runs this
                                           // script for real against a temporary bundle, and a
                                           // hard-coded label made it boot out the live agent —
                                           // running the tests uninstalled the user's dictation
                                           // service. Everything else in the script is already
                                           // addressed by path, so the label was the last thing
                                           // reaching outside the sandbox.
                                           agentLabel: String = AGENT_LABEL) -> String {
    let preparing = localizedText("Подготавливаю замену приложения…",
                                  "Preparing to replace the application…",
                                  language: language)
    let installing = localizedText("Устанавливаю Dictor v\(targetVersion)…",
                                    "Installing Dictor v\(targetVersion)…",
                                    language: language)
    let verifying = localizedText("Проверяю установленную версию…",
                                   "Verifying the installed version…",
                                   language: language)
    let relaunching = localizedText("Обновление готово. Запускаю Dictor…",
                                    "Update complete. Reopening Dictor…",
                                    language: language)
    let complete = localizedText("Dictor v\(targetVersion) установлена.",
                                  "Dictor v\(targetVersion) is installed.",
                                  language: language)
    let failed = localizedText("Обновление не установлено. Предыдущая версия восстановлена.",
                                "The update was not installed. The previous version was restored.",
                                language: language)

    return #"""
    #!/bin/bash
    set -u
    umask 077

    SCRIPT_PATH="$0"
    PANEL_PID=\#(pid)
    TARGET_VERSION=\#(shellSingleQuoted(targetVersion))
    STATE_PATH=\#(shellSingleQuoted(statePath))
    STAGED_APP=\#(shellSingleQuoted(stagedAppPath))
    WORK_DIR=\#(shellSingleQuoted(workDirectory))
    BACKUP_APP=\#(shellSingleQuoted(backupAppPath))
    APP_PATH=\#(shellSingleQuoted(appPath))
    SHOULD_RELAUNCH=\#(relaunch ? "1" : "0")
    APP_PARENT="$(/usr/bin/dirname "$APP_PATH")"
    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    SERVICE="gui/$(/usr/bin/id -u)/\#(agentLabel)"
    AGENT_PLIST="$HOME/Library/LaunchAgents/\#(agentLabel).plist"

    timestamp() {
        /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
    }

    log() {
        printf '[%s] %s\n' "$(timestamp)" "$*"
    }

    state() {
        local phase="$1"
        local message="$2"
        local tmp="${STATE_PATH}.$$"
        log "$message"
        if printf '%s\t%s\n' "$phase" "$message" >"$tmp"; then
            /bin/chmod 600 "$tmp" 2>/dev/null || true
            /bin/mv -f "$tmp" "$STATE_PATH" 2>/dev/null || true
        else
            /bin/rm -f "$tmp" 2>/dev/null || true
        fi
    }

    cleanup() {
        /bin/rm -rf "$WORK_DIR" 2>/dev/null || true
        /bin/rm -f "$SCRIPT_PATH" 2>/dev/null || true
    }
    trap cleanup EXIT

    wait_for_panel_exit() {
        for _ in {1..40}; do
            if ! /bin/kill -0 "$PANEL_PID" 2>/dev/null; then
                return 0
            fi
            /bin/sleep 0.25
        done
        /bin/kill -TERM "$PANEL_PID" 2>/dev/null || true
        /bin/sleep 1
        ! /bin/kill -0 "$PANEL_PID" 2>/dev/null
    }

    verify_app() {
        [ -x "$APP_PATH/Contents/MacOS/Dictor" ] || return 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null)" = "com.raul.dictor" ] || return 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null)" = "$TARGET_VERSION" ] || return 1
        /usr/bin/codesign --verify --deep --strict "$APP_PATH"
    }

    rollback() {
        log "Rolling back the application bundle."
        if [ -d "$BACKUP_APP" ]; then
            /bin/rm -rf "$APP_PATH" 2>/dev/null || true
            /bin/mv "$BACKUP_APP" "$APP_PATH" 2>/dev/null || true
        fi
        state "failed" \#(shellSingleQuoted(failed))
        if [ "$SHOULD_RELAUNCH" = "1" ] && [ -d "$APP_PATH" ]; then
            /usr/bin/open "$APP_PATH" 2>/dev/null || true
        fi
        exit 1
    }

    state "preparing" \#(shellSingleQuoted(preparing))
    [ -d "$STAGED_APP" ] || rollback
    [ -d "$APP_PATH" ] || rollback
    [ ! -e "$BACKUP_APP" ] || rollback
    [ -w "$APP_PATH" ] && [ -w "$APP_PARENT" ] || rollback
    wait_for_panel_exit || rollback

    /bin/launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    # Снимаем ВСЕ процессы приложения, а не только службу. Dictor — это ещё и
    # окно, отдельный процесс; оно переживало подмену бандла, и тогда финальный
    # `open` не запускал ничего нового: macOS видел живое приложение с тем же
    # идентификатором и просто выводил его вперёд. Ставить службу обратно
    # оказывалось некому — обновление проходило, а диктовка исчезала.
    /usr/bin/pkill -f "$APP_PATH/Contents/MacOS/Dictor" >/dev/null 2>&1 || true
    /bin/sleep 1

    state "installing" \#(shellSingleQuoted(installing))
    /bin/mv "$APP_PATH" "$BACKUP_APP" || rollback
    /usr/bin/ditto "$STAGED_APP" "$APP_PATH" || rollback

    state "verifying" \#(shellSingleQuoted(verifying))
    verify_app || rollback

    /bin/rm -rf "$BACKUP_APP" || true
    state "relaunching" \#(shellSingleQuoted(relaunching))
    if [ "$SHOULD_RELAUNCH" = "1" ]; then
        /usr/bin/open "$APP_PATH" || rollback
        # Службу поднимаем сами, а не надеемся, что это сделает запущенное
        # приложение: диктовка — то, ради чего Dictor стоит на машине, и
        # обновление не имеет права её потерять. Если приложение поднимет
        # службу первым, bootstrap просто вернёт ошибку «уже загружена».
        if [ -f "$AGENT_PLIST" ]; then
            /bin/sleep 2
            /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
        fi
    fi
    /bin/sleep 2
    state "complete" \#(shellSingleQuoted(complete))
    """#
}

func writePrivateUpdateHelperScript(_ script: String,
                                            directory: String = NSTemporaryDirectory(),
                                            fileName: String? = nil) throws -> String {
    guard !directory.isEmpty else { throw posixError(EINVAL) }
    let leafName = fileName ?? "dictor-update-\(UUID().uuidString).sh"
    guard !leafName.isEmpty,
          (leafName as NSString).lastPathComponent == leafName else {
        throw posixError(EINVAL)
    }

    let path = (directory as NSString).appendingPathComponent(leafName)
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(path, flags, PRIVATE_HELPER_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }

    var closed = false
    var removeOnFailure = true
    do {
        try validateSingleLinkRegularFileDescriptor(fd)
        guard Darwin.fchmod(fd, PRIVATE_HELPER_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
        try writeAllData(Data(script.utf8), to: fd)
        try validateSingleLinkRegularFileDescriptor(fd)

        let closeStatus = Darwin.close(fd)
        closed = true
        guard closeStatus == 0 else { throw currentPOSIXError() }

        removeOnFailure = false
        return path
    } catch {
        if !closed { _ = Darwin.close(fd) }
        if removeOnFailure { _ = Darwin.unlink(path) }
        throw error
    }
}

struct PrivateOutputFile {
    let path: String
    let handle: FileHandle
}

func openPrivateUpdateHelperLog(preferredPath: String = UPDATE_HELPER_LOG_PATH,
                                        fallbackDirectory: String = NSTemporaryDirectory()) throws -> PrivateOutputFile {
    do {
        let fd = try openPrivateOutputFileDescriptor(atPath: preferredPath,
                                                     exclusive: false,
                                                     removeOnFailure: false)
        return PrivateOutputFile(path: preferredPath,
                                 handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    } catch {
        let fallbackPath = (fallbackDirectory as NSString)
            .appendingPathComponent("dictor-update-\(UUID().uuidString).log")
        let fd = try openPrivateOutputFileDescriptor(atPath: fallbackPath,
                                                     exclusive: true,
                                                     removeOnFailure: true)
        return PrivateOutputFile(path: fallbackPath,
                                 handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
}

func createPrivateUpdateProgressStateFile(directory: String = NSTemporaryDirectory()) throws -> String {
    let path = (directory as NSString)
        .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).state")
    let fd = try openPrivateOutputFileDescriptor(atPath: path,
                                                 exclusive: true,
                                                 removeOnFailure: true)
    do {
        try writeAllData(Data("starting\tStarting update...\n".utf8), to: fd)
        guard Darwin.close(fd) == 0 else { throw currentPOSIXError() }
        return path
    } catch {
        _ = Darwin.close(fd)
        _ = Darwin.unlink(path)
        throw error
    }
}

func openPrivateOutputFileDescriptor(atPath path: String,
                                             exclusive: Bool,
                                             removeOnFailure: Bool) throws -> Int32 {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)

    var flags = O_WRONLY | O_CREAT | O_NOFOLLOW
    if exclusive { flags |= O_EXCL }

    let fd = Darwin.open(path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }

    do {
        try validateSingleLinkRegularFileDescriptor(fd)
        guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
        guard Darwin.ftruncate(fd, 0) == 0 else {
            throw currentPOSIXError()
        }
        return fd
    } catch {
        _ = Darwin.close(fd)
        if removeOnFailure { _ = Darwin.unlink(path) }
        throw error
    }
}
