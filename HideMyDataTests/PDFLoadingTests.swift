import Testing
import Foundation
import PDFKit
@testable import HideMyData

@MainActor
@Suite("PDF loading and passwords")
struct PDFLoadingTests {
    let locked = Fixture(name: "user256", password: "userpw")

    @Test("Locked PDF with no password fails loudly and never becomes a blank document")
    func lockedCancelled() throws {
        var prompts: [(String, Bool)] = []
        let redactor = makeRedactor(password: nil) { prompts.append(($0, $1)) }
        #expect(!redactor.loadPDF(from: locked.url))
        #expect(redactor.document == nil)
        #expect(prompts.count == 1)
        #expect(prompts.first?.0 == "user256.pdf")
        #expect(prompts.first?.1 == false)
        guard case .failed(let message) = redactor.phase else {
            Issue.record("expected .failed, got \(redactor.phase)")
            return
        }
        #expect(message.contains("Password required"))
    }

    @Test("Wrong password re-prompts, flags the failed attempt, then fails on cancel")
    func lockedWrongPassword() throws {
        var answers = ["wrong-1", "wrong-2"]
        var flags: [Bool] = []
        let redactor = PDFRedactor(passwordProvider: { _, failed in
            flags.append(failed)
            return answers.isEmpty ? nil : answers.removeFirst()
        })
        #expect(!redactor.loadPDF(from: locked.url))
        #expect(flags == [false, true, true])
        #expect(redactor.document == nil)
        if case .failed = redactor.phase {} else { Issue.record("expected .failed, got \(redactor.phase)") }
    }

    @Test("A provider that never gives up is bounded")
    func lockedBounded() {
        var calls = 0
        let redactor = PDFRedactor(passwordProvider: { _, _ in calls += 1; return "nope" })
        redactor.maxPasswordAttempts = 3
        #expect(!redactor.loadPDF(from: locked.url))
        #expect(calls == 3)
    }

    @Test("Right password (also after a wrong one) opens and the content is real")
    func lockedRightPassword() throws {
        var answers = ["wrong", "userpw"]
        let redactor = PDFRedactor(passwordProvider: { _, _ in answers.isEmpty ? nil : answers.removeFirst() })
        #expect(redactor.loadPDF(from: locked.url))
        let doc = try #require(redactor.document)
        #expect(!doc.isLocked && !doc.isEncrypted)
        #expect(doc.page(at: 0)?.string?.contains(Fixture.publicHeader) == true)
        #expect(redactor.phase == .loaded)
    }

    @Test("Locked PDF via the in-memory (recents) path asks for the password too")
    func lockedFromData() throws {
        let data = try Data(contentsOf: locked.url)
        var asked = 0
        let redactor = PDFRedactor(passwordProvider: { _, _ in asked += 1; return "userpw" })
        #expect(redactor.loadPDF(data: data, originalURL: URL(fileURLWithPath: "/somewhere/user256.pdf")))
        #expect(asked == 1)
        #expect(redactor.document?.page(at: 0)?.string?.contains("123-45-6789") == true)
    }

    @Test("Owner-password PDFs open without prompting")
    func ownerPasswordNoPrompt() {
        for fixture in Fixture.permissionRestricted {
            var asked = 0
            let redactor = PDFRedactor(passwordProvider: { _, _ in asked += 1; return nil })
            #expect(redactor.loadPDF(from: fixture.url), "\(fixture)")
            #expect(asked == 0)
        }
    }

    @Test("A failed load keeps the previously open document")
    func failedLoadKeepsPrevious() throws {
        let redactor = makeRedactor(password: nil)
        #expect(redactor.loadPDF(from: Fixture(name: "plain").url))
        let before = try #require(redactor.document)
        #expect(!redactor.loadPDF(from: locked.url))
        #expect(redactor.document === before)
    }

    @Test("Garbage data fails loudly")
    func garbage() {
        let redactor = makeRedactor()
        #expect(!redactor.loadPDF(data: Data("not a pdf".utf8), originalURL: URL(fileURLWithPath: "/x/garbage.pdf")))
        #expect(redactor.document == nil)
        if case .failed = redactor.phase {} else { Issue.record("expected .failed") }
    }

    @Test("Normalizer rejects locked documents")
    func normalizerRejectsLocked() throws {
        let doc = try #require(PDFDocument(url: locked.url))
        #expect(doc.isLocked)
        #expect(throws: PDFNormalizer.Failure.locked) { try PDFNormalizer.normalize(doc) }
    }
}
