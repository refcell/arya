import SwiftUI

/// SwiftUI's `State` property wrapper under a name the `State()` macro does not shadow.
///
/// The SDK declares both a `State` macro and the `State` property wrapper; `@State` resolves to
/// the macro, whose plugin the command-line tools do not ship (decision 0020). Write
/// `@AryaState private var isOpen = false` wherever SwiftUI code would write `@State`.
public typealias AryaState<Value> = SwiftUI.State<Value>
