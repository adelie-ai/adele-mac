import Testing

@testable import AdeleCore

/// The Mac client must claim its own `client-mcp.toml` surface. The Rust core is
/// shared with adele-kde and defaults to `kde`, so a missing or mistyped surface
/// silently resolves KDE's server selection instead of the Mac's.
@Suite struct McpSurfaceTests {
    @Test func macSurfaceIsMac() {
        #expect(AdeleCore.macMcpSurface == "mac")
    }

    /// Pinned against `client-common`'s `CLIENT_SURFACES` list. A surface not in
    /// that array resolves no servers at all, and the failure is silent, so the
    /// spelling is worth asserting rather than trusting.
    @Test func macSurfaceIsAKnownClientSurface() {
        let knownClientSurfaces = ["gtk", "tui", "kde", "voice", "mac"]
        #expect(knownClientSurfaces.contains(AdeleCore.macMcpSurface))
    }

    /// It must NOT be the core's default, or the whole change is a no-op.
    @Test func macSurfaceIsNotTheSharedDefault() {
        #expect(AdeleCore.macMcpSurface != "kde")
    }
}
