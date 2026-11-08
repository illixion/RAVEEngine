//
//  RAVEBusAction.swift
//  RAVEModuleBus
//
//  What a module can be asked to do, described well enough that a model can be
//  offered the verbs that make sense this turn and its choice checked in code
//  before anything runs.
//

import Foundation

public enum RAVEBusValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
}

public struct RAVEBusParameter: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Free text, or one of `choices` when given.
        case string(choices: [String]?)
        case number(range: ClosedRange<Double>?)
        case bool
    }

    public let name: String
    public let kind: Kind
    public let doc: String
    public let required: Bool

    public init(_ name: String, _ kind: Kind, doc: String, required: Bool = true) {
        self.name = name
        self.kind = kind
        self.doc = doc
        self.required = required
    }
}

/// Whether an action stays on this headset or reaches beyond it.
public enum RAVEBusEffect: String, Sendable, Equatable {
    /// Changes something in this process: pauses a film, moves a screen.
    case local
    /// Touches another machine or the person's accounts (launch a game on the PC, run a
    /// command). The reader must put it through its consent gate first.
    case outward
}

public struct RAVEBusAction: Sendable, Equatable {
    /// Namespaced, lowercase: `media.pause`.
    public let id: String
    /// The module that offers it.
    public let module: String
    /// One line a model can read to decide when to use it.
    public let summary: String
    public let parameters: [RAVEBusParameter]
    public let effect: RAVEBusEffect

    public init(id: String, module: String, summary: String, parameters: [RAVEBusParameter] = [],
                effect: RAVEBusEffect = .local) {
        self.id = id
        self.module = module
        self.summary = summary
        self.parameters = parameters
        self.effect = effect
    }

    /// Nil when the arguments fit; otherwise what is wrong, in words a model can act on.
    public func validate(_ arguments: [String: RAVEBusValue]) -> String? {
        for name in arguments.keys where !parameters.contains(where: { $0.name == name }) {
            return "\(id) has no parameter \(name)."
        }
        for p in parameters {
            guard let value = arguments[p.name] else {
                if p.required { return "\(id) needs \(p.name): \(p.doc)" }
                continue
            }
            switch (p.kind, value) {
            case (.string(let choices), .string(let s)):
                if let choices, !choices.contains(s) {
                    return "\(p.name) must be one of \(choices.joined(separator: ", "))."
                }
            case (.number(let range), .number(let n)):
                if !n.isFinite { return "\(p.name) must be a number." }
                if let range, !range.contains(n) { return "\(p.name) must be within \(range.lowerBound) to \(range.upperBound)." }
            case (.bool, .bool):
                break
            default:
                return "\(p.name) has the wrong type."
            }
        }
        return nil
    }
}

public enum RAVEBusResult: Sendable, Equatable {
    /// It ran; the text, if any, says what happened, for the reader to relay.
    case done(String?)
    /// It didn't run, and why.
    case refused(String)

    public var succeeded: Bool { if case .done = self { true } else { false } }
}
