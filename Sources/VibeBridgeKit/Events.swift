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

/// An IDE session drafted a build-in-public post for a given day. Content Planner
/// files it on that day, and image or video attachments become the post's assets.
///
/// `id` is the dedupe key and doubles as the link back: re-publishing the same id
/// updates the post it created rather than adding another. A natural key like
/// `cp:<space>:<day>` makes a re-run idempotent.
public struct PostDrafted: Codable, Sendable, Equatable {
    public static let type = "post.drafted"

    /// `webiny` or `personal`. Anything else is filed under webiny.
    public var space: String
    /// The day the post is planned for, `yyyy-MM-dd`.
    public var day: String
    public var title: String
    public var body: String
    /// `idea`, `draft`, `ready`, or nil for draft.
    public var status: String?

    public init(space: String = "webiny", day: String, title: String = "",
                body: String, status: String? = nil) {
        self.space = space
        self.day = day
        self.title = title
        self.body = body
        self.status = status
    }
}
