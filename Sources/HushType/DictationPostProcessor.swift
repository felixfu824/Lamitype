import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "transcription")

enum DictationPostProcessor {
    static func apply(_ raw: String) -> String {
        let rawText = raw

        // Classify once on the raw ASR text. Gates the Chinese-only stages
        // (OpenCC, ITN, punctuation strip) so they never touch JP/KO/EN.
        let script = ScriptDetector.detect(rawText)

        // Apply Traditional Chinese conversion
        let convertedText = ChineseConverter.convert(rawText)
        if convertedText != rawText {
            log.info("Traditional Chinese conversion applied in=\(rawText.count, privacy: .public)ch out=\(convertedText.count, privacy: .public)ch")
        }

        // Apply number conversion (ITN) if enabled. Deterministic regex-based
        // pass that converts Chinese numerals to Arabic digits.
        let itnResult: NumberNormalizer.Result
        if script == .zh && AppConfig.shared.numberConversionEnabled {
            itnResult = NumberNormalizer.normalize(convertedText)
            if itnResult.applied {
                log.info("ITN applied in=\(convertedText.count, privacy: .public)ch out=\(itnResult.text.count, privacy: .public)ch note=\(itnResult.note, privacy: .public)")
            } else if itnResult.note != "no-op" {
                log.debug("ITN skipped: \(itnResult.note, privacy: .public)")
            }
        } else {
            itnResult = NumberNormalizer.Result(text: convertedText, applied: false, note: "disabled")
        }

        // Apply user customized dictionary as the final post-processing step.
        // No-op if the dictionary file doesn't exist or is empty.
        let dictText = DictionaryReplacer.apply(itnResult.text)
        if dictText != itnResult.text {
            log.info("Dictionary applied in=\(itnResult.text.count, privacy: .public)ch out=\(dictText.count, privacy: .public)ch")
        }

        // Final step: strip the model's over-aggressive Chinese inline
        // punctuation. Chinese only, and last in the chain so nothing downstream
        // can re-introduce it.
        let finalText: String
        if script == .zh {
            finalText = PunctuationNormalizer.apply(dictText, mode: AppConfig.shared.punctuationMode)
            if finalText != dictText {
                log.info("Punctuation cleanup applied in=\(dictText.count, privacy: .public)ch out=\(finalText.count, privacy: .public)ch")
            }
        } else {
            finalText = dictText
        }

        return finalText
    }
}
