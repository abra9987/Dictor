// Обновление из меню-бара: проверка по расписанию, окно «Доступна версия»,
// напоминание позже и запуск установки. После обновления — сброс
// залипших разрешений TCC.

import AppKit

extension DictorApp {
    // MARK: - Update flow

    func startUpdateCheckLoop() {
        // Цикл был отключён, пока обновления вели на апстрим-репозиторий.
        // Теперь канал свой (UPDATE_MANIFEST_URL), а ставится только сборка,
        // подписанная нашим сертификатом (UPDATE_SIGNING_CERT_SHA1).
        guard settings.checkForUpdates else { return }
        guard updateCheckLoopTask == nil else { return }
        updateCheckLoopTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UPDATE_CHECK_FIRST_DELAY_SECONDS * 1_000_000_000))
            while !Task.isCancelled {
                await self?.tickUpdateCheck()
                try? await Task.sleep(nanoseconds: UInt64(UPDATE_CHECK_INTERVAL_SECONDS * 1_000_000_000))
            }
        }
    }

    /// Silent update check: failures are recorded in diagnostics but
    /// never alerted. Manual checks take a different path
    /// (`quickPanelCheckForUpdates`) and record `.manual` themselves.
    private func tickUpdateCheck(source: UpdateCheckSource = .automatic) async {
        guard settings.checkForUpdates else { return }
        let outcome = await UpdateCheck.fetchLatest()
        await MainActor.run {
            self.recordUpdateCheck(release: try? outcome.get(), source: source)
            guard let release = try? outcome.get() else { return }
            self.handleFetchedRelease(release, source: source)
        }
    }

    func recordUpdateCheck(release: DictorRelease?, source: UpdateCheckSource) {
        let skippedVersions = source == .manual ? [] : settings.skippedVersions
        let result = updateCheckResult(
            for: release,
            currentVersion: currentBundleVersion(),
            skippedVersions: skippedVersions
        )
        settings.lastUpdateCheckAt = Date()
        settings.lastUpdateCheckSource = source
        settings.lastUpdateCheckResult = result
        settings.lastUpdateCheckVersion = release?.version ?? ""

        let versionText = release.map { " v\($0.version)" } ?? ""
        log("update check \(source.rawValue): \(result.rawValue)\(versionText)")
    }

    func handleFetchedRelease(_ release: DictorRelease,
                                      source: UpdateCheckSource = .automatic) {
        let current = currentBundleVersion()
        guard isNewer(release.version, than: current) else { return }
        // Пропуск версии и пауза «Позже» глушат только автоматические
        // проверки. Ручную человек запускает сам — и «Установлена последняя
        // версия» при живом обновлении была ложью, а снять пропуск было
        // просто негде.
        if source != .manual {
            if settings.skippedVersions.contains(release.version) {
                log("update available (v\(release.version)) but user skipped — staying quiet")
                return
            }
            let now = Date()
            if shouldSuppressUpdateForReminder(version: release.version,
                                               reminderVersion: reminderPausedUpdateVersion,
                                               reminderUntil: reminderPausedUntil,
                                               now: now) {
                if let reminderPausedUntil {
                    log("update available (v\(release.version)) but reminder is paused until \(ISO8601DateFormatter().string(from: reminderPausedUntil))")
                }
                return
            }
            // Same version → the pause expired and the update is re-shown.
            // Newer version → it supersedes the paused one, so the stale
            // pause must not linger in diagnostics alongside the new
            // pending update. (An ACTIVE pause for this exact version
            // already returned above.)
            if shouldClearUpdateReminderPause(fetchedVersion: release.version,
                                              pausedVersion: reminderPausedUpdateVersion) {
                clearUpdateReminderPause()
            }
        }
        log("update available: \(current) → v\(release.version)")
        pendingUpdate = release
        rebuildMenu()
        if source == .manual, let existing = updateAvailableWindow {
            // Окно уже показано (и, возможно, закопано под чужими) — ручная
            // проверка обязана его поднять, а не промолчать об уже известном.
            showAppForModal()
            existing.makeKeyAndOrderFront(nil)
        } else {
            presentUpdateWindow(for: release, currentVersion: current)
        }
    }

    /// Окно с предложением обновиться. Пункт в меню-баре для этого не годился:
    /// меню открывается правым кликом по иконке в строке состояния, а до этого
    /// не додумывается почти никто — предложение обновиться существовало
    /// примерно нигде.
    func presentUpdateWindow(for release: DictorRelease, currentVersion: String) {
        guard updateAvailableWindow == nil else { return }
        let window = UpdateAvailableWindow(release: release,
                                           currentVersion: currentVersion,
                                           language: settings.interfaceLanguage)
        window.updateDelegate = self
        // Крестик обязан чистить ссылку так же, как «Позже» и «Пропустить»
        // (windowWillClose), — окно .closable, и человек им пользуется.
        window.delegate = self
        updateAvailableWindow = window
        window.center()
        showAppForModal()
        window.makeKeyAndOrderFront(nil)
        log("update window shown for v\(release.version)")
    }

    func closeUpdateWindow() {
        updateAvailableWindow?.close()
        updateAvailableWindow = nil
    }

    func buildUpdateItem(for release: DictorRelease) -> NSMenuItem {
        // Пока идёт скачивание, меню — единственное место, где видно, что
        // нажатие вообще что-то сделало: окно прогресса появляется только
        // после проверки архива, а до неё десятки мегабайт.
        if let installing = installingUpdateVersion {
            let busy = NSMenuItem(title: t("Устанавливаю Dictor v\(installing)…",
                                           "Installing Dictor v\(installing)…"),
                                  action: nil, keyEquivalent: "")
            busy.isEnabled = false
            return busy
        }

        let parent = NSMenuItem(title: t("Обновить до v\(release.version)",
                                         "Update to v\(release.version)"),
                                action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let whatsNew = NSMenuItem(title: t("Что нового…", "What's new…"),
                                  action: #selector(whatsNewClicked(_:)),
                                  keyEquivalent: "")
        whatsNew.target = self
        sub.addItem(whatsNew)

        let updateNow = NSMenuItem(title: t("Обновить сейчас…", "Update now…"),
                                   action: #selector(updateNowClicked(_:)),
                                   keyEquivalent: "")
        updateNow.target = self
        sub.addItem(updateNow)

        let remindLater = NSMenuItem(title: t("Напомнить через 24 часа", "Remind me in 24 hours"),
                                     action: #selector(remindMeLaterClicked(_:)),
                                     keyEquivalent: "")
        remindLater.target = self
        sub.addItem(remindLater)

        let skip = NSMenuItem(title: t("Пропустить v\(release.version)",
                                       "Skip v\(release.version)"),
                              action: #selector(skipVersionClicked(_:)),
                              keyEquivalent: "")
        skip.target = self
        sub.addItem(skip)

        parent.submenu = sub
        return parent
    }

    private func showReleaseNotes(for release: DictorRelease) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Dictor v\(release.version)"
        var body = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { body = "(No release notes available for this version.)" }
        else if body.count > 1500 { body = String(body.prefix(1500)) + "\n\n…" }
        alert.informativeText = body
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Open in Browser")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
           let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func whatsNewClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        showReleaseNotes(for: release)
    }

    @objc private func updateNowClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        startUpdate(for: release)
    }

    @objc private func remindMeLaterClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        pauseUpdateReminder(for: release)
    }

    @objc private func skipVersionClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        var skipped = settings.skippedVersions
        if !skipped.contains(release.version) {
            skipped.append(release.version)
            settings.skippedVersions = skipped
            log("user skipped v\(release.version); suppressing until a newer release")
        }
        pendingUpdate = nil
        clearUpdateReminderPause()
        rebuildMenu()
    }

    func pauseUpdateReminder(for release: DictorRelease) {
        setUpdateReminderPause(version: release.version,
                               until: Date().addingTimeInterval(UPDATE_REMIND_LATER_SECONDS))
        pendingUpdate = nil
        if let reminderPausedUntil {
            log("user chose remind later for v\(release.version); paused until \(ISO8601DateFormatter().string(from: reminderPausedUntil))")
        }
        rebuildMenu()
    }

    // MARK: "Remind me later" pause state
    //
    // The in-memory fields drive menu/diagnostics decisions; the
    // Settings copies survive relaunches. The pause used to be
    // memory-only, so quitting inside the 24 h window re-prompted the
    // user ~30 s after the next launch. These two helpers are the ONLY
    // write paths so memory and defaults can never disagree.

    private func setUpdateReminderPause(version: String, until: Date) {
        reminderPausedUpdateVersion = version
        reminderPausedUntil = until
        settings.updateReminderPausedVersion = version
        settings.updateReminderPausedUntil = until
    }

    private func clearUpdateReminderPause() {
        reminderPausedUpdateVersion = nil
        reminderPausedUntil = nil
        settings.updateReminderPausedVersion = nil
        settings.updateReminderPausedUntil = nil
    }

    /// Restores a persisted pause at launch. Either half missing or
    /// corrupt (the validated Settings accessors degrade those to nil)
    /// means no pause: clear the leftover half rather than carrying
    /// incoherent state.
    func restoreUpdateReminderPause() {
        guard let version = settings.updateReminderPausedVersion,
              let until = settings.updateReminderPausedUntil else {
            clearUpdateReminderPause()
            return
        }
        reminderPausedUpdateVersion = version
        reminderPausedUntil = until
    }

    func showUpdateCheckFailedAlert(_ failure: UpdateCheckFailure) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = manualUpdateCheckFailureText(failure)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// «Update now…» — единственная кнопка, ради которой писался апдейтер.
    /// До 1.1.0 она не устанавливала ничего: показывала совет выполнить в
    /// Терминале установочный скрипт из апстримового репозитория, которого в
    /// проекте давно нет. Заметно это не было, потому что цикл проверки стоял
    /// за мёртвым `return` и до кнопки нельзя было добраться.
    ///
    /// Теперь она делает то, что обещает: манифест → архив → SHA-256 →
    /// проверка подписи нашим сертификатом → подмена бандла с перезапуском.
    /// Загрузка идёт в фоне, а меню всё это время показывает, что происходит:
    /// молчание в ответ на нажатие читается как поломка.
    func startUpdate(for release: DictorRelease) {
        guard updateInstallTask == nil else { return }
        let version = release.version
        log("update: installing v\(version)")
        installingUpdateVersion = version
        rebuildMenu()
        updateAvailableWindow?.showProgress(
            localizedText("Скачиваю и проверяю архив…",
                          "Downloading and verifying the archive…",
                          language: settings.interfaceLanguage))
        updateInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manifest = try await DictorUpdateInstaller.fetchManifest(
                    expectedVersion: version)
                let prepared = try await DictorUpdateInstaller.prepare(manifest: manifest) {
                    [weak self] progress in
                    Task { @MainActor in
                        // Прогресс, доехавший после сбоя, не должен затереть
                        // текст ошибки.
                        guard let self, self.installingUpdateVersion == version else { return }
                        self.updateAvailableWindow?.showProgress(
                            updateDownloadPhaseText(progress,
                                                    language: self.settings.interfaceLanguage,
                                                    capitalized: true))
                    }
                }
                // Скрипт ждёт смерти этого процесса, чтобы заменить бандл, и
                // сам снимает службу. Уходим с дороги сразу после запуска.
                try launchPreparedDictorUpdate(prepared, language: self.settings.interfaceLanguage)
                log("update: helper started, quitting for v\(version)")
                self.updateInstallTask = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            } catch {
                self.updateInstallTask = nil
                self.installingUpdateVersion = nil
                self.rebuildMenu()
                let detail = (error as? DictorUpdateInstallerError)?
                    .message(language: self.settings.interfaceLanguage)
                    ?? error.localizedDescription
                // В журнал — при любом исходе. Раньше сбой при открытом окне
                // обновления не записывался, и отчёт о проблеме молчал.
                log("update: install of v\(version) failed: \(error)")
                if let window = self.updateAvailableWindow {
                    window.showFailure(detail)
                } else {
                    self.showUpdateCouldNotStart(version: version, detail: detail)
                }
            }
        }
    }

    private func showUpdateCouldNotStart(version: String, detail: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Dictor v\(version) was not installed"
        alert.informativeText = """
        \(detail)

        The version you have is untouched. You can try again later, or \
        download the new version yourself from \(UPDATE_CHANNEL_PAGE.absoluteString)
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Download Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(UPDATE_CHANNEL_PAGE)
        }
    }

    // MARK: - TCC stale-state recovery on upgrade

    func recoverStaleTCCAfterUpgrade() {
        let last = settings.lastSeenVersion
        let current = currentBundleVersion()
        guard !last.isEmpty else {
            // First-ever launch — just record the version. No state
            // to recover.
            settings.lastSeenVersion = current
            return
        }
        guard last != current else { return }
        log("upgrade detected: \(last) → \(current); checking for stale TCC state")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.raul.dictor"
        for p in Permission.allCases {
            if Permissions.isGranted(p) { continue }
            // Fire-and-forget on TCC's serial queue: these resets are
            // best-effort scrubbing of stale DENIED entries, nothing
            // at launch depends on their completion, and the user's
            // first Grant click has its own reset-and-retry path.
            TCC.reset(p, bundleID: bundleID)
        }
        settings.lastSeenVersion = current
    }
}
