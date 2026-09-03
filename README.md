# LiteSDK for iOS

The Lite Checkout native iOS SDK, version **0.0.1**.

Proprietary and confidential — see [LICENSE](./LICENSE). Access to this
repository does not grant permission to redistribute or disclose its contents.

This repository is generated. Source lives in `lite-sa/checkout` under
`native/LiteSDK`, and every commit here is produced by the *Release iOS SDK*
workflow. Open issues and pull requests against the monorepo.

## Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/lite-sa/lite-ios.git", from: "0.0.1"),
]
```

In Xcode: **File ▸ Add Package Dependencies…**, paste the repository URL, and
sign in with a GitHub account that has access.

## Usage

One import brings in the card fields, Apple Pay and the checkout session:

```swift
import LiteSDK
```

Requires iOS 15 or later.
