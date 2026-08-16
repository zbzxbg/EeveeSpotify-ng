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
}
