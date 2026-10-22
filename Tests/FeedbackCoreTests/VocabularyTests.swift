import Testing
@testable import FeedbackCore

@Test func parsesPhrasesSkippingBlanksAndCommentsAndCapsAt100() {
    let text = "# domain\nAcme\n\n  Northwind  \nForma\n" + (1...120).map { "term\($0)" }.joined(separator: "\n")
    let phrases = Vocabulary.parse(text)
    #expect(phrases.prefix(3) == ["Acme", "Northwind", "Forma"])
    #expect(phrases.count == 100)
}
