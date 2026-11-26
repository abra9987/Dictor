// Обновление из окна: строка версии на вкладке «Приложение», ручная
// проверка и установка с прогрессом прямо в окне.

import AppKit

extension DictorControlPanelApp {
    /// Версия и проверка обновлений. Ни того, ни другого в интерфейсе не было:
    /// номер версии человек мог узнать только из «О программе» в меню-баре, а
    /// проверить обновления вручную — никак, оставалось ждать автоматической
    /// проверки раз в шесть часов. Для приложения, которое обновляет себя само
    /// и не лежит в App Store, это две вещи, которые спрашивают первыми.
    func versionRow() -> NSView {
        let version = monoValueLabel("v\(currentBundleVersion())")
        let button: NSButton
        let subtitle: String

        switch updateState {
        case .notChecked:
            subtitle = settings.checkForUpdates
                ? t("Проверка ещё не выполнялась", "No check has run yet")
                : t("Автопроверка выключена", "Automatic checks are off")
            button = panelButton(t("Проверить", "Check"),
                                 action: #selector(updateRowButtonClicked(_:)))
        case .checking:
            subtitle = t("Проверяю обновления…", "Checking for updates…")
            button = panelButton(t("Проверить", "Check"),
                                 action: #selector(updateRowButtonClicked(_:)),
                                 enabled: false)
        case .upToDate:
            subtitle = t("Установлена последняя версия", "This is the latest version")
            button = panelButton(t("Проверить", "Check"),
                                 action: #selector(updateRowButtonClicked(_:)))
        case .available(let release):
            subtitle = t("Доступна версия \(release.version) — скачается, проверится и установится",
                         "Version \(release.version) is available — it downloads, verifies and installs")
            button = panelButton(t("Обновить", "Update"),
                                 action: #selector(updateRowButtonClicked(_:)))
        case .preparing(let target, let phase):
            subtitle = "\(t("Обновляю до", "Updating to")) \(target): \(phase)"
            button = panelButton(t("Обновить", "Update"),
                                 action: #selector(updateRowButtonClicked(_:)),
                                 enabled: false)
        case .failed(let message):
            subtitle = message
            button = panelButton(t("Повторить", "Retry"),
                                 action: #selector(updateRowButtonClicked(_:)))
        }
        button.controlSize = .small

        let control = NSStackView(views: [version, button])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 10

        return SDRowView(title: t("Версия", "Version"),
                         subtitle: subtitle,
                         control: control,
                         style: .card)
    }

    @objc private func updateRowButtonClicked(_ sender: NSButton) {
        switch updateState {
        case .available(let release):
            beginInAppUpdate(for: release)
        case .checking, .preparing:
            return
        case .notChecked, .upToDate, .failed:
            checkForUpdates()
        }
    }

    func checkForUpdates() {
        updateTask?.cancel()
        updateState = .checking
        refresh(force: true)
        updateTask = Task { [weak self] in
            let outcome = await UpdateCheck.fetchLatest()
            guard !Task.isCancelled, let self else { return }
            self.updateTask = nil
            switch outcome {
            case .success(let release):
                self.settings.lastUpdateCheckAt = Date()
                self.settings.lastUpdateCheckSource = .manual
                self.settings.lastUpdateCheckVersion = release.version
                if isNewer(release.version, than: currentBundleVersion()) {
                    self.settings.lastUpdateCheckResult = .available
                    self.updateState = .available(release)
                } else {
                    self.settings.lastUpdateCheckResult = .upToDate
                    self.updateState = .upToDate(currentBundleVersion())
                }
            case .failure(let failure):
                self.settings.lastUpdateCheckAt = Date()
                self.settings.lastUpdateCheckSource = .manual
                self.settings.lastUpdateCheckResult = .failed
                self.updateState = .failed(self.localizedUpdateFailure(failure))
            }
            self.lastRenderFingerprint = ""
            self.refresh(force: true)
        }
    }

    /// Установка из окна. Путь тот же, что у «Update now…» в меню-баре, —
    /// `launchPreparedDictorUpdate`; отличается только тем, что ход работы
    /// видно прямо в строке настроек, а не в пункте меню.
    private func beginInAppUpdate(for release: DictorRelease) {
        guard updateTask == nil else { return }
        let version = release.version
        log("update: installing v\(version) from the window")
        updateState = .preparing(
            version: version,
            phase: t("получаю манифест…", "fetching the manifest…"))
        refresh(force: true)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await DictorUpdateInstaller.fetchManifest(
                    expectedVersion: version)
                guard !Task.isCancelled else { return }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("скачиваю…", "downloading…"))
                self.refresh(force: true)
                let prepared = try await DictorUpdateInstaller.prepare(manifest: manifest) {
                    [weak self] progress in
                    Task { @MainActor in
                        // Только пока идёт скачивание этой версии: опоздавший
                        // прогресс не должен затереть «архив проверен» или ошибку.
                        guard let self, self.updateTask != nil,
                              case .preparing(let target, let current) = self.updateState,
                              target == version,
                              current != self.t("архив проверен, ставлю…",
                                                "archive verified, installing…")
                        else { return }
                        let phase = updateDownloadPhaseText(progress, language: self.language,
                                                            capitalized: false)
                        guard self.updateState != .preparing(version: version, phase: phase)
                        else { return }
                        self.updateState = .preparing(version: version, phase: phase)
                        self.refresh(force: true)
                    }
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: prepared.workDirectory)
                    return
                }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("архив проверен, ставлю…",
                                  "archive verified, installing…"))
                self.refresh(force: true)
                // Скрипт ждёт смерти этого процесса, чтобы подменить бандл.
                // Уходим с дороги сразу после запуска.
                try launchPreparedDictorUpdate(prepared, language: self.language)
                self.updateTask = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            } catch is CancellationError {
                // Окно закрывается — это не сбой обновления, показывать нечего.
                log("update: install of v\(version) cancelled")
                self.updateTask = nil
            } catch {
                self.updateTask = nil
                log("update: install of v\(version) failed: \(error)")
                let message = (error as? DictorUpdateInstallerError)?
                    .message(language: self.language) ?? error.localizedDescription
                self.updateState = .failed(message)
                self.lastRenderFingerprint = ""
                self.refresh(force: true)
            }
        }
    }

    private func localizedUpdateFailure(_ failure: UpdateCheckFailure) -> String {
        guard language == .russian else { return manualUpdateCheckFailureText(failure) }
        switch failure {
        case .network:
            return "Не удалось связаться с сервером обновлений. Проверьте интернет и повторите попытку."
        case .httpStatus(let code):
            return "Сервер обновлений вернул ошибку HTTP \(code). Повторите попытку позже."
        case .unexpectedResponse:
            return "Сервер обновлений вернул ответ, который Dictor не смог проверить."
        }
    }
}
