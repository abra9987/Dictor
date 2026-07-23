# Dictor

Локальная диктовка для macOS (Apple Silicon). Нажми хоткей — говори — текст
появляется там, где стоит курсор. Аудио и расшифровка не покидают Mac.

- Распознавание: Parakeet TDT v3 (CoreML, Apple Neural Engine) через FluidAudio
- Русский, английский и ещё ~17 языков; авто-определение
- История диктовок, словарь автозамен, удаление слов-паразитов
- Ни облака, ни телеметрии, ни аккаунтов

## Сборка

```bash
./scripts/build-app.sh        # → dist/Dictor.app (нужны только Xcode CLT)
```

Личный проект. Основан на открытом коде SuperDictate/Parakey (MIT, см. LICENSE
и NOTICE.md).
