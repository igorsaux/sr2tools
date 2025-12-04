# sr2tools

Библиотека и инструмент для распаковки файлов игры Space Rangers HD: A War Apart.

## Использование

Распаковка (с разжатием) содержимого `common.pkg` в папку `common`:

```shell
$ sr2tools unpack DATA/common.pkg common
```

Дамп (с разжатием) в JSON содержимого `common.pkg` в файл `common.json`:

```shell
$ sr2tools dump DATA/common.pkg common.json
```

## TODO:

- [X] PKG
- [ ] DAT
- [ ] GI
- [ ] GAI
- [ ] HAI
- [ ] QM
