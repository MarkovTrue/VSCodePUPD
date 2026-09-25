# <img src="Preview/HeaderIcon.png" width="30" height="36" align="absmiddle" alt=""> VSCodePUPD

[![Release](https://img.shields.io/github/v/release/MarkovTrue/VSCodePUPD?label=Release&color=%238a2be2&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwYXRoIGQ9Ik0xMSAyMS43M2EyIDIgMCAwIDAgMiAwbDctNEEyIDIgMCAwIDAgMjEgMTZWOGEyIDIgMCAwIDAtMS0xLjczbC03LTRhMiAyIDAgMCAwLTIgMGwtNyA0QTIgMiAwIDAgMCAzIDh2OGEyIDIgMCAwIDAgMSAxLjczeiIvPjxwYXRoIGQ9Ik0xMiAyMlYxMiIvPjxwb2x5bGluZSBwb2ludHM9IjMuMjkgNyAxMiAxMiAyMC43MSA3Ii8%2BPC9zdmc%2B)](https://github.com/MarkovTrue/VSCodePUPD/releases) [![Downloads](https://img.shields.io/github/downloads/MarkovTrue/VSCodePUPD/total?label=Downloads&color=%230078D4&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwYXRoIGQ9Ik0yMSAxNXY0YTIgMiAwIDAgMS0yIDJINWEyIDIgMCAwIDEtMi0ydi00Ii8%2BPHBvbHlsaW5lIHBvaW50cz0iNyAxMCAxMiAxNSAxNyAxMCIvPjxsaW5lIHgxPSIxMiIgeDI9IjEyIiB5MT0iMTUiIHkyPSIzIi8%2BPC9zdmc%2B)](https://github.com/MarkovTrue/VSCodePUPD/releases)

Портативный [Visual Studio Code](https://code.visualstudio.com/docs/setup/portable) не умеет обновляться.
<br>VS Code Portable Updater берет на себя эту рутину.

![Превью](Preview/Preview.png)

### Как это работает

Вместо прямого запуска `Code.exe` запускаете `VSCodePUPD.exe` из соседней папки, можно пробросить аргументы командной строки в случае необходимости.

Утилита проверит обновления и предложит их установить.

Папка `VSCode` указывается пользователем при первом запуске, далее весь нужный контекст утилита собирает сама, и ссылку для загрузки обновлений, и путь папки пользователя для резервирования.

### Возможности

- Проверка обновлений при каждом запуске, без фонового агента и служб
- Загрузка с докачкой и проверка архива по SHA-256
- Перенос папки пользователя целиком, включая настройки и расширения
- Удаление только через корзину
- Проброс аргументов командной строки в `Code.exe`
- Восстановление после сбоя: если обновление прервалось, папка пользователя вернётся на место при следующем запуске
- Проверка блокировки папки до загрузки: держателей видно списком
- Журнал работы в `VSCodePUPD.log`

### Зависимости

Windows 10 версия 1803 или новее: программа использует `curl.exe` из состава системы. На более старых системах загрузка идёт через встроенный в AutoIt механизм, но без докачки.

