import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "transcription")

enum DictationPostProcessor {
    struct Options {
        let chineseConversion: Bool
        let numberConversion: Bool
        let punctuation: PunctuationMode
        static func snapshot() -> Options {
            Options(chineseConversion: AppConfig.shared.chineseConversionEnabled,
                    numberConversion: AppConfig.shared.numberConversionEnabled,
                    punctuation: AppConfig.shared.punctuationMode)
        }
    }
    static func apply(_ raw: String, options: Options? = nil) -> String {
        let options = options ?? .snapshot()
        let rawText = raw

        // Classify once on the raw ASR text. Gates the Chinese-only stages
        // (OpenCC, punctuation strip). ITN also handles English.
        let script = ScriptDetector.detect(rawText)

        // Apply Traditional Chinese conversion
        let convertedText = ChineseConverter.convert(rawText, enabled: options.chineseConversion)
        if convertedText != rawText {
            log.info("Traditional Chinese conversion applied in=\(rawText.count, privacy: .public)ch out=\(convertedText.count, privacy: .public)ch")
        }

        // One preference gates deterministic Chinese and English span conversion.
        let itnResult: NumberNormalizer.Result
        if (script == .zh || script == .other) && options.numberConversion {
            itnResult = NumberNormalizer.normalize(convertedText, script: script)
            if itnResult.applied {
                log.info("ITN applied in=\(convertedText.count, privacy: .public)ch out=\(itnResult.text.count, privacy: .public)ch note=\(itnResult.note, privacy: .public)")
            } else if itnResult.note != "no-op" {
                log.debug("ITN skipped: \(itnResult.note, privacy: .public)")
            }
        } else {
            itnResult = NumberNormalizer.Result(text: convertedText, applied: false, note: "disabled", edits: [])
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
            finalText = PunctuationNormalizer.apply(dictText, mode: options.punctuation)
            if finalText != dictText {
                log.info("Punctuation cleanup applied in=\(dictText.count, privacy: .public)ch out=\(finalText.count, privacy: .public)ch")
            }
        } else {
            finalText = dictText
        }

        return finalText
    }
}
