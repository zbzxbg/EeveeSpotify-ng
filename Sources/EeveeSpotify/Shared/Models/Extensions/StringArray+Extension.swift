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
    /// 返回占比最高且高于阈值的 CJK 语言（日语/韩语/中文）；否则返回 nil。
    func dominantCJKLanguageAbove(threshold: Double) -> NLLanguage? {
        let text = self.joined(separator: "\n")
        guard !text.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)

        let cjk: [NLLanguage] = [.japanese, .korean, .simplifiedChinese, .traditionalChinese]
        // 先在 guard 外算出候选：guard/if 条件里不能使用尾随闭包，
        // 否则 { } 会被解析成新的语句（"consecutive statements..." 语法错）。
        let topCJK = hypotheses
            .filter { cjk.contains($0.key) }
            .max { $0.value < $1.value }
        guard let top = topCJK, top.value > threshold else { return nil }

        return top.key
    }
}
