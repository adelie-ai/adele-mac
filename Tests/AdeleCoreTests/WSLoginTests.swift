import Testing
import Foundation
@testable import AdeleCore

/// Spec: `/login` URL derivation mirrors the Rust `derive_login_url_from_ws_url`
/// (ws→http, wss→https, path=/login, query/fragment dropped).
@Suite struct WSLoginTests {
    @Test func wsBecomesHttp() {
        #expect(WSLogin.loginURL(fromWS: "ws://127.0.0.1:11339/ws")?.absoluteString == "http://127.0.0.1:11339/login")
    }

    @Test func wssBecomesHttps() {
        #expect(WSLogin.loginURL(fromWS: "wss://host.example:11339/ws")?.absoluteString == "https://host.example:11339/login")
    }

    @Test func queryAndFragmentDropped() {
        #expect(WSLogin.loginURL(fromWS: "ws://h:1/ws?token=x#frag")?.absoluteString == "http://h:1/login")
    }

    @Test func nonWebSocketSchemeRejected() {
        #expect(WSLogin.loginURL(fromWS: "http://h:1/ws") == nil)
        #expect(WSLogin.loginURL(fromWS: "not a url at all ::::") == nil)
    }
}
