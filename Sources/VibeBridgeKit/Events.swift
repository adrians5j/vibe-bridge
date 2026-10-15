import Foundation

// Shared payload types. Publisher and consumers both import these, so a field
// renamed here breaks the build instead of silently dropping data.

/// gmail-bar saw a new message in an inbox. PDF and image attachments ride along
/// as event attachments.
public struct EmailReceived: Codable, Sendable, Equatable {
    public static let type = "email.received"

    public var account: String
    public var messageId: String
    public var threadId: String
    public var fromName: String
    public var fromEmail: String
    public var subject: String
    public var snippet: String
    public var date: Date
    /// Opens the thread in Gmail.
    public var url: String
    /// Hidden by one of gmail-bar's filters. Still published, since bill senders are often filtered.
    public var filtered: Bool

    public init(account: String, messageId: String, threadId: String, fromName: String, fromEmail: String,
                subject: String, snippet: String, date: Date, url: String, filtered: Bool) {
        self.account = account
        self.messageId = messageId
        self.threadId = threadId
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.url = url
        self.filtered = filtered
    }
}
