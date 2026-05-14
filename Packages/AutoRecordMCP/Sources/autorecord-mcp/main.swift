import Foundation
import MCP
import AutoRecordMCPCore

@main
struct AutoRecordMCPMain {
    static func main() async {
        let tools = Tools()
        let server = Server(
            name: "autorecord",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        // ListTools — translate our descriptors into MCP Tool values.
        await server.withMethodHandler(ListTools.self) { _ in
            let mcpTools = tools.descriptors.map { d -> Tool in
                Tool(
                    name: d.name,
                    description: d.description,
                    inputSchema: jsonToValue(d.inputSchema)
                )
            }
            return ListTools.Result(tools: mcpTools)
        }

        // CallTool — flatten arguments to [String: Any], dispatch through Tools,
        // map ToolError into MCP error responses.
        await server.withMethodHandler(CallTool.self) { params in
            let args = valueDictToAny(params.arguments ?? [:])
            do {
                let text = try tools.call(name: params.name, arguments: args)
                return CallTool.Result(
                    content: [.text(text: text, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch let err as ToolError {
                let body = #"{"code":"\#(err.code)","message":"\#(escape(err.message))"}"#
                return CallTool.Result(
                    content: [.text(text: body, annotations: nil, _meta: nil)],
                    isError: true
                )
            } catch {
                let body = #"{"code":"io_error","message":"\#(escape(String(describing: error)))"}"#
                return CallTool.Result(
                    content: [.text(text: body, annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        do {
            let transport = StdioTransport()
            try await server.start(transport: transport)
            // Block until the transport's read loop ends (stdin closes).
            await server.waitUntilCompleted()
        } catch {
            fputs("autorecord-mcp: fatal: \(error)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - Value helpers

/// Convert the SDK's Value enum tree into Swift Any/Dictionary so we can hand
/// it to our `Tools.call(arguments:)` API.
private func valueDictToAny(_ dict: [String: Value]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in dict {
        out[k] = valueToAny(v)
    }
    return out
}

private func valueToAny(_ v: Value) -> Any {
    if let s = v.stringValue { return s }
    if let i = v.intValue { return i }
    if let d = v.doubleValue { return d }
    if let b = v.boolValue { return b }
    if let arr = v.arrayValue { return arr.map(valueToAny) }
    if let obj = v.objectValue {
        var d: [String: Any] = [:]
        for (k, e) in obj { d[k] = valueToAny(e) }
        return d
    }
    return NSNull()
}

/// Convert a Swift dict-of-Any (our descriptor inputSchema) into a Value tree
/// the SDK can carry on the wire.
private func jsonToValue(_ any: Any) -> Value {
    if let s = any as? String { return .string(s) }
    if let b = any as? Bool   { return .bool(b) }
    if let i = any as? Int    { return .int(i) }
    if let d = any as? Double { return .double(d) }
    if let arr = any as? [Any] { return .array(arr.map(jsonToValue)) }
    if let obj = any as? [String: Any] {
        var d: [String: Value] = [:]
        for (k, v) in obj { d[k] = jsonToValue(v) }
        return .object(d)
    }
    return .null
}

private func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
     .replacingOccurrences(of: "\n", with: "\\n")
}
