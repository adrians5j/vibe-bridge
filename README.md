# Vibe Bridge

A local event bus for my Mac apps, living in the menu bar. One app publishes an event ("email received"), and any app that subscribed to that type gets it, even if it was closed when the event happened.

The first use: gmail-bar publishes `email.received` with PDF and image attachments, and Računi files the ones that look like bills.

## Build and install

Needs the Swift toolchain, macOS 13 or newer.

```sh
./build.sh           # builds build/VibeBridge.app
./build.sh install   # also copies it to ~/Applications and launches it
```

Tick "Launch at login" in the popover after installing.

## How it works

- **Publishing** writes a folder into `inbox/` with `event.json` and any attachment files, then renames it into place. The bridge watches that folder. A publish works while the bridge is down, and the bridge picks the event up when it starts.
- **The log** is SQLite (`events.sqlite`). Each event gets a `seq`. Its `id` is unique, so publishing the same id twice stores it once. gmail-bar uses `gmail:<account>:<message id>`, so a repeat is harmless.
- **Consumers** long-poll `GET /poll` with a name and the types they want, and ack each event after handling it. The bridge stores each consumer's cursor. A closed app catches up when it next launches. A new consumer starts at the end of the log and doesn't get history.
- **Delivery** is at-least-once. If an app quits mid-handler, it sees that event again, so handlers have to tolerate repeats. Računi already ignores a file it has attached before.
- **Attachments** move to `files/<folder>/` and the event carries absolute paths. Consumers read the files directly, so they should copy anything they keep.
- **Retention** is 30 days (`VB_RETENTION_DAYS`). Older events and their files are deleted.

The HTTP server binds 127.0.0.1 only. It refuses any request with an `Origin` header, which keeps web pages from posting to it.

## Using it from a Swift app

Add the package and depend on `VibeBridgeKit`:

```swift
dependencies: [.package(path: "../vibe-bridge")],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "VibeBridgeKit", package: "vibe-bridge")]
    )
]
```

Publish:

```swift
try VibeBridge.publish(type: EmailReceived.type, source: "gmail-bar",
                       id: "gmail:\(account):\(id)", data: payload,
                       files: [VibeBridge.File(name: "racun.pdf", mime: "application/pdf", data: bytes)])
```

Subscribe (keep the task if you want to cancel it later):

```swift
let task = VibeBridge.subscribe(consumer: "racuni", types: ["email.received"]) { event in
    let mail = try? event.decode(EmailReceived.self)
    for file in event.attachments { /* file.url */ }
}
```

Types match exactly, or by prefix with `email.*`. Put shared payload structs in `Sources/VibeBridgeKit/Events.swift`. Then publisher and consumer compile against the same fields, and a rename breaks the build instead of dropping data.

## Using it from anything else

Rust (tide), scripts or curl can use HTTP on port 47400:

```sh
# publish (attachments are base64)
curl -X POST localhost:47400/events -H 'content-type: application/json' \
  -d '{"type":"agent.done","source":"tide","data":{"pane":"3"}}'

# recent events
curl localhost:47400/events?limit=10

# wait up to 25s for something for consumer "x"
curl 'localhost:47400/poll?consumer=x&types=email.*&wait=25'
curl -X POST localhost:47400/ack -d '{"consumer":"x","seq":12}'

# redeliver everything after seq 10
curl -X POST localhost:47400/rewind -d '{"consumer":"x","seq":10}'

curl localhost:47400/consumers
```

## Events in use

| Type | Publisher | Consumers | Data |
|------|-----------|-----------|------|
| `email.received` | gmail-bar | racuni | `EmailReceived`: account, ids, from, subject, snippet, date, Gmail link, `filtered`. PDF and image attachments, up to 15 MB each. |
| `post.drafted` | IDE sessions | content-planner | `PostDrafted`: space, day, title, body, status. Image and video attachments become the post's assets. Content Planner overwrites whatever sits on that day. |

## Where things live

`~/Library/Application Support/VibeBridge/` (override with `VB_DATA_DIR`)

- `events.sqlite`: the log and consumer cursors
- `inbox/`: events waiting to be ingested. A folder that failed to parse is renamed to `.bad-*` and left there.
- `files/`: attachments

The port is 47400, or `VB_PORT`. Both env vars apply to the apps using `VibeBridgeKit` too, which is how the tests point everything at a scratch bridge.

## Code

- `Sources/VibeBridgeKit/`: the client library, plus the shared event types
- `Sources/VibeBridge/EventLog.swift`: SQLite storage
- `Sources/VibeBridge/Hub.swift`: inbox ingest, long-poll delivery, cursors, pruning
- `Sources/VibeBridge/HTTPServer.swift`: a small HTTP/1.1 server on Network.framework
- `Sources/VibeBridge/Routes.swift`: the endpoints
- `Sources/VibeBridge/Views.swift`: the popover
