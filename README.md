# HawkClient

Hawk Client for iOS/MacOS written in Swift

## Features

* Subscribe to any topics and receive notification events in flexible [swifty JSON](https://github.com/SwiftyJSON/SwiftyJSON) format
* Automatically attempts to reconnect after being disconnected
* Listens to missed heartbeats and will reconnect if needed

## Usage

### Steps

1. Create a client
2. Subscribe to a topic or topics by calling async/await method `subscribeToTopics(Set<String> topics)` this will implicitly create a channel.
3. Listen to events using the `notificationMessage` [publisher](https://developer.apple.com/documentation/combine/publisher)

    Publisher will publish `EventPayload` struct made from a `topic` and [swifty JSON](https://github.com/SwiftyJSON/SwiftyJSON) `message` attributes

```swift
    public struct EventPayload {
        public let topic: String
        public let message: JSON
    }
```

4. Listen to socket events using the `socketEvent` [publisher](https://developer.apple.com/documentation/combine/publisher)

### Example

```swift
func connectToHawk() async throws {
    let hawkClient = HawkClient(token: myAuthToken , host: "mypurecloud.com")
    let topics = try await hawkClient.subscribeToTopics(topics: Set(["v2.users.1ef53ada-ef64-4edf-a711-9970a534c7aa.presence"])))
    hawkClient.notificationMessage.sink(receiveValue: { payload in
        if payload.topic.hasSuffix(".presence") {
            // Do something with the eventBody
            payload.message["eventBody"]
        } else {
            self.logger.error("Unknown topic \(payload.topic)")
        }
    }).store(in: &cancellables)
    try hawkClient.connect()
}
```
## Install

Requires Swift 5 and Xcode 14

### Swift Package Manager

Add the project as a dependency to your Package.swift:
```swift
// swift-tools-version:4.2

import PackageDescription

let package = Package(
    name: "hawkclient-test",
    products: [
        .executable(name: "hawkclient-test", targets: ["YourTargetName"])
    ],
    dependencies: [
        .package(url: "https://github.com/hyperlink/hawk-client-swift", .upToNextMinor(from: "1.0.0"))
    ],
    targets: [
        .target(name: "YourTargetName", dependencies: ["HawkClient"], path: "./Path/To/Your/Sources")
    ]
)
```
