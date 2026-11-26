# MeowLab i10n — Localization Hub & Portable Zig App

Відкритий портал локалізацій та портативна кросплатформна програма на **Zig** для встановлення перекладів Minecraft-модпаків, модів, шейдерів, ресурспаків та датапаків.

## Структура

- `index.html` — веб-портал `i10n` у стилі MeowLab (13 мов інтерфейсу, темна/світла тема, каталог із [`i10n-downloadform`](https://github.com/BANSAFAn/i10n-downloadform)).
- `app/` — портативна програма на **Zig** (один виконуваний файл без інсталятора для **Windows / Linux / macOS**):
  - Автоматично знаходить папки Minecraft і лаунчерів (`.minecraft`, PrismLauncher, MultiMC, XMCL, Modrinth App).
  - Встановлює переклади напряму з сервера `i10n-downloadform` **або** з будь-якого локального файлу (`.zip`, `.json`, `.lang`).
  - Вбудований MeowLab UI (`13` мов, світла/темна тема) + CLI-режим (`meowlab-i10n list`, `meowlab-i10n install <id> <dir>`, `meowlab-i10n install-local <file> <dir> <target>`).
- `.github/workflows/release-zig.yml` — автоматичний CI/CD для крос-компіляції під Windows x64, Linux x64, macOS ARM64 та macOS Intel.

## Локальна збірка Zig-програми

```bash
cd app
zig build -Doptimize=ReleaseSafe
```

Готовий портативний файл: `app/zig-out/bin/meowlab-i10n(.exe)` — не потребує встановлення.
