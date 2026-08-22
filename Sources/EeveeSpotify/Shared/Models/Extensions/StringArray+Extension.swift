import Foundation
import NaturalLanguage

extension Array where Element == String {
    var canBeRomanized: Bool {
        var languageList: [NLLanguage] = []
        
        for line in self {
            if let language = NLLanguageRecognizer.dominantLanguage(for: line) {
                languageList.append(language)
            }
        }
        
        return languageList.contains {
            [.japanese, .korean, .simplifiedChinese, .traditionalChinese].contains($0)
        }
    }

    /// 整首歌语言占比检测：把所有行合并后交给 NLLanguageRecognizer，
    /// 返回占比最高且高于对应阈值的 CJK 语言（日语/韩语/中文）；否则返回 nil。
    /// 日语与其它语言使用不同阈值：日语可被「更严格」开关收紧，其它语言保持宽松阈值。
    func dominantCJKLanguageAbove(japaneseThreshold: Double, otherThreshold: Double) -> NLLanguage? {
        let text = self.joined(separator: "\n")
        guard !text.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)

        let cjk: [NLLanguage] = [.japanese, .korean, .simplifiedChinese, .traditionalChinese]
        guard let top = hypotheses
            .filter { cjk.contains($0.key) }
            .max(by: { $0.value < $1.value }) else { return nil }

        let threshold = (top.key == .japanese) ? japaneseThreshold : otherThreshold
        guard top.value > threshold else { return nil }

        return top.key
    }
}
