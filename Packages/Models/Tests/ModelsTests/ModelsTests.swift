import Testing

@testable import Models

@Test func moduleLoads() { #expect(ModelsModule.name == "Models") }
