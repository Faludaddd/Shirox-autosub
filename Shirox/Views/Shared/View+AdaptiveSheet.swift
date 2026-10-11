import SwiftUI

private struct ShimmerModifier: ViewModifier {
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.2),
                        .init(color: .white.opacity(1.0), location: 0.5),
                        .init(color: .clear, location: 0.8),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 2)
                .offset(x: -geo.size.width + geo.size.width * 2 * offset)
            }
            .clipped()
            .mask { content }
        )
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                offset = 1
            }
        }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

extension View {
    @ViewBuilder
    func persistentSystemOverlaysHidden() -> some View {
        if #available(iOS 16, *) {
            self.persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func hideScrollContentBackground() -> some View {
        #if !os(tvOS)
        if #available(iOS 16, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func toolbarBackgroundHidden() -> some View {
        if #available(iOS 16, macOS 13, *) {
            #if os(macOS)
                self.toolbarBackground(.hidden, for: .windowToolbar)
            #else
                self.toolbarBackground(.hidden, for: .navigationBar)
            #endif
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollDismissesKeyboardImmediately() -> some View {
        if #available(iOS 16, *) {
            self.scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
    }

    /// #99 — Applies an `.ultraThinMaterial` (liquid glass) background to the
    /// tab bar so it picks up the content scrolling underneath. The
    /// `.toolbarBackground(_:for:)` API is iOS 16+ / macOS 13+ only, so this is
    /// a no-op on iOS 15. tvOS has no tab bar background API to tweak here, so
    /// it's skipped there too.
    @ViewBuilder
    func glassTabBarBackground() -> some View {
        #if !os(tvOS)
        if #available(iOS 16, macOS 13, *) {
            self
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    @ViewBuilder
    func navigationSplitViewColumnWidthIfAvailable(_ width: CGFloat) -> some View {
        if #available(iOS 16, macOS 13, *) {
            self.navigationSplitViewColumnWidth(width)
        } else {
            self
        }
    }
}

// MARK: - onChange compat
// iOS 14–16 / macOS 11–13: onChange(of:perform:) takes a single-value closure.
// iOS 17+  / macOS 14+:    the single-value form is deprecated; the preferred
//                           form passes (oldValue, newValue).
// These two overloads pick the right variant at runtime so call sites stay clean.
extension View {
    /// Use when you don't need the new value at all: `.onChangeOf(x) { reload() }`
    @ViewBuilder
    func onChangeOf<V: Equatable>(_ value: V, perform action: @escaping () -> Void) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            self.onChange(of: value) { _, _ in action() }
        } else {
            self.onChange(of: value) { _ in action() }
        }
    }

    /// Use when you need the new value: `.onChangeOf(x) { newX in use(newX) }`
    @ViewBuilder
    func onChangeOf<V: Equatable>(_ value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            self.onChange(of: value) { _, new in action(new) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}

// MARK: - NavigationLink(isActive:) compat
// NavigationLink(destination:isActive:label:) is deprecated on macOS 13 / iOS 16.
// The modern replacement is navigationDestination(isPresented:), available from the same OS.
extension View {
    /// Drop-in for the `.background(NavigationLink(isActive:) { EmptyView() })` hack.
    /// Drives push navigation from an optional: set the item to push, clear it to pop.
    @ViewBuilder
    func navigationDestinationCompat<V, D: View>(
        item: Binding<V?>,
        @ViewBuilder destination: @escaping (V) -> D
    ) -> some View {
        #if os(iOS)
        // IMPORTANT: on iOS the app shims `NavigationStack` over `NavigationView`
        // (see Shared/NavigationStack.swift), and `NavigationView` silently ignores
        // `navigationDestination(...)` — the destination builds but never pushes. Drive
        // the push with a hidden `NavigationLink(isActive:)`, which `NavigationView` honors.
        self.background(
            NavigationLink(
                destination: Group { if let v = item.wrappedValue { destination(v) } },
                isActive: Binding(
                    get: { item.wrappedValue != nil },
                    set: { if !$0 { item.wrappedValue = nil } }
                )
            ) { EmptyView() }
        )
        #else
        // macOS/tvOS use the real SwiftUI.NavigationStack via the shim.
        if #available(macOS 13, tvOS 16, *) {
            let isPresented = Binding<Bool>(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            )
            self.navigationDestination(isPresented: isPresented) {
                if let v = item.wrappedValue { destination(v) }
            }
        } else {
            self.background(
                NavigationLink(
                    destination: Group { if let v = item.wrappedValue { destination(v) } },
                    isActive: Binding(
                        get: { item.wrappedValue != nil },
                        set: { if !$0 { item.wrappedValue = nil } }
                    )
                ) { EmptyView() }
            )
        }
        #endif
    }
}

extension View {
    func adaptiveSheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    func adaptiveSheet<Item, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        self.sheet(
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            onDismiss: onDismiss
        ) {
            if let value = item.wrappedValue {
                content(value)
            }
        }
    }
}

// MARK: - Sheets that grow out of their button

extension View {
    /// Marks the button a sheet grows out of, from iOS 18 — pair it with `zoomingOut(of:in:)` on
    /// the sheet's content, under the same id. Before 18 the sheet slides up as usual.
    ///
    /// `cornerRadius` rounds the shape the sheet starts from; the default is the button's own
    /// rectangle.
    @ViewBuilder
    func zoomSource(_ id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat? = nil) -> some View {
        #if os(iOS)
        if #available(iOS 18, *) {
            if let cornerRadius {
                matchedTransitionSource(id: id, in: namespace) {
                    $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            } else {
                matchedTransitionSource(id: id, in: namespace)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// A sheet's content, growing out of the view marked with `zoomSource` under `id` — or, with
    /// `fromToolbar`, out of the button added by `toolbarZoomSource`. That one is a source only from
    /// iOS 26; before, a zoom with nothing to start from would grow from the middle of the screen,
    /// so the sheet slides up as usual instead.
    @ViewBuilder
    func zoomingOut(of id: some Hashable, in namespace: Namespace.ID, fromToolbar: Bool = false) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else if #available(iOS 18, *), !fromToolbar {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// A toolbar button a sheet grows out of — pair it with `zoomingOut(of:in:fromToolbar:)`.
    ///
    /// A toolbar item can be a zoom source only from iOS 26, so the button comes in a plain
    /// toolbar below that. A plain `zoomSource` on a view inside a toolbar item isn't found: the
    /// sheet grows from the middle of the screen.
    @ViewBuilder
    func toolbarZoomSource<Item: View>(_ id: some Hashable, in namespace: Namespace.ID,
                                       placement: ToolbarItemPlacement = .primaryAction,
                                       @ViewBuilder item: @escaping () -> Item) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            toolbar {
                ToolbarItem(placement: placement, content: item)
                    .matchedTransitionSource(id: id, in: namespace)
            }
        } else {
            toolbar { ToolbarItem(placement: placement, content: item) }
        }
        #else
        toolbar { ToolbarItem(placement: placement, content: item) }
        #endif
    }
}
