package main

// i18n.go — bilingual EN/RU string table (issue #1 §8).
//
// Both tables carry the identical key set; i18n_test.go pins that, so a
// missing RU key can never silently degrade a Russian run to English.

import (
	"fmt"
	"strings"
)

const (
	langEN = "en"
	langRU = "ru"
)

var messageTable = map[string]map[string]string{
	langEN: {
		"selftest.start":        "selftest: start (dry-run=%v)",
		"selftest.done":         "selftest: ok - all checks passed",
		"selftest.hold":         "selftest: hold %d ms - forward channel ready",
		"selftest.hold.got":     "selftest: hold received url %s",
		"selftest.hold.none":    "selftest: hold ended without a forwarded url",
		"mutex.acquired":        "mutex: acquired Global\\YandexPortable_SingleInstance",
		"mutex.busy":            "mutex: held by another instance - second invocation path",
		"mutex.error":           "mutex: create error: %v",
		"forward.sent":          "forward: url delivered to the running instance (%s)",
		"forward.none":          "forward: no forwarding target (no window handle) - exiting 0 (%s)",
		"forward.listen.broke":  "forward: listener unavailable - %v",
		"forward.handoff.broke": "forward: hand-off to browser.exe failed - %v",
		"second.nothing":        "second instance: no url in argv - exiting 0",
		"mode.active":           "mode: hkcu - %s",
		"mode.skip":             "mode: skip - %s",
		"policy.applied":        "policy: applied %d values to HKCU\\Software\\Policies\\YandexBrowser",
		"policy.verified":       "policy: readback ok - %d values present during run",
		"policy.restored":       "policy: cleanup - deleted=%d restored=%d untouched=%d",
		"policy.cleanup.broke":  "policy: cleanup incomplete - %v",
		"policy.readback.broke": "policy: readback mismatch - %s",
		"policy.open.broke":     "policy: cannot open HKCU view - %v",
		"prune.stale":           "prune: %s - executing",
		"prune.fresh":           "prune: %s - fast skip",
		"prune.busy":            "prune: browser running - skipped",
		"prune.executed":        "prune: executed - removed %d dir(s): %s",
		"prune.state":           "prune: state.json written (%s)",
		"launch.dll":            "launch: version.dll next to browser.exe - portable Data/Cache redirection",
		"launch.fallback":       "launch: version.dll missing - fallback flags: %s",
		"launch.cmd":            "launch: %s",
		"launch.wait":           "launch: browser exited with code %d",
		"settings.title":        "config:",
		"settings.lang":         "  language: %s",
		"settings.mode":         "  hkcu-mode: %s",
		"settings.app":          "  app-dir: %s",
		"settings.root":         "  package-root: %s",
		"settings.prune":        "  prune-days: %d",
		"settings.dryrun":       "  dry-run: %v",
		"err.findings.missing":  "findings doc missing: %s (Task 1 incomplete)",
		"err.findings.noT1":     "findings doc has no 'T1 verdict:' line: %s (Task 1 incomplete)",
	},
	langRU: {
		"selftest.start":        "самотест: старт (сухой_запуск=%v)",
		"selftest.done":         "самотест: ок - все проверки пройдены",
		"selftest.hold":         "самотест: пауза %d мс - канал пересылки готов",
		"selftest.hold.got":     "самотест: во время паузы получен адрес %s",
		"selftest.hold.none":    "самотест: пауза завершена без полученного адреса",
		"mutex.acquired":        "мьютекс: получен Global\\YandexPortable_SingleInstance",
		"mutex.busy":            "мьютекс: занят другим экземпляром - путь второго запуска",
		"mutex.error":           "мьютекс: ошибка создания: %v",
		"forward.sent":          "пересылка: адрес доставлен работающему экземпляру (%s)",
		"forward.none":          "пересылка: нет цела (нет окна) - выход 0 (%s)",
		"forward.listen.broke":  "пересылка: слушатель недоступен - %v",
		"forward.handoff.broke": "пересылка: передача в browser.exe не удалась - %v",
		"second.nothing":        "второй экземпляр: в аргументах нет адреса - выход 0",
		"mode.active":           "режим: hkcu - %s",
		"mode.skip":             "режим: пропущен - %s",
		"policy.applied":        "политики: записано %d значений в HKCU\\Software\\Policies\\YandexBrowser",
		"policy.verified":       "политики: чтение подтверждено - %d значений на месте во время работы",
		"policy.restored":       "политики: очистка - удалено=%d восстановлено=%d не тронуто=%d",
		"policy.cleanup.broke":  "политики: очистка неполная - %v",
		"policy.readback.broke": "политики: расхождение при чтении - %s",
		"policy.open.broke":     "политики: не удалось открыть HKCU - %v",
		"prune.stale":           "очистка: %s - выполняется",
		"prune.fresh":           "очистка: %s - быстрый пропуск",
		"prune.busy":            "очистка: браузер запущен - пропущено",
		"prune.executed":        "очистка: выполнено - удалено папок: %d: %s",
		"prune.state":           "очистка: записан state.json (%s)",
		"launch.dll":            "запуск: version.dll рядом с browser.exe - перенаправление Data/Cache",
		"launch.fallback":       "запуск: version.dll отсутствует - резервные флаги: %s",
		"launch.cmd":            "запуск: %s",
		"launch.wait":           "запуск: браузер завершился с кодом %d",
		"settings.title":        "настройки:",
		"settings.lang":         "  язык: %s",
		"settings.mode":         "  hkcu-режим: %s",
		"settings.app":          "  каталог_приложения: %s",
		"settings.root":         "  корень_пакета: %s",
		"settings.prune":        "  дней_до_очистки: %d",
		"settings.dryrun":       "  сухой_запуск: %v",
		"err.findings.missing":  "файл находок отсутствует: %s (задача 1 не выполнена)",
		"err.findings.noT1":     "в файле находок нет строки 'T1 verdict:': %s (задача 1 не выполнена)",
	},
}

// normalizeLang maps a user/OS language tag onto a supported table.
func normalizeLang(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", false
	}
	base := s
	if i := strings.IndexAny(s, "-_"); i > 0 {
		base = s[:i]
	}
	switch strings.ToLower(base) {
	case langEN:
		return langEN, true
	case langRU:
		return langRU, true
	}
	return "", false
}

// translate returns the localised text for key, falling back to English and
// finally to the key itself so a typo is visible instead of silent.
func translate(lang, key string) string {
	if table, ok := messageTable[lang]; ok {
		if val, ok := table[key]; ok && val != "" {
			return val
		}
	}
	if table, ok := messageTable[langEN]; ok {
		if val, ok := table[key]; ok && val != "" {
			return val
		}
	}
	return key
}

// format is translate + fmt.Sprintf.
func format(lang, key string, args ...any) string {
	return fmt.Sprintf(translate(lang, key), args...)
}
