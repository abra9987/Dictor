// Раздел «Словарь» и правка замен: диалог новой замены, импорт и экспорт
// файла словаря, синхронизация через файл на диске.

import AppKit

extension DictorControlPanelApp {
    @objc private func addCorrectionFromPanel(_ sender: NSButton) {
        _ = presentCorrectionDialog(heard: "")
        refresh(force: true)
    }

    /// Диалог новой автозамены. `heard` подставляется в первое поле, когда
    /// слово пришло из выделения в «Истории»: человек уже показал его пальцем,
    /// просить набрать заново незачем.
    ///
    /// Возвращает добавленную запись или nil, если человек отменил, оставил
    /// поле пустым или такая замена уже есть. Вызывающий сам решает, как
    /// подтвердить — в «Словаре» новая строка видна сразу, а в «Истории»
    /// подтверждать надо на кнопке.
    @discardableResult
    private func presentCorrectionDialog(heard: String) -> TranscriptCorrection? {
        let alert = NSAlert()
        alert.messageText = t("Новая автозамена", "New correction")
        alert.informativeText = t(
            "Что слышит модель — и что должно быть в тексте. Слово находится "
            + "целиком и в любом регистре, а подставляется ровно так, как "
            + "написано справа. Одна запись чинит одну форму слова: для падежей "
            + "добавьте отдельные записи.",
            "What the model hears — and what the text should say. The word is "
            + "matched whole and in any case, and is replaced exactly as written "
            + "on the right. One entry fixes one form of a word: add separate "
            + "entries for other forms.")
        let sourceField = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        sourceField.placeholderString = t("слышится («супер диктант»)", "heard (“super dictate”)")
        sourceField.stringValue = heard
        let replacementField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        replacementField.placeholderString = t("должно быть (Dictor)", "should be (Dictor)")
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        holder.addSubview(sourceField)
        holder.addSubview(replacementField)
        alert.accessoryView = holder
        alert.addButton(withTitle: t("Добавить", "Add"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        // Курсор туда, где человеку есть что печатать: услышанное уже стоит.
        alert.window.initialFirstResponder = heard.isEmpty ? sourceField : replacementField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let source = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !replacement.isEmpty else { return nil }

        let existing = settings.transcriptCorrections
        // `normalizedTranscriptCorrections` схлопнет дубликат молча, и человек
        // решит, что добавление не сработало. Говорим прямо.
        if let clash = existing.first(where: { $0.source.lowercased() == source.lowercased() }) {
            guard confirmCorrectionOverwrite(source: source,
                                             from: clash.replacement,
                                             to: replacement) else { return nil }
        }
        let entry = TranscriptCorrection(source: source, replacement: replacement)
        settings.transcriptCorrections = normalizedTranscriptCorrections(existing + [entry])
        // Содержимое пары в лог не пишется: хвост лога дословно попадает в
        // отчёт диагностики, который обещает «text-correction contents are
        // not included», — и человек прикладывает его к публичным issue.
        log("dictionary: correction added (\(source.count) chars → \(replacement.count) chars)")
        return entry
    }

    private func confirmCorrectionOverwrite(source: String, from: String, to: String) -> Bool {
        guard from != to else { return false }
        let alert = NSAlert()
        alert.messageText = t("«\(source)» уже есть в словаре", "«\(source)» is already in the dictionary")
        alert.informativeText = t("Сейчас заменяется на «\(from)». Заменить на «\(to)»?",
                                  "It is currently replaced with «\(from)». Change it to «\(to)»?")
        alert.addButton(withTitle: t("Заменить", "Replace"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// «В словарь» из «Истории» — из кнопки в шапке или из контекстного меню
    /// текста. Без выделения открывает пустой диалог: кнопка, которая молчит
    /// в ответ на нажатие, читается как сломанная.
    @objc func addHistorySelectionToDictionary(_ sender: Any?) {
        let heard = (historyDetailTranscriptView?.selectedText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let added = presentCorrectionDialog(heard: heard)
        guard let added else { return }
        if let button = sender as? SDSecondaryButton {
            button.flashTitle(t("Добавлено", "Added"),
                              revertingTo: t("В словарь", "To dictionary"))
        } else {
            // Из контекстного меню подтверждать негде — кнопки под рукой нет.
            let done = NSAlert()
            done.messageText = t("Добавлено в словарь", "Added to the dictionary")
            done.informativeText = t("«\(added.source)» → «\(added.replacement)». "
                                     + "Замена сработает в следующих диктовках.",
                                     "«\(added.source)» → «\(added.replacement)». "
                                     + "It will apply to the next dictations.")
            done.addButton(withTitle: "OK")
            done.runModal()
        }
        // Окно намеренно не пересобирается: «История» от новой записи в
        // словаре не меняется, а пересборка заменила бы кнопку вместе с
        // подтверждением, которое на ней только что появилось. Словарь
        // перечитает настройки, когда человек туда перейдёт.
    }

    @objc private func removeCorrectionFromPanel(_ sender: NSButton) {
        var corrections = settings.transcriptCorrections
        guard corrections.indices.contains(sender.tag) else { return }
        corrections.remove(at: sender.tag)
        settings.transcriptCorrections = corrections
        refresh(force: true)
    }

    // MARK: - Перенос и синхронизация словаря
    //
    // Окно только читает и пишет файлы и настройки; сам цикл синхронизации
    // (таймер, слияние, конфликты) живёт в службе, которая подхватывает
    // смену пути через наблюдатель настроек. Порядок в настройке важен:
    // сначала файл, потом словарь, потом путь — служба не должна увидеть
    // путь раньше, чем файл готов.

    @objc func importDictionaryFromPanel(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.title = t("Импорт словаря", "Import Dictionary")
        panel.message = t("Выберите файл автозамен Dictor.",
                          "Choose a Dictor corrections file.")
        panel.prompt = t("Импортировать", "Import")
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try TranscriptCorrectionsTransfer.readCounted(from: url)
            guard let choice = chooseDictionaryImportMode(imported: imported.corrections,
                                                          originalCount: imported.originalCount,
                                                          sourceName: url.lastPathComponent,
                                                          allowsEmptyReplace: false) else {
                return
            }
            let next = transcriptCorrections(afterApplying: imported.corrections,
                                             to: settings.transcriptCorrections,
                                             mode: choice)
            guard storeDictionaryFromPanel(next) else { return }
            log("dictionary: panel import read \(imported.corrections.count) corrections")
            refresh(force: true)
        } catch {
            showDictionaryTransferError(title: t("Импорт не удался", "Import Failed"),
                                        error: error)
        }
    }

    @objc func exportDictionaryFromPanel(_ sender: NSButton) {
        let panel = NSSavePanel()
        panel.title = t("Экспорт словаря", "Export Dictionary")
        panel.message = t("Файл можно переслать, положить в iCloud Drive или "
                          + "импортировать на другом Mac.",
                          "Save a file you can AirDrop, store in iCloud Drive, "
                          + "or import on another Mac.")
        panel.prompt = t("Экспортировать", "Export")
        panel.nameFieldStringValue = CORRECTIONS_FILE_NAME
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            log("dictionary: panel export wrote \(settings.transcriptCorrections.count) corrections")
        } catch {
            showDictionaryTransferError(title: t("Экспорт не удался", "Export Failed"),
                                        error: error)
        }
    }

    @objc func setUpDictionarySyncFromPanel(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = t("Синхронизация словаря", "Set Up Dictionary Sync")
        alert.informativeText = t(
            "Dictor держит автозамены в одном локальном файле. Положите его в папку, "
            + "которую синхронизирует iCloud Drive, Dropbox или Syncthing, — и словарь "
            + "станет общим для нескольких Mac без всякого аккаунта.\n\n"
            + "Dictor читает и пишет только выбранный файл.",
            "Dictor can keep corrections in one local file. Put that file in iCloud "
            + "Drive, Dropbox, Syncthing, or another synced folder to keep multiple "
            + "Macs aligned without a Dictor account.\n\n"
            + "Dictor only reads and writes the file you choose.")
        alert.addButton(withTitle: t("Создать файл", "Create Sync File"))
        alert.addButton(withTitle: t("Выбрать существующий", "Use Existing File"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            createDictionarySyncFileFromPanel()
        case .alertSecondButtonReturn:
            useExistingDictionarySyncFileFromPanel()
        default:
            return
        }
    }

    private func createDictionarySyncFileFromPanel() {
        let panel = NSSavePanel()
        panel.title = t("Создать файл синхронизации", "Create Sync File")
        panel.message = t("Выберите, где хранить файл. Лучше всего — папка, которую "
                          + "синхронизирует iCloud Drive или другой сервис.",
                          "Choose where Dictor should keep the sync file. A folder "
                          + "synced by iCloud Drive or another provider works best.")
        panel.prompt = t("Создать", "Create")
        panel.nameFieldStringValue = CORRECTIONS_FILE_NAME
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            settings.transcriptCorrectionsSyncFile = url.path
            log("dictionary: panel created sync file with "
                + "\(settings.transcriptCorrections.count) corrections")
            refresh(force: true)
        } catch {
            showDictionaryTransferError(title: t("Синхронизация не настроилась",
                                                 "Sync Setup Failed"),
                                        error: error)
        }
    }

    private func useExistingDictionarySyncFileFromPanel() {
        let panel = NSOpenPanel()
        panel.title = t("Файл синхронизации", "Choose Sync File")
        panel.message = t("Выберите существующий файл автозамен Dictor.",
                          "Choose an existing Dictor corrections file.")
        panel.prompt = t("Использовать", "Use File")
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try TranscriptCorrectionsTransfer.readCounted(from: url)
            guard let choice = chooseDictionaryImportMode(imported: imported.corrections,
                                                          originalCount: imported.originalCount,
                                                          sourceName: url.lastPathComponent,
                                                          allowsEmptyReplace: true) else {
                return
            }
            let next = transcriptCorrections(afterApplying: imported.corrections,
                                             to: settings.transcriptCorrections,
                                             mode: choice)
            // При объединении файл переписывается до подключения: служба,
            // увидев новый путь, читает файл как истину, и результат слияния
            // обязан уже лежать в нём.
            if choice == .merge {
                try TranscriptCorrectionsTransfer.write(next, to: url)
            }
            guard storeDictionaryFromPanel(next) else { return }
            settings.transcriptCorrectionsSyncFile = url.path
            log("dictionary: panel linked sync file with "
                + "\(imported.corrections.count) corrections")
            refresh(force: true)
        } catch {
            showDictionaryTransferError(title: t("Синхронизация не настроилась",
                                                 "Sync Setup Failed"),
                                        error: error)
        }
    }

    @objc func stopDictionarySyncFromPanel(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Отключить синхронизацию словаря?",
                              "Stop Syncing the Dictionary?")
        alert.informativeText = t("Автозамены на этом Mac сохранятся. Сам файл "
                                  + "синхронизации не удаляется.",
                                  "Dictor will keep the corrections already on this "
                                  + "Mac. The sync file will not be deleted.")
        alert.addButton(withTitle: t("Отключить", "Stop Syncing"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        settings.transcriptCorrectionsSyncFile = ""
        refresh(force: true)
    }

    private func chooseDictionaryImportMode(imported: [TranscriptCorrection],
                                            originalCount: Int,
                                            sourceName: String,
                                            allowsEmptyReplace: Bool) -> CorrectionImportChoice? {
        let imported = normalizedTranscriptCorrections(imported)
        if imported.isEmpty {
            let alert = NSAlert()
            alert.messageText = t("В файле нет автозамен", "No Text Corrections Found")
            alert.informativeText = allowsEmptyReplace
                ? t("В файле «\(sourceName)» нет ни одной автозамены. Его всё равно "
                    + "можно использовать как пустой файл синхронизации.",
                    "\(sourceName) does not contain any corrections. You can still "
                    + "use it as an empty sync file.")
                : t("В файле «\(sourceName)» нет ни одной автозамены.",
                    "\(sourceName) does not contain any corrections to import.")
            alert.addButton(withTitle: allowsEmptyReplace
                            ? t("Использовать пустой файл", "Use Empty File")
                            : "OK")
            if allowsEmptyReplace { alert.addButton(withTitle: t("Отмена", "Cancel")) }
            let response = alert.runModal()
            return allowsEmptyReplace && response == .alertFirstButtonReturn ? .replace : nil
        }

        let summary = correctionImportSummary(existing: settings.transcriptCorrections,
                                              imported: imported)
        let countText = correctionImportCountText(sourceName: sourceName,
                                                  originalCount: originalCount,
                                                  keptCount: summary.total,
                                                  language: language)
        let mergeCapWarning = correctionImportMergeCapWarningText(
            existingCount: settings.transcriptCorrections.count,
            newCount: summary.newCount,
            language: language
        )
        let alert = NSAlert()
        alert.messageText = t("Импортировать автозамены?", "Import Text Corrections?")
        alert.informativeText = t("""
            \(countText)

            Новых: \(summary.newCount) · обновят существующие: \(summary.updatedCount) · уже совпадают: \(summary.unchangedCount).

            «Объединить» сохранит записи этого Mac, которых нет в файле. «Заменить все» сделает словарь точной копией файла.\(mergeCapWarning.map { "\n\n" + $0 } ?? "")
            """, """
            \(countText)

            \(summary.newCount) new, \(summary.updatedCount) will update existing corrections, \(summary.unchangedCount) already match.

            Merge keeps local corrections that are not in the file. Replace All makes this Mac match the file exactly.\(mergeCapWarning.map { "\n\n" + $0 } ?? "")
            """)
        alert.addButton(withTitle: t("Объединить", "Merge"))
        alert.addButton(withTitle: t("Заменить все", "Replace All"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    /// Пишет словарь и говорит вслух, если запись не удалась: молча
    /// пропавший импорт выглядит как потеря данных.
    private func storeDictionaryFromPanel(_ corrections: [TranscriptCorrection]) -> Bool {
        guard let error = settings.storeTranscriptCorrections(
            normalizedTranscriptCorrections(corrections)) else { return true }
        showDictionaryTransferError(title: t("Словарь не сохранился",
                                             "Saving Corrections Failed"),
                                    error: error)
        return false
    }

    private func showDictionaryTransferError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Раздел «Словарь»

    /// Словарь в окне (макет 5d). Пометки источника пока нет — провенанс
    /// автозамен не сохраняется, поэтому все записи показаны как ручные.
    func makeDictionarySectionView() -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        let addButton = NSButton(title: t("Добавить слово", "Add word"),
                                 target: self,
                                 action: #selector(addCorrectionFromPanel(_:)))
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 12, weight: .semibold)
        addButton.contentTintColor = SD.C.voice
        let header = makeSectionHeader(title: MainWindowSection.dictionary.title(language),
                                       accessory: addButton)

        let corrections = settings.transcriptCorrections
        let card = SDCardBackgroundView()
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false

        if corrections.isEmpty {
            let empty = panelLabel(
                t("Пока пусто. Добавьте термины, которые модель слышит неправильно.",
                  "Empty so far. Add terms the model keeps mishearing."),
                size: 12.5, color: SD.C.graphite)
            let wrapper = NSStackView(views: [empty])
            wrapper.orientation = .vertical
            wrapper.edgeInsets = NSEdgeInsets(top: 22, left: 16, bottom: 22, right: 16)
            list.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        } else {
            for (index, correction) in corrections.enumerated() {
                if index > 0 {
                    let hairline = SDHairlineView()
                    list.addArrangedSubview(hairline)
                    hairline.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                }
                let word = panelLabel(correction.replacement, size: 12.5, color: SD.C.ink)
                let badge = SDBadgeLabel(text: t("вручную", "manual"))
                let heard = panelLabel(t("слышится как «\(correction.source)»",
                                         "heard as “\(correction.source)”"),
                                       size: 11, color: SD.C.subtle)
                let remove = NSButton(title: "✕", target: self,
                                      action: #selector(removeCorrectionFromPanel(_:)))
                remove.isBordered = false
                remove.font = .systemFont(ofSize: 11)
                remove.contentTintColor = SD.C.subtle
                remove.tag = index

                let row = NSStackView(views: [word, badge, heard, NSView(), remove])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 10
                row.edgeInsets = NSEdgeInsets(top: 10, left: 13, bottom: 10, right: 13)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }

        card.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            list.topAnchor.constraint(equalTo: card.topAnchor),
            list.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        // Встроенные наборы правят текст молча, поэтому о них надо сказать
        // вслух — и дать выключить. Обе карточки устроены одинаково.
        let column = NSStackView(views: [card])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 24, right: 28)
        column.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: header.bottomAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        card.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -56).isActive = true
        return root
    }
}
