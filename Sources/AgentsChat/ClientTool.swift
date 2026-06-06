import Agents
import Foundation

/// A client-executed tool registered with a ``ChatSession``.
///
/// Client tools live on the device, not the server: the session sends their
/// serializable schemas (`{ name, description?, parameters? }`) as the top-level
/// `clientTools` field of every chat request body, the server merges them into
/// the model's toolset without an execute function, and when the model calls one
/// the call streams back to the client in the `input-available` state. The
/// session then runs ``execute`` and reports the result via
/// `cf_agent_tool_result`, after which the server auto-continues the turn.
///
/// Mirrors the `tools` option of the reference `useAgentChat`
/// (`packages/ai-chat/src/react.tsx`), where each entry is
/// `{ description, parameters, execute }`.
///
/// ```swift
/// let timezone = ClientTool(
///     name: "getUserTimezone",
///     description: "Get the user's timezone from their device",
///     parameters: .object(["type": .string("object")])
/// ) { _ in
///     .string(TimeZone.current.identifier)
/// }
/// ```
public struct ClientTool: Sendable {
    /// The result of executing a client tool: the output value to report.
    public typealias Execute = @Sendable (_ input: JSONValue?) async throws -> JSONValue

    /// Unique tool name. Registering another tool with the same name replaces
    /// this one.
    public let name: String

    /// Human-readable description of what the tool does, shown to the model.
    public let description: String?

    /// JSON-Schema object describing the tool's input parameters. `nil` means
    /// the server substitutes an empty `{ "type": "object" }` schema.
    public let parameters: JSONValue?

    /// Executes the tool. Receives the model-provided input (if any) and returns
    /// the output to report. A thrown error is reported to the model as the tool
    /// output (`"Error executing tool: …"`), matching the reference automatic
    /// tool resolution, so the turn auto-continues and the model can react.
    public let execute: Execute

    /// Creates a client tool.
    /// - Parameters:
    ///   - name: See ``name``.
    ///   - description: See ``description``.
    ///   - parameters: See ``parameters``.
    ///   - execute: See ``execute``.
    public init(
        name: String,
        description: String? = nil,
        parameters: JSONValue? = nil,
        execute: @escaping Execute
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.execute = execute
    }

    /// The serializable wire schema for this tool, used in `cf_agent_tool_result`
    /// frames (`clientTools` field).
    var wireSchema: ChatClientTool {
        ChatClientTool(name: name, description: description, parameters: parameters)
    }

    /// The serializable schema as a ``JSONValue`` object, omitting `nil` fields.
    var schemaJSON: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name)]
        if let description {
            object["description"] = .string(description)
        }
        if let parameters {
            object["parameters"] = parameters
        }
        return .object(object)
    }

    /// Builds the `clientTools` request-body value for a set of registered tools,
    /// preserving registration order. Mirrors `extractClientToolSchemas`.
    static func schemaJSON(of tools: [ClientTool]) -> JSONValue {
        .array(tools.map(\.schemaJSON))
    }
}
